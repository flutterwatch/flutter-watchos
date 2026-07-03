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

  group('installApp (physical watch)', () {
    WatchosDevice physicalDevice() => WatchosDevice(
      'watch-1',
      name: 'My Watch',
      logger: BufferLogger.test(),
      isSimulator: false,
    );

    List<String> installCmd(String appPath) => <String>[
      'xcrun',
      'devicectl',
      'device',
      'install',
      'app',
      '--device',
      'watch-1',
      appPath,
    ];

    setUp(() {
      WatchosDevice.installRetryDelay = Duration.zero;
    });

    tearDown(() {
      WatchosDevice.installRetryDelay = const Duration(seconds: 3);
    });

    testUsingContext(
      'retries a devicectl install interrupted by a tunnel drop',
      () async {
        final WatchosApp app = appAt('/proj/watchos');
        final String appPath = fileSystem.path.join(
          '/proj',
          'build',
          'watchos',
          'Release-watchos',
          'Runner.app',
        );
        fileSystem.directory(appPath).createSync(recursive: true);

        // Wireless CoreDevice tunnels drop routinely mid-transfer; the
        // install is idempotent, so the device must retry, not give up.
        processManager.addCommand(
          FakeCommand(
            command: installCmd(appPath),
            exitCode: 1,
            stderr:
                'ERROR: The tunnel was interrupted while establishing '
                'connectivity to coredevice-326. '
                '(com.apple.dt.CoreDeviceError error 4000 (0xFA0))',
          ),
        );
        processManager.addCommand(FakeCommand(command: installCmd(appPath)));

        expect(await physicalDevice().installApp(app), isTrue);
        expect(processManager, hasNoRemainingExpectations);
      },
      overrides: <Type, Generator>{
        FileSystem: () => fileSystem,
        ProcessManager: () => processManager,
      },
    );

    testUsingContext(
      'gives up after three failed install attempts with tunnel guidance',
      () async {
        final WatchosApp app = appAt('/proj/watchos');
        final String appPath = fileSystem.path.join(
          '/proj',
          'build',
          'watchos',
          'Release-watchos',
          'Runner.app',
        );
        fileSystem.directory(appPath).createSync(recursive: true);

        final logger = BufferLogger.test();
        final device = WatchosDevice(
          'watch-1',
          name: 'My Watch',
          logger: logger,
          isSimulator: false,
        );
        for (var i = 0; i < 3; i++) {
          processManager.addCommand(
            FakeCommand(command: installCmd(appPath), exitCode: 1, stderr: 'tunnel interrupted'),
          );
        }

        expect(await device.installApp(app), isFalse);
        expect(processManager, hasNoRemainingExpectations);
        expect(logger.errorText, contains('after 3 attempts'));
        expect(logger.errorText, contains('same Wi-Fi network'));
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
