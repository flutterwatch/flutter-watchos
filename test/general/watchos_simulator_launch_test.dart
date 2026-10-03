// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io show ProcessSignal;

import 'package:fake_async/fake_async.dart';
import 'package:file/memory.dart';
import 'package:flutter_tools/src/application_package.dart';
import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/base/process.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/device.dart';
import 'package:flutter_tools/src/drive/drive_service.dart';
import 'package:flutter_tools/src/macos/xcode.dart';
import 'package:flutter_tools/src/resident_runner.dart';
import 'package:flutter_watchos/watchos_application_package.dart';
import 'package:flutter_watchos/watchos_device.dart';

import 'package:test/fake.dart';

import '../src/common.dart';
import '../src/context.dart';
import '../src/fake_process_manager.dart';

// The Simulator launch flow of WatchosDevice.startApp: boot, install,
// terminate, start the unified-log stream, launch, then find the VM Service
// line in the log. These tests drive it with scripted processes and fake time.

const _simId = 'sim-1';
const _bundleId = 'com.example.demo';
const _appPath = '/build/watchos/Debug-watchsimulator/Runner.app';
const _preamble = 'Filtering the log data using "eventType = logEvent"';

/// `simctl launch` of a debug run with default options: stock's launch
/// arguments minus the filtered ones leave only the profiling flag.
const _launchCommand = <String>[
  'xcrun',
  'simctl',
  'launch',
  _simId,
  _bundleId,
  '--enable-dart-profiling',
];

// `log stream --style json` prints one field per line.
const _vmServiceLine =
    '  "eventMessage" : "[flutter:flutter] The Dart VM service is listening on '
    'http://127.0.0.1:50123/abc=/",';

/// The three engine switches and the three host switches, all set.
const _switches = <String, String>{
  'FLUTTER_WATCHOS_RENDERER': 'software',
  'FLUTTER_WATCHOS_VSYNC': 'fallback',
  'FLUTTER_WATCHOS_SEMANTICS': '0',
  'FLUTTER_WATCHOS_PRESENT': 'texture',
  'FLUTTER_WATCHOS_DISPLAY_CLOCK': 'continuous',
  'FLUTTER_WATCHOS_CPU_LOG': '2',
};

/// A `log stream` process whose output the test writes line by line, and
/// which runs until the test ends it.
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

class _Packages extends Fake implements ApplicationPackageFactory {
  _Packages(this.app);

  final ApplicationPackage app;

  @override
  Future<ApplicationPackage?> getPackageForPlatform(
    TargetPlatform platform, {
    BuildInfo? buildInfo,
    File? applicationBinary,
  }) async => app;
}

class _NoDevtools extends Fake implements DevtoolsLauncher {}

/// Xcode 27's Simulator viewer.
const _deviceHub = '/Applications/Xcode.app/Contents/Applications/DeviceHub.app';

/// An Xcode whose Simulator viewer is at [simulatorPath].
class _FakeXcode extends Fake implements Xcode {
  _FakeXcode(this.simulatorPath);

  final String? simulatorPath;

  @override
  String? getSimulatorPath() => simulatorPath;
}

FakeCommand _run(
  List<String> command, {
  int exitCode = 0,
  String stderr = '',
  void Function(List<String>)? onRun,
}) => FakeCommand(command: command, exitCode: exitCode, stderr: stderr, onRun: onRun);

FakeCommand _logStream(_LogStreamProcess process) => FakeCommand(
  command: <Pattern>[
    'xcrun',
    'simctl',
    'spawn',
    _simId,
    'log',
    'stream',
    '--style',
    'json',
    '--predicate',
    RegExp('.+'),
  ],
  process: process,
);

/// Advances fake time by [by], then lets the callbacks that Dart's stream
/// internals leave on the real event loop run, with the fake microtasks they
/// schedule in turn.
Future<void> _advance(FakeAsync time, Duration by) async {
  time.elapse(by);
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
    time.flushMicrotasks();
    time.elapse(Duration.zero);
  }
}

void main() {
  late MemoryFileSystem fileSystem;
  late FakeProcessManager processManager;
  late BufferLogger logger;
  late FakeAsync time;

  setUp(() {
    fileSystem = MemoryFileSystem.test();
    fileSystem.directory(_appPath).createSync(recursive: true);
    processManager = FakeProcessManager.empty();
    logger = BufferLogger.test();
    time = FakeAsync();
  });

  WatchosDevice simulator() => WatchosDevice(
    _simId,
    name: 'Apple Watch Series 11 (46mm)',
    logger: logger,
    isSimulator: true,
  );

  WatchosApp app() => WatchosApp(id: _bundleId, projectDirectory: fileSystem.directory('/watchos'));

  /// Starts a prebuilt debug launch in fake time; the result lands in the
  /// returned list once the launch returns.
  List<LaunchResult> start([WatchosDevice? device, DebuggingOptions? options]) {
    final results = <LaunchResult>[];
    time.run((_) {
      (device ?? simulator())
          .startApp(
            app(),
            prebuiltApplication: true,
            debuggingOptions: options ?? DebuggingOptions.enabled(BuildInfo.debug),
          )
          .then(results.add);
    });
    return results;
  }

  List<FakeCommand> upToTheLogStream(_LogStreamProcess logProcess) => <FakeCommand>[
    _run(<String>['xcrun', 'simctl', 'boot', _simId]),
    _run(<String>['open', '-a', _deviceHub]),
    _run(<String>['xcrun', 'simctl', 'install', _simId, _appPath]),
    _run(<String>['xcrun', 'simctl', 'terminate', _simId, _bundleId]),
    _logStream(logProcess),
  ];

  testUsingContext(
    'boots, installs, terminates, starts the log stream, then launches',
    () async {
      final _LogStreamProcess logProcess = time.run((_) => _LogStreamProcess());
      processManager.addCommands(<FakeCommand>[
        ...upToTheLogStream(logProcess),
        _run(
          _launchCommand,
          // The app prints its VM Service line shortly after it starts.
          onRun: (_) =>
              Timer(const Duration(milliseconds: 100), () => logProcess.emit(_vmServiceLine)),
        ),
      ]);

      final List<LaunchResult> results = start();
      await _advance(time, Duration.zero);
      time.run((_) => logProcess.emit(_preamble));
      await _advance(time, const Duration(seconds: 1));

      expect(results, hasLength(1));
      expect(results.single.started, isTrue);
      expect(results.single.vmServiceUri, Uri.parse('http://127.0.0.1:50123/abc=/'));
      expect(processManager, hasNoRemainingExpectations);
    },
    overrides: <Type, Generator>{
      FileSystem: () => fileSystem,
      ProcessManager: () => processManager,
      Xcode: () => _FakeXcode(_deviceHub),
    },
  );

  // Each of the six switches reaches the app once, through the variable
  // simctl hands to the launched app.
  testUsingContext(
    'the launch carries every switch to the app as SIMCTL_CHILD_',
    () async {
      final _LogStreamProcess logProcess = time.run((_) => _LogStreamProcess());
      processManager.addCommands(<FakeCommand>[
        ...upToTheLogStream(logProcess),
        FakeCommand(
          command: _launchCommand,
          environment: <String, String>{
            for (final MapEntry<String, String> e in _switches.entries)
              'SIMCTL_CHILD_${e.key}': e.value,
          },
          onRun: (_) =>
              Timer(const Duration(milliseconds: 100), () => logProcess.emit(_vmServiceLine)),
        ),
      ]);

      final List<LaunchResult> results = start();
      await _advance(time, Duration.zero);
      time.run((_) => logProcess.emit(_preamble));
      await _advance(time, const Duration(seconds: 1));

      expect(results.single.started, isTrue);
      expect(processManager, hasNoRemainingExpectations);
    },
    overrides: <Type, Generator>{
      FileSystem: () => fileSystem,
      ProcessManager: () => processManager,
      Xcode: () => _FakeXcode(_deviceHub),
      Platform: () => FakePlatform(environment: _switches),
    },
  );

  testUsingContext(
    'an install failure is reported and stops the launch',
    () async {
      processManager.addCommands(<FakeCommand>[
        _run(<String>['xcrun', 'simctl', 'boot', _simId]),
        _run(<String>['open', '-a', _deviceHub]),
        _run(
          <String>['xcrun', 'simctl', 'install', _simId, _appPath],
          exitCode: 1,
          stderr: 'No space left',
        ),
      ]);

      final List<LaunchResult> results = start();
      await _advance(time, const Duration(seconds: 1));

      expect(results, hasLength(1));
      expect(results.single.started, isFalse);
      expect(logger.errorText, contains('simctl install failed: No space left'));
      // Nothing after the install ran: no terminate, no log stream, no launch.
      expect(processManager, hasNoRemainingExpectations);
    },
    overrides: <Type, Generator>{
      FileSystem: () => fileSystem,
      ProcessManager: () => processManager,
      Xcode: () => _FakeXcode(_deviceHub),
    },
  );

  testUsingContext(
    'a log stream that is not ready after 10 s still leads to a launch',
    () async {
      final _LogStreamProcess logProcess = time.run((_) => _LogStreamProcess());
      var launched = false;
      processManager.addCommands(<FakeCommand>[
        ...upToTheLogStream(logProcess),
        _run(_launchCommand, onRun: (_) => launched = true),
      ]);

      start();
      await _advance(time, const Duration(seconds: 9));
      expect(launched, isFalse);

      await _advance(time, const Duration(seconds: 2));
      expect(launched, isTrue);
      expect(logger.traceText, contains('Timed out waiting for simctl log stream to go live'));
      await _advance(time, const Duration(minutes: 2));
    },
    overrides: <Type, Generator>{
      FileSystem: () => fileSystem,
      ProcessManager: () => processManager,
      Xcode: () => _FakeXcode(_deviceHub),
    },
  );

  // Stock waits for the VM Service line with no limit; a watch Simulator
  // launch fails after 60 s and says what it saw (spec 0005 criterion 11).
  testUsingContext(
    'with no VM Service line after 60 s the launch fails and names what it saw',
    () async {
      final _LogStreamProcess logProcess = time.run((_) => _LogStreamProcess());
      processManager.addCommands(<FakeCommand>[
        ...upToTheLogStream(logProcess),
        const FakeCommand(command: _launchCommand, stdout: '$_bundleId: 4242\n'),
        _run(<String>['ps', '-p', '4242', '-o', 'pid=']),
      ]);

      final List<LaunchResult> results = start();
      await _advance(time, Duration.zero);
      time.run((_) => logProcess.emit(_preamble));
      await _advance(time, const Duration(seconds: 59));
      expect(results, isEmpty);

      await _advance(time, const Duration(seconds: 2));
      expect(results.single.started, isFalse);
      expect(logger.errorText, contains('no Dart VM Service address within 60 seconds'));
      expect(logger.errorText, contains('The Simulator log stream was live before the launch'));
      expect(logger.errorText, contains('the app is still running (pid 4242)'));
      expect(processManager, hasNoRemainingExpectations);
    },
    overrides: <Type, Generator>{
      FileSystem: () => fileSystem,
      ProcessManager: () => processManager,
      Xcode: () => _FakeXcode(_deviceHub),
    },
  );

  testUsingContext(
    'the failure says when the stream never went live and the app is gone',
    () async {
      final _LogStreamProcess logProcess = time.run((_) => _LogStreamProcess());
      processManager.addCommands(<FakeCommand>[
        ...upToTheLogStream(logProcess),
        const FakeCommand(command: _launchCommand, stdout: '$_bundleId: 4242\n'),
        _run(<String>['ps', '-p', '4242', '-o', 'pid='], exitCode: 1),
      ]);

      final List<LaunchResult> results = start();
      await _advance(time, const Duration(seconds: 71));

      expect(results.single.started, isFalse);
      expect(logger.errorText, contains('never went live, so the address may have been missed'));
      expect(logger.errorText, contains('the app is no longer running (pid 4242)'));
    },
    overrides: <Type, Generator>{
      FileSystem: () => fileSystem,
      ProcessManager: () => processManager,
      Xcode: () => _FakeXcode(_deviceHub),
    },
  );

  testUsingContext(
    'with debugging off the launch does not wait for a VM Service',
    () async {
      final _LogStreamProcess logProcess = time.run((_) => _LogStreamProcess());
      processManager.addCommands(<FakeCommand>[
        ...upToTheLogStream(logProcess),
        _run(_launchCommand),
      ]);

      final List<LaunchResult> results = start(null, DebuggingOptions.disabled(BuildInfo.debug));
      await _advance(time, Duration.zero);
      time.run((_) => logProcess.emit(_preamble));
      await _advance(time, Duration.zero);

      expect(results.single.started, isTrue);
      expect(results.single.vmServiceUri, isNull);
      expect(processManager, hasNoRemainingExpectations);
    },
    overrides: <Type, Generator>{
      FileSystem: () => fileSystem,
      ProcessManager: () => processManager,
      Xcode: () => _FakeXcode(_deviceHub),
    },
  );

  // drive tries three launches (stock drive_service.dart). Each one fails
  // cleanly, so drive ends with its own message, not a null-check error on a
  // started launch that has no VM Service.
  testUsingContext(
    'drive against launches that never print the VM Service fails to start',
    () async {
      final _LogStreamProcess logProcess = time.run((_) => _LogStreamProcess());
      FakeCommand launch() =>
          const FakeCommand(command: _launchCommand, stdout: '$_bundleId: 4242\n');
      FakeCommand ps() => _run(<String>['ps', '-p', '4242', '-o', 'pid=']);
      List<FakeCommand> again() => <FakeCommand>[
        _run(<String>['xcrun', 'simctl', 'boot', _simId]),
        _run(<String>['open', '-a', _deviceHub]),
        _run(<String>['xcrun', 'simctl', 'install', _simId, _appPath]),
        _run(<String>['xcrun', 'simctl', 'terminate', _simId, _bundleId]),
        launch(),
        ps(),
      ];
      processManager.addCommands(<FakeCommand>[
        ...upToTheLogStream(logProcess),
        launch(),
        ps(),
        ...again(),
        ...again(),
      ]);
      final driver = FlutterDriverService(
        applicationPackageFactory: _Packages(app()),
        logger: logger,
        platform: FakePlatform(),
        processUtils: ProcessUtils(processManager: processManager, logger: logger),
        dartSdkPath: 'dart',
        devtoolsLauncher: _NoDevtools(),
      );

      Object? error;
      time.run((_) {
        driver
            .start(
              BuildInfo.debug,
              simulator(),
              DebuggingOptions.enabled(BuildInfo.debug),
              applicationBinary: fileSystem.file(_appPath),
            )
            .then<void>((_) {}, onError: (Object e) => error = e);
      });
      await _advance(time, Duration.zero);
      time.run((_) => logProcess.emit(_preamble));
      for (var i = 0; i < 3; i++) {
        await _advance(time, const Duration(seconds: 61));
      }

      expect(
        error,
        isA<ToolExit>().having(
          (ToolExit e) => e.message,
          'message',
          contains('Application failed to start'),
        ),
      );
      expect(processManager, hasNoRemainingExpectations);
    },
    overrides: <Type, Generator>{
      FileSystem: () => fileSystem,
      ProcessManager: () => processManager,
      Xcode: () => _FakeXcode(_deviceHub),
    },
  );

  // `run` listens to the log reader before startApp has built the app and
  // booted the Simulator, so the reader's first start can fail.
  testUsingContext(
    'a listen before the boot fails once; startApp starts the stream after the boot',
    () async {
      final _LogStreamProcess logProcess = time.run((_) => _LogStreamProcess());
      processManager.addCommands(<FakeCommand>[
        // The early start, on a Simulator that is still shut down.
        FakeCommand(
          command: _logStream(logProcess).command,
          exitCode: 149,
          stderr: 'Unable to lookup in current state: Shutdown',
        ),
        ...upToTheLogStream(logProcess),
        _run(
          _launchCommand,
          onRun: (_) =>
              Timer(const Duration(milliseconds: 100), () => logProcess.emit(_vmServiceLine)),
        ),
      ]);
      final WatchosDevice device = simulator();
      final lines = <String>[];
      unawaited(
        time.run((_) async {
          final DeviceLogReader reader = await device.getLogReader();
          reader.logLines.listen(lines.add);
        }),
      );
      await _advance(time, const Duration(seconds: 1));
      expect(logger.traceText, contains('ended before it went live'));

      final List<LaunchResult> results = start(device);
      await _advance(time, Duration.zero);
      time.run((_) => logProcess.emit(_preamble));
      await _advance(time, const Duration(seconds: 1));

      expect(results.single.vmServiceUri, Uri.parse('http://127.0.0.1:50123/abc=/'));
      // The early listener, run's console, gets the lines of the second start.
      expect(lines, contains(startsWith('flutter: The Dart VM service is listening on')));
      expect(processManager, hasNoRemainingExpectations);
    },
    overrides: <Type, Generator>{
      FileSystem: () => fileSystem,
      ProcessManager: () => processManager,
      Xcode: () => _FakeXcode(_deviceHub),
    },
  );

  testUsingContext(
    'startApp reuses a live stream, and holds it after discovery cancels',
    () async {
      final _LogStreamProcess logProcess = time.run((_) => _LogStreamProcess());
      processManager.addCommands(<FakeCommand>[
        _logStream(logProcess),
        _run(<String>['xcrun', 'simctl', 'boot', _simId]),
        _run(<String>['open', '-a', _deviceHub]),
        _run(<String>['xcrun', 'simctl', 'install', _simId, _appPath]),
        _run(<String>['xcrun', 'simctl', 'terminate', _simId, _bundleId]),
        // No second log stream.
        _run(
          _launchCommand,
          onRun: (_) =>
              Timer(const Duration(milliseconds: 100), () => logProcess.emit(_vmServiceLine)),
        ),
        _run(<String>['xcrun', 'simctl', 'terminate', _simId, _bundleId]),
      ]);
      final WatchosDevice device = simulator();
      final lines = <String>[];
      late StreamSubscription<String> console;
      unawaited(
        time.run((_) async {
          final DeviceLogReader reader = await device.getLogReader();
          console = reader.logLines.listen(lines.add);
        }),
      );
      await _advance(time, Duration.zero);
      time.run((_) => logProcess.emit(_preamble));
      await _advance(time, Duration.zero);

      final List<LaunchResult> results = start(device);
      await _advance(time, const Duration(seconds: 1));
      expect(results.single.vmServiceUri, isNotNull);

      // Discovery has cancelled its subscription, and the console leaves too:
      // startApp's own hold keeps the stream running.
      await time.run((_) => console.cancel());
      await _advance(time, Duration.zero);
      expect(logProcess.killed, isFalse);

      // Stopping the app releases it.
      unawaited(time.run((_) => device.stopApp(app())));
      await _advance(time, Duration.zero);
      expect(logProcess.killed, isTrue);
      expect(processManager, hasNoRemainingExpectations);
    },
    overrides: <Type, Generator>{
      FileSystem: () => fileSystem,
      ProcessManager: () => processManager,
      Xcode: () => _FakeXcode(_deviceHub),
    },
  );

  group('SimulatorLaunchOptions', () {
    // Mirrors stock simulators_test.dart 'startApp forwards all supported
    // debugging options', with DDS on, so no host port binds the VM.
    DebuggingOptions everyOption({int? hostPort, int? devicePort, bool dds = true}) =>
        DebuggingOptions.enabled(
          const BuildInfo(
            BuildMode.debug,
            'flavor',
            treeShakeIcons: false,
            packageConfigPath: '.dart_tool/package_config.json',
          ),
          enableSoftwareRendering: true,
          traceSystrace: true,
          traceToFile: 'path/to/trace.binpb',
          startPaused: true,
          disableServiceAuthCodes: true,
          skiaDeterministicRendering: true,
          useTestFonts: true,
          traceSkia: true,
          traceAllowlist: 'foo,bar',
          traceSkiaAllowlist: 'skia.a,skia.b',
          endlessTraceBuffer: true,
          profileMicrotasks: true,
          profileStartup: true,
          verboseSystemLogs: true,
          purgePersistentCache: true,
          dartFlags: '--baz',
          enableImpeller: ImpellerStatus.disabled,
          enableFlutterGpu: true,
          enableDds: dds,
          hostVmServicePort: hostPort,
          deviceVmServicePort: devicePort,
        );

    const forwarded = <String>[
      '--enable-dart-profiling',
      '--profile-startup',
      '--disable-service-auth-codes',
      '--start-paused',
      '--dart-flags=--baz',
      '--use-test-fonts',
      '--trace-systrace',
      '--trace-to-file="path/to/trace.binpb"',
      '--skia-deterministic-rendering',
      '--trace-skia',
      '--trace-allowlist="foo,bar"',
      '--trace-skia-allowlist="skia.a,skia.b"',
      '--endless-trace-buffer',
      '--profile-microtasks',
      '--verbose-logging',
      '--purge-persistent-cache',
      '--route=/details',
      '--trace-startup',
    ];

    testWithoutContext('forwards stock options minus the filtered flags, each once', () {
      final options = SimulatorLaunchOptions(
        everyOption(),
        route: '/details',
        platformArgs: const <String, Object?>{'trace-startup': true},
      );

      expect(options.arguments, unorderedEquals(forwarded));
      expect(options.arguments.toSet(), hasLength(options.arguments.length));
      for (final filtered in <String>[
        '--enable-checked-mode',
        '--verify-entry-points',
        '--enable-software-rendering',
        '--enable-impeller=false',
        '--enable-flutter-gpu',
      ]) {
        expect(options.arguments, isNot(contains(filtered)));
      }
      expect(options.environment, <String, String>{'FLUTTER_WATCHOS_RENDERER': 'software'});
      expect(options.warning, isNull);
    });

    testWithoutContext('a device port binds the VM on the Simulator', () {
      final options = SimulatorLaunchOptions(everyOption(devicePort: 50999));

      expect(options.arguments.where((String a) => a.startsWith('--vm-service-port')), <String>[
        '--vm-service-port=50999',
      ]);
      expect(options.discoveryDevicePort, 50999);
      expect(options.discoveryHostPort, isNull);
    });

    testWithoutContext('with --no-dds, the device port wins over the host port', () {
      final options = SimulatorLaunchOptions(
        everyOption(dds: false, hostPort: 50111, devicePort: 50999),
      );

      expect(options.arguments.where((String a) => a.startsWith('--vm-service-port')), <String>[
        '--vm-service-port=50999',
      ]);
      expect(options.warning, contains('--host-vmservice-port 50111 is ignored'));
      expect(options.warning, contains('--device-vmservice-port 50999'));
      expect(options.discoveryDevicePort, 50999);
      expect(options.discoveryHostPort, isNull);
    });

    testWithoutContext('with --no-dds and only a host port, the VM binds it', () {
      final options = SimulatorLaunchOptions(everyOption(dds: false, hostPort: 50111));

      expect(options.arguments, contains('--vm-service-port=50111'));
      expect(options.warning, isNull);
      expect(options.discoveryHostPort, 50111);
      expect(options.discoveryDevicePort, isNull);
    });

    testWithoutContext('the same port twice is one flag and no warning', () {
      final options = SimulatorLaunchOptions(
        everyOption(dds: false, hostPort: 50999, devicePort: 50999),
      );

      expect(
        options.arguments.where((String a) => a.startsWith('--vm-service-port')),
        hasLength(1),
      );
      expect(options.warning, isNull);
    });
  });

  testUsingContext(
    'startApp launches with the options, and waits for the VM on the device port',
    () async {
      final _LogStreamProcess logProcess = time.run((_) => _LogStreamProcess());
      processManager.addCommands(<FakeCommand>[
        ...upToTheLogStream(logProcess),
        FakeCommand(
          command: const <String>[
            'xcrun',
            'simctl',
            'launch',
            _simId,
            _bundleId,
            '--enable-dart-profiling',
            '--start-paused',
            '--vm-service-port=50999',
          ],
          environment: const <String, String>{'SIMCTL_CHILD_FLUTTER_WATCHOS_RENDERER': 'software'},
          onRun: (_) => Timer(const Duration(milliseconds: 100), () {
            // A VM Service on another port is not the app's.
            logProcess.emit(_vmServiceLine);
            logProcess.emit(_vmServiceLine.replaceAll('50123', '50999'));
          }),
        ),
      ]);

      final List<LaunchResult> results = start(
        null,
        DebuggingOptions.enabled(
          BuildInfo.debug,
          startPaused: true,
          enableSoftwareRendering: true,
          enableDds: false,
          hostVmServicePort: 50111,
          deviceVmServicePort: 50999,
        ),
      );
      await _advance(time, Duration.zero);
      time.run((_) => logProcess.emit(_preamble));
      await _advance(time, const Duration(seconds: 1));

      expect(results.single.vmServiceUri, Uri.parse('http://127.0.0.1:50999/abc=/'));
      expect(logger.warningText, contains('--host-vmservice-port 50111 is ignored'));
      expect(processManager, hasNoRemainingExpectations);
    },
    overrides: <Type, Generator>{
      FileSystem: () => fileSystem,
      ProcessManager: () => processManager,
      Xcode: () => _FakeXcode(_deviceHub),
    },
  );

  // The window that shows the Simulator: the selected Xcode's viewer, or one
  // hint; the launch goes on either way (spec 0002 criterion 18).
  group('Simulator window', () {
    const developer = '/Applications/Xcode.app/Contents/Developer';
    const simulatorApp = '$developer/Applications/Simulator.app';
    const hint = 'Could not open the Simulator window';

    Xcode xcodeWith(List<String> apps) {
      for (final app in apps) {
        fileSystem.directory(app).createSync(recursive: true);
      }
      return Xcode.test(
        processManager: FakeProcessManager.list(<FakeCommand>[
          const FakeCommand(
            command: <String>['/usr/bin/xcode-select', '--print-path'],
            stdout: developer,
          ),
        ]),
        fileSystem: fileSystem,
      );
    }

    /// Runs a launch whose window step is [window], and returns it.
    Future<List<LaunchResult>> launchWith(List<FakeCommand> window) async {
      final _LogStreamProcess logProcess = time.run((_) => _LogStreamProcess());
      processManager.addCommands(<FakeCommand>[
        _run(<String>['xcrun', 'simctl', 'boot', _simId]),
        ...window,
        _run(<String>['xcrun', 'simctl', 'install', _simId, _appPath]),
        _run(<String>['xcrun', 'simctl', 'terminate', _simId, _bundleId]),
        _logStream(logProcess),
        _run(
          _launchCommand,
          onRun: (_) =>
              Timer(const Duration(milliseconds: 100), () => logProcess.emit(_vmServiceLine)),
        ),
      ]);
      final List<LaunchResult> results = start();
      await _advance(time, Duration.zero);
      time.run((_) => logProcess.emit(_preamble));
      await _advance(time, const Duration(seconds: 1));
      return results;
    }

    testUsingContext(
      'Xcode 27 opens Device Hub',
      () async {
        final List<LaunchResult> results = await launchWith(<FakeCommand>[
          _run(<String>['open', '-a', _deviceHub]),
        ]);

        expect(results.single.started, isTrue);
        expect(processManager, hasNoRemainingExpectations);
        expect(logger.statusText, isNot(contains(hint)));
      },
      overrides: <Type, Generator>{
        FileSystem: () => fileSystem,
        ProcessManager: () => processManager,
        Xcode: () => xcodeWith(<String>[_deviceHub, simulatorApp]),
      },
    );

    testUsingContext(
      'Xcode 26 opens Simulator.app',
      () async {
        final List<LaunchResult> results = await launchWith(<FakeCommand>[
          _run(<String>['open', '-a', simulatorApp]),
        ]);

        expect(results.single.started, isTrue);
        expect(processManager, hasNoRemainingExpectations);
      },
      overrides: <Type, Generator>{
        FileSystem: () => fileSystem,
        ProcessManager: () => processManager,
        Xcode: () => xcodeWith(<String>[simulatorApp]),
      },
    );

    testUsingContext(
      'with neither app, no open runs, one hint, and the launch goes on',
      () async {
        final List<LaunchResult> results = await launchWith(const <FakeCommand>[]);

        expect(results.single.started, isTrue);
        expect(processManager, hasNoRemainingExpectations);
        expect(hint.allMatches(logger.statusText), hasLength(1));
        expect(logger.statusText, contains('Device Hub (Xcode 27) or Simulator (Xcode 26)'));
      },
      overrides: <Type, Generator>{
        FileSystem: () => fileSystem,
        ProcessManager: () => processManager,
        Xcode: () => xcodeWith(const <String>[]),
      },
    );

    testUsingContext(
      'when open fails, one hint, and the launch goes on',
      () async {
        final List<LaunchResult> results = await launchWith(<FakeCommand>[
          _run(
            <String>['open', '-a', _deviceHub],
            exitCode: 1,
            stderr: 'LSOpenURLsWithRole() failed',
          ),
        ]);

        expect(results.single.started, isTrue);
        expect(processManager, hasNoRemainingExpectations);
        expect(hint.allMatches(logger.statusText), hasLength(1));
      },
      overrides: <Type, Generator>{
        FileSystem: () => fileSystem,
        ProcessManager: () => processManager,
        Xcode: () => xcodeWith(<String>[_deviceHub]),
      },
    );
  });
}
