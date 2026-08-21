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
  // These arguments reach the Dart VM for real as of engine v0.1.2, so a
  // release app must not be launched asking for a VM Service at all.
  // The app runs on the watch and inherits nothing from this Mac, so a switch
  // typed on the command line only reaches the engine if the launcher carries
  // it. Without this a benchmark cannot pick a renderer per arm at all —
  // --dart-entrypoint-args is desktop-only and goes to Dart's main(), not the
  // embedder.
  group('engine switch forwarding', () {
    testWithoutContext('forwards nothing when nothing is set', () {
      expect(engineSwitchesFromEnvironment(const <String, String>{}), isEmpty);
      expect(engineSwitchArguments(const <String, String>{}), isEmpty);
    });

    testWithoutContext('carries the renderer, vsync and semantics switches', () {
      expect(
        engineSwitchesFromEnvironment(const <String, String>{
          'FLUTTER_WATCHOS_RENDERER': 'metal',
          'FLUTTER_WATCHOS_VSYNC': 'fallback',
          'FLUTTER_WATCHOS_SEMANTICS': '0',
        }),
        <String, String>{
          'FLUTTER_WATCHOS_RENDERER': 'metal',
          'FLUTTER_WATCHOS_VSYNC': 'fallback',
          'FLUTTER_WATCHOS_SEMANTICS': '0',
        },
      );
    });

    testWithoutContext('ignores unrelated and empty variables', () {
      expect(
        engineSwitchesFromEnvironment(const <String, String>{
          'FLUTTER_WATCHOS_RENDERER': '',
          'PATH': '/usr/bin',
          'FLUTTER_WATCHOS_ENGINE_ARTIFACTS': '/somewhere',
        }),
        isEmpty,
      );
    });

    // The host scans argv for this one and never reads the environment, so it
    // cannot ride along with the others.
    testWithoutContext('log-to-file becomes a launch argument, not a variable', () {
      expect(
        engineSwitchArguments(const <String, String>{'FLUTTER_WATCHOS_LOG_TO_FILE': '1'}),
        <String>['--watchos-log-to-file'],
      );
      expect(
        engineSwitchesFromEnvironment(const <String, String>{'FLUTTER_WATCHOS_LOG_TO_FILE': '1'}),
        isEmpty,
      );
    });

    testWithoutContext('log-to-file is off for 0 and for empty', () {
      expect(engineSwitchArguments(const <String, String>{'FLUTTER_WATCHOS_LOG_TO_FILE': '0'}), isEmpty);
      expect(engineSwitchArguments(const <String, String>{'FLUTTER_WATCHOS_LOG_TO_FILE': ''}), isEmpty);
    });
  });

  group('appLaunchArguments', () {
    testWithoutContext('release asks for no VM Service', () {
      expect(
        appLaunchArguments(enableVmService: false, relaying: false),
        isEmpty,
      );
    });

    testWithoutContext('release keeps caller-supplied arguments', () {
      expect(
        appLaunchArguments(
          enableVmService: false,
          relaying: false,
          extraLaunchArguments: <String>['--trace-startup'],
        ),
        <String>['--trace-startup'],
      );
    });

    testWithoutContext('profile enables profiling and drops the auth code', () {
      final List<String> args = appLaunchArguments(enableVmService: true, relaying: false);
      expect(args, contains('--enable-dart-profiling'));
      expect(args, contains('--disable-service-auth-codes'));
    });

    testWithoutContext('binds loopback when relaying, dual-stack otherwise', () {
      // `::0` leaves the service on `[::]`, which the bridge dialling
      // 127.0.0.1 cannot reach — measured, and the symptom is indistinguishable
      // from the service never starting.
      expect(
        appLaunchArguments(enableVmService: true, relaying: true),
        contains('--vm-service-host=127.0.0.1'),
      );
      expect(
        appLaunchArguments(enableVmService: true, relaying: false),
        contains('--vm-service-host=::0'),
      );
    });
  });

  group('WatchosPhysicalDeviceLogReader', () {
    testWithoutContext('records the VM Service line and still passes it through', () async {
      // The relay path has no ProtocolDiscovery subscribed at launch, so this
      // line used to vanish — and its absence looks identical to the VM Service
      // never starting. Capturing it is what makes the two distinguishable.
      final reader = WatchosPhysicalDeviceLogReader('test', logger: BufferLogger.test());
      final lines = <String>[];
      reader.logLines.listen(lines.add);

      reader.processLogLine(
        '2026-07-29 16:35:56.101220+0200 Runner[4140:1863467] '
        'flutter: The Dart VM service is listening on http://127.0.0.1:45651/',
      );
      await Future<void>.delayed(Duration.zero);

      expect(reader.deviceVmServiceUri, 'http://127.0.0.1:45651/');
      // ProtocolDiscovery still needs the line on the non-relay path.
      expect(lines, hasLength(1));

      reader.dispose();
    });

    testWithoutContext('reports no VM Service URI until the VM announces one', () async {
      final reader = WatchosPhysicalDeviceLogReader('test', logger: BufferLogger.test());
      reader.processLogLine('[flutter:flutter] starting up');

      expect(reader.deviceVmServiceUri, isNull);

      reader.dispose();
    });

    testWithoutContext('leaves ordinary app output alone', () async {
      final reader = WatchosPhysicalDeviceLogReader('test', logger: BufferLogger.test());
      final lines = <String>[];
      reader.logLines.listen(lines.add);

      reader.processLogLine('[flutter:flutter] Hello from Dart!');
      await Future<void>.delayed(Duration.zero);

      expect(lines, hasLength(1));

      reader.dispose();
    });
  });

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

    // There is no device debug engine (the watchOS device SDK removes the
    // Mach APIs the Dart JIT VM needs) and no Simulator AOT engine, so
    // startApp must reject the two impossible mode/target combinations with
    // guidance — BEFORE building, where the failure would otherwise surface
    // as a bare "libflutter_engine.dylib not found → run precache".
    testWithoutContext('startApp rejects debug mode on a physical watch with guidance', () async {
      final device = WatchosDevice(
        'physical-id',
        name: 'My Watch',
        logger: BufferLogger.test(),
        isSimulator: false,
      );

      await expectLater(
        device.startApp(null, debuggingOptions: DebuggingOptions.enabled(BuildInfo.debug)),
        throwsToolExit(message: RegExp(r'Debug mode is not supported on a physical Apple Watch[\s\S]*--profile[\s\S]*--release[\s\S]*Simulator')),
      );
    });

    testWithoutContext('startApp rejects AOT modes on the Simulator with guidance', () async {
      final device = WatchosDevice(
        'sim-id',
        name: 'Apple Watch Series 11 (46mm)',
        logger: BufferLogger.test(),
        isSimulator: true,
      );

      await expectLater(
        device.startApp(null, debuggingOptions: DebuggingOptions.disabled(BuildInfo.release)),
        throwsToolExit(message: RegExp(r'--release is not supported on the watchOS Simulator[\s\S]*JIT-only[\s\S]*physical watch')),
      );
      await expectLater(
        device.startApp(null, debuggingOptions: DebuggingOptions.disabled(BuildInfo.profile)),
        throwsToolExit(message: RegExp(r'--profile is not supported on the watchOS Simulator')),
      );
    });
  });
}
