// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/os.dart';
import 'package:flutter_tools/src/device.dart';
import 'package:flutter_watchos/watchos_device.dart';
import 'package:flutter_watchos/watchos_device_discovery.dart';
import 'package:flutter_watchos/watchos_doctor.dart';

import '../src/common.dart';
import '../src/context.dart';
import '../src/fake_process_manager.dart';
import '../src/fakes.dart';

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
  });
}
