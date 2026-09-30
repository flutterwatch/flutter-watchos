// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/commands/screenshot.dart';
import 'package:flutter_tools/src/device.dart';
import 'package:flutter_watchos/watchos_device.dart';

import '../src/common.dart';
import '../src/context.dart';
import '../src/fake_process_manager.dart';
import '../src/test_flutter_command_runner.dart';

// Screenshots of a watch: `screenshot -d` and the `s` key call
// supportsScreenshot and takeScreenshot (spec 0008 criterion 3 for the
// Simulator, spec 0005 criterion 27 for a physical watch).

void main() {
  late FakeProcessManager processManager;
  late BufferLogger logger;
  late MemoryFileSystem fileSystem;

  setUp(() {
    processManager = FakeProcessManager.empty();
    logger = BufferLogger.test();
    fileSystem = MemoryFileSystem.test();
  });

  WatchosDevice simulator() =>
      WatchosDevice('x', name: 'Apple Watch Series 11 (46mm)', logger: logger, isSimulator: true);

  group('Simulator screenshot', () {
    // Mirrors stock simulators_test.dart 'supports screenshots'.
    testUsingContext('supports screenshots, through simctl io', () async {
      processManager.addCommand(
        const FakeCommand(
          command: <String>['xcrun', 'simctl', 'io', 'x', 'screenshot', 'screenshot.png'],
        ),
      );
      final WatchosDevice device = simulator();

      expect(device.supportsScreenshot, isTrue);
      await device.takeScreenshot(fileSystem.file('screenshot.png'));
      expect(processManager, hasNoRemainingExpectations);
      expect(logger.errorText, isEmpty);
    }, overrides: <Type, Generator>{ProcessManager: () => processManager});

    testUsingContext('reports a simctl failure', () async {
      processManager.addCommand(
        const FakeCommand(
          command: <String>['xcrun', 'simctl', 'io', 'x', 'screenshot', 'screenshot.png'],
          exitCode: 1,
          stderr: 'No devices are booted.',
        ),
      );

      await simulator().takeScreenshot(fileSystem.file('screenshot.png'));
      expect(logger.errorText, contains('Unable to take screenshot of x:'));
      expect(logger.errorText, contains('No devices are booted.'));
    }, overrides: <Type, Generator>{ProcessManager: () => processManager});
  });

  group('physical watch screenshot', () {
    late FakeDeviceManager deviceManager;

    setUp(() {
      Cache.disableLocking();
      deviceManager = FakeDeviceManager();
    });

    tearDown(Cache.enableLocking);

    WatchosDevice watch({bool capable = true}) => WatchosDevice(
      'watch-1',
      name: 'My Watch',
      logger: logger,
      isSimulator: false,
      coreDeviceCapabilities: <String>{if (capable) WatchosDevice.captureScreenshotCapability},
    );

    const capture = <String>[
      'xcrun',
      'devicectl',
      'device',
      'capture',
      'screenshot',
      '--device',
      'watch-1',
      '--destination',
      'shot.png',
    ];

    Future<void> screenshot() => createTestCommandRunner(
      ScreenshotCommand(fs: fileSystem),
    ).run(<String>['screenshot', '-d', 'watch-1', '-o', 'shot.png']);

    testUsingContext(
      "a watch without the capability is refused with stock's message",
      () async {
        deviceManager.attachedDevices.add(watch(capable: false));

        await expectLater(
          screenshot(),
          throwsToolExit(message: 'Screenshot not supported for My Watch.'),
        );
        expect(processManager, hasNoRemainingExpectations);
        expect(fileSystem.file('shot.png').existsSync(), isFalse);
      },
      overrides: <Type, Generator>{
        DeviceManager: () => deviceManager,
        FileSystem: () => fileSystem,
        ProcessManager: () => processManager,
      },
    );

    testUsingContext(
      'a capable watch takes it through devicectl',
      () async {
        deviceManager.attachedDevices.add(watch());
        processManager.addCommand(
          FakeCommand(
            command: capture,
            onRun: (_) => fileSystem.file('shot.png').writeAsBytesSync(<int>[0x89, 0x50]),
          ),
        );

        await screenshot();
        expect(processManager, hasNoRemainingExpectations);
        expect(fileSystem.file('shot.png').lengthSync(), 2);
      },
      overrides: <Type, Generator>{
        DeviceManager: () => deviceManager,
        FileSystem: () => fileSystem,
        ProcessManager: () => processManager,
      },
    );

    testUsingContext(
      'a failing capture exits non-zero with the Xcode 27 line and leaves no file',
      () async {
        deviceManager.attachedDevices.add(watch());
        processManager.addCommand(
          FakeCommand(
            command: capture,
            exitCode: 1,
            stderr: "error: Unknown subcommand 'capture'",
            onRun: (_) => fileSystem.file('shot.png').createSync(),
          ),
        );

        await expectLater(
          screenshot(),
          throwsA(
            isA<ToolExit>().having(
              (ToolExit e) => e.message,
              'message',
              allOf(contains("Unknown subcommand 'capture'"), contains('need Xcode 27 or later')),
            ),
          ),
        );
        expect(fileSystem.file('shot.png').existsSync(), isFalse);
      },
      overrides: <Type, Generator>{
        DeviceManager: () => deviceManager,
        FileSystem: () => fileSystem,
        ProcessManager: () => processManager,
      },
    );

    testUsingContext(
      'a capture that writes nothing fails too, and leaves no empty file',
      () async {
        deviceManager.attachedDevices.add(watch());
        processManager.addCommand(
          FakeCommand(command: capture, onRun: (_) => fileSystem.file('shot.png').createSync()),
        );

        await expectLater(screenshot(), throwsToolExit(message: 'devicectl wrote no screenshot.'));
        expect(fileSystem.file('shot.png').existsSync(), isFalse);
      },
      overrides: <Type, Generator>{
        DeviceManager: () => deviceManager,
        FileSystem: () => fileSystem,
        ProcessManager: () => processManager,
      },
    );
  });
}
