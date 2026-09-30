// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/io.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/build_system/build_system.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/ios/plist_parser.dart';
import 'package:flutter_tools/src/project.dart';
import 'package:flutter_watchos/commands/build.dart';
import 'package:flutter_watchos/watchos_build_info.dart';

import '../../../flutter/packages/flutter_tools/test/src/test_build_system.dart';
import '../../src/common.dart';
import '../../src/context.dart';
import '../../src/fakes.dart';
import '../../src/test_flutter_command_runner.dart';

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
      artifacts: FakeArtifacts(),
      cache: FakeCache(),
      fileSystem: fileSystem,
      flutterVersion: FakeFlutterVersion(),
      buildSystem: TestBuildSystem.all(BuildResult(success: true)),
      osUtils: FakeOperatingSystemUtils(),
      logger: logger,
      androidSdk: FakeAndroidSdk(),
      config: FakeConfig(),
      platform: FakePlatform(),
      processUtils: FakeProcessUtils(),
      processManager: FakeProcessManager.empty(),
      fileSystemUtils: FakeFileSystemUtils(),
      templateRenderer: FakeTemplateRenderer(),
      terminal: FakeTerminal(),
      plistParser: FakePlistParser(),
      xcode: FakeXcode(),
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

    testUsingContext('--simulator --release is a tool exit with the guidance', () async {
      await expectLater(
        createTestCommandRunner(
          buildCommand(),
        ).run(<String>['build', 'watchos', '--simulator', '--release', '--no-pub']),
        throwsToolExit(message: 'flutter-watchos build watchos --simulator'),
      );
      expect(builds, isEmpty);
      expect(registrations, isEmpty);
    }, overrides: overrides());

    testUsingContext('a device debug build is a tool exit', () async {
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
}
