// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io show ProcessSignal;

import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/device.dart';
import 'package:flutter_watchos/watchos_device.dart';
import 'package:flutter_watchos/watchos_mode_guidance.dart';

import '../src/common.dart';
import '../src/context.dart';
import '../src/fake_process_manager.dart';

/// A `log stream` process whose output the test writes line by line, and
/// which runs until the test ends it or the reader kills it.
class _LogStreamProcess extends FakeProcess {
  final _stdout = StreamController<List<int>>();
  final _exit = Completer<int>();

  /// Whether the reader killed this process.
  bool killed = false;

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => const Stream<List<int>>.empty();

  @override
  Future<int> get exitCode => _exit.future;

  void emit(String line) => _stdout.add(utf8.encode('$line\n'));

  void end([int code = 0]) {
    if (!_exit.isCompleted) {
      _exit.complete(code);
      unawaited(_stdout.close());
    }
  }

  @override
  bool kill([io.ProcessSignal signal = io.ProcessSignal.sigterm]) {
    killed = true;
    end(-15);
    return true;
  }
}

const _preamble = 'Filtering the log data using "eventType = logEvent"';

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

    // The host reads these three (host/FlutterRunner.swift); the app inherits
    // nothing from this Mac, so they travel like the engine's.
    testWithoutContext('carries the host switches: present, display clock, CPU log', () {
      expect(
        engineSwitchesFromEnvironment(const <String, String>{
          'FLUTTER_WATCHOS_PRESENT': 'texture',
          'FLUTTER_WATCHOS_DISPLAY_CLOCK': 'continuous',
          'FLUTTER_WATCHOS_CPU_LOG': '2',
        }),
        <String, String>{
          'FLUTTER_WATCHOS_PRESENT': 'texture',
          'FLUTTER_WATCHOS_DISPLAY_CLOCK': 'continuous',
          'FLUTTER_WATCHOS_CPU_LOG': '2',
        },
      );
      expect(engineSwitchEnvironment.toSet(), hasLength(engineSwitchEnvironment.length));
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

  // The unified-log predicate, as stock's (simulators_test.dart 'unified
  // logging with app name'), with the watch app's name, without stock's three
  // UIScene clauses and with the [flutter: clause.
  const expectedPredicate =
      'eventType = logEvent AND processImagePath ENDSWITH "/Runner" AND '
      '(senderImagePath ENDSWITH "/Flutter" OR senderImagePath ENDSWITH "/libswiftCore.dylib" '
      'OR processImageUUID == senderImageUUID OR eventMessage CONTAINS "[flutter:") AND '
      'NOT(eventMessage CONTAINS ": could not find icon for representation -> com.apple.") AND '
      'NOT(eventMessage BEGINSWITH "assertion failed: ") AND '
      'NOT(eventMessage CONTAINS " libxpc.dylib ")';

  FakeCommand logStream({FakeProcess? process, String stdout = ''}) => FakeCommand(
    command: const <String>[
      'xcrun',
      'simctl',
      'spawn',
      'sim-1',
      'log',
      'stream',
      '--style',
      'json',
      '--predicate',
      expectedPredicate,
    ],
    process: process,
    stdout: stdout,
  );

  Future<void> pump() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  group('WatchosSimulatorLogReader stream', () {
    late FakeProcessManager processManager;
    late BufferLogger logger;

    setUp(() {
      processManager = FakeProcessManager.empty();
      logger = BufferLogger.test();
    });

    WatchosSimulatorLogReader reader() => WatchosSimulatorLogReader(
      'Apple Watch Series 11 (46mm)',
      deviceId: 'sim-1',
      logger: logger,
    );

    testWithoutContext("the predicate has no UIScene clause and keeps stock's filters", () {
      expect(WatchosSimulatorLogReader.predicate, expectedPredicate);
      expect(WatchosSimulatorLogReader.predicate, isNot(contains('UIScene')));
    });

    testWithoutContext('toString is the device name, for both readers', () {
      expect(reader().toString(), 'Apple Watch Series 11 (46mm)');
      expect(WatchosPhysicalDeviceLogReader('My Watch').toString(), 'My Watch');
    });

    testUsingContext('starts on the first listen, not before', () async {
      final logProcess = _LogStreamProcess();
      processManager.addCommand(logStream(process: logProcess));
      final WatchosSimulatorLogReader subject = reader();
      await pump();
      expect(processManager, isNot(hasNoRemainingExpectations));

      subject.logLines.listen(null);
      await pump();
      expect(processManager, hasNoRemainingExpectations);
      subject.dispose();
    }, overrides: <Type, Generator>{ProcessManager: () => processManager});

    // Mirrors stock simulators_test.dart 'log reader handles escaped
    // multiline messages', plus an escaped quote, which a lazy capture cut.
    testUsingContext('escaped quotes and multi-line messages decode', () async {
      processManager.addCommand(
        logStream(
          stdout: r'''
},{
  "traceID" : 37579774151491588,
  "eventMessage" : "Single line message",
  "eventType" : "logEvent"
},{
  "traceID" : 37579774151491588,
  "eventMessage" : "Multi line message\n  continues...\n  continues..."
},{
  "traceID" : 37579774151491588,
  "eventMessage" : "[flutter:flutter] A \"quoted\" word, then more",
  "eventType" : "logEvent"
},{
''',
        ),
      );
      final lines = <String>[];
      final WatchosSimulatorLogReader subject = reader();
      subject.logLines.listen(lines.add);
      await pump();

      expect(lines, <String>[
        'Single line message',
        'Multi line message\n  continues...\n  continues...',
        'flutter: A "quoted" word, then more',
      ]);
      subject.dispose();
    }, overrides: <Type, Generator>{ProcessManager: () => processManager});

    testUsingContext(
      'a stream that dies is restarted once, and a second death ends the lines',
      () async {
        final first = _LogStreamProcess();
        final second = _LogStreamProcess();
        processManager.addCommands(<FakeCommand>[
          logStream(process: first),
          logStream(process: second),
        ]);
        final WatchosSimulatorLogReader subject = reader();
        var done = false;
        subject.logLines.listen(null, onDone: () => done = true);
        await pump();
        first.emit(_preamble);
        await pump();
        final Future<void> firstReady = subject.ready;

        first.end(1);
        await pump();
        expect(logger.traceText, contains('restarting it once'));
        // ready is re-armed for the new process.
        expect(identical(subject.ready, firstReady), isFalse);
        var ready = false;
        unawaited(subject.ready.then((_) => ready = true));
        await pump();
        expect(ready, isFalse);
        second.emit(_preamble);
        await pump();
        expect(ready, isTrue);

        expect(done, isFalse);
        second.end(1);
        await pump();
        expect(logger.traceText, contains('not restarting it'));
        expect(logger.traceText, isNot(contains('Could not start')));
        // Nothing more will come: listeners such as `logs` are told so.
        expect(done, isTrue);
        expect(processManager, hasNoRemainingExpectations);
        subject.dispose();
      },
      overrides: <Type, Generator>{ProcessManager: () => processManager},
    );

    testUsingContext('a stream that ends before it goes live is not restarted', () async {
      processManager.addCommand(
        FakeCommand(
          command: logStream().command,
          exitCode: 149,
          stderr: 'Unable to lookup in current state: Shutdown',
        ),
      );
      final WatchosSimulatorLogReader subject = reader();
      subject.logLines.listen(null);
      await pump();

      expect(logger.traceText, contains('ended before it went live'));
      expect(processManager, hasNoRemainingExpectations);
      subject.dispose();
    }, overrides: <Type, Generator>{ProcessManager: () => processManager});

    testUsingContext('ensureStarted reuses a live stream', () async {
      final first = _LogStreamProcess();
      final second = _LogStreamProcess();
      processManager.addCommands(<FakeCommand>[
        logStream(process: first),
        logStream(process: second),
      ]);
      final WatchosSimulatorLogReader subject = reader();
      subject.logLines.listen(null);
      await pump();
      first.emit(_preamble);
      await subject.ensureStarted();
      await pump();
      expect(processManager, isNot(hasNoRemainingExpectations));

      first.end(1);
      await pump(); // The one restart.
      expect(processManager, hasNoRemainingExpectations);
      subject.dispose();
    }, overrides: <Type, Generator>{ProcessManager: () => processManager});

    testUsingContext('the last cancel stops the stream', () async {
      final logProcess = _LogStreamProcess();
      processManager.addCommand(logStream(process: logProcess));
      final WatchosSimulatorLogReader subject = reader();
      final StreamSubscription<String> a = subject.logLines.listen(null);
      final StreamSubscription<String> b = subject.logLines.listen(null);
      await pump();

      await a.cancel();
      expect(logProcess.killed, isFalse);
      await b.cancel();
      expect(logProcess.killed, isTrue);
      // Stopped on purpose: no restart.
      await pump();
      expect(logger.traceText, isNot(contains('restarting')));
      subject.dispose();
    }, overrides: <Type, Generator>{ProcessManager: () => processManager});

    testUsingContext('dispose stops the stream and ends the lines', () async {
      final logProcess = _LogStreamProcess();
      processManager.addCommand(logStream(process: logProcess));
      final WatchosSimulatorLogReader subject = reader();
      final done = Completer<void>();
      subject.logLines.listen(null, onDone: done.complete);
      await pump();

      subject.dispose();
      await done.future;
      expect(logProcess.killed, isTrue);
    }, overrides: <Type, Generator>{ProcessManager: () => processManager});
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

    // Mirrors stock simulators_test.dart 'simulators only support debug mode':
    // the Simulator engine is JIT-only.
    testWithoutContext('a Simulator only supports debug mode', () {
      final device = WatchosDevice(
        'test-id',
        name: 'Apple Watch Series 11 (46mm)',
        logger: BufferLogger.test(),
        isSimulator: true,
      );

      expect(device.supportsRuntimeMode(BuildMode.debug), isTrue);
      expect(device.supportsRuntimeMode(BuildMode.profile), isFalse);
      expect(device.supportsRuntimeMode(BuildMode.release), isFalse);
      expect(device.supportsRuntimeMode(BuildMode.jitRelease), isFalse);
    });

    // There is no device debug engine (the watchOS device SDK removes the
    // Mach APIs the Dart JIT VM needs) and no Simulator AOT engine, so
    // startApp must reject the two impossible mode/target combinations with
    // guidance, before building, where the failure would otherwise surface
    // as a bare "libflutter_engine.dylib not found → run precache". The
    // guidance is an error line and a failed launch, not a tool exit: the
    // runners print an exception from startApp with its stack trace.
    testWithoutContext('startApp rejects debug mode on a physical watch with guidance', () async {
      final logger = BufferLogger.test();
      final device = WatchosDevice(
        'physical-id',
        name: 'My Watch',
        logger: logger,
        isSimulator: false,
      );

      final LaunchResult result = await device.startApp(
        null,
        debuggingOptions: DebuggingOptions.enabled(BuildInfo.debug),
      );

      expect(result.started, isFalse);
      expect(
        logger.errorText,
        matches(RegExp(r'Debug mode is not supported on a physical Apple Watch[\s\S]*--profile[\s\S]*--release[\s\S]*Simulator')),
      );
      expect(logger.errorText, isNot(contains('#0')));
    });

    testWithoutContext('startApp rejects AOT modes on the Simulator with guidance', () async {
      for (final mode in <BuildInfo>[BuildInfo.release, BuildInfo.profile]) {
        final logger = BufferLogger.test();
        final device = WatchosDevice(
          'sim-id',
          name: 'Apple Watch Series 11 (46mm)',
          logger: logger,
          isSimulator: true,
        );

        final LaunchResult result = await device.startApp(
          null,
          debuggingOptions: DebuggingOptions.disabled(mode),
        );

        expect(result.started, isFalse);
        expect(
          logger.errorText,
          matches(RegExp('--${mode.mode.cliName} is not supported on the watchOS Simulator[\\s\\S]*JIT-only[\\s\\S]*physical watch')),
        );
        expect(logger.errorText, isNot(contains('#0')));
      }
    });

    testWithoutContext('a prebuilt AOT app is refused on the Simulator too', () async {
      final logger = BufferLogger.test();
      final device = WatchosDevice(
        'sim-id',
        name: 'Apple Watch Series 11 (46mm)',
        logger: logger,
        isSimulator: true,
      );

      final LaunchResult result = await device.startApp(
        null,
        prebuiltApplication: true,
        debuggingOptions: DebuggingOptions.disabled(BuildInfo.release),
      );

      expect(result.started, isFalse);
      expect(logger.errorText, contains('--release is not supported on the watchOS Simulator'));
    });

    testWithoutContext('unsupportedModeGuidance is null for the modes a target runs', () {
      final simulator = WatchosDevice('s', name: 'S', logger: BufferLogger.test(), isSimulator: true);
      final watch = WatchosDevice('w', name: 'W', logger: BufferLogger.test(), isSimulator: false);

      expect(simulator.unsupportedModeGuidance(BuildMode.debug), isNull);
      expect(watch.unsupportedModeGuidance(BuildMode.profile), isNull);
      expect(watch.unsupportedModeGuidance(BuildMode.release), isNull);
      expect(watch.unsupportedModeGuidance(BuildMode.debug), startsWith('Debug mode is not supported'));
    });

    // One source for the mode guidance: what startApp prints is run's
    // guidance, so no second text with comments after its commands exists.
    testWithoutContext("unsupportedModeGuidance is run's paste-ready guidance", () {
      for (final simulator in <bool>[true, false]) {
        final device = WatchosDevice(
          'id-1',
          name: 'W',
          logger: BufferLogger.test(),
          isSimulator: simulator,
        );
        for (final BuildMode mode in BuildMode.values) {
          final String? guidance = device.unsupportedModeGuidance(mode);
          expect(
            guidance,
            watchosModeRefusal(
              command: WatchosModeCommand.run,
              mode: mode,
              simulator: simulator,
              deviceId: 'id-1',
            ),
            reason: '${simulator ? 'Simulator' : 'watch'} ${mode.cliName}',
          );
          expect(guidance ?? '', isNot(contains('#')));
        }
      }
    });
  });
}
