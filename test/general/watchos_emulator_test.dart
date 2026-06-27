// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/process.dart';
import 'package:flutter_watchos/watchos_device.dart';
import 'package:flutter_watchos/watchos_emulator.dart';

import '../src/common.dart';
import '../src/fake_process_manager.dart';

void main() {
  late FakeProcessManager processManager;
  late BufferLogger logger;
  late ProcessUtils processUtils;

  setUp(() {
    processManager = FakeProcessManager.empty();
    logger = BufferLogger.test();
    processUtils = ProcessUtils(processManager: processManager, logger: logger);
  });

  group('getConnectedSimulators', () {
    testWithoutContext('returns available watchOS simulators only', () async {
      // Only Booted+isAvailable watchOS sims are returned; iOS sims and
      // Shutdown watchOS sims are excluded.
      processManager.addCommand(
        const FakeCommand(
          command: <String>['xcrun', 'simctl', 'list', 'devices', '--json'],
          stdout:
              '{"devices":{"com.apple.CoreSimulator.SimRuntime.watchOS-11-0":[{"udid":"AAAA-BBBB-CCCC","name":"Apple Watch Series 11 (46mm)","state":"Booted","isAvailable":true},{"udid":"DDDD-EEEE-FFFF","name":"Apple Watch SE","state":"Shutdown","isAvailable":false}],"com.apple.CoreSimulator.SimRuntime.iOS-18-4":[{"udid":"1111-2222-3333","name":"iPhone 16","state":"Booted","isAvailable":true}]}}',
        ),
      );

      final List<WatchosDevice> devices = await WatchosEmulator.getConnectedSimulators(
        logger,
        processUtils: processUtils,
      );

      expect(devices, hasLength(1));
      expect(devices.first.id, equals('AAAA-BBBB-CCCC'));
      expect(devices.first.name, equals('Apple Watch Series 11 (46mm)'));
      expect(devices.first.isSimulator, isTrue);
      expect(processManager, hasNoRemainingExpectations);
    });

    testWithoutContext('returns empty list when no watchOS runtimes present', () async {
      processManager.addCommand(
        const FakeCommand(
          command: <String>['xcrun', 'simctl', 'list', 'devices', '--json'],
          stdout:
              '{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-18-4":[{"udid":"1111-2222-3333","name":"iPhone 16","state":"Booted","isAvailable":true}]}}',
        ),
      );

      final List<WatchosDevice> devices = await WatchosEmulator.getConnectedSimulators(
        logger,
        processUtils: processUtils,
      );

      expect(devices, isEmpty);
    });

    testWithoutContext('handles simctl failure gracefully', () async {
      processManager.addCommand(
        const FakeCommand(
          command: <String>['xcrun', 'simctl', 'list', 'devices', '--json'],
          exitCode: 1,
        ),
      );

      final List<WatchosDevice> devices = await WatchosEmulator.getConnectedSimulators(
        logger,
        processUtils: processUtils,
      );

      expect(devices, isEmpty);
    });

    testWithoutContext('derives the runtime version string from the runtime key', () async {
      processManager.addCommand(
        const FakeCommand(
          command: <String>['xcrun', 'simctl', 'list', 'devices', '--json'],
          stdout:
              '{"devices":{"com.apple.CoreSimulator.SimRuntime.watchOS-11-0":[{"udid":"AAAA-BBBB-CCCC","name":"Apple Watch Series 11 (46mm)","state":"Booted","isAvailable":true}]}}',
        ),
      );

      final List<WatchosDevice> devices = await WatchosEmulator.getConnectedSimulators(
        logger,
        processUtils: processUtils,
      );

      expect(devices, hasLength(1));
      expect(devices.first.osVersion ?? '', contains('watchOS 11.0'));
    });

    testWithoutContext('includes Shutdown sims when includeShutdown is set', () async {
      processManager.addCommand(
        const FakeCommand(
          command: <String>['xcrun', 'simctl', 'list', 'devices', '--json'],
          stdout:
              '{"devices":{"com.apple.CoreSimulator.SimRuntime.watchOS-11-0":[{"udid":"AAAA-BBBB-CCCC","name":"Apple Watch Series 11 (46mm)","state":"Shutdown","isAvailable":true}]}}',
        ),
      );

      final List<WatchosDevice> devices = await WatchosEmulator.getConnectedSimulators(
        logger,
        processUtils: processUtils,
        includeShutdown: true,
      );

      expect(devices, hasLength(1));
      expect(devices.first.id, equals('AAAA-BBBB-CCCC'));
    });
  });

  group('parseDevicectlOutput', () {
    testWithoutContext('returns a physical paired watch with a derived OS string', () {
      const json = '''
{"result":{"devices":[{
  "identifier":"00008301-001234567890ABCD",
  "hardwareProperties":{"platform":"watchOS","reality":"physical","marketingName":"Apple Watch Series 11"},
  "deviceProperties":{"name":"My Watch","osVersionNumber":"11.0","osBuildUpdate":"23R123"},
  "connectionProperties":{"tunnelState":"connected"}
}]}}''';

      final List<WatchosDevice> devices = WatchosEmulator.parseDevicectlOutput(json, logger);

      expect(devices, hasLength(1));
      expect(devices.first.id, '00008301-001234567890ABCD');
      expect(devices.first.name, 'My Watch');
      expect(devices.first.isSimulator, isFalse);
      expect(devices.first.osVersion ?? '', contains('watchOS 11.0'));
    });

    testWithoutContext('excludes non-watchOS and non-physical devices', () {
      const json = '''
{"result":{"devices":[
  {"identifier":"ios-1","hardwareProperties":{"platform":"iOS","reality":"physical"},"deviceProperties":{"name":"iPhone"}},
  {"identifier":"sim-1","hardwareProperties":{"platform":"watchOS","reality":"simulator"},"deviceProperties":{"name":"Sim Watch"}}
]}}''';

      expect(WatchosEmulator.parseDevicectlOutput(json, logger), isEmpty);
    });

    testWithoutContext('skips paired-but-offline watches (tunnelState unavailable)', () {
      const json = '''
{"result":{"devices":[{
  "identifier":"w-offline",
  "hardwareProperties":{"platform":"watchOS","reality":"physical"},
  "deviceProperties":{"name":"Offline Watch"},
  "connectionProperties":{"tunnelState":"unavailable"}
}]}}''';

      expect(WatchosEmulator.parseDevicectlOutput(json, logger), isEmpty);
    });

    testWithoutContext('returns empty on missing result / devices keys', () {
      expect(WatchosEmulator.parseDevicectlOutput('{}', logger), isEmpty);
      expect(WatchosEmulator.parseDevicectlOutput('{"result":{}}', logger), isEmpty);
    });
  });
}
