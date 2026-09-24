// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/os.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/doctor_validator.dart';
import 'package:flutter_watchos/watchos_auth.dart';
import 'package:flutter_watchos/watchos_cache.dart';
import 'package:flutter_watchos/watchos_doctor.dart';

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

const FakeCommand _xcodeOk = FakeCommand(
  command: <String>['xcodebuild', '-version'],
  stdout: 'Xcode 16.3\nBuild version 16E140',
);
const FakeCommand _watchosSdkOk = FakeCommand(
  command: <String>['xcrun', '--sdk', 'watchos', '--show-sdk-path'],
  // ignore: lines_longer_than_80_chars
  stdout: '/Applications/Xcode.app/Contents/Developer/Platforms/WatchOS.platform/Developer/SDKs/WatchOS11.0.sdk',
);
const FakeCommand _runtimeOk = FakeCommand(
  command: <String>['xcrun', 'simctl', 'list', 'runtimes', '--json'],
  // ignore: lines_longer_than_80_chars
  stdout: '{"runtimes":[{"name":"watchOS 11.0","identifier":"com.apple.CoreSimulator.SimRuntime.watchOS-11-0"}]}',
);
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
      processManager.addCommands(<FakeCommand>[_xcodeOk, _watchosSdkOk, _runtimeOk, _podOk]);

      final validator = WatchosValidator(
        processManager: processManager,
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
      processManager.addCommand(
        const FakeCommand(command: <String>['xcodebuild', '-version'], exitCode: 1),
      );

      final validator = WatchosValidator(
        processManager: processManager,
        fileSystem: _makeEngineFs(),
        platform: _makePlatform(),
        operatingSystemUtils: _appleSilicon(),
      );

      final ValidationResult result = await validator.validate();
      expect(result.type, equals(ValidationType.missing));
      expect(result.messages.first.message, contains('Xcode is not installed'));
    });

    testWithoutContext('partial when watchOS SDK is missing', () async {
      processManager.addCommands(<FakeCommand>[
        _xcodeOk,
        const FakeCommand(
          command: <String>['xcrun', '--sdk', 'watchos', '--show-sdk-path'],
          exitCode: 1,
        ),
        _runtimeOk,
        _podOk,
      ]);

      final validator = WatchosValidator(
        processManager: processManager,
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
        _xcodeOk,
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
        _xcodeOk,
        _watchosSdkOk,
        _runtimeOk,
        const FakeCommand(command: <String>['pod', '--version'], exitCode: 1),
      ]);

      final validator = WatchosValidator(
        processManager: processManager,
        fileSystem: _makeEngineFs(),
        platform: _makePlatform(),
        operatingSystemUtils: _appleSilicon(),
      );

      final ValidationResult result = await validator.validate();
      expect(result.type, equals(ValidationType.success));
      expect(_texts(result), contains(contains('CocoaPods not installed')));
    });

    testWithoutContext('absent engine artifacts is a hint, not a failure', () async {
      processManager.addCommands(<FakeCommand>[_xcodeOk, _watchosSdkOk, _runtimeOk, _podOk]);

      final validator = WatchosValidator(
        processManager: processManager,
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
      processManager.addCommands(<FakeCommand>[_xcodeOk, _watchosSdkOk, _runtimeOk, _podOk]);

      final validator = WatchosValidator(
        processManager: processManager,
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
      processManager.addCommands(<FakeCommand>[_xcodeOk, _watchosSdkOk, _runtimeOk, _podOk]);

      final validator = WatchosValidator(
        processManager: processManager,
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
      processManager.addCommands(<FakeCommand>[_xcodeOk, _watchosSdkOk, _runtimeOk, _podOk]);
      return WatchosValidator(
        processManager: processManager,
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
