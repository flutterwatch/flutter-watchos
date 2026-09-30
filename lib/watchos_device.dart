// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show InternetAddress, InternetAddressType, Process;

import 'package:file/file.dart';
import 'package:flutter_tools/src/application_package.dart';
import 'package:flutter_tools/src/base/dds.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/process.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/device.dart';
import 'package:flutter_tools/src/device_port_forwarder.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/mdns_discovery.dart';
import 'package:flutter_tools/src/project.dart';
import 'package:flutter_tools/src/protocol_discovery.dart';
import 'package:flutter_tools/src/vmservice.dart';
import 'package:meta/meta.dart';

import 'watchos_application_package.dart';
import 'watchos_build_info.dart';
import 'watchos_builder.dart';
import 'watchos_dds.dart';
import 'watchos_vm_relay.dart';

/// Engine switches the host reads at startup, and the environment variable
/// each is spelled as on the command line that launches `run`.
///
/// The engine reads most of these from its own environment already, but the
/// app runs on the watch and inherits nothing from this Mac, so they have to
/// be carried across deliberately. Forwarding them here is what makes
///
///   FLUTTER_WATCHOS_RENDERER=software flutter-watchos run --profile -d `<id>`
///
/// mean the same thing on a device as `SIMCTL_CHILD_…` does on the simulator —
/// and it is what lets a benchmark script select a renderer per arm, which it
/// otherwise could not do at all: `--dart-entrypoint-args` is desktop-only and
/// goes to Dart's `main`, not to the embedder.
///
/// Values are passed through untouched; the engine is the only validator.
@visibleForTesting
const engineSwitchEnvironment = <String>[
  // Renderer selection. Impeller on Metal is the engine's default, so the
  // value that changes anything is "software" — "metal" only forces back what
  // an app already gets, which is what a renderer A/B's Metal arm wants to say
  // out loud. Note the empty string never travels (see below), so an A/B arm
  // has to name its renderer rather than leaving it unset.
  'FLUTTER_WATCHOS_RENDERER',
  // "fallback" restores the engine's free-running 60 Hz timer instead of the
  // display clock. The A/B switch behind scripts/scroll_vsync_ab.sh.
  'FLUTTER_WATCHOS_VSYNC',
  // "0" turns the semantics bridge off.
  'FLUTTER_WATCHOS_SEMANTICS',
];

/// The subset of [engineSwitchEnvironment] this process was given, ready to
/// hand to a launcher. Empty when none were set, which is the normal case.
Map<String, String> engineSwitchesFromEnvironment([Map<String, String>? source]) {
  final Map<String, String> env = source ?? globals.platform.environment;
  return <String, String>{
    for (final String name in engineSwitchEnvironment)
      if (env[name] case final String value when value.isNotEmpty) name: value,
  };
}

/// One engine switch has no environment spelling — the host only scans argv
/// for it — so it is carried as a launch argument instead.
@visibleForTesting
List<String> engineSwitchArguments([Map<String, String>? source]) {
  final Map<String, String> env = source ?? globals.platform.environment;
  final String? logToFile = env['FLUTTER_WATCHOS_LOG_TO_FILE'];
  return <String>[
    if (logToFile != null && logToFile.isNotEmpty && logToFile != '0')
      '--watchos-log-to-file',
  ];
}

/// [relaying] picks the bind address. With the relay the only consumer is the
/// in-process bridge, so IPv4 loopback is both tighter and avoids a real trap:
/// `::0` leaves the service on `[::]`, which a bridge dialling `127.0.0.1`
/// cannot reach, and the symptom is an endless "Could not connect to the
/// server" against a service that is plainly listening. Without the relay the
/// dual-stack wildcard is right — nothing off-device can reach it either way
/// — but a wirelessly-paired watch is often reachable only over IPv6.

/// Arguments forwarded to the Flutter app's `main()` on a device launch.
///
/// These reach the Dart VM as of engine `v0.1.2`; against older artifacts they
/// are accepted and silently ignored.
///
/// [enableVmService] must be false for release. A release engine has no Dart
/// VM Service, so the flags are inert there — but `--disable-service-auth-codes`
/// is not something to hand a shipping build on the assumption that nothing is
/// listening.
///
@visibleForTesting
List<String> appLaunchArguments({
  required bool enableVmService,
  required bool relaying,
  List<String> extraLaunchArguments = const <String>[],
}) {
  return <String>[
    if (enableVmService) ...<String>[
      '--enable-dart-profiling',
      '--disable-service-auth-codes',
      if (relaying) '--vm-service-host=127.0.0.1' else '--vm-service-host=::0',
    ],
    ...extraLaunchArguments,
  ];
}

/// A log reader that captures logs from a physical Apple Watch via devicectl.
class WatchosPhysicalDeviceLogReader implements DeviceLogReader {
  /// Creates a log reader for a physical watchOS device.
  ///
  /// [logger] is used for noise-filtered lines (demoted to printTrace). If
  /// omitted, falls back to the DI-injected [globals.logger].
  WatchosPhysicalDeviceLogReader(this.name, {Logger? logger}) : _logger = logger;

  final Logger? _logger;
  Logger get _log => _logger ?? globals.logger;

  final StreamController<String> _linesController = StreamController<String>.broadcast();

  Process? _logProcess;

  Future<void>? _consoleEnded;

  /// Completes when the console session of the newest launch ends: the app
  /// exited or was stopped, or devicectl lost the watch (`--console` blocks
  /// for as long as the app runs). Never completes before a launch.
  Future<void> get consoleEnded => _consoleEnded ?? Completer<void>().future;

  @override
  final String name;

  @override
  Stream<String> get logLines => _linesController.stream;

  @override
  String toString() => name;

  /// Launches the app on the watch and streams its console output as log
  /// lines.
  Future<void> startLogStreamForBundle(
    String deviceId,
    String bundleId, {
    List<String> extraLaunchArguments = const <String>[],
    Map<String, String> environment = const <String, String>{},
    bool enableVmService = true,
  }) async {
    // Wrap in `script -t 0 /dev/null` to convince devicectl it has a TTY and
    // forward child stdout. `--console` blocks until the app exits.
    final cmd = <String>[
      'script', '-t', '0', '/dev/null',
      'xcrun', 'devicectl', 'device', 'process', 'launch',
      '--device', deviceId,
      '--console',
      // Stale instances survive a `run` that ends without a clean stop, and
      // they keep holding the pinned VM Service port — the next launch then
      // starts with no VM Service at all. Always take over the old one.
      '--terminate-existing',
      '--environment-variables',
      jsonEncode(<String, String>{'OS_ACTIVITY_DT_MODE': 'enable', ...environment}),
      bundleId,
      ...appLaunchArguments(
        enableVmService: enableVmService,
        relaying: environment.containsKey('FLUTTER_WATCHOS_VM_PORT'),
        extraLaunchArguments: extraLaunchArguments,
      ),
    ];
    _log.printTrace('launching: ${cmd.join(' ')}');
    _logProcess = await globals.processManager.start(cmd);
    _consoleEnded = _logProcess!.exitCode.then((_) {});

    _logProcess!.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((
      String line,
    ) {
      _processLine(line);
    });

    _logProcess!.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((
      String line,
    ) {
      _processLine(line);
    });
  }

  // Lines we hide from the `flutter-watchos run` console because they're
  // implementation chatter (devicectl progress) or non-actionable system
  // framework warnings. Verbose mode (`-v`) bypasses the filter via printTrace.
  static final RegExp _devicectlProgress = RegExp(
    r'^\d{2}:\d{2}:\d{2}\s+(Acquired|Enabling|Establishing|Resolved|Granted)',
  );
  static final RegExp _scriptWrapper = RegExp(r'^Script (started|done), output file');
  static final RegExp _systemNoise = RegExp(
    r'\[(Scene|Storyboard|UIKitCore|PreviewsAgentExecutorLibrary)\]',
  );
  static final RegExp _benignHangDetected = RegExp(
    r'Hang detected:.*\(debugger attached, not reporting\)',
  );
  static final RegExp _backboardSnapshotFailure = RegExp(
    r'\[Common\] Snapshot request 0x[0-9a-fA-F]+ complete with error:.*'
    r'BSActionErrorDomain.*response-not-possible',
  );
  static final List<String> _verbatimNoise = <String>[
    'Launched application with',
    'Waiting for the application to terminate',
    'CLIENT OF UIKIT REQUIRES UPDATE',
    'Unable to create restoration in progress marker file',
    'fopen failed for data file:',
    'Errors found! Invalidating cache...',
    'App is being debugged, do not track this hang',
  ];

  bool _isNoise(String line) {
    final String trimmed = line.trim();
    if (trimmed.isEmpty) {
      return true;
    }
    if (_devicectlProgress.hasMatch(trimmed)) {
      return true;
    }
    if (_scriptWrapper.hasMatch(trimmed)) {
      return true;
    }
    if (_systemNoise.hasMatch(line)) {
      return true;
    }
    if (_benignHangDetected.hasMatch(line)) {
      return true;
    }
    if (_backboardSnapshotFailure.hasMatch(line)) {
      return true;
    }
    for (final String n in _verbatimNoise) {
      if (line.contains(n)) {
        return true;
      }
    }
    return false;
  }

  void _processLine(String line) {
    if (_linesController.isClosed) {
      return;
    }
    // Always trace the VM's own "listening on" line, even though it is passed
    // through to ProtocolDiscovery below.
    //
    // On the relay path nothing subscribes to this stream at launch time, so
    // the line was silently dropped — and its absence from the console reads
    // exactly like the VM Service failing to start. It cost a session's worth
    // of chasing a bug that was not there. Recording it here makes `-v` answer
    // the question directly.
    final Match? listening = _vmServiceListening.firstMatch(line);
    if (listening != null) {
      _deviceVmServiceUri = listening.group(1);
      _log.printTrace('Device VM Service is up: $_deviceVmServiceUri');
    }
    if (_isNoise(line)) {
      _log.printTrace(line);
      return;
    }
    _linesController.add(line);
  }

  /// Matches the line the Dart VM prints once its service is bound.
  static final RegExp _vmServiceListening = RegExp(
    r'VM [Ss]ervice is listening on (\S+)',
  );

  /// The device-local VM Service URI, once the VM has announced it. Not
  /// reachable from the Mac — it exists to tell "never started" apart from
  /// "started but unreachable".
  String? get deviceVmServiceUri => _deviceVmServiceUri;
  String? _deviceVmServiceUri;

  /// Processes a single line for testing.
  @visibleForTesting
  void processLogLine(String line) => _processLine(line);

  @override
  void dispose() {
    _logProcess?.kill();
    if (!_linesController.isClosed) {
      _linesController.close();
    }
  }

  @override
  Future<void> provideVmService(FlutterVmService connectedVmService) async {}
}

/// A log reader that captures logs from a watchOS simulator app via unified
/// logging (`xcrun simctl spawn <device> log stream --style json`).
///
/// As stock's Simulator reader does, it starts its `log stream` when the first
/// listener subscribes and stops it when the last one cancels. `run` listens
/// before `startApp` has built the app and booted the Simulator, so that first
/// start can fail; [ensureStarted] starts the stream again after the boot.
class WatchosSimulatorLogReader implements DeviceLogReader {
  /// Creates a reader for the Simulator [deviceId], named [name].
  ///
  /// Without a [deviceId] the reader never starts a stream; lines can still be
  /// fed to it with [processLogLine].
  WatchosSimulatorLogReader(this.name, {String? deviceId, Logger? logger})
    : _deviceId = deviceId,
      _logger = logger;

  final String? _deviceId;
  final Logger? _logger;
  Logger get _log => _logger ?? globals.logger;

  late final _linesController = StreamController<String>.broadcast(
    onListen: _onListen,
    onCancel: _stop,
  );

  /// The running `log stream` process, if any.
  Process? _logProcess;

  /// A start in progress, so a second caller joins it instead of starting
  /// another process.
  Future<void>? _starting;

  /// Whether the current process has printed its preamble.
  bool _live = false;

  /// Whether the current stream was already restarted once after it died.
  bool _restarted = false;

  bool _disposed = false;

  Completer<void> _readyCompleter = Completer<void>();

  /// Completes once the current `log stream` process has emitted its
  /// `Filtering the log data using …` preamble, i.e. it is actually live and
  /// will capture subsequent events. Each process gets its own completer.
  /// Callers must await this (with a timeout) before launching the app,
  /// otherwise the VM Service line, printed by the embedder within about 40 ms
  /// of launch, races ahead of the stream and is lost.
  Future<void> get ready => _readyCompleter.future;

  @override
  final String name;

  @override
  Stream<String> get logLines => _linesController.stream;

  @override
  String toString() => name;

  /// The unified-log predicate: stock's (`launchDeviceUnifiedLogging` in
  /// flutter_tools' `ios/simulators.dart`), with the watch app's process name
  /// and without stock's three UIScene clauses, which a watch app never logs,
  /// plus the `[flutter:` clause.
  ///
  /// Measured on 2026-09-29 (spec 0005, F4): Dart output reaches the unified
  /// log through the embedder's `NSLog("[flutter:<tag>] …")` in the `Runner`
  /// process, and engine lines such as `Unhandled Exception` come untagged
  /// from `Flutter.framework/Flutter`, which the sender clause keeps. The
  /// sender of the host module's own `NSLog` lines (app code, in
  /// `Runner.debug.dylib` in a debug build) has not been measured, and no
  /// clause names it yet.
  @visibleForTesting
  static const predicate =
      'eventType = logEvent AND processImagePath ENDSWITH "/Runner" AND '
      '(senderImagePath ENDSWITH "/Flutter" '
      'OR senderImagePath ENDSWITH "/libswiftCore.dylib" '
      'OR processImageUUID == senderImageUUID '
      'OR eventMessage CONTAINS "[flutter:") AND '
      'NOT(eventMessage CONTAINS ": could not find icon for representation -> com.apple.") AND '
      'NOT(eventMessage BEGINSWITH "assertion failed: ") AND '
      'NOT(eventMessage CONTAINS " libxpc.dylib ")';

  void _onListen() {
    if (_deviceId != null) {
      unawaited(_startIfIdle());
    }
  }

  /// Starts the `log stream` unless one is running or starting, and re-arms
  /// [ready] for the new process. `startApp` calls this after the boot.
  Future<void> ensureStarted() => _startIfIdle();

  Future<void> _startIfIdle() {
    if (_disposed || _deviceId == null) {
      return Future<void>.value();
    }
    if (_starting case final Future<void> starting) {
      return starting;
    }
    if (_logProcess != null) {
      return Future<void>.value();
    }
    _restarted = false;
    return _starting = _launch().whenComplete(() => _starting = null);
  }

  Future<void> _launch() async {
    if (_readyCompleter.isCompleted) {
      _readyCompleter = Completer<void>();
    }
    _live = false;
    final Process process;
    try {
      process = await globals.processManager.start(<String>[
        'xcrun',
        'simctl',
        'spawn',
        _deviceId!,
        'log',
        'stream',
        '--style',
        'json',
        '--predicate',
        predicate,
      ]);
    } on Exception catch (error) {
      _log.printTrace('Could not start the Simulator log stream: $error');
      return;
    }
    if (_disposed || !_linesController.hasListener) {
      // Everyone left while the process was starting.
      process.kill();
      return;
    }
    _logProcess = process;
    process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(_onLine);
    process.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(_onLine);
    unawaited(process.exitCode.then((int code) => _onExit(process, code)));
  }

  void _onLine(String line) {
    if (!_live && line.contains('Filtering the log data')) {
      _live = true;
      if (!_readyCompleter.isCompleted) {
        _readyCompleter.complete();
      }
    }
    _onUnifiedLoggingLine(line);
  }

  void _onExit(Process process, int code) {
    if (!identical(process, _logProcess)) {
      return; // Stopped on purpose.
    }
    _logProcess = null;
    final bool wasLive = _live;
    _live = false;
    if (_disposed || !_linesController.hasListener) {
      return;
    }
    if (!wasLive) {
      // A Simulator that is still shut down refuses `spawn`. The stream
      // starts again once startApp has booted it.
      _log.printTrace('The Simulator log stream ended before it went live (exit $code).');
      return;
    }
    if (_restarted) {
      _log.printTrace('The Simulator log stream ended again (exit $code); not restarting it.');
      return;
    }
    _restarted = true;
    _log.printTrace('The Simulator log stream ended (exit $code); restarting it once.');
    _starting = _launch().whenComplete(() => _starting = null);
  }

  void _stop() {
    final Process? process = _logProcess;
    _logProcess = null;
    _live = false;
    process?.kill();
  }

  // Greedy, as stock's (`simulators.dart`): `log stream --style json` prints
  // one field per line, so the message runs to the line's last quote, and an
  // escaped quote inside it is not the end.
  static final RegExp _eventMessageRegex = RegExp(r'.*"eventMessage"\s*:\s*(".*")');

  /// Processes a single line from the unified log stream.
  @visibleForTesting
  void processLogLine(String line) => _onUnifiedLoggingLine(line);

  /// The embedder's NSLog bridge prepends `[flutter:<tag>] ` to every engine /
  /// Dart log line. Rewrite that to the `<tag>: ` form `flutter run` uses on
  /// iOS, where Dart `print('x')` surfaces as `flutter: x` — so a watchOS run
  /// console reads identically (Dart output as `flutter: …`).
  static final RegExp _flutterTagPrefix = RegExp(r'^\[flutter:([^\]]*)\]\s*');

  void _onUnifiedLoggingLine(String line) {
    final Match? match = _eventMessageRegex.firstMatch(line);
    if (match != null) {
      final String rawMessage = match.group(1)!;
      String message;
      try {
        final Object? decoded = jsonDecode(rawMessage);
        message = decoded is String ? decoded : rawMessage;
      } on FormatException {
        message = rawMessage;
      }
      message = message.replaceFirstMapped(_flutterTagPrefix, (Match m) => '${m.group(1)}: ');
      if (!_linesController.isClosed) {
        _linesController.add(message);
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _stop();
    if (!_linesController.isClosed) {
      _linesController.close();
    }
  }

  @override
  Future<void> provideVmService(FlutterVmService connectedVmService) async {}
}

class WatchosDevice extends Device {
  WatchosDevice(
    super.id, {
    required this.name,
    required this.logger,
    required this.isSimulator,
    this.osVersion,
  }) : super(
         category: Category.mobile,
         platformType: PlatformType.custom,
         ephemeral: true,
         logger: logger,
       );

  @override
  final String name;
  final Logger logger;
  final bool isSimulator;

  /// Human-readable OS version such as `watchOS 11.0 22R5xxx` (physical) or
  /// `watchOS 11.0` (simulator).
  final String? osVersion;

  /// DDS has to bind on the same address family as the watch's Dart VM Service,
  /// which `DebuggingOptions.ipv6` (i.e. `--ipv6`) does not know about.
  @override
  DartDevelopmentService get dds => _dds;
  late final DartDevelopmentService _dds = WatchosDartDevelopmentService(logger: logger);

  DeviceLogReader? _logReader;

  /// startApp's own subscription to the Simulator log stream, held from the
  /// launch until the app is stopped or the device is disposed.
  StreamSubscription<String>? _launchHold;

  /// Mac half of the VM Service relay for a profile run on a physical watch.
  WatchosVmRelay? _vmRelay;

  /// The Mac address the watch was told to dial. Worth naming when the bridge
  /// never checks in: on a multi-homed Mac the usual cause is that this is the
  /// wrong one of several, which is invisible otherwise.
  String? _relayAdvertisedHost;

  /// Port the VM Service is pinned to on the watch for this run.
  int _deviceVmServicePort = 0;

  @override
  Future<TargetPlatform> get targetPlatform async => TargetPlatform.ios;

  // Override the display name so `flutter-watchos devices` shows `watchos` in
  // the platform column instead of the inherited `ios`. The build pipeline
  // still sees `TargetPlatform.ios` (we ride the iOS toolchain).
  @override
  Future<String> get targetPlatformDisplayName async => 'watchos';

  @override
  Future<bool> isSupported() async => true;

  @override
  Future<bool> get isLocalEmulator async => isSimulator;

  @override
  Future<String?> get emulatorId async => isSimulator ? id : null;

  @override
  Future<String> get sdkNameAndVersion async => osVersion ?? 'watchOS';

  /// The modes this target can run: debug only on the Simulator, whose
  /// engine is JIT-only (as stock iOS Simulators), and profile or release on
  /// a physical watch, which has no JIT engine.
  @override
  bool supportsRuntimeMode(BuildMode buildMode) => isSimulator
      ? buildMode == BuildMode.debug
      : buildMode == BuildMode.profile || buildMode == BuildMode.release;

  /// The guidance for a [mode] this target cannot run, or null when it can.
  ///
  /// `run`, `drive` and `attach` refuse such a mode before they build;
  /// [startApp] refuses it too, for the daemon path, which skips their checks.
  String? unsupportedModeGuidance(BuildMode mode) {
    if (supportsRuntimeMode(mode)) {
      return null;
    }
    if (!isSimulator) {
      return 'Debug mode is not supported on a physical Apple Watch: it needs a '
          'JIT engine, which cannot be built for watchOS (the device SDK '
          'removes the Mach APIs the Dart JIT VM relies on).\n'
          'Use one of:\n'
          '  flutter-watchos run -d $id --profile   # AOT, with logging and DevTools\n'
          '  flutter-watchos run -d $id --release   # AOT, fastest\n'
          'For hot reload and fast iteration, run on the watchOS Simulator, '
          'where debug (JIT) mode works.';
    }
    return '--${mode.cliName} is not supported on the watchOS Simulator: its '
        'engine is JIT-only, so Simulator runs are always debug. AOT '
        '(profile/release) runs target a physical watch.\n'
        'Use one of:\n'
        '  flutter-watchos run -d $id             # debug, on the Simulator\n'
        '  flutter-watchos run -d <watch> --${mode.cliName}';
  }

  @override
  Future<bool> isAppInstalled(covariant ApplicationPackage app, {String? userIdentifier}) async =>
      false;

  @override
  Future<bool> isLatestBuildInstalled(covariant ApplicationPackage app) async => false;

  @override
  Future<bool> installApp(covariant ApplicationPackage app, {String? userIdentifier}) async {
    final watchosApp = app as WatchosApp;

    // Prefer Release bundle if present (device/release builds); fall back to
    // Debug.
    String appPath = watchosApp.bundlePath(BuildMode.release, isSimulator: isSimulator);
    if (!globals.fs.directory(appPath).existsSync()) {
      appPath = watchosApp.bundlePath(BuildMode.debug, isSimulator: isSimulator);
    }

    if (isSimulator) {
      final RunResult result = await globals.processUtils.run(<String>[
        'xcrun',
        'simctl',
        'install',
        id,
        appPath,
      ]);
      if (result.exitCode != 0) {
        logger.printError('simctl install failed:\n${result.stderr}');
        return false;
      }
      return true;
    }

    // Physical device: use devicectl against the paired watch.
    logger.printTrace('Installing on physical Apple Watch ($id)...');
    return _installOnPhysicalDevice(appPath);
  }

  /// How many times to attempt a `devicectl install` before giving up, and
  /// the pause between attempts. Wireless CoreDevice tunnels to a paired
  /// watch drop routinely mid-transfer (`com.apple.dt.CoreDeviceError 4000`,
  /// "Connection reset by peer"); the install is idempotent, so a retry
  /// usually succeeds where the first attempt was interrupted.
  static const int _installAttempts = 3;

  /// Overridable so retry tests don't sleep for real.
  @visibleForTesting
  static Duration installRetryDelay = const Duration(seconds: 3);

  Future<bool> _installOnPhysicalDevice(String appPath) async {
    for (var attempt = 1; ; attempt++) {
      final RunResult result = await globals.processUtils.run(<String>[
        'xcrun',
        'devicectl',
        'device',
        'install',
        'app',
        '--device',
        id,
        appPath,
      ]);
      if (result.exitCode == 0) {
        logger.printTrace(result.stdout);
        return true;
      }
      if (attempt >= _installAttempts) {
        logger.printError(
          'devicectl install failed after $_installAttempts attempts:\n'
          '${result.stderr}\n'
          'The wireless tunnel to the watch keeps dropping. Make sure the '
          'watch is unlocked, on your wrist, near this Mac, and on the same '
          'Wi-Fi network; then try again (see doc/debug-app.md for '
          'pairing/tunnel troubleshooting).',
        );
        return false;
      }
      logger.printStatus(
        'Install to the watch was interrupted (the wireless tunnel dropped); '
        'retrying — attempt ${attempt + 1} of $_installAttempts...',
      );
      logger.printTrace('devicectl install attempt $attempt failed:\n${result.stderr}');
      await Future<void>.delayed(installRetryDelay);
    }
  }

  @override
  Future<bool> uninstallApp(covariant ApplicationPackage app, {String? userIdentifier}) async {
    if (isSimulator) {
      final RunResult result = await globals.processUtils.run(<String>[
        'xcrun',
        'simctl',
        'uninstall',
        id,
        app.id,
      ]);
      return result.exitCode == 0;
    }

    final RunResult result = await globals.processUtils.run(<String>[
      'xcrun',
      'devicectl',
      'device',
      'uninstall',
      'app',
      '--device',
      id,
      app.id,
    ]);
    return result.exitCode == 0;
  }

  @override
  Future<LaunchResult> startApp(
    covariant ApplicationPackage? package, {
    String? mainPath,
    String? route,
    required DebuggingOptions debuggingOptions,
    Map<String, Object?> platformArgs = const <String, Object?>{},
    bool prebuiltApplication = false,
    String? userIdentifier,
  }) async {
    // Mode/target contradictions fail here, with guidance, before anything is
    // built or installed: debug needs the JIT engine, which exists only for
    // the Simulator (the watchOS device SDK removes the Mach APIs the Dart JIT
    // VM relies on), and the Simulator engine is JIT-only, so AOT modes need a
    // physical watch. Without this check the engine lookup fails mid-build
    // with a bare "libflutter_engine.dylib not found — run precache", which
    // cannot help. `run`, `drive` and `attach` refuse earlier; this covers the
    // daemon (IDE) path, which skips their checks, and prebuilt apps too.
    //
    // The guidance is printed and the launch fails, rather than a tool exit:
    // the runners print an exception from startApp with its stack trace.
    final String? refusal = unsupportedModeGuidance(debuggingOptions.buildInfo.mode);
    if (refusal != null) {
      logger.printError(refusal);
      return LaunchResult.failed();
    }

    final FlutterProject project = FlutterProject.current();

    // 1. Build the watchOS app (unless prebuilt)
    if (!prebuiltApplication) {
      final watchosBuildInfo = WatchosBuildInfo(
        debuggingOptions.buildInfo,
        targetArch: 'arm64',
        simulator: isSimulator,
      );

      logger.printTrace('Building watchOS application...');
      await WatchosBuilder.buildBundle(
        project: project,
        watchosBuildInfo: watchosBuildInfo,
        targetFile: mainPath ?? 'lib/main.dart',
      );
    }

    if (isSimulator) {
      return _startAppOnSimulator(project, package, debuggingOptions);
    } else {
      return _startAppOnDevice(project, package, debuggingOptions);
    }
  }

  Future<LaunchResult> _startAppOnSimulator(
    FlutterProject project,
    ApplicationPackage? package,
    DebuggingOptions debuggingOptions,
  ) async {
    final configuration = debuggingOptions.buildInfo.isDebug ? 'Debug' : 'Release';
    final String appPath = globals.fs.path.join(
      project.directory.path,
      'build',
      'watchos',
      '$configuration-watchsimulator',
      'Runner.app',
    );

    if (!globals.fs.directory(appPath).existsSync()) {
      logger.printError('App bundle not found at: $appPath');
      return LaunchResult.failed();
    }

    // Boot simulator and open Simulator.app window.
    await globals.processUtils.run(<String>['xcrun', 'simctl', 'boot', id]);
    await globals.processUtils.run(<String>['open', '-a', 'Simulator']);

    logger.printStatus('Installing and launching...');
    logger.printTrace('Installing on Apple Watch simulator ($id)...');
    final RunResult installResult = await globals.processUtils.run(<String>[
      'xcrun',
      'simctl',
      'install',
      id,
      appPath,
    ]);
    if (installResult.exitCode != 0) {
      logger.printError('simctl install failed: ${installResult.stderr}');
      return LaunchResult.failed();
    }

    final String bundleId = package?.id ?? _readBundleId(project);

    logger.printTrace('Launching $bundleId on Apple Watch...');

    // Terminate any prior instance so this launch reliably re-emits the
    // VM-service banner that the log stream below is waiting to capture.
    await globals.processUtils.run(<String>['xcrun', 'simctl', 'terminate', id, bundleId]);

    final logReader = await getLogReader() as WatchosSimulatorLogReader;
    // Hold the stream from here until the app is stopped, so that neither
    // discovery's cancel below nor a late listener such as drive's ever meets
    // a stopped stream.
    _launchHold ??= logReader.logLines.listen(null);
    // A reader that started on run's early listen, before the boot, may have
    // failed; start it again now. A live stream is reused.
    await logReader.ensureStarted();

    // Wait until the log stream is actually live before launching, otherwise the
    // embedder prints the VM-service URI (~40ms after launch) before the stream
    // is listening and protocol discovery times out.
    await logReader.ready.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        logger.printTrace('Timed out waiting for simctl log stream to go live; launching anyway.');
      },
    );

    final RunResult launchResult = await globals.processUtils.run(
      <String>[
        'xcrun',
        'simctl',
        'launch',
        id,
        bundleId,
        ...engineSwitchArguments(),
      ],
      // simctl gives the launched app any variable it sees prefixed
      // SIMCTL_CHILD_, which is how the same switch reaches the simulator that
      // devicectl's --environment-variables carries to a watch.
      environment: <String, String>{
        for (final MapEntry<String, String> e in engineSwitchesFromEnvironment().entries)
          'SIMCTL_CHILD_${e.key}': e.value,
      },
    );
    if (launchResult.exitCode != 0) {
      logger.printError('simctl launch failed: ${launchResult.stderr}');
      return LaunchResult.failed();
    }

    final discovery = ProtocolDiscovery.vmService(logReader, ipv6: false, logger: logger);

    final Uri? vmServiceUri = await discovery.uri.timeout(
      const Duration(seconds: 30),
      onTimeout: () => null,
    );
    await discovery.cancel();

    if (vmServiceUri != null) {
      logger.printTrace('VM service available at: $vmServiceUri');
      return LaunchResult.succeeded(vmServiceUri: vmServiceUri);
    }

    return LaunchResult.succeeded();
  }

  Future<LaunchResult> _startAppOnDevice(
    FlutterProject project,
    ApplicationPackage? package,
    DebuggingOptions debuggingOptions,
  ) async {
    final configuration = debuggingOptions.buildInfo.isDebug ? 'Debug' : 'Release';
    final String appPath = globals.fs.path.join(
      project.directory.path,
      'build',
      'watchos',
      '$configuration-watchos',
      'Runner.app',
    );

    if (!globals.fs.directory(appPath).existsSync()) {
      logger.printError('App bundle not found at: $appPath');
      return LaunchResult.failed();
    }

    logger.printStatus('Installing and launching...');
    logger.printTrace('Installing on Apple Watch ($id)...');
    if (!await _installOnPhysicalDevice(appPath)) {
      return LaunchResult.failed();
    }

    final String bundleId = package?.id ?? _readBundleId(project);

    // LaunchServices needs a moment after install to index the new bundle.
    // Poll until the app shows up in `devicectl device info apps`, up to 15s.
    logger.printTrace('Waiting for $bundleId to register...');
    final String? installUrl = await _waitForAppRegistration(id, bundleId);
    if (installUrl == null) {
      logger.printError(
        'Timed out waiting for $bundleId to register on the device. '
        'The app was installed but LaunchServices did not index it.',
      );
      return LaunchResult.failed();
    }

    logger.printTrace('Launching $bundleId on Apple Watch...');
    final logReader =
        (_logReader ??= WatchosPhysicalDeviceLogReader(name)) as WatchosPhysicalDeviceLogReader;

    // Live DevTools on a physical watch rides the relay: the app cannot be
    // dialled into, but it can dial out over URLSession. Start the Mac half
    // first so the bridge has something to reach the moment the app launches.
    final wantsRelay = debuggingOptions.buildInfo.mode == BuildMode.profile;
    var relayEnvironment = <String, String>{};
    if (wantsRelay) {
      relayEnvironment = await _startVmRelay();
    }

    await logReader.startLogStreamForBundle(
      id,
      bundleId,
      extraLaunchArguments: <String>[
        // Pin the port so the in-app bridge knows where the VM Service is
        // without having to discover it.
        if (relayEnvironment.isNotEmpty) '--vm-service-port=$_deviceVmServicePort',
        ...engineSwitchArguments(),
      ],
      environment: <String, String>{...relayEnvironment, ...engineSwitchesFromEnvironment()},
      // A release engine has no Dart VM Service, and a release app should not
      // be launched asking for one.
      enableVmService: debuggingOptions.buildInfo.mode != BuildMode.release,
    );

    // With the relay up, the Mac-reachable VM Service *is* the relay: it speaks
    // the protocol transparently, so DDS and DevTools connect to it unchanged.
    // Wait for the in-app bridge to check in first, so we do not hand out a URI
    // with nothing behind it.
    final WatchosVmRelay? relay = _vmRelay;
    if (relay != null) {
      // Wait for as long as the app runs. flutter_tools ends `run` when a
      // debuggable launch hands back no VM Service, so giving up here would
      // stop the app's log stream too. After 45s, say why DevTools is late.
      final bool bridged = await awaitRelayBridge(
        bridgeReady: relay.bridgeReady,
        appExited: logReader.consoleEnded,
        patience: const Duration(seconds: 45),
        onSlow: () => _warnRelayLate(logReader),
      );
      if (bridged) {
        logger.printTrace('VM Service relay bridged; serving at ${relay.vmServiceUri}');
        return LaunchResult.succeeded(vmServiceUri: relay.vmServiceUri);
      }
      logger.printError(
        'The session with the app on the watch ended before the app connected '
        'back to this Mac: the app exited, or this Mac lost the watch (asleep, '
        'off the wrist, or out of range).',
      );
      return LaunchResult.failed();
    }

    // Discover the Mac-reachable VM service URI: scrape the console for the
    // URL the VM printed, then rewrite its device-local host via mDNS or
    // devicectl. Note the VM currently binds loopback regardless of the
    // --vm-service-host we pass, so the rewritten URL is not yet connectable —
    // see the launch arguments in startLogStreamForBundle.
    final discovery = ProtocolDiscovery.vmService(logReader, ipv6: false, logger: logger);

    Uri? vmServiceUri = await discovery.uri.timeout(
      const Duration(seconds: 30),
      onTimeout: () => null,
    );
    await discovery.cancel();

    if (vmServiceUri != null && isDeviceLocalHost(vmServiceUri.host)) {
      vmServiceUri = await _resolveMacReachableVmServiceUri(vmServiceUri, bundleId);
    }

    if (vmServiceUri != null) {
      logger.printTrace('VM service available at: $vmServiceUri');
      return LaunchResult.succeeded(vmServiceUri: vmServiceUri);
    }

    logger.printWarning(
      'App launched, but its Dart VM Service was not found within the timeout — '
      'hot reload, hot restart, and DevTools will be unavailable. Check that '
      'this Mac has Local Network permission (System Settings ▸ Privacy & '
      'Security ▸ Local Network) and that the Apple Watch is on the same network.',
    );
    return LaunchResult.succeeded();
  }

  /// Whether [host] only means something on the watch itself — a wildcard bind
  /// address (`::`, `0.0.0.0`) or loopback. The Dart VM prints the address it
  /// bound to, so the URI scraped from the console always needs its host
  /// rewritten to something the Mac can dial.
  static bool isDeviceLocalHost(String host) {
    final InternetAddress? address = InternetAddress.tryParse(host);
    if (address == null) {
      return false;
    }
    // An all-zero address is the wildcard bind in either family, spelled
    // `0.0.0.0`, `::`, or `::0` depending on who printed it.
    return address.isLoopback || address.rawAddress.every((int byte) => byte == 0);
  }

  /// Rewrites the host of a device-local VM service URI to a Mac-reachable
  /// address: the mDNS record first, then devicectl's hostname.
  Future<Uri> _resolveMacReachableVmServiceUri(Uri deviceUri, String bundleId) async {
    try {
      final MDnsVmServiceDiscoveryResult? result = await _queryMdnsForVmService(
        bundleId,
        deviceUri.port,
      );
      final InternetAddress? mdnsAddress = result?.ipAddress;
      final Uri? mdnsUri = mdnsAddress == null
          ? null
          : Uri(
              scheme: 'http',
              host: mdnsAddress.address,
              port: result!.port,
              path: deviceUri.path,
            );

      // A link-local address (fe80::/10) is unusable without a scope id, which
      // mDNS does not report — devicectl's `.coredevice.local` hostname
      // resolves to one that works, so prefer it in that case.
      if (mdnsUri != null && !mdnsAddress!.isLinkLocal) {
        return mdnsUri;
      }
      final String? deviceHost = await _resolveDeviceIp(id);
      if (deviceHost != null) {
        return deviceUri.replace(host: deviceHost);
      }
      return mdnsUri ?? deviceUri;
    } on Object catch (e) {
      logger.printTrace('Could not resolve a Mac-reachable VM service host: $e');
      return deviceUri;
    }
  }

  /// Asks mDNS for the app's Dart VM Service record, IPv4 first then IPv6.
  ///
  /// A wirelessly-paired watch commonly publishes AAAA records only, and an
  /// IPv4-only query throws `Did not find IP for service` in that case.
  Future<MDnsVmServiceDiscoveryResult?> _queryMdnsForVmService(
    String bundleId,
    int devicePort,
  ) async {
    for (final ipv6 in <bool>[false, true]) {
      try {
        final MDnsVmServiceDiscoveryResult? result =
            // ignore: invalid_use_of_visible_for_testing_member
            await MDnsVmServiceDiscovery.instance!.queryForLaunch(
              applicationId: bundleId,
              deviceVmservicePort: devicePort,
              useDeviceIPAsHost: true,
              ipv6: ipv6,
              timeout: const Duration(seconds: 10),
            );
        if (result != null) {
          return result;
        }
      } on Object catch (e) {
        logger.printTrace('mDNS ${ipv6 ? 'IPv6' : 'IPv4'} query failed: $e');
      }
    }
    return null;
  }

  /// Extracts a Mac-reachable address for [deviceId] from
  /// `devicectl list devices --json-output`.
  ///
  /// In preference order: an IPv4 address, a routable IPv6 address, then a
  /// `.coredevice.local` (or other `.local`) hostname. Link-local IPv6
  /// literals are skipped — they need a scope id devicectl does not report,
  /// while the hostname resolves to a usable address.
  static String? parseDeviceAddress(String jsonOutput, String deviceId) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(jsonOutput);
    } on FormatException {
      return null;
    }
    final dynamic devices = (decoded is Map && decoded['result'] is Map)
        ? (decoded['result'] as Map)['devices']
        : null;
    if (devices is! List) {
      return null;
    }
    for (final Object? d in devices) {
      if (d is! Map || d['identifier'] != deviceId) {
        continue;
      }
      final dynamic conn = d['connectionProperties'];
      if (conn is Map) {
        // `networkAddresses` entries are plain strings on some devicectl
        // versions and `{"address": ...}` maps on others.
        final addresses = <InternetAddress>[];
        final dynamic netAddrs = conn['networkAddresses'];
        if (netAddrs is List) {
          for (final Object? a in netAddrs) {
            final Object? raw = a is Map ? a['address'] : a;
            final InternetAddress? parsed = raw is String ? InternetAddress.tryParse(raw) : null;
            if (parsed != null) {
              addresses.add(parsed);
            }
          }
        }
        for (final a in addresses) {
          if (a.type == InternetAddressType.IPv4) {
            return a.address;
          }
        }
        for (final a in addresses) {
          if (!a.isLinkLocal && !a.isLoopback) {
            return a.address;
          }
        }

        final dynamic hostnames = conn['potentialHostnames'];
        if (hostnames is List) {
          String? best;
          for (final Object? h in hostnames) {
            if (h is! String || !h.endsWith('.coredevice.local')) {
              continue;
            }
            if (best == null || h.length < best.length) {
              best = h;
            }
          }
          if (best != null) {
            return best;
          }
        }
        final dynamic localHostnames = conn['localHostnames'];
        if (localHostnames is List) {
          for (final Object? h in localHostnames) {
            if (h is String && h.endsWith('.local')) {
              return h;
            }
          }
        }
      }
      final dynamic hp = d['hardwareProperties'];
      if (hp is Map && hp['address'] is String) {
        return hp['address'] as String;
      }
    }
    return null;
  }

  /// Asks devicectl for the device's network IP (fallback when mDNS fails).
  Future<String?> _resolveDeviceIp(String deviceId) async {
    final Directory tmp = globals.fs.systemTempDirectory.createTempSync('devicectl_ip.');
    try {
      final File out = tmp.childFile('device.json');
      final RunResult r = await globals.processUtils.run(<String>[
        'xcrun',
        'devicectl',
        'list',
        'devices',
        '--json-output',
        out.path,
      ]);
      if (r.exitCode != 0 || !out.existsSync()) {
        return null;
      }
      return parseDeviceAddress(out.readAsStringSync(), deviceId);
    } finally {
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        /* ignore */
      }
    }
  }

  /// Polls `devicectl device info apps` until [bundleId] shows up (LaunchServices
  /// indexing gap) or the timeout expires. Returns the install URL.
  Future<String?> _waitForAppRegistration(
    String deviceId,
    String bundleId, {
    Duration timeout = const Duration(seconds: 15),
    Duration pollInterval = const Duration(milliseconds: 200),
  }) async {
    final sw = Stopwatch()..start();
    var attempts = 0;
    final Directory tmp = globals.fs.systemTempDirectory.createTempSync('devicectl_apps.');
    try {
      while (sw.elapsed < timeout) {
        attempts++;
        final File jsonOut = tmp.childFile('apps_$attempts.json');
        final RunResult result = await globals.processUtils.run(<String>[
          'xcrun',
          'devicectl',
          'device',
          'info',
          'apps',
          '--device',
          deviceId,
          '--json-output',
          jsonOut.path,
        ]);
        String? foundUrl;
        var bodyLen = -1;
        final bool fileExists = jsonOut.existsSync();
        if (fileExists) {
          final String body = jsonOut.readAsStringSync();
          bodyLen = body.length;
          try {
            final dynamic decoded = jsonDecode(body);
            final dynamic apps = (decoded is Map && decoded['result'] is Map)
                ? (decoded['result'] as Map)['apps']
                : null;
            if (apps is List) {
              for (final Object? app in apps) {
                if (app is Map && app['bundleIdentifier'] == bundleId) {
                  final dynamic url = app['url'];
                  if (url is String && url.startsWith('file://')) {
                    foundUrl = url;
                  }
                  break;
                }
              }
            }
          } on FormatException {
            // JSON not ready yet.
          }
        }
        globals.logger.printTrace(
          '  [attempt $attempts] exit=${result.exitCode} '
          'fileExists=$fileExists bodyLen=$bodyLen '
          'foundUrl=${foundUrl ?? "null"} jsonPath=${jsonOut.path}',
        );
        if (foundUrl != null) {
          return foundUrl;
        }
        await Future<void>.delayed(pollInterval);
      }
      return null;
    } finally {
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // Best effort cleanup; tempdir may already be gone.
      }
    }
  }

  /// Reads PRODUCT_BUNDLE_IDENTIFIER from the watchOS project.pbxproj.
  String _readBundleId(FlutterProject project) {
    final String pbxprojPath = globals.fs.path.join(
      project.directory.path,
      'watchos',
      'Runner.xcodeproj',
      'project.pbxproj',
    );
    final File file = globals.fs.file(pbxprojPath);
    if (file.existsSync()) {
      final String content = file.readAsStringSync();
      final regex = RegExp(r'PRODUCT_BUNDLE_IDENTIFIER\s*=\s*(.*?);');
      final Match? match = regex.firstMatch(content);
      if (match != null) {
        String? id = match.group(1)?.trim();
        if (id != null && id.length >= 2 && id.startsWith('"') && id.endsWith('"')) {
          id = id.substring(1, id.length - 1);
        }
        if (id != null && !id.contains('RunnerTests')) {
          return id;
        }
      }
    }
    return 'com.example.${project.directory.basename.replaceAll('-', '_')}';
  }

  @override
  Future<bool> stopApp(covariant ApplicationPackage? app, {String? userIdentifier}) async {
    if (app == null) {
      return false;
    }

    await _launchHold?.cancel();
    _launchHold = null;
    _logReader?.dispose();
    _logReader = null;

    if (isSimulator) {
      final RunResult result = await globals.processUtils.run(<String>[
        'xcrun',
        'simctl',
        'terminate',
        id,
        app.id,
      ]);
      return result.exitCode == 0;
    }

    // Physical device: the log reader dispose() above already terminates the
    // launch console session (which unlocks the app).
    return true;
  }

  /// Tells the user why DevTools has not arrived yet, while `run` goes on
  /// waiting for the watch to reach this Mac.
  void _warnRelayLate(WatchosPhysicalDeviceLogReader logReader) {
    // Which half failed matters: the app not reaching the Mac is a network
    // problem, the VM Service never coming up is not.
    final cause = logReader.deviceVmServiceUri == null
        ? 'The Dart VM Service did not start on the watch.'
        : 'The Dart VM Service started on the watch '
              '(${logReader.deviceVmServiceUri}) but the app did not reach '
              'this Mac.';
    logger.printWarning(
      'The app has not connected back to the DevTools relay after 45s. '
      'App logs keep streaming, and DevTools connects if the watch reaches '
      'this Mac later; press Ctrl+C to stop. $cause The watch reaches the Mac '
      'through its paired iPhone — check the iPhone is nearby, unlocked, and '
      'on the same network as this Mac.'
      '${_relayAdvertisedHost == null ? '' : ' The watch was told to dial '
            '$_relayAdvertisedHost; if the iPhone cannot reach that address '
            '(a Mac on several networks at once has more than one, and only '
            'some are reachable), set FLUTTER_WATCHOS_RELAY_HOST to the '
            'right one.'}',
    );
  }

  /// Brings up the Mac half of the VM Service relay.
  ///
  /// Returns the environment the app needs to find it, or an empty map if the
  /// relay could not be started — in which case the run continues without live
  /// DevTools rather than failing outright.
  Future<Map<String, String>> _startVmRelay() async {
    try {
      final String? macAddress = await resolveMacLanAddress(
        override: globals.platform.environment['FLUTTER_WATCHOS_RELAY_HOST'],
      );
      if (macAddress == null) {
        logger.printTrace('No routable Mac address; skipping the VM Service relay.');
        return const <String, String>{};
      }
      _relayAdvertisedHost = macAddress;
      _deviceVmServicePort = pickDeviceVmServicePort();
      final WatchosVmRelay relay = await WatchosVmRelay.start(logTrace: logger.printTrace);
      _vmRelay = relay;
      globals.shutdownHooks.addShutdownHook(relay.dispose);
      logger.printTrace(
        'VM Service relay listening on ${relay.port}; watch will dial '
        '${relay.bridgeUri(macAddress)}',
      );
      return <String, String>{
        'FLUTTER_WATCHOS_RELAY_URL': relay.bridgeUri(macAddress).toString(),
        'FLUTTER_WATCHOS_VM_PORT': '$_deviceVmServicePort',
      };
    } on Object catch (e) {
      logger.printTrace('Could not start the VM Service relay: $e');
      return const <String, String>{};
    }
  }

  @override
  void clearLogs() {}

  @override
  FutureOr<DeviceLogReader> getLogReader({
    covariant ApplicationPackage? app,
    bool includePastLogs = false,
  }) {
    if (isSimulator) {
      return _logReader ??= WatchosSimulatorLogReader(name, deviceId: id, logger: logger);
    }
    return _logReader ??= WatchosPhysicalDeviceLogReader(name);
  }

  @override
  final DevicePortForwarder portForwarder = const NoOpDevicePortForwarder();

  @override
  bool get supportsScreenshot => false;

  @override
  bool isSupportedForProject(FlutterProject flutterProject) {
    return flutterProject.directory.childDirectory('watchos').existsSync();
  }

  @override
  Future<void> dispose() async {
    await _launchHold?.cancel();
    _launchHold = null;
    _logReader?.dispose();
  }
}
