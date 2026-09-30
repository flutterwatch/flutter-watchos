// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_watchos/watchos_device.dart';

import '../src/common.dart';
import '../src/context.dart';
import '../src/fake_process_manager.dart';

// Screenshots of a watch: `screenshot -d` and the `s` key call
// supportsScreenshot and takeScreenshot (spec 0008 criterion 3).

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

  testWithoutContext("a physical watch keeps stock's refusal", () {
    final device = WatchosDevice('w', name: 'My Watch', logger: logger, isSimulator: false);
    expect(device.supportsScreenshot, isFalse);
  });
}
