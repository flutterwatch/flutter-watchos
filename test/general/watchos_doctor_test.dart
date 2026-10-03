// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';

import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/os.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/base/version.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/doctor_validator.dart';
import 'package:flutter_tools/src/ios/xcodeproj.dart';
import 'package:flutter_tools/src/macos/xcode.dart';
import 'package:flutter_watchos/watchos_auth.dart';
import 'package:flutter_watchos/watchos_cache.dart';
import 'package:flutter_watchos/watchos_doctor.dart';
import 'package:test/fake.dart';

import '../src/common.dart';
import '../src/fake_process_manager.dart';
import '../src/fakes.dart';

// The CLI checkout the tests pretend to run from (Cache.flutterRoot is set to
// its flutter/ in setUp), so the engine is looked up where precache puts it:
//   /cli/flutter/                              ← Cache.flutterRoot
//   /cli/engine_artifacts/watchos_debug_sim_arm64/
FakePlatform _makePlatform({Map<String, String>? environment}) => FakePlatform(
  script: Uri.file('/cli/bin/cache/flutter-watchos.snapshot'),
  environment: environment ?? <String, String>{'HOME': '/home/u'},
);

// The hardware every other test assumes: an arm64 Mac in a native shell.
FakeOperatingSystemUtils _appleSilicon() =>
    FakeOperatingSystemUtils(hostPlatform: HostPlatform.darwin_arm64);

MemoryFileSystem _makeEngineFs({bool artifactsPresent = true}) {
  final fs = MemoryFileSystem.test();
  if (artifactsPresent) {
    fs.directory('/cli/engine_artifacts/watchos_debug_sim_arm64').createSync(recursive: true);
  }
  return fs;
}

/// A cached Xcode as stock reads it from `xcodebuild -version`; null
/// [version] is no Xcode at all.
Xcode _xcode([
  Version? version = const Version.withText(27, 0, 0, '27.0'),
  String build = '27A266a',
]) => Xcode.test(
  processManager: FakeProcessManager.any(),
  xcodeProjectInterpreter: XcodeProjectInterpreter.test(
    processManager: FakeProcessManager.any(),
    version: version,
    build: build,
  ),
);

FakeCommand _watchosSdk(String sdkName) => FakeCommand(
  command: const <String>['xcrun', '--sdk', 'watchos', '--show-sdk-path'],
  stdout:
      '/Applications/Xcode.app/Contents/Developer/Platforms/WatchOS.platform/Developer/SDKs/$sdkName',
);
final FakeCommand _watchosSdkOk = _watchosSdk('WatchOS27.0.sdk');

/// `simctl list runtimes --json` output listing [runtimes], each a map of the
/// keys simctl prints.
FakeCommand _runtimes(List<Map<String, Object>> runtimes) => FakeCommand(
  command: const <String>['xcrun', 'simctl', 'list', 'runtimes', '--json'],
  stdout: jsonEncode(<String, Object>{'runtimes': runtimes}),
);

Map<String, Object> _watchosRuntime(String version, {bool? isAvailable}) => <String, Object>{
  'name': 'watchOS $version',
  'version': version,
  'platform': 'watchOS',
  'identifier': 'com.apple.CoreSimulator.SimRuntime.watchOS-${version.replaceAll('.', '-')}',
  'isAvailable': ?isAvailable,
};

final FakeCommand _runtimeOk = _runtimes(<Map<String, Object>>[
  _watchosRuntime('26.5', isAvailable: true),
  _watchosRuntime('27.0', isAvailable: true),
]);

const FakeCommand _podOk = FakeCommand(command: <String>['pod', '--version'], stdout: '1.15.2');

List<String> _texts(ValidationResult r) =>
    r.messages.map((ValidationMessage m) => m.message).toList();

void main() {
  late FakeProcessManager processManager;

  setUp(() {
    processManager = FakeProcessManager.empty();
    Cache.flutterRoot = '/cli/flutter';
  });

  group('WatchosValidator', () {
    testWithoutContext('success when all checks pass', () async {
      processManager.addCommands(<FakeCommand>[_watchosSdkOk, _runtimeOk, _podOk]);

      final validator = WatchosValidator(
        processManager: processManager,
        xcode: _xcode(),
        fileSystem: _makeEngineFs(),
        platform: _makePlatform(),
        operatingSystemUtils: _appleSilicon(),
      );

      final ValidationResult result = await validator.validate();
      expect(result.type, equals(ValidationType.success));

      final List<String> messageTexts = _texts(result);
      expect(messageTexts, contains(contains('Xcode installed')));
      expect(messageTexts, contains(contains('watchOS SDK')));
      expect(messageTexts, contains(contains('watchOS Simulator runtime')));
      expect(messageTexts, contains(contains('CocoaPods')));
      expect(messageTexts, contains(contains('watchOS engine at /cli/engine_artifacts')));
      expect(processManager, hasNoRemainingExpectations);
    });

    testWithoutContext('missing when Xcode is not installed', () async {
      final validator = WatchosValidator(
        processManager: processManager,
        xcode: _xcode(null),
        fileSystem: _makeEngineFs(),
        platform: _makePlatform(),
        operatingSystemUtils: _appleSilicon(),
      );

      final ValidationResult result = await validator.validate();
      expect(result.type, equals(ValidationType.missing));
      expect(result.messages.first.message, contains('Xcode is not installed'));
      expect(processManager, hasNoRemainingExpectations);
    });

    testWithoutContext('partial when watchOS SDK is missing', () async {
      processManager.addCommands(<FakeCommand>[
        const FakeCommand(
          command: <String>['xcrun', '--sdk', 'watchos', '--show-sdk-path'],
          exitCode: 1,
        ),
        _runtimeOk,
        _podOk,
      ]);

      final validator = WatchosValidator(
        processManager: processManager,
        xcode: _xcode(),
        fileSystem: _makeEngineFs(),
        platform: _makePlatform(),
        operatingSystemUtils: _appleSilicon(),
      );

      final ValidationResult result = await validator.validate();
      expect(result.type, equals(ValidationType.partial));
      expect(_texts(result), contains(contains('watchOS SDK not found')));
    });

    testWithoutContext('partial when no watchOS Simulator runtime is installed', () async {
      processManager.addCommands(<FakeCommand>[
        _watchosSdkOk,
        const FakeCommand(
          command: <String>['xcrun', 'simctl', 'list', 'runtimes', '--json'],
          // ignore: lines_longer_than_80_chars
          stdout: '{"runtimes":[{"name":"iOS 17.0","identifier":"com.apple.CoreSimulator.SimRuntime.iOS-17-0"}]}',
        ),
        _podOk,
      ]);

      final validator = WatchosValidator(
        processManager: processManager,
        xcode: _xcode(),
        fileSystem: _makeEngineFs(),
        platform: _makePlatform(),
        operatingSystemUtils: _appleSilicon(),
      );

      final ValidationResult result = await validator.validate();
      expect(result.type, equals(ValidationType.partial));
      expect(_texts(result), contains(contains('No watchOS Simulator runtime found')));
    });

    testWithoutContext('CocoaPods missing is a hint, not a failure', () async {
      processManager.addCommands(<FakeCommand>[
        _watchosSdkOk,
        _runtimeOk,
        const FakeCommand(command: <String>['pod', '--version'], exitCode: 1),
      ]);

      final validator = WatchosValidator(
        processManager: processManager,
        xcode: _xcode(),
        fileSystem: _makeEngineFs(),
        platform: _makePlatform(),
        operatingSystemUtils: _appleSilicon(),
      );

      final ValidationResult result = await validator.validate();
      expect(result.type, equals(ValidationType.success));
      // Only a watchos/Podfile makes the build run `pod install`; plugins
      // build without CocoaPods, so the hint must not say they need it.
      final ValidationMessage hint = result.messages.singleWhere(
        (ValidationMessage m) => m.message.startsWith('CocoaPods not installed'),
      );
      expect(hint.isHint, isTrue);
      expect(hint.message, contains('only if your watchos/ folder has a Podfile'));
      expect(hint.message, contains('brew install cocoapods'));
      expect(hint.message, isNot(contains('plugins')));
    });

    testWithoutContext('absent engine artifacts is a hint, not a failure', () async {
      processManager.addCommands(<FakeCommand>[_watchosSdkOk, _runtimeOk, _podOk]);

      final validator = WatchosValidator(
        processManager: processManager,
        xcode: _xcode(),
        fileSystem: _makeEngineFs(artifactsPresent: false),
        platform: _makePlatform(),
        operatingSystemUtils: _appleSilicon(),
      );

      final ValidationResult result = await validator.validate();
      expect(result.type, equals(ValidationType.success));
      expect(_texts(result), contains(contains('engine artifacts not found')));
    });

    // The engine's host tools are arm64-only Mach-O. Before this check the
    // first sign on an Intel Mac was "bad CPU type" from gen_snapshot, a
    // gigabyte of SDK download later.
    testWithoutContext('an Intel Mac is an error', () async {
      processManager.addCommands(<FakeCommand>[_watchosSdkOk, _runtimeOk, _podOk]);

      final validator = WatchosValidator(
        processManager: processManager,
        xcode: _xcode(),
        fileSystem: _makeEngineFs(),
        platform: _makePlatform(),
        operatingSystemUtils: FakeOperatingSystemUtils(hostPlatform: HostPlatform.darwin_x64),
      );

      final ValidationResult result = await validator.validate();
      expect(result.type, equals(ValidationType.partial));
      expect(_texts(result), contains(contains('Apple Silicon Mac')));
    });

    // hostPlatform reports the hardware, so an arm64 Mac whose shell runs
    // under Rosetta passes that check and still cannot exec the tools: its
    // bootstrap downloaded an x86_64 Dart SDK. The VM's version string is
    // what gives that away.
    testWithoutContext('a Rosetta shell on Apple Silicon is an error', () async {
      processManager.addCommands(<FakeCommand>[_watchosSdkOk, _runtimeOk, _podOk]);

      final validator = WatchosValidator(
        processManager: processManager,
        xcode: _xcode(),
        fileSystem: _makeEngineFs(),
        platform: FakePlatform(
          script: Uri.file('/cli/bin/cache/flutter-watchos.snapshot'),
          version: '3.11.0 (stable) (Tue Sep 1 00:00:00 2026 +0000) on "macos_x64"',
        ),
        operatingSystemUtils: _appleSilicon(),
      );

      final ValidationResult result = await validator.validate();
      expect(result.type, equals(ValidationType.partial));
      expect(_texts(result), contains(contains('Rosetta')));
    });
  });

  // The Xcode and SDK floors, and which Simulator runtime doctor names.
  group('WatchosValidator watchOS 26 floor', () {
    Future<ValidationResult> validate({Xcode? xcode, FakeCommand? sdk, FakeCommand? runtimes}) {
      processManager.addCommands(<FakeCommand>[
        sdk ?? _watchosSdkOk,
        runtimes ?? _runtimeOk,
        _podOk,
      ]);
      return WatchosValidator(
        processManager: processManager,
        xcode: xcode ?? _xcode(),
        fileSystem: _makeEngineFs(),
        platform: _makePlatform(),
        operatingSystemUtils: _appleSilicon(),
      ).validate();
    }

    List<String> errors(ValidationResult result) => <String>[
      for (final ValidationMessage message in result.messages)
        if (message.isError) message.message,
    ];

    List<String> hints(ValidationResult result) => <String>[
      for (final ValidationMessage message in result.messages)
        if (message.isHint) message.message,
    ];

    testWithoutContext('Xcode 27.0 is named with its build, with no error', () async {
      final ValidationResult result = await validate();
      expect(result.type, ValidationType.success);
      expect(_texts(result), contains('Xcode installed (Xcode 27.0, build 27A266a)'));
      expect(errors(result), isEmpty);
      expect(processManager, hasNoRemainingExpectations);
    });

    testWithoutContext('Xcode 26.0 has no Xcode-version error', () async {
      final ValidationResult result = await validate(
        xcode: _xcode(const Version.withText(26, 0, 0, '26.0'), '17A324'),
      );
      expect(result.type, ValidationType.success);
      expect(_texts(result), contains('Xcode installed (Xcode 26.0, build 17A324)'));
      expect(errors(result), isEmpty);
    });

    testWithoutContext('Xcode 16.4 is an error that names both versions', () async {
      final ValidationResult result = await validate(
        xcode: _xcode(const Version.withText(16, 4, 0, '16.4'), '16F6'),
      );
      expect(result.type, ValidationType.partial);
      expect(errors(result), <Object>[
        allOf(contains('Xcode 26.0 or later'), contains('found Xcode 16.4')),
      ]);
    });

    testWithoutContext('an Xcode version that does not parse is named without a verdict', () async {
      final ValidationResult result = await validate(xcode: _UnparsedXcode());
      expect(result.type, ValidationType.success);
      expect(_texts(result), contains('Xcode installed (Xcode X)'));
      expect(errors(result), isEmpty);
    });

    testWithoutContext('a watchOS SDK older than 26.0 is an error', () async {
      final ValidationResult result = await validate(sdk: _watchosSdk('WatchOS11.0.sdk'));
      expect(result.type, ValidationType.partial);
      expect(_texts(result), contains('watchOS SDK 11.0 installed'));
      expect(errors(result), <Object>[
        allOf(contains('watchOS SDK 11.0 is older than watchOS 26.0'), contains('Xcode 26.0')),
      ]);
    });

    testWithoutContext(
      'watchOS SDK 26.0 passes, and an SDK path without a version is named',
      () async {
        ValidationResult result = await validate(sdk: _watchosSdk('WatchOS26.0.sdk'));
        expect(_texts(result), contains('watchOS SDK 26.0 installed'));
        expect(errors(result), isEmpty);

        result = await validate(sdk: _watchosSdk('WatchOS.sdk'));
        expect(_texts(result), contains('watchOS SDK installed'));
        expect(errors(result), isEmpty);
      },
    );

    testWithoutContext(
      'the highest available runtime is named, wherever simctl lists it',
      () async {
        for (final order in <List<String>>[
          <String>['27.0', '26.5'],
          <String>['26.5', '27.0'],
        ]) {
          final ValidationResult result = await validate(
            runtimes: _runtimes(<Map<String, Object>>[
              for (final version in order) _watchosRuntime(version, isAvailable: true),
            ]),
          );
          expect(
            _texts(result),
            contains('watchOS Simulator runtime (watchOS 27.0)'),
            reason: '$order',
          );
          expect(hints(result), isEmpty);
        }
      },
    );

    testWithoutContext('an unavailable runtime is not named', () async {
      final ValidationResult result = await validate(
        runtimes: _runtimes(<Map<String, Object>>[
          _watchosRuntime('26.5', isAvailable: true),
          <String, Object>{
            ..._watchosRuntime('27.0', isAvailable: false),
            'availabilityError': 'The runtime is not available.',
          },
        ]),
      );
      expect(_texts(result), contains('watchOS Simulator runtime (watchOS 26.5)'));
      expect(_texts(result).join('\n'), isNot(contains('watchOS 27.0')));
    });

    testWithoutContext('a runtime without isAvailable counts as available', () async {
      final ValidationResult result = await validate(
        runtimes: _runtimes(<Map<String, Object>>[
          <String, Object>{
            'name': 'watchOS 27.0',
            'identifier': 'com.apple.CoreSimulator.SimRuntime.watchOS-27-0',
          },
        ]),
      );
      expect(result.type, ValidationType.success);
      expect(_texts(result), contains('watchOS Simulator runtime (watchOS 27.0)'));
    });

    testWithoutContext('only runtimes below 26.0: the highest is named, with a hint', () async {
      final ValidationResult result = await validate(
        runtimes: _runtimes(<Map<String, Object>>[
          _watchosRuntime('10.5', isAvailable: true),
          _watchosRuntime('11.0', isAvailable: true),
        ]),
      );
      expect(_texts(result), contains('watchOS Simulator runtime (watchOS 11.0)'));
      expect(hints(result), <Object>[contains('watchOS 26.0 or later')]);
      expect(errors(result), isEmpty);
    });

    testWithoutContext(
      'only unavailable runtimes, or output that is not JSON: none found',
      () async {
        for (final runtimes in <FakeCommand>[
          _runtimes(<Map<String, Object>>[_watchosRuntime('27.0', isAvailable: false)]),
          const FakeCommand(
            command: <String>['xcrun', 'simctl', 'list', 'runtimes', '--json'],
            stdout: 'watchOS 27.0 (27.0 - 24R1) - com.apple.CoreSimulator.SimRuntime.watchOS-27-0',
          ),
        ]) {
          final ValidationResult result = await validate(runtimes: runtimes);
          expect(result.type, ValidationType.partial);
          expect(errors(result), <Object>[contains('No watchOS Simulator runtime found')]);
        }
      },
    );
  });

  // doctor is where people look when something is off, and it said nothing
  // about the account, nor about the engines a signed-out download skipped.
  group('WatchosValidator engines and account', () {
    const engineDirs = <String>[
      'watchos_debug_sim_arm64',
      'watchos_profile_arm64',
      'watchos_release_arm64',
      'host_debug_unopt',
      'host_release',
    ];

    Future<ValidationResult> validate(MemoryFileSystem fs, {FakePlatform? platform}) {
      processManager.addCommands(<FakeCommand>[_watchosSdkOk, _runtimeOk, _podOk]);
      return WatchosValidator(
        processManager: processManager,
        xcode: _xcode(),
        fileSystem: fs,
        platform: platform ?? _makePlatform(),
        operatingSystemUtils: _appleSilicon(),
      ).validate();
    }

    testWithoutContext('signed out, it says the Simulator needs no account and what is owed', () async {
      final MemoryFileSystem fs = _makeEngineFs();
      final Directory dir = fs.directory('/cli/engine_artifacts');
      writeEngineVersionStamp(dir, 'engine-0123456789ab');
      writePendingEngineZips(dir, kWatchosEngineZipNames.skip(1));

      final ValidationResult result = await validate(fs);

      expect(result.type, ValidationType.success);
      expect(result.statusInfo, 'Simulator engine, not signed in');
      expect(
        _texts(result),
        containsAll(<Object>[
          'watchOS engine engine-0123456789ab at /cli/engine_artifacts: Simulator (debug)',
          contains('Not signed in: the Simulator engine works without an account'),
          contains('Not installed yet: profile, release (they need an account'),
        ]),
      );
      // Nothing is wrong with a Simulator-only setup: no warning sign for it.
      expect(result.messages.where((ValidationMessage m) => m.isHint), isEmpty);
    });

    testWithoutContext('signed in, it names the account and never the token', () async {
      final MemoryFileSystem fs = _makeEngineFs();
      for (final dir in engineDirs) {
        fs.directory('/cli/engine_artifacts/$dir').createSync(recursive: true);
      }
      final FakePlatform platform = _makePlatform();
      writeWatchosCredentials(fs, platform, token: 'fw_secret_token', login: 'someone');

      final ValidationResult result = await validate(fs, platform: platform);

      expect(result.statusInfo, 'all engines, signed in');
      expect(_texts(result), contains('Signed in to flutterwatch.dev as someone'));
      expect(_texts(result), contains(endsWith('Simulator (debug), profile, release')));
      expect(_texts(result).join('\n'), isNot(contains('fw_secret_token')));
      expect(
        result.messages.map((ValidationMessage m) => m.piiStrippedMessage).join('\n'),
        isNot(contains('someone')),
      );
    });

    testWithoutContext('signed in with an engine still owed, it points at precache', () async {
      final MemoryFileSystem fs = _makeEngineFs();
      for (final String dir in engineDirs.take(4)) {
        fs.directory('/cli/engine_artifacts/$dir').createSync(recursive: true);
      }
      writePendingEngineZips(fs.directory('/cli/engine_artifacts'), const <String>['host_release.zip']);
      final FakePlatform platform = _makePlatform();
      writeWatchosCredentials(fs, platform, token: 'fw_secret_token');

      final ValidationResult result = await validate(fs, platform: platform);

      expect(result.statusInfo, 'Simulator and profile engines, signed in');
      expect(_texts(result), contains('Signed in to flutterwatch.dev'));
      final ValidationMessage owed = result.messages.singleWhere(
        (ValidationMessage m) => m.message.startsWith('Not installed yet'),
      );
      expect(owed.isHint, isTrue);
      expect(owed.message, contains('release'));
      expect(owed.message, contains('flutter-watchos precache'));
    });

    testWithoutContext('looks where precache does: WATCHOS_ENGINE_ARTIFACTS first', () async {
      final fs = MemoryFileSystem.test();
      for (final dir in engineDirs) {
        fs.directory('/engines/$dir').createSync(recursive: true);
      }

      final ValidationResult result = await validate(
        fs,
        platform: _makePlatform(environment: <String, String>{
          'HOME': '/home/u',
          'WATCHOS_ENGINE_ARTIFACTS': '/engines',
        }),
      );

      expect(_texts(result), contains('watchOS engine at /engines: Simulator (debug), profile, release'));
    });
  });

  // The pinned SDK sits on a detached HEAD, so stock Flutter's entry read
  // "[!] Flutter (Channel [user-branch], …)" on every install, and told people
  // to switch channel and to put the pinned SDK first on their PATH.
  group('PinnedFlutterValidator', () {
    const versionOnUnknownChannel =
        'Flutter version 3.47.4 on channel [user-branch] at /cli/flutter\n'
        'Currently on an unknown channel. Run `flutter channel` to switch to an official channel.\n'
        "If that doesn't fix the issue, try deleting the 'bin/cache/flutter.version.json' file in "
        'your Flutter SDK directory and then reinstall Flutter by following instructions at '
        'https://flutter.dev/setup.';
    const pathWarning =
        'Warning: `flutter` on your path resolves to /Users/me/sdk/flutter/bin/flutter, which is '
        'not inside your current Flutter SDK checkout at /cli/flutter. Consider adding '
        '/cli/flutter/bin to the front of your path.';
    const noDartOnPath =
        'The dart binary is not on your path. Consider adding /cli/flutter/bin to your path.';
    const intentional =
        'If those were intentional, you can disregard the above warnings; however it is '
        'recommended to use "git" directly to perform update checks and upgrades.';
    const statusInfo = 'Channel [user-branch], 3.47.4, on macOS 26.0 25A354 darwin-arm64, locale en-US';

    // The checkout the tests run from is /cli (Cache.flutterRoot is /cli/flutter).
    MemoryFileSystem checkoutFs() =>
        MemoryFileSystem.test()..file('/cli/bin/flutter-watchos').createSync(recursive: true);

    // [onPath] is what `which flutter-watchos` finds; null finds nothing.
    PinnedFlutterValidator pinned(ValidationResult stock, {FileSystem? fileSystem, String? onPath}) {
      final FileSystem fs = fileSystem ?? checkoutFs();
      return PinnedFlutterValidator(
        _FakeValidator(stock),
        operatingSystemUtils: _FakeWhich(fs, onPath),
        fileSystem: fs,
      );
    }

    ValidationResult stock(List<ValidationMessage> extra, {String status = statusInfo}) =>
        ValidationResult(ValidationType.partial, <ValidationMessage>[
          const ValidationMessage.hint(versionOnUnknownChannel),
          const ValidationMessage.hint(pathWarning),
          const ValidationMessage.hint(noDartOnPath),
          const ValidationMessage('Upstream repository https://github.com/flutter/flutter.git'),
          const ValidationMessage('Framework revision 9584c67132 (5 weeks ago), 2026-08-20'),
          ...extra,
          const ValidationMessage(intentional),
        ], statusInfo: status);

    testWithoutContext('a fresh install is [✓], and says the SDK is pinned', () async {
      final ValidationResult result = await pinned(stock(const <ValidationMessage>[])).validate();

      expect(result.type, ValidationType.success);
      expect(result.statusInfo, '3.47.4, pinned by flutter-watchos, on macOS 26.0 25A354 darwin-arm64, locale en-US');
      expect(_texts(result).first, 'Flutter version 3.47.4 at /cli/flutter, pinned by flutter-watchos');
      expect(result.messages.every((ValidationMessage m) => m.isInformation), isTrue);
      final String all = _texts(result).join('\n');
      expect(all, isNot(contains('unknown channel')));
      expect(all, isNot(contains('your path')));
      expect(all, isNot(contains('If those were intentional')));
      expect(all, contains('Framework revision 9584c67132'));
    });

    testWithoutContext('any other warning still stands, with its footer', () async {
      const nonStandardRemote =
          'Upstream repository https://example.com/flutter.git is not a standard remote.\n'
          'Set environment variable "FLUTTER_GIT_URL" to https://example.com/flutter.git to dismiss this error.';
      final ValidationResult result = await pinned(
        stock(const <ValidationMessage>[ValidationMessage.hint(nonStandardRemote)]),
      ).validate();

      expect(result.type, ValidationType.partial);
      expect(_texts(result), contains(nonStandardRemote));
      expect(_texts(result).last, intentional);
      expect(_texts(result).join('\n'), isNot(contains('your path')));
    });

    testWithoutContext('an SDK on a real channel is left as it is', () async {
      final result = ValidationResult(
        ValidationType.success,
        const <ValidationMessage>[
          ValidationMessage('Flutter version 3.47.4 on channel stable at /cli/flutter'),
        ],
        statusInfo: 'Channel stable, 3.47.4, on macOS 26.0 25A354 darwin-arm64, locale en-US',
      );
      final ValidationResult wrapped = await pinned(result).validate();

      expect(wrapped.type, ValidationType.success);
      expect(wrapped.statusInfo, result.statusInfo);
      expect(_texts(wrapped), _texts(result));
    });

    // Stock's own check for `flutter` on PATH is dropped above; this is the
    // one that matters here: an older checkout ahead of this one on PATH runs
    // instead of it.
    group('flutter-watchos on PATH', () {
      const oldCheckout = '/Users/me/sdk/flutter-watchos/bin/flutter-watchos';
      const otherCheckoutWarning =
          'Warning: `flutter-watchos` on your path resolves to $oldCheckout, not to the '
          'flutter-watchos checkout running now at /cli, so typing `flutter-watchos` runs another '
          'checkout. Consider adding /cli/bin to the front of your path.';

      testWithoutContext('another checkout is [!], named next to this one', () async {
        final MemoryFileSystem fs = checkoutFs()..file(oldCheckout).createSync(recursive: true);
        final ValidationResult result = await pinned(
          stock(const <ValidationMessage>[]),
          fileSystem: fs,
          onPath: oldCheckout,
        ).validate();

        expect(result.type, ValidationType.partial);
        expect(result.statusInfo, startsWith('3.47.4, pinned by flutter-watchos'));
        expect(_texts(result).take(2), <String>[
          'Flutter version 3.47.4 at /cli/flutter, pinned by flutter-watchos',
          otherCheckoutWarning,
        ]);
        expect(result.messages[1].type, ValidationMessageType.hint);
        // Stock's footer is about the SDK's git setup, not about PATH.
        expect(_texts(result), isNot(contains(intentional)));
      });

      testWithoutContext('the warning follows the version line wherever it is', () async {
        final MemoryFileSystem fs = checkoutFs()..file(oldCheckout).createSync(recursive: true);
        const before = ValidationMessage.hint('A message stock put before the version line');
        final ValidationResult moved = await pinned(
          ValidationResult(ValidationType.partial, <ValidationMessage>[
            before,
            ...stock(const <ValidationMessage>[]).messages,
          ], statusInfo: statusInfo),
          fileSystem: fs,
          onPath: oldCheckout,
        ).validate();
        final ValidationResult noVersionLine = await pinned(
          ValidationResult(ValidationType.partial, const <ValidationMessage>[
            ValidationMessage.error('Unable to determine the Flutter version'),
          ], statusInfo: statusInfo),
          fileSystem: fs,
          onPath: oldCheckout,
        ).validate();

        expect(_texts(moved).take(3), <String>[
          before.message,
          'Flutter version 3.47.4 at /cli/flutter, pinned by flutter-watchos',
          otherCheckoutWarning,
        ]);
        expect(_texts(noVersionLine).first, otherCheckoutWarning);
      });

      testWithoutContext('a link to another checkout is named by its target', () async {
        final MemoryFileSystem fs = checkoutFs()..file(oldCheckout).createSync(recursive: true);
        fs.link('/usr/local/bin/flutter-watchos').createSync(oldCheckout, recursive: true);

        final ValidationResult result = await pinned(
          stock(const <ValidationMessage>[]),
          fileSystem: fs,
          onPath: '/usr/local/bin/flutter-watchos',
        ).validate();

        expect(result.type, ValidationType.partial);
        expect(_texts(result)[1], otherCheckoutWarning);
      });

      testWithoutContext('this checkout adds nothing, found directly or through a link', () async {
        final MemoryFileSystem fs = checkoutFs();
        fs.link('/usr/local/bin/flutter-watchos').createSync('/cli/bin/flutter-watchos', recursive: true);

        for (final onPath in <String>['/cli/bin/flutter-watchos', '/usr/local/bin/flutter-watchos']) {
          final ValidationResult result = await pinned(
            stock(const <ValidationMessage>[]),
            fileSystem: fs,
            onPath: onPath,
          ).validate();

          expect(result.type, ValidationType.success, reason: onPath);
          expect(_texts(result).join('\n'), isNot(contains('your path')), reason: onPath);
        }
      });

      testWithoutContext('a checkout run through a link is compared by its real path', () async {
        final MemoryFileSystem fs = checkoutFs();
        fs.link('/home/u/fw').createSync('/cli', recursive: true);
        Cache.flutterRoot = '/home/u/fw/flutter';

        final ValidationResult result = await pinned(
          stock(const <ValidationMessage>[]),
          fileSystem: fs,
          onPath: '/cli/bin/flutter-watchos',
        ).validate();

        expect(result.type, ValidationType.success);
      });

      testWithoutContext('a clone inside this checkout is another checkout', () async {
        const nested = '/cli/build/flutter-watchos/bin/flutter-watchos';
        final MemoryFileSystem fs = checkoutFs()..file(nested).createSync(recursive: true);

        final ValidationResult result = await pinned(
          stock(const <ValidationMessage>[]),
          fileSystem: fs,
          onPath: nested,
        ).validate();

        expect(result.type, ValidationType.partial);
        expect(_texts(result)[1], startsWith('Warning: `flutter-watchos` on your path resolves to $nested,'));
      });

      testWithoutContext('with another stock warning, both stand and so does the footer', () async {
        const nonStandardRemote = 'Upstream repository https://example.com/flutter.git is not a standard remote.';
        final MemoryFileSystem fs = checkoutFs()..file(oldCheckout).createSync(recursive: true);
        final ValidationResult result = await pinned(
          stock(const <ValidationMessage>[ValidationMessage.hint(nonStandardRemote)]),
          fileSystem: fs,
          onPath: oldCheckout,
        ).validate();

        expect(result.type, ValidationType.partial);
        expect(_texts(result), containsAll(<String>[otherCheckoutWarning, nonStandardRemote]));
        expect(_texts(result).last, intentional);
      });

      testWithoutContext('the PII-stripped warning names no path', () async {
        final MemoryFileSystem fs = checkoutFs()..file(oldCheckout).createSync(recursive: true);
        final ValidationResult result = await pinned(
          stock(const <ValidationMessage>[]),
          fileSystem: fs,
          onPath: oldCheckout,
        ).validate();

        expect(
          result.messages[1].piiStrippedMessage,
          'Warning: `flutter-watchos` on your path resolves to another flutter-watchos checkout.',
        );
      });

      testWithoutContext('a dangling link is named as it is', () async {
        final MemoryFileSystem fs = checkoutFs();
        fs.link('/opt/bin/flutter-watchos').createSync('/gone/bin/flutter-watchos', recursive: true);

        final ValidationResult result = await pinned(
          stock(const <ValidationMessage>[]),
          fileSystem: fs,
          onPath: '/opt/bin/flutter-watchos',
        ).validate();

        expect(result.type, ValidationType.partial);
        expect(
          _texts(result)[1],
          startsWith('Warning: `flutter-watchos` on your path resolves to /opt/bin/flutter-watchos,'),
        );
      });
    });
  });

  group('WatchosWorkflow', () {
    testWithoutContext('applies to a macOS host and can list/launch devices', () {
      final workflow = WatchosWorkflow(
        operatingSystemUtils: FakeOperatingSystemUtils(hostPlatform: HostPlatform.darwin_arm64),
      );
      expect(workflow.appliesToHostPlatform, isTrue);
      expect(workflow.canLaunchDevices, isTrue);
      expect(workflow.canListDevices, isTrue);
      expect(workflow.canListEmulators, isTrue);
    });
  });
}

/// Finds [_found] as `flutter-watchos` on PATH, or nothing when it is null.
class _FakeWhich extends FakeOperatingSystemUtils {
  _FakeWhich(this._fileSystem, this._found);

  final FileSystem _fileSystem;
  final String? _found;

  @override
  File? which(String execName) {
    final String? found = _found;
    return execName == 'flutter-watchos' && found != null ? _fileSystem.file(found) : null;
  }
}

class _FakeValidator extends DoctorValidator {
  _FakeValidator(this._result) : super('Flutter');

  final ValidationResult _result;

  @override
  Future<ValidationResult> validateImpl() async => _result;
}

/// An Xcode whose `xcodebuild -version` output stock could not parse.
class _UnparsedXcode extends Fake implements Xcode {
  @override
  String? get versionText => 'Xcode X, Build version 27A266a';

  @override
  Version? get currentVersion => null;

  @override
  String? get buildVersion => null;
}
