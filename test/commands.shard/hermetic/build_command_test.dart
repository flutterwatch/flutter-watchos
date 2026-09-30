// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/io.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/ios/plist_parser.dart';
import 'package:flutter_tools/src/project.dart';
import 'package:flutter_watchos/commands/build.dart';
import 'package:flutter_watchos/commands/stock_build_stub.dart';
import 'package:flutter_watchos/watchos_build_info.dart';
import 'package:flutter_watchos/watchos_mode_guidance.dart';

import '../../src/common.dart';
import '../../src/context.dart';
import '../../src/fakes.dart';
import '../../src/test_flutter_command_runner.dart';
import 'src/words.dart';

const String _flutterRoot = '/flutter-watchos/flutter';
const String _home = '/home/user';

/// One call to the build seam.
class _Build {
  _Build(this.mode, {required this.simulator});

  final BuildMode mode;
  final bool simulator;
}

void main() {
  late MemoryFileSystem fileSystem;
  late BufferLogger logger;
  late List<_Build> builds;
  late List<Map<String, Object?>> registrations;

  setUpAll(() {
    Cache.disableLocking();
  });

  setUp(() {
    fileSystem = MemoryFileSystem.test();
    logger = BufferLogger.test();
    builds = <_Build>[];
    registrations = <Map<String, Object?>>[];
    Cache.flutterRoot = _flutterRoot;

    fileSystem.file('$_flutterRoot/../bin/internal/engine.version')
      ..createSync(recursive: true)
      ..writeAsStringSync('engine-0123456789ab\n');
    final Directory project = fileSystem.directory('/project')..createSync();
    project.childFile('pubspec.yaml').writeAsStringSync('name: my_app\n');
    project.childDirectory('lib').childFile('main.dart').createSync(recursive: true);
    fileSystem.currentDirectory = project;
  });

  void signIn() {
    fileSystem.file('$_home/.flutter-watchos/credentials.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{"token": "t0k3n", "login": "someone"}');
  }

  /// The seam: records the call and leaves a built `Runner.app` behind, as
  /// the real build does.
  Future<void> fakeBuild({
    required FlutterProject project,
    required WatchosBuildInfo watchosBuildInfo,
    required String targetFile,
  }) async {
    builds.add(_Build(watchosBuildInfo.buildInfo.mode, simulator: watchosBuildInfo.simulator));
    project.directory
        .childDirectory('build')
        .childDirectory('watchos')
        .childDirectory(watchosBuildInfo.productsDirName)
        .childDirectory('Runner.app')
        .childFile('Info.plist')
        .createSync(recursive: true);
  }

  WatchosBuildCommand buildCommand({
    Future<int> Function(Uri uri, String token, Map<String, Object?> body)? post,
  }) {
    return WatchosBuildCommand(
      logger: logger,
      verboseHelp: false,
      bundleBuilder: fakeBuild,
      registryPost:
          post ??
          (Uri uri, String token, Map<String, Object?> body) async {
            registrations.add(body);
            return 200;
          },
    );
  }

  Map<Type, Generator> overrides() => <Type, Generator>{
    FileSystem: () => fileSystem,
    ProcessManager: () => FakeProcessManager.empty(),
    Platform: () =>
        FakePlatform(operatingSystem: 'macos', environment: <String, String>{'HOME': _home}),
    Logger: () => logger,
    Cache: () => Cache.test(processManager: FakeProcessManager.empty()),
    PlistParser: () => FakePlistParser(<String, Object>{
      'CFBundleIdentifier': 'com.example.watch',
      'CFBundleShortVersionString': '1.2.0',
      'CFBundleVersion': '7',
    }),
  };

  group('build watchos', () {
    testUsingContext('a release build registers once', () async {
      signIn();
      await createTestCommandRunner(
        buildCommand(),
      ).run(<String>['build', 'watchos', '--release', '--no-pub']);

      expect(builds, hasLength(1));
      expect(builds.single.mode, BuildMode.release);
      expect(builds.single.simulator, isFalse);
      expect(registrations, <Map<String, Object?>>[
        <String, Object?>{
          'bundle_id': 'com.example.watch',
          'app_version': '1.2.0+7',
          'engine_version': 'engine-0123456789ab',
          'build_mode': 'release',
        },
      ]);
      expect(logger.statusText, contains('Registered this release build of com.example.watch'));
    }, overrides: overrides());

    testUsingContext('--no-register-build never registers', () async {
      signIn();
      await createTestCommandRunner(
        buildCommand(),
      ).run(<String>['build', 'watchos', '--release', '--no-register-build', '--no-pub']);

      expect(builds, hasLength(1));
      expect(registrations, isEmpty);
    }, overrides: overrides());

    testUsingContext('a profile build never registers', () async {
      signIn();
      await createTestCommandRunner(
        buildCommand(),
      ).run(<String>['build', 'watchos', '--profile', '--no-pub']);

      expect(builds, hasLength(1));
      expect(builds.single.mode, BuildMode.profile);
      expect(registrations, isEmpty);
    }, overrides: overrides());

    testUsingContext('--simulator builds debug for the Simulator', () async {
      await createTestCommandRunner(
        buildCommand(),
      ).run(<String>['build', 'watchos', '--simulator', '--no-pub']);

      expect(builds, hasLength(1));
      expect(builds.single.mode, BuildMode.debug);
      expect(builds.single.simulator, isTrue);
      expect(registrations, isEmpty);
    }, overrides: overrides());

    for (final (List<String> args, BuildMode mode, bool simulator)
        in <(List<String>, BuildMode, bool)>[
          (<String>['--simulator', '--release'], BuildMode.release, true),
          (<String>['--simulator', '--profile'], BuildMode.profile, true),
          (<String>['--simulator', '--jit-release'], BuildMode.jitRelease, true),
          (<String>['--debug'], BuildMode.debug, false),
          (<String>['--jit-release'], BuildMode.jitRelease, false),
        ]) {
      testUsingContext('"${args.join(' ')}" is a tool exit with the guidance', () async {
        await expectLater(
          createTestCommandRunner(
            buildCommand(),
          ).run(<String>['build', 'watchos', ...args, '--no-pub']),
          throwsToolExit(
            message: watchosModeRefusal(
              command: WatchosModeCommand.build,
              mode: mode,
              simulator: simulator,
            ),
          ),
        );
        expect(builds, isEmpty);
        expect(registrations, isEmpty);
      }, overrides: overrides());
    }

    testUsingContext('a device debug build names the Simulator build', () async {
      await expectLater(
        createTestCommandRunner(
          buildCommand(),
        ).run(<String>['build', 'watchos', '--debug', '--no-pub']),
        throwsToolExit(message: 'Debug mode is not supported on a physical Apple Watch'),
      );
      expect(builds, isEmpty);
    }, overrides: overrides());

    testUsingContext('a registry failure never fails the build', () async {
      signIn();
      var attempts = 0;
      await createTestCommandRunner(
        buildCommand(
          post: (Uri uri, String token, Map<String, Object?> body) async {
            attempts++;
            throw const SocketException('offline');
          },
        ),
      ).run(<String>['build', 'watchos', '--release', '--no-pub']);

      expect(builds, hasLength(1));
      expect(attempts, 1);
      expect(logger.statusText, isNot(contains('Registered')));
      expect(logger.errorText, isEmpty);
    }, overrides: overrides());

    testUsingContext('a refused registration never fails the build', () async {
      signIn();
      await createTestCommandRunner(
        buildCommand(post: (Uri uri, String token, Map<String, Object?> body) async => 403),
      ).run(<String>['build', 'watchos', '--release', '--no-pub']);

      expect(builds, hasLength(1));
      expect(logger.statusText, isNot(contains('Registered')));
    }, overrides: overrides());
  });

  group('build watchos size analysis', () {
    /// A `watchos/` folder, so the tooling check would write the plugin
    /// list if it ran.
    File pluginList() {
      fileSystem.directory('/project/watchos').createSync();
      return fileSystem.file('/project/.flutter-plugins');
    }

    Iterable<String> sizeDirectories() => fileSystem
        .directory('/project/build')
        .listSync(recursive: true)
        .map((FileSystemEntity entity) => entity.basename)
        .where((String name) => name.startsWith('flutter_size_'));

    for (final args in <List<String>>[
      <String>['--release', '--analyze-size'],
      <String>['--release', '--analyze-size', '--code-size-directory', 'd'],
      <String>['--release', '--code-size-directory', 'd'],
      <String>['--code-size-directory=d'],
    ]) {
      testUsingContext('"${args.join(' ')}" is refused before any build', () async {
        final File plugins = pluginList();

        await expectLater(
          createTestCommandRunner(
            buildCommand(),
          ).run(<String>['build', 'watchos', ...args, '--no-pub']),
          throwsToolExit(message: 'Size analysis is not available for watchOS builds'),
        );

        expect(builds, isEmpty);
        expect(registrations, isEmpty);
        // validateCommand refused before the tooling check ran.
        expect(plugins.existsSync(), isFalse);
        expect(fileSystem.directory('/project/build').existsSync(), isFalse);
        expect(fileSystem.directory('/project/d').existsSync(), isFalse);
      }, overrides: overrides());
    }

    testUsingContext('the refusal names a bare command to run instead', () async {
      final List<String> commandLines = kWatchosSizeAnalysisRefusal
          .split('\n')
          .where((String line) => line.startsWith('  flutter-watchos '))
          .toList();

      expect(commandLines, <String>['  flutter-watchos build watchos --release']);
      expect(forbiddenWordsIn(kWatchosSizeAnalysisRefusal), isEmpty);
    });

    testUsingContext('--no-analyze-size builds as before', () async {
      final File plugins = pluginList();

      await createTestCommandRunner(
        buildCommand(),
      ).run(<String>['build', 'watchos', '--release', '--no-analyze-size', '--no-pub']);

      expect(builds, hasLength(1));
      // The tooling check ran for this build.
      expect(plugins.existsSync(), isTrue);
      expect(sizeDirectories(), isEmpty);
    }, overrides: overrides());

    testUsingContext('build watchos -h lists neither flag', () async {
      await createTestCommandRunner(buildCommand()).run(<String>['build', 'watchos', '-h']);

      // Stock's --split-debug-info help still names --analyze-size in a
      // sentence; neither option has a line of its own.
      expect(logger.statusText, contains('\n    --[no-]simulator '));
      expect(logger.statusText, isNot(contains('\n    --[no-]analyze-size')));
      expect(logger.statusText, isNot(contains('\n    --code-size-directory')));
    }, overrides: overrides());
  });
  group('build subcommands', () {
    /// The lines under "Available subcommands:" in `build -h`.
    List<String> listedSubcommands(String usage) {
      final List<String> lines = usage.split('\n');
      final int start = lines.indexOf('Available subcommands:') + 1;
      return lines
          .skip(start)
          .takeWhile((String line) => line.isNotEmpty)
          .map((String line) => line.trim().split(' ').first)
          .toList();
    }

    testUsingContext('build -h lists only watchos', () async {
      await createTestCommandRunner(buildCommand()).run(<String>['build', '-h']);

      expect(listedSubcommands(logger.statusText), <String>['watchos']);
    }, overrides: overrides());

    testUsingContext('the stubs cover every stock build target', () async {
      final Set<String> stubs = buildCommand().subcommands.keys.toSet()..remove('watchos');

      expect(stubs, <String>{...kStockBuildSubcommands, 'aab', 'xcarchive'});
      expect(kStockBuildSubcommands, hasLength(13));
    });

    for (final String name in kStockBuildSubcommands.where((String name) => name != 'ipa')) {
      testUsingContext('build $name is refused and names flutter build $name', () async {
        Object? caught;
        try {
          await createTestCommandRunner(buildCommand()).run(<String>['build', name]);
        } on ToolExit catch (error) {
          caught = error;
        }

        expect(caught, isA<ToolExit>());
        final exit = caught! as ToolExit;
        expect(exit.exitCode, 1);
        expect(exit.message, contains('flutter-watchos build $name is not available'));
        expect(exit.message, endsWith('\n  flutter build $name'));
        expect(forbiddenWordsIn(exit.message!), isEmpty);
        expect(builds, isEmpty);
      }, overrides: overrides());
    }

    for (final args in <List<String>>[
      <String>['apk', '--split-per-abi'],
      <String>['ipa', '--release', '--export-options-plist=x'],
      <String>['aab', '--release'],
      <String>['xcarchive'],
      <String>['web', '--wasm', 'extra'],
    ]) {
      testUsingContext(
        '"build ${args.join(' ')}" reaches the refusal, not a usage error',
        () async {
          await expectLater(
            createTestCommandRunner(buildCommand()).run(<String>['build', ...args]),
            throwsToolExit(
              message: 'is not available: flutter-watchos builds only the watchOS app.',
            ),
          );
          expect(builds, isEmpty);
        },
        overrides: overrides(),
      );
    }

    testUsingContext('build ipa in a project with an iOS app gives the companion route', () async {
      fileSystem.file('/project/ios/Runner.xcodeproj/project.pbxproj').createSync(recursive: true);
      fileSystem.currentDirectory = fileSystem.directory('/project/lib');

      await expectLater(
        createTestCommandRunner(buildCommand()).run(<String>['build', 'ipa', '--release']),
        throwsToolExit(
          message:
              'This project has an iOS app, and the watch app ships inside it. '
              'Build the watch app first, then the iOS archive with stock Flutter:\n'
              '  flutter-watchos build watchos --release\n'
              '  flutter build ipa',
        ),
      );
      expect(builds, isEmpty);
    }, overrides: overrides());

    testUsingContext('build ipa in a watch-only project gives the Xcode route', () async {
      await expectLater(
        createTestCommandRunner(buildCommand()).run(<String>['build', 'ipa']),
        throwsToolExit(
          message:
              'Product → Archive → Distribute App:\n'
              '  flutter-watchos build watchos --release\n'
              'To upload an .ipa exported from Xcode, run:\n'
              '  flutter-watchos upload --ipa <file>',
        ),
      );
      expect(builds, isEmpty);
    }, overrides: overrides());

    test('every refusal offers bare commands and no forbidden word', () {
      for (final String name in kStockBuildSubcommands) {
        for (final companion in <bool>[false, true]) {
          final String message = stockBuildRefusal(name, companion: companion);
          final Iterable<String> commandLines = message
              .split('\n')
              .where((String line) => line.startsWith('  '));

          expect(commandLines, isNotEmpty, reason: name);
          for (final line in commandLines) {
            expect(line, matches(RegExp(r'^  (flutter|flutter-watchos) [a-z]')), reason: line);
            expect(line, isNot(contains('#')), reason: line);
            expect(line, isNot(contains('(')), reason: line);
          }
          expect(forbiddenWordsIn(message), isEmpty, reason: name);
        }
      }
    });
  });
}
