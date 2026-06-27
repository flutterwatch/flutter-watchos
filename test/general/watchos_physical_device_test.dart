// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/device.dart';
import 'package:flutter_watchos/watchos_device.dart';

import '../src/common.dart';

void main() {
  group('WatchosPhysicalDeviceLogReader noise filtering', () {
    late WatchosPhysicalDeviceLogReader reader;
    late List<String> lines;

    setUp(() {
      reader = WatchosPhysicalDeviceLogReader('test', logger: BufferLogger.test());
      lines = <String>[];
      reader.logLines.listen(lines.add);
    });

    tearDown(() => reader.dispose());

    testWithoutContext('emits real flutter output', () async {
      reader.processLogLine(
        'flutter: The Dart VM service is listening on http://127.0.0.1:12345/abc=/',
      );
      await Future<void>.delayed(Duration.zero);
      expect(lines, hasLength(1));
      expect(lines.first, contains('Dart VM service'));
    });

    testWithoutContext('emits non-noise lines unchanged', () async {
      reader.processLogLine('Some debug output');
      reader.processLogLine('flutter: Hello!');
      reader.processLogLine('Another line');
      await Future<void>.delayed(Duration.zero);
      expect(lines, hasLength(3));
    });

    testWithoutContext('suppresses devicectl progress + script wrapper + system noise', () async {
      reader.processLogLine('Script started, output file is /dev/null');
      reader.processLogLine('07:49:03  Acquired tunnel connection to device.');
      reader.processLogLine('07:49:03  Enabling developer mode throttling override.');
      reader.processLogLine('07:49:04  Establishing a tunnel connection to the device.');
      reader.processLogLine('07:49:05  Resolved tunnel endpoint.');
      reader.processLogLine('Script done, output file is /dev/null');
      reader.processLogLine('2026-06-27 07:49:05.123+0200 Runner[1234] [Scene] update started');
      reader.processLogLine('2026-06-27 07:49:05.200+0200 Runner[1234] [UIKitCore] layout');
      reader.processLogLine('');
      reader.processLogLine('flutter: VM service listening on http://0.0.0.0:12345/abc=/');
      await Future<void>.delayed(Duration.zero);
      expect(lines, hasLength(1));
      expect(lines.first, contains('VM service'));
    });

    testWithoutContext('suppresses verbatim system noise and the benign hang breadcrumb', () async {
      reader.processLogLine(
        '2026-06-27 11:21:48.891334+0200 Runner[2936] '
        'Warning: Unable to create restoration in progress marker file',
      );
      reader.processLogLine(
        '2026-06-27 11:21:49.030171+0200 Runner[2936] '
        'fopen failed for data file: errno = 2 (No such file or directory)',
      );
      reader.processLogLine('2026-06-27 11:21:49.030179+0200 Runner[2936] Errors found! Invalidating cache...');
      reader.processLogLine(
        '2026-06-27 11:21:54.413893+0200 Runner[2936] [] App is being debugged, do not track this hang',
      );
      reader.processLogLine(
        '2026-06-27 11:21:54.413893+0200 Runner[2936] [] '
        'Hang detected: 3.05s (debugger attached, not reporting)',
      );
      reader.processLogLine('flutter: hello world');
      await Future<void>.delayed(Duration.zero);
      expect(lines, hasLength(1));
      expect(lines.first, contains('hello world'));
    });

    testWithoutContext('suppresses the benign BackBoardServices snapshot failure only', () async {
      // `response-not-possible` snapshot-on-background is benign noise…
      reader.processLogLine(
        '2026-06-27 11:31:59.884006+0200 Runner[2956] [Common] '
        'Snapshot request 0x3001eed60 complete with error: '
        '<NSError: 0x3001df870; domain: BSActionErrorDomain; code: 1 ("response-not-possible")>',
      );
      // …but a different BSActionErrorDomain failure is signal — pass it through.
      reader.processLogLine(
        '2026-06-27 11:32:13.107011+0200 Runner[2956] [Common] '
        'Snapshot request 0x3001a1ef0 complete with error: '
        '<NSError: 0x3001ef900; domain: BSActionErrorDomain; code: 5 ("denied")>',
      );
      await Future<void>.delayed(Duration.zero);
      expect(lines, hasLength(1));
      expect(lines.first, contains('denied'));
    });

    testWithoutContext('does not swallow a real (non-debugger) hang detection', () async {
      reader.processLogLine(
        '2026-06-27 11:21:54.413893+0200 Runner[2936] [] '
        'Hang detected: 12.5s (always-reporting telemetry)',
      );
      await Future<void>.delayed(Duration.zero);
      expect(lines, hasLength(1));
      expect(lines.first, contains('Hang detected'));
    });
  });

  group('WatchosDevice physical properties', () {
    testWithoutContext('a physical watch is not an emulator and supports AOT modes', () async {
      final device = WatchosDevice(
        'physical-watch-id',
        name: 'My Watch',
        logger: BufferLogger.test(),
        isSimulator: false,
      );
      expect(await device.isLocalEmulator, isFalse);
      expect(await device.emulatorId, isNull);
      expect(device.supportsRuntimeMode(BuildMode.release), isTrue);
      expect(device.supportsRuntimeMode(BuildMode.jitRelease), isFalse);
    });

    testWithoutContext('getLogReader returns the physical reader for a device', () async {
      final device = WatchosDevice(
        'physical-id',
        name: 'My Watch',
        logger: BufferLogger.test(),
        isSimulator: false,
      );
      final DeviceLogReader logReader = await device.getLogReader();
      expect(logReader, isA<WatchosPhysicalDeviceLogReader>());
    });

    testWithoutContext('getLogReader returns the simulator reader for a sim', () async {
      final device = WatchosDevice(
        'sim-id',
        name: 'Apple Watch Series 11 (46mm)',
        logger: BufferLogger.test(),
        isSimulator: true,
      );
      final DeviceLogReader logReader = await device.getLogReader();
      expect(logReader, isA<WatchosSimulatorLogReader>());
    });
  });

  group('WatchosDevice.parseDeviceUdid', () {
    // The Xcode-debugger fallback identifies the device by its hardware UDID,
    // read from `devicectl device info details --json-output`.
    testWithoutContext('extracts the hardware UDID from devicectl info details JSON', () {
      const jsonOutput = '''
{
  "result": {
    "hardwareProperties": {
      "udid": "00008110-00114D2E36F0A01E",
      "platform": "watchOS",
      "marketingName": "Apple Watch Series 11"
    }
  },
  "info": { "outcome": "success" }
}
''';
      expect(WatchosDevice.parseDeviceUdid(jsonOutput), '00008110-00114D2E36F0A01E');
    });

    testWithoutContext('returns null when the UDID is missing', () {
      expect(WatchosDevice.parseDeviceUdid('{"result": {"hardwareProperties": {}}}'), isNull);
      expect(WatchosDevice.parseDeviceUdid('{"result": {}}'), isNull);
      expect(WatchosDevice.parseDeviceUdid('{}'), isNull);
    });

    testWithoutContext('returns null for malformed or empty JSON', () {
      expect(WatchosDevice.parseDeviceUdid('not json'), isNull);
      expect(WatchosDevice.parseDeviceUdid(''), isNull);
    });
  });
}
