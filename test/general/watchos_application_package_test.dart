// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/project.dart';
import 'package:flutter_watchos/watchos_application_package.dart';
import 'package:flutter_watchos/watchos_project.dart';

import '../src/common.dart';
import '../src/context.dart';

void main() {
  late MemoryFileSystem fileSystem;
  late FakeProcessManager processManager;

  setUp(() {
    fileSystem = MemoryFileSystem.test();
    processManager = FakeProcessManager.any();
  });

  group('WatchosApp', () {
    testUsingContext(
      'bundlePath returns the Debug-watchsimulator Runner.app for debug sim',
      () {
        final Directory projectDir = fileSystem.directory('/project/watchos')
          ..createSync(recursive: true);
        final app = WatchosApp(id: 'com.example.test', projectDirectory: projectDir);

        final String path = app.bundlePath(BuildMode.debug, isSimulator: true);
        expect(path, contains('Debug-watchsimulator'));
        expect(path, endsWith('Runner.app'));
      },
      overrides: <Type, Generator>{
        FileSystem: () => fileSystem,
        ProcessManager: () => processManager,
      },
    );

    testUsingContext(
      'bundlePath returns the Release-watchos Runner.app for release device',
      () {
        final Directory projectDir = fileSystem.directory('/project/watchos')
          ..createSync(recursive: true);
        final app = WatchosApp(id: 'com.example.test', projectDirectory: projectDir);

        final String path = app.bundlePath(BuildMode.release);
        expect(path, contains('Release-watchos'));
        expect(path, endsWith('Runner.app'));
      },
      overrides: <Type, Generator>{
        FileSystem: () => fileSystem,
        ProcessManager: () => processManager,
      },
    );

    testWithoutContext('name returns the project directory basename', () {
      final Directory projectDir = fileSystem.directory('/my_app/watchos')
        ..createSync(recursive: true);
      final app = WatchosApp(id: 'com.example.test', projectDirectory: projectDir);

      expect(app.name, equals('watchos'));
    });
  });

  group('WatchosApp.fromWatchosProject', () {
    WatchosProject projectAt(String dir) =>
        WatchosProject.fromFlutter(FlutterProject.fromDirectory(fileSystem.directory(dir)));

    void writePbxproj(String bundleIdLine) {
      fileSystem.directory('/proj/watchos').createSync(recursive: true);
      fileSystem.file('/proj/watchos/Runner.xcodeproj/project.pbxproj')
        ..createSync(recursive: true)
        ..writeAsStringSync('buildSettings = {\n  $bundleIdLine\n};\n');
    }

    testUsingContext(
      'reads a quoted PRODUCT_BUNDLE_IDENTIFIER from project.pbxproj',
      () async {
        writePbxproj('PRODUCT_BUNDLE_IDENTIFIER = "com.acme.watch";');
        final WatchosApp? app = await WatchosApp.fromWatchosProject(projectAt('/proj'));
        expect(app, isNotNull);
        expect(app!.id, equals('com.acme.watch'));
      },
      overrides: <Type, Generator>{
        FileSystem: () => fileSystem,
        ProcessManager: () => processManager,
      },
    );

    testUsingContext(
      'reads an unquoted PRODUCT_BUNDLE_IDENTIFIER',
      () async {
        writePbxproj('PRODUCT_BUNDLE_IDENTIFIER = com.acme.bare;');
        final WatchosApp? app = await WatchosApp.fromWatchosProject(projectAt('/proj'));
        expect(app!.id, equals('com.acme.bare'));
      },
      overrides: <Type, Generator>{
        FileSystem: () => fileSystem,
        ProcessManager: () => processManager,
      },
    );

    testUsingContext(
      'falls back to com.example.<dir> when no pbxproj is present',
      () async {
        fileSystem.directory('/proj/watchos').createSync(recursive: true);
        final WatchosApp? app = await WatchosApp.fromWatchosProject(projectAt('/proj'));
        expect(app!.id, equals('com.example.proj'));
      },
      overrides: <Type, Generator>{
        FileSystem: () => fileSystem,
        ProcessManager: () => processManager,
      },
    );

    testUsingContext(
      'returns null when the watchos/ project does not exist',
      () async {
        fileSystem.directory('/proj').createSync(recursive: true);
        expect(await WatchosApp.fromWatchosProject(projectAt('/proj')), isNull);
      },
      overrides: <Type, Generator>{
        FileSystem: () => fileSystem,
        ProcessManager: () => processManager,
      },
    );
  });
}
