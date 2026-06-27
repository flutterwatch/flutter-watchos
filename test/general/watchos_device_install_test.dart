// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_watchos/watchos_application_package.dart';
import 'package:flutter_watchos/watchos_device.dart';

import '../src/common.dart';
import '../src/context.dart';
import '../src/fake_process_manager.dart';

void main() {
  late MemoryFileSystem fileSystem;
  late FakeProcessManager processManager;

  setUp(() {
    fileSystem = MemoryFileSystem.test();
    processManager = FakeProcessManager.empty();
  });

  WatchosApp appAt(String projectDir) => WatchosApp(
    id: 'com.example.demo',
    projectDirectory: fileSystem.directory(projectDir)..createSync(recursive: true),
  );

  String bundle(String config) =>
      fileSystem.path.join('/proj', 'build', 'watchos', '$config-watchsimulator', 'Runner.app');

  WatchosDevice simDevice() => WatchosDevice(
    'sim-1',
    name: 'Apple Watch Series 11 (46mm)',
    logger: BufferLogger.test(),
    isSimulator: true,
  );

  group('installApp (simulator)', () {
    testUsingContext(
      'prefers the Release bundle and returns true on simctl success',
      () async {
        final WatchosApp app = appAt('/proj/watchos');
        fileSystem.directory(bundle('Release')).createSync(recursive: true);
        processManager.addCommand(
          FakeCommand(command: <String>['xcrun', 'simctl', 'install', 'sim-1', bundle('Release')]),
        );

        expect(await simDevice().installApp(app), isTrue);
        expect(processManager, hasNoRemainingExpectations);
      },
      overrides: <Type, Generator>{
        FileSystem: () => fileSystem,
        ProcessManager: () => processManager,
      },
    );

    testUsingContext(
      'falls back to the Debug bundle when Release is absent',
      () async {
        final WatchosApp app = appAt('/proj/watchos');
        // No Release-watchsimulator bundle → installApp uses the Debug path.
        processManager.addCommand(
          FakeCommand(command: <String>['xcrun', 'simctl', 'install', 'sim-1', bundle('Debug')]),
        );

        expect(await simDevice().installApp(app), isTrue);
        expect(processManager, hasNoRemainingExpectations);
      },
      overrides: <Type, Generator>{
        FileSystem: () => fileSystem,
        ProcessManager: () => processManager,
      },
    );

    testUsingContext(
      'returns false when simctl install fails',
      () async {
        final WatchosApp app = appAt('/proj/watchos');
        fileSystem.directory(bundle('Release')).createSync(recursive: true);
        processManager.addCommand(
          FakeCommand(
            command: <String>['xcrun', 'simctl', 'install', 'sim-1', bundle('Release')],
            exitCode: 1,
            stderr: 'Unable to install',
          ),
        );

        expect(await simDevice().installApp(app), isFalse);
        expect(processManager, hasNoRemainingExpectations);
      },
      overrides: <Type, Generator>{
        FileSystem: () => fileSystem,
        ProcessManager: () => processManager,
      },
    );
  });

  group('uninstallApp (simulator)', () {
    testUsingContext(
      'returns true on simctl uninstall success',
      () async {
        final WatchosApp app = appAt('/proj/watchos');
        processManager.addCommand(
          const FakeCommand(
            command: <String>['xcrun', 'simctl', 'uninstall', 'sim-1', 'com.example.demo'],
          ),
        );

        expect(await simDevice().uninstallApp(app), isTrue);
        expect(processManager, hasNoRemainingExpectations);
      },
      overrides: <Type, Generator>{
        FileSystem: () => fileSystem,
        ProcessManager: () => processManager,
      },
    );

    testUsingContext(
      'returns false when simctl uninstall fails',
      () async {
        final WatchosApp app = appAt('/proj/watchos');
        processManager.addCommand(
          const FakeCommand(
            command: <String>['xcrun', 'simctl', 'uninstall', 'sim-1', 'com.example.demo'],
            exitCode: 1,
          ),
        );

        expect(await simDevice().uninstallApp(app), isFalse);
        expect(processManager, hasNoRemainingExpectations);
      },
      overrides: <Type, Generator>{
        FileSystem: () => fileSystem,
        ProcessManager: () => processManager,
      },
    );
  });
}
