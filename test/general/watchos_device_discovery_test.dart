// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/memory.dart';
import 'package:flutter_tools/src/android/android_workflow.dart';
import 'package:flutter_tools/src/artifacts.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/os.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/base/user_messages.dart';
import 'package:flutter_tools/src/custom_devices/custom_devices_config.dart';
import 'package:flutter_tools/src/device.dart';
import 'package:flutter_tools/src/ios/ios_workflow.dart';
import 'package:flutter_tools/src/ios/simulators.dart';
import 'package:flutter_tools/src/macos/macos_workflow.dart';
import 'package:flutter_tools/src/macos/xcdevice.dart';
import 'package:flutter_tools/src/windows/windows_workflow.dart';
import 'package:flutter_watchos/watchos_device.dart';
import 'package:flutter_watchos/watchos_device_discovery.dart';
import 'package:flutter_watchos/watchos_doctor.dart';
import 'package:test/fake.dart';

import '../src/common.dart';
import '../src/context.dart';
import '../src/fake_process_manager.dart';
import '../src/fakes.dart';

class _FakeAndroidWorkflow extends Fake implements AndroidWorkflow {}

class _FakeIOSWorkflow extends Fake implements IOSWorkflow {}

class _FakeIOSSimulatorUtils extends Fake implements IOSSimulatorUtils {}

class _FakeXCDevice extends Fake implements XCDevice {}

class _FakeMacOSWorkflow extends Fake implements MacOSWorkflow {}

class _FakeWindowsWorkflow extends Fake implements WindowsWorkflow {}

class _FakeCustomDevicesConfig extends Fake implements CustomDevicesConfig {}

void main() {
  late WatchosDeviceDiscovery discovery;

  setUp(() {
    final workflow = WatchosWorkflow(
      operatingSystemUtils: FakeOperatingSystemUtils(hostPlatform: HostPlatform.darwin_arm64),
    );
    discovery = WatchosDeviceDiscovery(watchosWorkflow: workflow, logger: BufferLogger.test());
  });

  testWithoutContext('supportsPlatform reflects workflow capability', () {
    expect(discovery.supportsPlatform, isTrue);
    expect(discovery.canListAnything, isTrue);
  });

  testWithoutContext('wellKnownIds is empty', () {
    expect(discovery.wellKnownIds, isEmpty);
  });

  testWithoutContext('getDiagnostics returns empty list', () async {
    expect(await discovery.getDiagnostics(), isEmpty);
  });

  // The discoverer asks for the `-d` value on each poll and passes it on, so
  // a shut-down Simulator is found by its exact UDID and by nothing else.
  group('a shut-down Simulator', () {
    late FakeProcessManager processManager;

    setUp(() => processManager = FakeProcessManager.empty());

    // Only the Simulator listing is scripted; the watch listing that follows
    // it fails, which discovery reports at trace level only.
    void script() {
      processManager.addCommands(<FakeCommand>[
        const FakeCommand(
          command: <String>['xcrun', 'simctl', 'list', 'devices', '--json'],
          stdout:
              '{"devices":{"com.apple.CoreSimulator.SimRuntime.watchOS-27-0":['
              '{"udid":"AAAA-BBBB-CCCC","name":"Apple Watch Ultra 3","state":"Shutdown","isAvailable":true}]}}',
        ),
      ]);
    }

    WatchosDeviceDiscovery discoveryFor(String? requested) => WatchosDeviceDiscovery(
      watchosWorkflow: WatchosWorkflow(
        operatingSystemUtils: FakeOperatingSystemUtils(hostPlatform: HostPlatform.darwin_arm64),
      ),
      logger: BufferLogger.test(),
      requestedDeviceId: () => requested,
    );

    testUsingContext('is found when -d names its UDID', () async {
      script();
      final List<Device> devices = await discoveryFor('AAAA-BBBB-CCCC').pollingGetDevices();

      expect(devices.single.id, 'AAAA-BBBB-CCCC');
      expect((devices.single as WatchosDevice).isShutDown, isTrue);
      expect(processManager, hasNoRemainingExpectations);
    }, overrides: <Type, Generator>{ProcessManager: () => processManager});

    testUsingContext('is not listed otherwise', () async {
      script();
      expect(await discoveryFor(null).pollingGetDevices(), isEmpty);
      script();
      expect(await discoveryFor('Apple Watch Ultra 3').pollingGetDevices(), isEmpty);
    }, overrides: <Type, Generator>{ProcessManager: () => processManager});

    // The device manager made a new watch discoverer each time it was asked
    // for its discoverers, so nothing was cached: attach listed the devices
    // three times, drive twice, and --flavor added one more lookup.
    testUsingContext('two lookups through the device manager list the devices once', () async {
      // One listing only: a second one would find no simctl to run, report
      // that at trace level, and list no Simulator.
      script();
      final manager = WatchosDeviceManager(
        logger: BufferLogger.test(),
        processManager: processManager,
        platform: FakePlatform(operatingSystem: 'macos'),
        androidSdk: null,
        iosSimulatorUtils: _FakeIOSSimulatorUtils(),
        featureFlags: TestFeatureFlags(),
        fileSystem: MemoryFileSystem.test(),
        iosWorkflow: _FakeIOSWorkflow(),
        artifacts: Artifacts.test(),
        flutterVersion: FakeFlutterVersion(),
        androidWorkflow: _FakeAndroidWorkflow(),
        xcDevice: _FakeXCDevice(),
        userMessages: UserMessages(),
        windowsWorkflow: _FakeWindowsWorkflow(),
        macOSWorkflow: _FakeMacOSWorkflow(),
        operatingSystemUtils: FakeOperatingSystemUtils(),
        customDevicesConfig: _FakeCustomDevicesConfig(),
        nativeAssetsBuilder: null,
        watchosWorkflow: WatchosWorkflow(
          operatingSystemUtils: FakeOperatingSystemUtils(hostPlatform: HostPlatform.darwin_arm64),
        ),
      )..specifiedDeviceId = 'AAAA-BBBB-CCCC';

      Future<List<Device>> lookUp() =>
          manager.deviceDiscoverers.whereType<WatchosDeviceDiscovery>().single.devices();

      expect((await lookUp()).single.id, 'AAAA-BBBB-CCCC');
      expect((await lookUp()).single.id, 'AAAA-BBBB-CCCC');
      expect(manager.deviceDiscoverers, same(manager.deviceDiscoverers));
      expect(processManager, hasNoRemainingExpectations);
    }, overrides: <Type, Generator>{ProcessManager: () => processManager});
  });
}
