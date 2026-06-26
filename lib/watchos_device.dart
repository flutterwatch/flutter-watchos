// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Process;

import 'package:file/file.dart';
import 'package:flutter_tools/src/application_package.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/process.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/device.dart';
import 'package:flutter_tools/src/device_port_forwarder.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/ios/lldb.dart';
import 'package:flutter_tools/src/ios/xcode_debug.dart';
import 'package:flutter_tools/src/macos/xcode.dart';
import 'package:flutter_tools/src/mdns_discovery.dart';
import 'package:flutter_tools/src/project.dart';
import 'package:flutter_tools/src/protocol_discovery.dart';
import 'package:flutter_tools/src/vmservice.dart';
import 'package:meta/meta.dart';

import 'watchos_application_package.dart';
import 'watchos_build_info.dart';
import 'watchos_builder.dart';

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

  @override
  final String name;

  @override
  Stream<String> get logLines => _linesController.stream;

  /// Starts streaming logs from the physical device using devicectl.
  Future<void> startLogStream(String deviceId) async {
    _logProcess = await globals.processManager.start(<String>[
      'xcrun', 'devicectl', 'device', 'process', 'launch',
      '--terminate-existing',
      '--device', deviceId,
      '--console',
    ]);

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

  /// Launches the app on device (optionally paused with --start-stopped) and
  /// streams its console output as log lines. When `startStopped` is true the
  /// caller attaches a debugger (lldb) to resume the process — JIT debug on a
  /// physical watch requires this.
  Future<void> startLogStreamForBundle(
    String deviceId,
    String bundleId, {
    bool startStopped = false,
  }) async {
    // Wrap in `script -t 0 /dev/null` to convince devicectl it has a TTY and
    // forward child stdout. `--console` blocks until the app exits.
    final cmd = <String>[
      'script', '-t', '0', '/dev/null',
      'xcrun', 'devicectl', 'device', 'process', 'launch',
      '--device', deviceId,
      '--console',
      '--environment-variables', '{"OS_ACTIVITY_DT_MODE": "enable"}',
      if (startStopped) '--start-stopped',
      bundleId,
      // Launch arguments forwarded to the Flutter app's main(): bind the Dart
      // VM on every interface so the Mac can reach it over the wireless tunnel,
      // enable profiling, and drop the auth token so a host:port from mDNS is
      // enough.
      '--enable-dart-profiling',
      '--disable-service-auth-codes',
      '--vm-service-host=0.0.0.0',
    ];
    _logProcess = await globals.processManager.start(cmd);

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
    if (_isNoise(line)) {
      _log.printTrace(line);
      return;
    }
    _linesController.add(line);
  }

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
class WatchosSimulatorLogReader implements DeviceLogReader {
  WatchosSimulatorLogReader(this.name);

  final StreamController<String> _linesController = StreamController<String>.broadcast();

  Process? _logProcess;

  @override
  final String name;

  @override
  Stream<String> get logLines => _linesController.stream;

  /// Starts streaming unified logs from the simulator, filtered for the app.
  Future<void> startLogStream(String deviceId) async {
    const predicate = 'senderImagePath ENDSWITH "/Flutter"';

    _logProcess = await globals.processManager.start(<String>[
      'xcrun',
      'simctl',
      'spawn',
      deviceId,
      'log',
      'stream',
      '--style',
      'json',
      '--predicate',
      predicate,
    ]);

    _logProcess!.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((
      String line,
    ) {
      _onUnifiedLoggingLine(line);
    });

    _logProcess!.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((
      String line,
    ) {
      _onUnifiedLoggingLine(line);
    });
  }

  static final RegExp _eventMessageRegex = RegExp(r'"eventMessage"\s*:\s*(".*?")');

  /// Processes a single line from the unified log stream.
  @visibleForTesting
  void processLogLine(String line) => _onUnifiedLoggingLine(line);

  void _onUnifiedLoggingLine(String line) {
    final Match? match = _eventMessageRegex.firstMatch(line);
    if (match != null) {
      final String rawMessage = match.group(1)!;
      try {
        final Object? decoded = jsonDecode(rawMessage);
        if (decoded is String && !_linesController.isClosed) {
          _linesController.add(decoded);
        }
      } on FormatException {
        if (!_linesController.isClosed) {
          _linesController.add(rawMessage);
        }
      }
    }
  }

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

  DeviceLogReader? _logReader;
  LLDB? _lldb;
  LLDBLogForwarder? _lldbLogForwarder;
  XcodeDebug? _xcodeDebug;

  /// How long to wait for lldb to attach over the (wireless-only) CoreDevice
  /// tunnel before giving up. Apple Watch has no USB data port, so the lldb
  /// attach always goes through the network tunnel. Override with
  /// `FLUTTER_WATCHOS_LLDB_ATTACH_TIMEOUT_SECONDS` for slow networks.
  Duration get _lldbAttachTimeout {
    final String? raw =
        globals.platform.environment['FLUTTER_WATCHOS_LLDB_ATTACH_TIMEOUT_SECONDS'];
    final int? seconds = raw == null ? null : int.tryParse(raw);
    return Duration(seconds: seconds != null && seconds > 0 ? seconds : 180);
  }

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

  @override
  bool supportsRuntimeMode(BuildMode buildMode) => buildMode != BuildMode.jitRelease;

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

    if (result.exitCode != 0) {
      logger.printError('devicectl install failed:\n${result.stderr}');
      return false;
    }
    return true;
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
    final logReader =
        (_logReader ??= WatchosSimulatorLogReader(name)) as WatchosSimulatorLogReader;
    await logReader.startLogStream(id);

    final RunResult launchResult = await globals.processUtils.run(<String>[
      'xcrun',
      'simctl',
      'launch',
      id,
      bundleId,
    ]);
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
    final RunResult installResult = await globals.processUtils.run(<String>[
      'xcrun',
      'devicectl',
      'device',
      'install',
      'app',
      '--device',
      id,
      appPath,
    ]);
    logger.printTrace(installResult.stdout);
    if (installResult.exitCode != 0) {
      logger.printError('devicectl install failed: ${installResult.stderr}');
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

    // Debug builds need JIT, which a physical watch only allows when a debugger
    // is attached. Launch `--start-stopped`, then attach lldb and resume.
    final bool needsDebugger = debuggingOptions.buildInfo.isDebug;
    logger.printTrace('Launching $bundleId on Apple Watch...');
    final logReader =
        (_logReader ??= WatchosPhysicalDeviceLogReader(name)) as WatchosPhysicalDeviceLogReader;
    await logReader.startLogStreamForBundle(id, bundleId, startStopped: needsDebugger);

    if (needsDebugger) {
      // Path 1: lldb (fast when it works). Over a wireless tunnel the attach
      // can stall or drop the CoreDevice connection.
      var attached = false;
      final int? pid = await _findAppPid(id, bundleId, installUrl: installUrl);
      if (pid != null) {
        logger.printTrace('Attaching lldb to pid $pid for JIT debugging...');
        final LLDBLogForwarder lldbForwarder = _lldbLogForwarder ??= LLDBLogForwarder();
        lldbForwarder.logLines.listen((String line) {
          logger.printTrace('[lldb] $line');
        });
        final LLDB lldb = _lldb ??= LLDB(logger: logger, processUtils: globals.processUtils);
        final Duration timeout = _lldbAttachTimeout;
        attached = await lldb
            .attachAndStart(
              deviceId: id,
              appProcessId: pid,
              lldbLogForwarder: lldbForwarder,
              mode: debuggingOptions.buildInfo.mode,
            )
            .timeout(
              timeout,
              onTimeout: () {
                logger.printTrace(
                  'lldb attach timed out after ${timeout.inSeconds}s; falling back.',
                );
                return false;
              },
            );
      }

      if (!attached) {
        // Path 2: Xcode debugger fallback — the same path stock Flutter uses
        // for iOS Core Devices, and the mechanism Xcode itself uses to reliably
        // debug a wirelessly-paired device.
        logger.printStatus(
          'lldb debugging did not attach — falling back to the Xcode debugger. '
          'You may be prompted to allow controlling Xcode '
          '(Settings ▸ Privacy & Security ▸ Automation).',
        );
        await _teardownDeviceLaunch();
        final bool xcodeStarted = await _launchViaXcodeDebugger(
          project: project,
          debuggingOptions: debuggingOptions,
        );
        if (!xcodeStarted) {
          logger.printError(
            'Could not attach a debugger to the app on this Apple Watch, so the '
            'debug session could not start (the app may briefly appear on the '
            'watch and then exit — watchOS debug mode requires an attached '
            'debugger).\n'
            '\n'
            'Apple Watch debugging is wireless-only and depends on the CoreDevice '
            'tunnel. Things to try, in order:\n'
            '  1. Restart the Apple Watch to reset the tunnel, then run again — a '
            'cold/stale tunnel is the most common cause.\n'
            '  2. Make sure the Apple Watch (via its paired iPhone) and this Mac '
            'are on the same Wi-Fi/LAN, and that the Mac has Local Network '
            'permission (System Settings ▸ Privacy & Security ▸ Local Network).\n'
            '  3. Re-run — the lldb attach over the tunnel can be slow; it is '
            'given ${_lldbAttachTimeout.inSeconds}s (override with '
            'FLUTTER_WATCHOS_LLDB_ATTACH_TIMEOUT_SECONDS).\n'
            '  4. For fast debug iteration without the device, use the watchOS '
            'simulator (JIT works there without a debugger).',
          );
          return LaunchResult.failed();
        }
        Uri? xcodeUri;
        try {
          xcodeUri = await MDnsVmServiceDiscovery.instance!.getVMServiceUriForAttach(
            bundleId,
            this,
            useDeviceIPAsHost: true,
            timeout: const Duration(seconds: 60),
          );
        } on Object catch (e) {
          logger.printTrace('mDNS VM Service lookup failed: $e');
        }
        if (xcodeUri != null) {
          logger.printTrace('VM service (via Xcode + mDNS) available at: $xcodeUri');
          return LaunchResult.succeeded(vmServiceUri: xcodeUri);
        }
        logger.printWarning(
          'App launched via Xcode, but its Dart VM Service was not found over '
          'mDNS within 60s — hot reload, hot restart, and DevTools will be '
          'unavailable. Check that this Mac has Local Network permission '
          '(System Settings ▸ Privacy & Security ▸ Local Network) and that the '
          'Apple Watch is on the same network.',
        );
        return LaunchResult.succeeded();
      }
    }

    // Discover the Mac-reachable VM service URI (console scan + mDNS; prefer
    // mDNS since --vm-service-host=0.0.0.0 makes the LAN URL reachable).
    final discovery = ProtocolDiscovery.vmService(logReader, ipv6: false, logger: logger);

    Uri? vmServiceUri = await discovery.uri.timeout(
      const Duration(seconds: 30),
      onTimeout: () => null,
    );
    await discovery.cancel();

    if (vmServiceUri != null &&
        (vmServiceUri.host == '127.0.0.1' || vmServiceUri.host == '0.0.0.0')) {
      final int devicePort = vmServiceUri.port;
      final String authPath = vmServiceUri.path;
      try {
        final MDnsVmServiceDiscoveryResult? result =
            // ignore: invalid_use_of_visible_for_testing_member
            await MDnsVmServiceDiscovery.instance!.queryForLaunch(
              applicationId: bundleId,
              deviceVmservicePort: devicePort,
              useDeviceIPAsHost: true,
              timeout: const Duration(seconds: 10),
            );
        if (result != null && result.ipAddress != null) {
          vmServiceUri = Uri(
            scheme: 'http',
            host: result.ipAddress!.address,
            port: result.port,
            path: authPath,
          );
        } else {
          final String? deviceIp = await _resolveDeviceIp(id);
          if (deviceIp != null) {
            vmServiceUri = vmServiceUri.replace(host: deviceIp);
          }
        }
      } on Object catch (e) {
        logger.printTrace('mDNS lookup failed: $e');
      }
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

  /// Tears down the in-flight devicectl `--console` launch and lldb session so
  /// the Xcode debugger can take the device over cleanly.
  Future<void> _teardownDeviceLaunch() async {
    _lldb?.exit();
    _lldb = null;
    unawaited(_lldbLogForwarder?.exit());
    _lldbLogForwarder = null;
    _logReader?.dispose();
    _logReader = null;
  }

  /// Launches + debugs the app through Xcode (AppleScript automation), mirroring
  /// stock Flutter's iOS Core Device Xcode fallback. Xcode reliably establishes
  /// the debugserver connection to a wirelessly-paired device.
  Future<bool> _launchViaXcodeDebugger({
    required FlutterProject project,
    required DebuggingOptions debuggingOptions,
  }) async {
    final Directory watchosDir = project.directory.childDirectory('watchos');
    final Directory workspace = watchosDir.childDirectory('Runner.xcworkspace');
    final Directory xcodeproj = watchosDir.childDirectory('Runner.xcodeproj');
    if (!workspace.existsSync()) {
      logger.printError(
        'Xcode debugger fallback unavailable: ${workspace.path} not found. '
        'Run the app once so CocoaPods generates the workspace.',
      );
      return false;
    }

    final Xcode? xcode = globals.xcode;
    if (xcode == null) {
      logger.printError(
        'Xcode is required for the wireless debug fallback but is not selected.\n'
        'Open Xcode once, or run '
        '`sudo xcode-select -s /Applications/Xcode.app`.',
      );
      return false;
    }

    final xcodeDebug = XcodeDebug(
      logger: logger,
      processManager: globals.processManager,
      xcode: xcode,
      fileSystem: globals.fs,
    );
    _xcodeDebug = xcodeDebug;

    final File schemeFile = xcodeproj
        .childDirectory('xcshareddata')
        .childDirectory('xcschemes')
        .childFile('Runner.xcscheme');
    if (schemeFile.existsSync()) {
      try {
        xcodeDebug.ensureXcodeDebuggerLaunchAction(schemeFile);
      } on Object catch (e) {
        logger.printError(
          'Could not prepare the Runner scheme for debugging: $e\n'
          'Open watchos/Runner.xcodeproj in Xcode and make sure the Runner '
          "scheme's Run action uses the LLDB debugger.",
        );
        return false;
      }
    }

    final List<String> launchArguments = debuggingOptions.getIOSLaunchArguments(
      EnvironmentType.physical,
      null,
      const <String, Object?>{},
      interfaceType: DeviceConnectionInterface.wireless,
    )..removeWhere((String a) => a == '--enable-checked-mode' || a == '--verify-entry-points');
    for (final flag in <String>[
      '--vm-service-host=0.0.0.0',
      '--disable-service-auth-codes',
      '--enable-dart-profiling',
    ]) {
      if (!launchArguments.contains(flag)) {
        launchArguments.add(flag);
      }
    }

    final debugProject = XcodeDebugProject(
      scheme: 'Runner',
      xcodeWorkspace: workspace,
      xcodeProject: xcodeproj,
      hostAppProjectName: 'Runner',
      verboseLogging: logger.isVerbose,
    );

    final String? resolvedUdid = await _resolveDeviceUdid(id);
    if (resolvedUdid == null) {
      logger.printTrace(
        'Could not resolve a hardware UDID; passing the CoreDevice id "$id" to '
        'Xcode. If Xcode reports the device cannot be found, this is why.',
      );
    }
    final String xcodeDeviceId = resolvedUdid ?? id;

    return xcodeDebug.debugApp(
      project: debugProject,
      deviceId: xcodeDeviceId,
      launchArguments: launchArguments,
    );
  }

  /// Resolves the device's hardware UDID from its CoreDevice identifier.
  Future<String?> _resolveDeviceUdid(String deviceId) async {
    final Directory tmp = globals.fs.systemTempDirectory.createTempSync('devicectl_udid.');
    try {
      final File out = tmp.childFile('info.json');
      final RunResult r = await globals.processUtils.run(<String>[
        'xcrun',
        'devicectl',
        'device',
        'info',
        'details',
        '--device',
        deviceId,
        '--json-output',
        out.path,
      ]);
      if (r.exitCode != 0 || !out.existsSync()) {
        logger.printTrace(
          'devicectl UDID lookup failed (exit ${r.exitCode}); '
          'falling back to the raw device id. stderr: ${r.stderr}',
        );
        return null;
      }
      final String? udid = parseDeviceUdid(out.readAsStringSync());
      if (udid == null) {
        logger.printTrace(
          'devicectl returned 0 but no result.hardwareProperties.udid was '
          'found (JSON shape may have changed); falling back to the raw id.',
        );
      }
      return udid;
    } on Object catch (e) {
      logger.printTrace('Failed to resolve device UDID: $e');
      return null;
    } finally {
      tmp.deleteSync(recursive: true);
    }
  }

  /// Extracts the hardware UDID from `devicectl device info details` JSON.
  static String? parseDeviceUdid(String jsonOutput) {
    try {
      final dynamic decoded = jsonDecode(jsonOutput);
      final dynamic result = (decoded is Map) ? decoded['result'] : null;
      final dynamic hw = (result is Map) ? result['hardwareProperties'] : null;
      if (hw is Map && hw['udid'] is String) {
        return hw['udid'] as String;
      }
    } on FormatException {
      return null;
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
      try {
        final dynamic decoded = jsonDecode(out.readAsStringSync());
        final dynamic devices = (decoded is Map && decoded['result'] is Map)
            ? (decoded['result'] as Map)['devices']
            : null;
        if (devices is! List) {
          return null;
        }
        for (final Object? d in devices) {
          if (d is! Map) {
            continue;
          }
          final dynamic hp = d['hardwareProperties'];
          final dynamic identifier = d['identifier'];
          if (identifier != deviceId) {
            continue;
          }
          final dynamic conn = d['connectionProperties'];
          if (conn is Map) {
            final dynamic netAddrs = conn['networkAddresses'];
            if (netAddrs is List) {
              for (final Object? a in netAddrs) {
                if (a is String && RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(a)) {
                  return a;
                }
              }
            }
            final dynamic hostnames = conn['potentialHostnames'];
            if (hostnames is List) {
              String? best;
              for (final Object? h in hostnames) {
                if (h is! String) {
                  continue;
                }
                if (!h.endsWith('.coredevice.local')) {
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
            final dynamic addrs = conn['localHostnames'];
            if (addrs is List && addrs.isNotEmpty) {
              for (final Object? h in addrs) {
                if (h is String && h.endsWith('.local')) {
                  return h;
                }
              }
            }
          }
          if (hp is Map && hp['address'] is String) {
            return hp['address'] as String;
          }
        }
      } on FormatException {
        return null;
      }
      return null;
    } finally {
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        /* ignore */
      }
    }
  }

  /// Polls `devicectl device info processes` until a process whose executable
  /// lives inside a bundle matching [installUrl] appears, returning its pid.
  Future<int?> _findAppPid(
    String deviceId,
    String bundleId, {
    String? installUrl,
    Duration timeout = const Duration(seconds: 15),
    Duration pollInterval = const Duration(milliseconds: 200),
  }) async {
    if (installUrl == null) {
      final Directory tmp = globals.fs.systemTempDirectory.createTempSync('devicectl_url.');
      try {
        final File out = tmp.childFile('apps.json');
        final RunResult r = await globals.processUtils.run(<String>[
          'xcrun',
          'devicectl',
          'device',
          'info',
          'apps',
          '--device',
          deviceId,
          '--json-output',
          out.path,
        ]);
        if (r.exitCode == 0 && out.existsSync()) {
          try {
            final dynamic decoded = jsonDecode(out.readAsStringSync());
            final dynamic apps = (decoded is Map && decoded['result'] is Map)
                ? (decoded['result'] as Map)['apps']
                : null;
            if (apps is List) {
              for (final Object? a in apps) {
                if (a is Map && a['bundleIdentifier'] == bundleId) {
                  final dynamic u = a['url'];
                  if (u is String) {
                    installUrl = u;
                  }
                  break;
                }
              }
            }
          } on FormatException {
            /* ignore */
          }
        }
      } finally {
        try {
          tmp.deleteSync(recursive: true);
        } on FileSystemException {
          /* ignore */
        }
      }
    }
    if (installUrl == null) {
      return null;
    }

    final sw = Stopwatch()..start();
    final Directory tmp = globals.fs.systemTempDirectory.createTempSync('devicectl_ps.');
    try {
      while (sw.elapsed < timeout) {
        final File out = tmp.childFile('ps.json');
        if (out.existsSync()) {
          out.deleteSync();
        }
        final RunResult r = await globals.processUtils.run(<String>[
          'xcrun',
          'devicectl',
          'device',
          'info',
          'processes',
          '--device',
          deviceId,
          '--json-output',
          out.path,
        ]);
        if (r.exitCode == 0 && out.existsSync()) {
          try {
            final dynamic decoded = jsonDecode(out.readAsStringSync());
            final dynamic procs = (decoded is Map && decoded['result'] is Map)
                ? (decoded['result'] as Map)['runningProcesses']
                : null;
            if (procs is List) {
              for (final Object? p in procs) {
                if (p is Map) {
                  final dynamic exe = p['executable'];
                  final dynamic pid = p['processIdentifier'];
                  if (exe is String &&
                      pid is int &&
                      exe.contains(installUrl.replaceFirst('file://', ''))) {
                    return pid;
                  }
                }
              }
            }
          } on FormatException {
            /* ignore */
          }
        }
        await Future<void>.delayed(pollInterval);
      }
      return null;
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

    _logReader?.dispose();
    _logReader = null;
    _lldb?.exit();
    _lldb = null;
    unawaited(_lldbLogForwarder?.exit());
    _lldbLogForwarder = null;
    unawaited(_xcodeDebug?.exit());
    _xcodeDebug = null;

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

  @override
  void clearLogs() {}

  @override
  FutureOr<DeviceLogReader> getLogReader({
    covariant ApplicationPackage? app,
    bool includePastLogs = false,
  }) {
    if (isSimulator) {
      return _logReader ??= WatchosSimulatorLogReader(name);
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
    _logReader?.dispose();
    unawaited(_xcodeDebug?.exit());
    _xcodeDebug = null;
  }
}
