// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/macos/xcode.dart';
import 'package:flutter_watchos/commands/clean.dart';

import '../../src/context.dart';
import '../../src/test_flutter_command_runner.dart';

void main() {
  late MemoryFileSystem fileSystem;
  late BufferLogger logger;
  late Directory project;

  setUpAll(() {
    Cache.disableLocking();
  });

  setUp(() {
    fileSystem = MemoryFileSystem.test();
    logger = BufferLogger.test();
    project = fileSystem.directory('/project')..createSync();
    project.childFile('pubspec.yaml').writeAsStringSync('name: my_app\n');
    fileSystem.currentDirectory = project;
  });

  Map<Type, Generator> overrides() => <Type, Generator>{
    FileSystem: () => fileSystem,
    ProcessManager: () => FakeProcessManager.empty(),
    Logger: () => logger,
    // No Xcode, so stock clean leaves DerivedData alone.
    Xcode: () => null,
  };

  File watchFile(String path) => project.childDirectory('watchos').childFile(path);

  testUsingContext('removes the watch build outputs and keeps the sources', () async {
    for (final path in <String>[
      'Pods/Manifest.lock',
      'Flutter/Flutter.framework/Flutter',
      'Flutter/App.framework/App',
      'Flutter/flutter_assets/AssetManifest.bin',
      'Flutter/Generated.xcconfig',
      'Flutter/GeneratedPluginRegistrant.swift',
      'Podfile.lock',
      'Runner/GeneratedPluginRegistrant.h',
      'Runner/GeneratedPluginRegistrant.m',
      'Runner/AppDelegate.swift',
      'Runner/Info.plist',
    ]) {
      watchFile(path).createSync(recursive: true);
    }
    project
        .childDirectory('build')
        .childDirectory('watchos')
        .childFile('x')
        .createSync(recursive: true);

    await createTestCommandRunner(WatchosCleanCommand(verbose: false)).run(<String>['clean']);

    for (final path in <String>[
      'Pods',
      'Flutter/Flutter.framework',
      'Flutter/App.framework',
      'Flutter/flutter_assets',
    ]) {
      expect(
        project.childDirectory('watchos').childDirectory(path).existsSync(),
        isFalse,
        reason: path,
      );
    }
    for (final path in <String>[
      'Flutter/Generated.xcconfig',
      'Flutter/GeneratedPluginRegistrant.swift',
      'Podfile.lock',
      'Runner/GeneratedPluginRegistrant.h',
      'Runner/GeneratedPluginRegistrant.m',
    ]) {
      expect(watchFile(path).existsSync(), isFalse, reason: path);
    }
    expect(watchFile('Runner/AppDelegate.swift').existsSync(), isTrue);
    expect(watchFile('Runner/Info.plist').existsSync(), isTrue);
    expect(project.childDirectory('build').existsSync(), isFalse);
    expect(logger.statusText, contains('Cleaned watchOS build artifacts.'));
  }, overrides: overrides());

  testUsingContext('without watchos/ it is stock clean', () async {
    project.childDirectory('build').childFile('x').createSync(recursive: true);

    await createTestCommandRunner(WatchosCleanCommand(verbose: false)).run(<String>['clean']);

    expect(project.childDirectory('build').existsSync(), isFalse);
    expect(logger.statusText, isNot(contains('watchOS')));
  }, overrides: overrides());
}
