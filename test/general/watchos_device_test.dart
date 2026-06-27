// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_watchos/watchos_device.dart';

import '../src/common.dart';

void main() {
  group('WatchosSimulatorLogReader', () {
    testWithoutContext('rewrites a [flutter:<tag>] eventMessage to `<tag>: msg`', () async {
      // The embedder NSLog-bridges engine/Dart logs as `[flutter:<tag>] ...`;
      // the reader rewrites that to the `<tag>: ...` form `flutter run` shows
      // on iOS, so a watchOS run console reads identically.
      final reader = WatchosSimulatorLogReader('test');
      final lines = <String>[];
      reader.logLines.listen(lines.add);

      reader.processLogLine('{ "eventMessage" : "[flutter:MyTag] Hello from Dart!" }');
      await Future<void>.delayed(Duration.zero);

      expect(lines, hasLength(1));
      expect(lines.first, equals('MyTag: Hello from Dart!'));

      reader.dispose();
    });

    testWithoutContext('passes through an eventMessage with no flutter tag', () async {
      final reader = WatchosSimulatorLogReader('test');
      final lines = <String>[];
      reader.logLines.listen(lines.add);

      reader.processLogLine('{ "eventMessage" : "fatal error: something broke" }');
      await Future<void>.delayed(Duration.zero);

      expect(lines, hasLength(1));
      expect(lines.first, equals('fatal error: something broke'));

      reader.dispose();
    });

    testWithoutContext('ignores lines without an eventMessage', () async {
      final reader = WatchosSimulatorLogReader('test');
      final lines = <String>[];
      reader.logLines.listen(lines.add);

      reader.processLogLine('Filtering the log data using "processImagePath ENDSWITH"');
      reader.processLogLine('[{');
      reader.processLogLine('  "timestamp" : "2026-06-27"');
      await Future<void>.delayed(Duration.zero);

      expect(lines, isEmpty);

      reader.dispose();
    });
  });

  group('WatchosDevice', () {
    testWithoutContext('a simulator reports iOS-family platform and emulator identity', () async {
      final device = WatchosDevice(
        'test-id',
        name: 'Apple Watch Series 11 (46mm)',
        logger: BufferLogger.test(),
        isSimulator: true,
      );

      // watchOS rides the iOS pipeline.
      expect(await device.targetPlatform, equals(TargetPlatform.ios));
      expect(await device.isLocalEmulator, isTrue);
      expect(await device.emulatorId, equals('test-id'));
      expect(await device.sdkNameAndVersion, equals('watchOS'));
    });

    testWithoutContext('a physical watch is not an emulator', () async {
      final device = WatchosDevice(
        'physical-id',
        name: 'My Watch',
        logger: BufferLogger.test(),
        isSimulator: false,
      );

      expect(await device.isLocalEmulator, isFalse);
      expect(await device.emulatorId, isNull);
    });

    testWithoutContext('reports the osVersion in sdkNameAndVersion when present', () async {
      final device = WatchosDevice(
        'test-id',
        name: 'My Watch',
        logger: BufferLogger.test(),
        isSimulator: false,
        osVersion: 'watchOS 11.0',
      );
      expect(await device.sdkNameAndVersion, equals('watchOS 11.0'));
    });

    testWithoutContext('supports debug/profile/release but not jitRelease', () {
      final device = WatchosDevice(
        'test-id',
        name: 'Apple Watch Series 11 (46mm)',
        logger: BufferLogger.test(),
        isSimulator: true,
      );

      expect(device.supportsRuntimeMode(BuildMode.debug), isTrue);
      expect(device.supportsRuntimeMode(BuildMode.profile), isTrue);
      expect(device.supportsRuntimeMode(BuildMode.release), isTrue);
      expect(device.supportsRuntimeMode(BuildMode.jitRelease), isFalse);
    });
  });
}
