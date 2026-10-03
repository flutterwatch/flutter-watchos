// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io';

import 'package:flutter_tools/executable.dart' show LoggerFactory;
import 'package:flutter_tools/runner.dart' as runner;
import 'package:flutter_tools/src/android/android_workflow.dart';
import 'package:flutter_tools/src/application_package.dart';
import 'package:flutter_tools/src/artifacts.dart';
import 'package:flutter_tools/src/base/config.dart';
import 'package:flutter_tools/src/base/context.dart';
import 'package:flutter_tools/src/base/io.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/os.dart' show findProjectRoot;
// Prefixed: dart:io has a Platform too, which [rootPath] reads.
import 'package:flutter_tools/src/base/platform.dart' as tools show Platform;
import 'package:flutter_tools/src/base/template.dart';
import 'package:flutter_tools/src/build_system/build_targets.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/commands/analyze.dart';
import 'package:flutter_tools/src/commands/assemble.dart';
import 'package:flutter_tools/src/commands/config.dart';
import 'package:flutter_tools/src/commands/daemon.dart';
import 'package:flutter_tools/src/commands/doctor.dart';
import 'package:flutter_tools/src/commands/emulators.dart';
import 'package:flutter_tools/src/commands/generate.dart';
import 'package:flutter_tools/src/commands/generate_localizations.dart';
import 'package:flutter_tools/src/commands/packages.dart';
import 'package:flutter_tools/src/commands/screenshot.dart';
import 'package:flutter_tools/src/commands/shell_completion.dart';
import 'package:flutter_tools/src/commands/symbolize.dart';
import 'package:flutter_tools/src/device.dart';
import 'package:flutter_tools/src/doctor.dart';
import 'package:flutter_tools/src/features.dart';
import 'package:flutter_tools/src/flutter_features.dart';
import 'package:flutter_tools/src/flutter_features_config.dart';
import 'package:flutter_tools/src/flutter_manifest.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/hook_runner.dart' show FlutterHookRunner;
import 'package:flutter_tools/src/isolated/mustache_template.dart';
import 'package:flutter_tools/src/macos/macos_workflow.dart';
import 'package:flutter_tools/src/project_validator.dart';
import 'package:flutter_tools/src/runner/flutter_command.dart';
import 'package:flutter_tools/src/version.dart';
import 'package:flutter_tools/src/windows/windows_workflow.dart';
import 'package:path/path.dart';

import 'build_targets/application.dart' show WatchosBuildTargets;
import 'build_targets/watchos_hooks.dart' show WatchosHookRunner;
import 'commands/attach.dart';
import 'commands/build.dart';
import 'commands/build_registry.dart';
import 'commands/channel.dart';
import 'commands/clean.dart';
import 'commands/create.dart';
import 'commands/debug_adapter.dart';
import 'commands/devices.dart';
import 'commands/downgrade.dart';
import 'commands/drive.dart';
import 'commands/host.dart';
import 'commands/install.dart';
import 'commands/login.dart';
import 'commands/logs.dart';
import 'commands/plugin.dart';
import 'commands/precache.dart';
import 'commands/run.dart';
import 'commands/test.dart';
import 'commands/upgrade.dart';
import 'commands/upload.dart';
import 'watchos_application_package.dart';
import 'watchos_artifacts.dart';
import 'watchos_cache.dart';
import 'watchos_device_discovery.dart';
import 'watchos_doctor.dart';
import 'watchos_logger.dart';
import 'watchos_platform_args.dart';

/// Main entry point for commands.
///
/// Source: `flutter.main` in `executable.dart` (some commands and options were omitted)
Future<void> main(List<String> args) async {
  final bool veryVerbose = args.contains('-vv');
  final bool verbose = args.contains('-v') || args.contains('--verbose') || veryVerbose;

  final bool doctor =
      (args.isNotEmpty && args.first == 'doctor') ||
      (args.length == 2 && verbose && args.last == 'doctor');
  final bool help =
      args.contains('-h') ||
      args.contains('--help') ||
      (args.isNotEmpty && args.first == 'help') ||
      (args.length == 1 && verbose);
  final bool muteCommandLogging = (help || doctor) && !veryVerbose;
  final bool verboseHelp = help && verbose;
  // As stock's main reads them, for the logger.
  final bool prefixedErrors = args.contains('--prefixed-errors');
  final bool daemon = args.contains('daemon');
  final bool runMachine = args.contains('--machine');

  args = <String>[
    '--suppress-analytics', // Suppress flutter analytics by default.
    '--no-version-check',
    ...args,
  ];

  // Make `flutter-watchos create --platforms=watchos` first-class. Upstream
  // Flutter's `--platforms` rejects `watchos` at parse time; rewrite it here
  // (the one argv seam we own) before the runner parses.
  args = expandWatchosPlatformArgs(args);

  Cache.flutterRoot = join(rootPath, 'flutter');

  await runner.run(
    args,
    () => generateWatchosCommands(verboseHelp: verboseHelp, verbose: verbose),
    verbose: verbose,
    verboseHelp: verboseHelp,
    muteCommandLogging: muteCommandLogging,
    reportCrashes: false,
    overrides: <Type, Generator>{
      // Runs the build hooks during a resident session. `RunCommand` already
      // passes this through as the resident runner's `dartBuilder`, and
      // `HotRunner._updateDevFS` calls it whenever the asset bundle needs
      // rebuilding — but the getter reads it out of the context, so without an
      // override it was null and the call was skipped for the whole session. A
      // package that generates its assets from a build hook then served
      // whatever the last full build happened to leave behind.
      //
      // What counts as "needs rebuilding" is upstream's
      // `AssetBundle.needsBuild()`, untouched here; this restores the call it
      // gates, not the gate.
      //
      // This is watchOS's own runner rather than upstream's, so a reload names
      // the same target OS a build does. Upstream's asks for data assets alone,
      // which carries no target OS at all, and a package choosing an output
      // from it would swap in a different one every time the two took turns.
      FlutterHookRunner: () => WatchosHookRunner(),
      ApplicationPackageFactory: () => WatchosApplicationPackageFactory(),
      BuildTargets: () => const WatchosBuildTargets(),
      Cache: () => WatchosFlutterCache(
        fileSystem: globals.fs,
        logger: globals.logger,
        platform: globals.platform,
        osUtils: globals.os,
        projectFactory: globals.projectFactory,
        processManager: globals.processManager,
      ),
      TemplateRenderer: () => const MustacheTemplateRenderer(),
      // Stock's flags, as stock's context builds them, with custom devices on
      // unless configured off: see [createWatchosFeatureFlags].
      FeatureFlags: () => createWatchosFeatureFlags(
        flutterVersion: globals.flutterVersion,
        globalConfig: globals.config,
        platform: globals.platform,
        projectManifest: FlutterManifest.createFromPath(
          globals.fs.path.join(
            findProjectRoot(globals.fs) ?? globals.fs.currentDirectory.path,
            'pubspec.yaml',
          ),
          fileSystem: globals.fs,
          logger: globals.logger,
        ),
      ),
      Artifacts: () => WatchosArtifacts(
        fileSystem: globals.fs,
        cache: globals.cache,
        platform: globals.platform,
        operatingSystemUtils: globals.os,
      ),
      DoctorValidatorsProvider: () => WatchosDoctorValidatorsProvider(),
      WatchosWorkflow: () => WatchosWorkflow(operatingSystemUtils: globals.os),
      DeviceManager: () => WatchosDeviceManager(
        logger: globals.logger,
        processManager: globals.processManager,
        platform: globals.platform,
        androidSdk: globals.androidSdk,
        iosSimulatorUtils: globals.iosSimulatorUtils!,
        featureFlags: featureFlags,
        fileSystem: globals.fs,
        iosWorkflow: globals.iosWorkflow!,
        artifacts: globals.artifacts!,
        flutterVersion: globals.flutterVersion,
        androidWorkflow: AndroidWorkflow(
          androidSdk: globals.androidSdk,
          featureFlags: featureFlags,
        ),
        xcDevice: globals.xcdevice!,
        userMessages: globals.userMessages,
        windowsWorkflow: WindowsWorkflow(featureFlags: featureFlags, platform: globals.platform),
        macOSWorkflow: MacOSWorkflow(platform: globals.platform, featureFlags: featureFlags),
        operatingSystemUtils: globals.os,
        customDevicesConfig: globals.customDevicesConfig,
        nativeAssetsBuilder: globals.nativeAssetsBuilder,
        watchosWorkflow: watchosWorkflow!,
      ),
      WatchosValidator: () => WatchosValidator(processManager: globals.processManager),
      // Stock's logger, as stock's main builds it. For people it is wrapped so
      // the device list shows `(watch)` and the usage hint names
      // flutter-watchos; for daemon and --machine it is stock's alone.
      Logger: () => createWatchosLogger(
        LoggerFactory(
          outputPreferences: globals.outputPreferences,
          terminal: globals.terminal,
          stdio: globals.stdio,
        ),
        daemon: daemon,
        machine: runMachine,
        verbose: verbose && !muteCommandLogging,
        prefixedErrors: prefixedErrors,
        windows: globals.platform.isWindows,
      ),
    },
    shutdownHooks: globals.shutdownHooks,
  );
}

/// Stock's [FlutterFeatureFlags], with custom devices on unless configured
/// off.
///
/// An IDE asks `daemon.getSupportedPlatforms` whether custom devices are
/// supported before it offers a device outside Flutter's own platforms, such
/// as a watch. Stock turns the feature on only through `flutter config
/// --enable-custom-devices`, which writes the settings file that stock Flutter
/// shares. Here it is on when nothing configures it, and nothing is written:
/// the pubspec, `flutter config` and `FLUTTER_CUSTOM_DEVICES` still decide, in
/// stock's order. Every other feature is stock's. With the feature on, stock's
/// custom-device discovery also lists the devices configured for stock
/// Flutter, if there are any.
///
/// The arguments are the ones stock's context builds its flags from.
FeatureFlags createWatchosFeatureFlags({
  required FlutterVersion flutterVersion,
  required Config globalConfig,
  required tools.Platform platform,
  required FlutterManifest? projectManifest,
}) => FlutterFeatureFlags(
  flutterVersion: flutterVersion,
  featuresConfig: _WatchosFeaturesConfig(
    FlutterFeaturesConfig(
      globalConfig: globalConfig,
      platform: platform,
      projectManifest: projectManifest,
    ),
  ),
  platform: platform,
);

/// Stock's feature configuration, which says "on" for custom devices when it
/// has no value of its own.
class _WatchosFeaturesConfig implements FlutterFeaturesConfig {
  const _WatchosFeaturesConfig(this._stock);

  final FlutterFeaturesConfig _stock;

  @override
  bool? isEnabled(Feature feature) =>
      _stock.isEnabled(feature) ?? (feature == flutterCustomDevicesFeature ? true : null);
}

/// The commands flutter-watchos registers.
///
/// A function, like stock `generateCommands`, so a test can pin the list. It
/// reads the commands' dependencies from `globals`, so it runs inside the
/// tool's context.
///
/// Some stock commands stay out. `custom-devices`, `ide-config` and the one
/// that shows widgets in a browser have no use on a watch. `update-packages`
/// (alias `upgrade-packages`) is a tool for the Flutter repository itself, and
/// it can rewrite the pinned SDK's pubspecs. Typing one gives the usage error.
List<FlutterCommand> generateWatchosCommands({required bool verboseHelp, required bool verbose}) =>
    <FlutterCommand>[
      // Commands forwarded directly from flutter_tools — these have no
      // watchOS-specific behaviour, so we register them as-is.
      AnalyzeCommand(
        verboseHelp: verboseHelp,
        fileSystem: globals.fs,
        platform: globals.platform,
        processManager: globals.processManager,
        logger: globals.logger,
        terminal: globals.terminal,
        artifacts: globals.artifacts!,
        allProjectValidators: <ProjectValidator>[
          GeneralInfoProjectValidator(),
          VariableDumpMachineProjectValidator(
            logger: globals.logger,
            fileSystem: globals.fs,
            platform: globals.platform,
            git: globals.git,
          ),
        ],
        suppressAnalytics: !globals.analytics.okToSend,
      ),
      AssembleCommand(verboseHelp: verboseHelp, buildSystem: globals.buildSystem),
      ConfigCommand(verboseHelp: verboseHelp),
      DaemonCommand(hidden: !verboseHelp),
      WatchosDebugAdapterCommand(verboseHelp: verboseHelp),
      DoctorCommand(verbose: verbose),
      EmulatorsCommand(),
      GenerateCommand(),
      GenerateLocalizationsCommand(
        fileSystem: globals.fs,
        logger: globals.logger,
        artifacts: globals.artifacts!,
        processManager: globals.processManager,
      ),
      WatchosInstallCommand(verboseHelp: verboseHelp),
      // `logs` streams a watch Simulator as stock streams an iOS Simulator,
      // and refuses a physical watch, which has no log stream, with guidance.
      WatchosLogsCommand(sigint: ProcessSignal.sigint, sigterm: ProcessSignal.sigterm),
      PackagesCommand(),
      ScreenshotCommand(fs: globals.fs),
      ShellCompletionCommand(),
      SymbolizeCommand(stdio: globals.stdio, fileSystem: globals.fs),
      // Commands extended for watchOS.
      // `upgrade` is overridden so it upgrades the flutter-watchos toolchain to
      // its latest release tag instead of moving the pinned Flutter SDK
      // upstream (which stock UpgradeCommand would do, breaking the
      // engine-artifact pin).
      WatchosUpgradeCommand(verboseHelp: verboseHelp),
      // `channel` shows the pin and `downgrade` refuses: the stock commands
      // move the pinned SDK, which the next run would reset.
      WatchosChannelCommand(),
      WatchosDowngradeCommand(),
      WatchosAttachCommand(
        verboseHelp: verboseHelp,
        stdio: globals.stdio,
        logger: globals.logger,
        terminal: globals.terminal,
        signals: globals.signals,
        platform: globals.platform,
        processInfo: globals.processInfo,
        fileSystem: globals.fs,
      ),
      WatchosBuildCommand(logger: globals.logger, verboseHelp: verboseHelp),
      WatchosCleanCommand(verbose: verbose),
      WatchosCreateCommand(verboseHelp: verboseHelp),
      WatchosDevicesCommand(verboseHelp: verboseHelp),
      WatchosDriveCommand(
        verboseHelp: verboseHelp,
        fileSystem: globals.fs,
        logger: globals.logger,
        platform: globals.platform,
        signals: globals.signals,
        terminal: globals.terminal,
        outputPreferences: globals.outputPreferences,
      ),
      WatchosHostCommand(),
      WatchosBuildRegistryCommand(),
      WatchosLoginCommand(),
      WatchosLogoutCommand(),
      WatchosPluginCommand(verboseHelp: verboseHelp),
      WatchosPrecacheCommand(
        verboseHelp: verboseHelp,
        cache: globals.cache,
        logger: globals.logger,
        platform: globals.platform,
        featureFlags: featureFlags,
      ),
      WatchosRunCommand(verboseHelp: verboseHelp),
      WatchosTestCommand(verboseHelp: verboseHelp),
      WatchosUploadCommand(),
    ];

/// See: [Cache.defaultFlutterRoot] in `cache.dart`
String get rootPath {
  final String scriptPath = Platform.script.toFilePath();
  return normalize(join(scriptPath, scriptPath.endsWith('.snapshot') ? '../../..' : '../..'));
}
