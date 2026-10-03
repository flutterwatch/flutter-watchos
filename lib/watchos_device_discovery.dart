// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/device.dart';
import 'package:flutter_tools/src/flutter_device_manager.dart';
import 'package:flutter_tools/src/globals.dart' as globals;

import 'watchos_doctor.dart';
import 'watchos_emulator.dart';

/// Extended device manager for watchOS.
///
/// Adds [WatchosDeviceDiscovery] to the standard Flutter device discoverers.
class WatchosDeviceManager extends FlutterDeviceManager {
  WatchosDeviceManager({
    required super.logger,
    required super.processManager,
    required super.platform,
    required super.androidSdk,
    required super.iosSimulatorUtils,
    required super.featureFlags,
    required super.fileSystem,
    required super.iosWorkflow,
    required super.artifacts,
    required super.flutterVersion,
    required super.androidWorkflow,
    required super.xcDevice,
    required super.userMessages,
    required super.windowsWorkflow,
    required super.macOSWorkflow,
    required super.operatingSystemUtils,
    required super.customDevicesConfig,
    required super.nativeAssetsBuilder,
    required this.watchosWorkflow,
  });

  final WatchosWorkflow watchosWorkflow;

  @override
  List<DeviceDiscovery> get deviceDiscoverers => <DeviceDiscovery>[
    ...super.deviceDiscoverers,
    WatchosDeviceDiscovery(
      watchosWorkflow: watchosWorkflow,
      logger: globals.logger,
      requestedDeviceId: () => specifiedDeviceId,
    ),
  ];
}

/// Discovers watchOS devices and simulators via `xcrun simctl` / `devicectl`.
///
/// Like stock, it lists booted Simulators only. The exception is a shut-down
/// Simulator whose UDID is exactly the one `-d` names, so `run -d <UDID>` can
/// boot it.
class WatchosDeviceDiscovery extends PollingDeviceDiscovery {
  /// Creates the discoverer. [requestedDeviceId] returns the `-d` value, if
  /// any, each time the devices are polled.
  WatchosDeviceDiscovery({
    required WatchosWorkflow watchosWorkflow,
    required Logger logger,
    String? Function()? requestedDeviceId,
  }) : _watchosWorkflow = watchosWorkflow,
       _logger = logger,
       _requestedDeviceId = requestedDeviceId,
       super('watchOS devices');

  final WatchosWorkflow _watchosWorkflow;
  final Logger _logger;
  final String? Function()? _requestedDeviceId;

  @override
  bool get supportsPlatform => _watchosWorkflow.canListDevices;

  @override
  bool get canListAnything => _watchosWorkflow.canListDevices;

  @override
  List<String> get wellKnownIds => const <String>[];

  @override
  Future<List<Device>> pollingGetDevices({
    Duration? timeout,
    bool forWirelessDiscovery = false,
  }) async {
    final devices = <Device>[];

    try {
      devices.addAll(
        await WatchosEmulator.getConnectedSimulators(
          _logger,
          shutDownUdid: _requestedDeviceId?.call(),
        ),
      );
    } on Exception catch (err) {
      _logger.printTrace('Failed to discover watchOS simulators: $err');
    }

    try {
      // A wireless watch is often unreachable on the first query; honour
      // `--device-timeout` by waiting for it within that budget.
      devices.addAll(await WatchosEmulator.getPhysicalDevices(_logger, timeout: timeout));
    } on Exception catch (err) {
      _logger.printTrace('Failed to discover physical watchOS devices: $err');
    }

    return devices;
  }

  @override
  Future<List<String>> getDiagnostics() async => const <String>[];
}
