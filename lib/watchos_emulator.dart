// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'package:file/file.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/process.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:meta/meta.dart';

import 'watchos_device.dart';

class WatchosEmulator {
  /// Queries `xcrun simctl list --json` for watchOS simulators.
  ///
  /// Matches stock Flutter's iOS simulator behaviour: by default, only
  /// **booted** simulators are returned (those are what `flutter devices`
  /// reports). Pass [includeShutdown] true to get every available simulator
  /// — used by `flutter-watchos emulators` and the device manager when
  /// `--device-id <id>` resolves to a shutdown sim that needs booting.
  static Future<List<WatchosDevice>> getConnectedSimulators(
    Logger logger, {
    ProcessUtils? processUtils,
    bool includeShutdown = false,
  }) async {
    final ProcessUtils pUtils = processUtils ?? globals.processUtils;
    final devices = <WatchosDevice>[];

    try {
      final RunResult result = await pUtils.run(<String>[
        'xcrun',
        'simctl',
        'list',
        'devices',
        '--json',
      ]);

      if (result.exitCode == 0) {
        final json = jsonDecode(result.stdout) as Map<String, dynamic>;
        final devicesList = json['devices'] as Map<String, dynamic>;

        for (final String runtime in devicesList.keys) {
          if (!runtime.contains('watchOS')) {
            continue;
          }
          final String runtimeVersion = _parseRuntimeVersion(runtime);
          final simulators = devicesList[runtime] as List<dynamic>;
          for (final dynamic simulator in simulators) {
            final sim = simulator as Map<String, dynamic>;
            if (sim['isAvailable'] != true) {
              continue;
            }
            final String state = (sim['state'] as String?) ?? 'Shutdown';
            if (!includeShutdown && state != 'Booted') {
              continue;
            }
            devices.add(
              WatchosDevice(
                sim['udid'] as String,
                name: sim['name'] as String,
                logger: logger,
                isSimulator: true,
                osVersion: runtimeVersion,
              ),
            );
          }
        }
      }
    } on Exception catch (e) {
      logger.printTrace('Error querying simctl: $e');
    }

    return devices;
  }

  /// Converts `com.apple.CoreSimulator.SimRuntime.watchOS-11-0` → `watchOS 11.0`.
  static String _parseRuntimeVersion(String runtime) {
    final RegExpMatch? m = RegExp(r'watchOS[-_](\d+)[-_](\d+)(?:[-_](\d+))?').firstMatch(runtime);
    if (m == null) {
      return 'watchOS';
    }
    final String major = m.group(1)!;
    final String minor = m.group(2)!;
    final String? patch = m.group(3);
    return patch == null ? 'watchOS $major.$minor' : 'watchOS $major.$minor.$patch';
  }

  /// Queries `xcrun devicectl list devices` to find paired physical Apple
  /// Watch devices.
  ///
  /// Requires Xcode 15+ with CoreDevice support. The JSON output is written to
  /// a temporary file (devicectl does not support stdout JSON output).
  static Future<List<WatchosDevice>> getPhysicalDevices(
    Logger logger, {
    ProcessUtils? processUtils,
  }) async {
    final ProcessUtils pUtils = processUtils ?? globals.processUtils;
    final devices = <WatchosDevice>[];

    try {
      final String tempPath = globals.fs.path.join(
        globals.fs.systemTempDirectory.path,
        'flutter_watchos_devicectl_${DateTime.now().millisecondsSinceEpoch}.json',
      );

      final RunResult result = await pUtils.run(<String>[
        'xcrun',
        'devicectl',
        'list',
        'devices',
        '--json-output',
        tempPath,
      ]);

      if (result.exitCode != 0) {
        logger.printTrace('devicectl list devices failed: ${result.stderr}');
        return devices;
      }

      final File jsonFile = globals.fs.file(tempPath);
      if (!jsonFile.existsSync()) {
        logger.printTrace('devicectl JSON output not found at $tempPath');
        return devices;
      }

      try {
        final String jsonContent = jsonFile.readAsStringSync();
        devices.addAll(parseDevicectlOutput(jsonContent, logger));
      } finally {
        jsonFile.deleteSync();
      }
    } on Exception catch (e) {
      logger.printTrace('Error querying devicectl: $e');
    }

    return devices;
  }

  /// Parses devicectl JSON output and returns paired physical Apple Watch
  /// devices.
  ///
  /// Hides devices that are paired but currently unreachable — devicectl
  /// reports them with `connectionProperties.tunnelState == "unavailable"`
  /// and emits a separate "Browsing on the local area network..." error.
  /// Stock `flutter devices` doesn't surface those either.
  @visibleForTesting
  static List<WatchosDevice> parseDevicectlOutput(String jsonContent, Logger logger) {
    final devices = <WatchosDevice>[];
    final json = jsonDecode(jsonContent) as Map<String, dynamic>;
    final resultMap = json['result'] as Map<String, dynamic>?;
    if (resultMap == null) {
      return devices;
    }

    final deviceList = resultMap['devices'] as List<dynamic>?;
    if (deviceList == null) {
      return devices;
    }

    for (final Object? device in deviceList) {
      final deviceMap = device! as Map<String, dynamic>;
      final hardware = deviceMap['hardwareProperties'] as Map<String, dynamic>?;
      final deviceProps = deviceMap['deviceProperties'] as Map<String, dynamic>?;
      final connection = deviceMap['connectionProperties'] as Map<String, dynamic>?;

      if (hardware == null) {
        continue;
      }

      final platform = hardware['platform'] as String?;
      final reality = hardware['reality'] as String?;

      // Only include physical watchOS devices.
      if (platform != 'watchOS' || reality != 'physical') {
        continue;
      }

      // Filter out paired-but-offline devices.
      final tunnelState = connection?['tunnelState'] as String?;
      if (tunnelState == 'unavailable') {
        final offlineName = deviceProps?['name'] as String?;
        logger.printTrace(
          'Skipping offline watchOS device "${offlineName ?? '?'}" '
          '(tunnelState=$tunnelState).',
        );
        continue;
      }

      final udid = deviceMap['identifier'] as String?;
      final String? name = deviceProps?['name'] as String? ?? hardware['marketingName'] as String?;

      if (udid == null || name == null) {
        continue;
      }

      final osVersionNumber = deviceProps?['osVersionNumber'] as String?;
      final osBuildUpdate = deviceProps?['osBuildUpdate'] as String?;
      final String osVersion = <String?>[
        if (osVersionNumber != null) 'watchOS $osVersionNumber',
        osBuildUpdate,
      ].whereType<String>().join(' ');

      devices.add(
        WatchosDevice(
          udid,
          name: name,
          logger: logger,
          isSimulator: false,
          osVersion: osVersion.isEmpty ? null : osVersion,
        ),
      );
    }

    return devices;
  }
}
