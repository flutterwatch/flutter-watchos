// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/process.dart';
import 'package:flutter_watchos/watchos_device.dart';
import 'package:flutter_watchos/watchos_emulator.dart';

import '../src/common.dart';
import '../src/context.dart';
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

    // `devices` stays booted-only, as stock; `-d <exact UDID>` also finds a
    // shut-down watch Simulator, so run can boot it (spec 0005 criterion 23).
    const shutDownJson = '''
{"devices":{"com.apple.CoreSimulator.SimRuntime.watchOS-26-5":[
  {"udid":"AAAA-BBBB-CCCC","name":"Apple Watch Series 11 (46mm)","state":"Shutdown","isAvailable":true},
  {"udid":"DDDD-EEEE-FFFF","name":"Apple Watch SE","state":"Booted","isAvailable":true}
]}}''';

    Future<List<WatchosDevice>> simulators({String? shutDownUdid}) {
      processManager.addCommand(
        const FakeCommand(
          command: <String>['xcrun', 'simctl', 'list', 'devices', '--json'],
          stdout: shutDownJson,
        ),
      );
      return WatchosEmulator.getConnectedSimulators(
        logger,
        processUtils: processUtils,
        shutDownUdid: shutDownUdid,
      );
    }

    testWithoutContext('lists a shut-down Simulator only for its exact UDID', () async {
      final List<WatchosDevice> byUdid = await simulators(shutDownUdid: 'aaaa-bbbb-cccc');
      expect(byUdid.map((WatchosDevice d) => d.id), <String>['AAAA-BBBB-CCCC', 'DDDD-EEEE-FFFF']);
      expect(byUdid.first.isShutDown, isTrue);
      expect(byUdid.last.isShutDown, isFalse);

      for (final other in <String?>[null, 'Apple Watch Series 11 (46mm)', 'AAAA']) {
        final List<WatchosDevice> devices = await simulators(shutDownUdid: other);
        expect(devices.map((WatchosDevice d) => d.id), <String>[
          'DDDD-EEEE-FFFF',
        ], reason: '$other');
      }
      expect(processManager, hasNoRemainingExpectations);
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

    // Xcode 27 lists this capability for a connected watch that can take
    // screenshots (spec 0005 criterion 27).
    testWithoutContext('reads the capture-screenshot capability', () {
      const json = '''
{"result":{"devices":[{
  "identifier":"w-able",
  "capabilities":[
    {"featureIdentifier":"com.apple.coredevice.feature.launchapplication","name":"Launch Application"},
    {"featureIdentifier":"com.apple.coredevice.feature.capturescreenshot","name":"Capture Screenshot"}
  ],
  "hardwareProperties":{"platform":"watchOS","reality":"physical"},
  "deviceProperties":{"name":"Able Watch"},
  "connectionProperties":{"tunnelState":"connected"}
},{
  "identifier":"w-unable",
  "capabilities":[{"featureIdentifier":"com.apple.coredevice.feature.launchapplication"}],
  "hardwareProperties":{"platform":"watchOS","reality":"physical"},
  "deviceProperties":{"name":"Unable Watch"},
  "connectionProperties":{"tunnelState":"connected"}
}]}}''';

      final List<WatchosDevice> devices = WatchosEmulator.parseDevicectlOutput(json, logger);

      expect(
        devices.first.coreDeviceCapabilities,
        contains(WatchosDevice.captureScreenshotCapability),
      );
      expect(devices.first.supportsScreenshot, isTrue);
      expect(devices.last.supportsScreenshot, isFalse);
    });

    testWithoutContext('returns empty on missing result / devices keys', () {
      expect(WatchosEmulator.parseDevicectlOutput('{}', logger), isEmpty);
      expect(WatchosEmulator.parseDevicectlOutput('{"result":{}}', logger), isEmpty);
    });
  });

  group('hasUnreachableWatch', () {
    testWithoutContext('is true for a paired watch whose tunnel is not up', () {
      expect(WatchosEmulator.hasUnreachableWatch(_offlineWatchJson), isTrue);
    });

    testWithoutContext('is false for a connected watch', () {
      expect(WatchosEmulator.hasUnreachableWatch(_connectedWatchJson), isFalse);
    });

    testWithoutContext('ignores unreachable devices that are not watches', () {
      const json =
          '{"result":{"devices":[{"identifier":"ios-1",'
          '"hardwareProperties":{"platform":"iOS","reality":"physical"},'
          '"connectionProperties":{"tunnelState":"unavailable"}}]}}';
      expect(WatchosEmulator.hasUnreachableWatch(json), isFalse);
    });

    testWithoutContext('is false for malformed or empty JSON', () {
      expect(WatchosEmulator.hasUnreachableWatch('not json'), isFalse);
      expect(WatchosEmulator.hasUnreachableWatch('{}'), isFalse);
    });
  });

  group('getPhysicalDevices', () {
    late MemoryFileSystem fileSystem;

    setUp(() {
      fileSystem = MemoryFileSystem.test();
    });

    // devicectl writes its JSON to a temp file rather than stdout.
    FakeCommand devicectlWriting(String json) => FakeCommand(
      // The temp path carries a timestamp, so match it loosely.
      command: <Pattern>['xcrun', 'devicectl', 'list', 'devices', '--json-output', RegExp('.*')],
      onRun: (List<String> command) {
        fileSystem.file(command.last)
          ..createSync(recursive: true)
          ..writeAsStringSync(json);
      },
    );

    testUsingContext(
      'waits out a watch whose tunnel is still coming up when given a timeout',
      () async {
        processManager.addCommand(devicectlWriting(_offlineWatchJson));
        processManager.addCommand(devicectlWriting(_connectedWatchJson));

        final List<WatchosDevice> devices = await WatchosEmulator.getPhysicalDevices(
          logger,
          processUtils: processUtils,
          timeout: const Duration(seconds: 30),
          retryInterval: Duration.zero,
        );

        expect(devices, hasLength(1));
        expect(devices.first.name, 'My Watch');
        expect(processManager, hasNoRemainingExpectations);
      },
      overrides: <Type, Generator>{
        FileSystem: () => fileSystem,
        ProcessManager: () => processManager,
      },
    );

    testUsingContext(
      'gives up at the timeout instead of retrying forever',
      () async {
        processManager.addCommand(devicectlWriting(_offlineWatchJson));

        final List<WatchosDevice> devices = await WatchosEmulator.getPhysicalDevices(
          logger,
          processUtils: processUtils,
          // Smaller than one retry interval, so a single query is all we get.
          timeout: const Duration(milliseconds: 1),
        );

        expect(devices, isEmpty);
        expect(processManager, hasNoRemainingExpectations);
      },
      overrides: <Type, Generator>{
        FileSystem: () => fileSystem,
        ProcessManager: () => processManager,
      },
    );

    testUsingContext(
      'does not wait when no timeout was given',
      () async {
        processManager.addCommand(devicectlWriting(_offlineWatchJson));

        final List<WatchosDevice> devices = await WatchosEmulator.getPhysicalDevices(
          logger,
          processUtils: processUtils,
          retryInterval: Duration.zero,
        );

        expect(devices, isEmpty);
        expect(processManager, hasNoRemainingExpectations);
      },
      overrides: <Type, Generator>{
        FileSystem: () => fileSystem,
        ProcessManager: () => processManager,
      },
    );

    testUsingContext(
      'returns a reachable watch on the first query',
      () async {
        processManager.addCommand(devicectlWriting(_connectedWatchJson));

        final List<WatchosDevice> devices = await WatchosEmulator.getPhysicalDevices(
          logger,
          processUtils: processUtils,
          timeout: const Duration(seconds: 30),
          retryInterval: Duration.zero,
        );

        expect(devices, hasLength(1));
        expect(processManager, hasNoRemainingExpectations);
      },
      overrides: <Type, Generator>{
        FileSystem: () => fileSystem,
        ProcessManager: () => processManager,
      },
    );
  });
}

const _connectedWatchJson = '''
{"result":{"devices":[{
  "identifier":"00008301-001234567890ABCD",
  "hardwareProperties":{"platform":"watchOS","reality":"physical"},
  "deviceProperties":{"name":"My Watch","osVersionNumber":"11.0"},
  "connectionProperties":{"tunnelState":"connected"}
}]}}''';

const _offlineWatchJson = '''
{"result":{"devices":[{
  "identifier":"00008301-001234567890ABCD",
  "hardwareProperties":{"platform":"watchOS","reality":"physical"},
  "deviceProperties":{"name":"My Watch"},
  "connectionProperties":{"tunnelState":"unavailable"}
}]}}''';
