// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io';

import 'package:flutter_tools/runner.dart' as runner;
import 'package:flutter_tools/src/android/android_workflow.dart';
import 'package:flutter_tools/src/application_package.dart';
import 'package:flutter_tools/src/artifacts.dart';
import 'package:flutter_tools/src/base/context.dart';
import 'package:flutter_tools/src/base/io.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/template.dart';
import 'package:flutter_tools/src/build_system/build_targets.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/commands/assemble.dart';
import 'package:flutter_tools/src/commands/channel.dart';
import 'package:flutter_tools/src/commands/config.dart';
import 'package:flutter_tools/src/commands/daemon.dart';
import 'package:flutter_tools/src/commands/debug_adapter.dart';
import 'package:flutter_tools/src/commands/doctor.dart';
import 'package:flutter_tools/src/commands/downgrade.dart';
import 'package:flutter_tools/src/commands/emulators.dart';
import 'package:flutter_tools/src/commands/generate.dart';
import 'package:flutter_tools/src/commands/generate_localizations.dart';
import 'package:flutter_tools/src/commands/install.dart';
import 'package:flutter_tools/src/commands/logs.dart';
import 'package:flutter_tools/src/commands/packages.dart';
import 'package:flutter_tools/src/commands/screenshot.dart';
import 'package:flutter_tools/src/commands/shell_completion.dart';
import 'package:flutter_tools/src/commands/symbolize.dart';
import 'package:flutter_tools/src/commands/update_packages.dart';
import 'package:flutter_tools/src/device.dart';
import 'package:flutter_tools/src/doctor.dart';
import 'package:flutter_tools/src/features.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/isolated/build_targets.dart';
import 'package:flutter_tools/src/isolated/mustache_template.dart';
import 'package:flutter_tools/src/macos/macos_workflow.dart';
import 'package:flutter_tools/src/runner/flutter_command.dart';
import 'package:flutter_tools/src/windows/windows_workflow.dart';
import 'package:path/path.dart';

import 'commands/attach.dart';
import 'commands/build.dart';
import 'commands/clean.dart';
import 'commands/create.dart';
import 'commands/devices.dart';
import 'commands/drive.dart';
import 'commands/plugin.dart';
import 'commands/precache.dart';
import 'commands/run.dart';
import 'commands/test.dart';
import 'commands/upgrade.dart';
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
    () => <FlutterCommand>[
      // Commands forwarded directly from flutter_tools — these have no
      // watchOS-specific behaviour, so we register them as-is.
      AssembleCommand(verboseHelp: verboseHelp, buildSystem: globals.buildSystem),
      ChannelCommand(verboseHelp: verboseHelp),
      ConfigCommand(verboseHelp: verboseHelp),
      DaemonCommand(hidden: !verboseHelp),
      DebugAdapterCommand(verboseHelp: verboseHelp),
      DoctorCommand(verbose: verbose),
      DowngradeCommand(verboseHelp: verboseHelp, logger: globals.logger),
      EmulatorsCommand(),
      GenerateCommand(),
      GenerateLocalizationsCommand(
        fileSystem: globals.fs,
        logger: globals.logger,
        artifacts: globals.artifacts!,
        processManager: globals.processManager,
      ),
      InstallCommand(verboseHelp: verboseHelp),
      LogsCommand(sigint: ProcessSignal.sigint, sigterm: ProcessSignal.sigterm),
      PackagesCommand(),
      ScreenshotCommand(fs: globals.fs),
      ShellCompletionCommand(),
      SymbolizeCommand(stdio: globals.stdio, fileSystem: globals.fs),
      UpdatePackagesCommand(verboseHelp: verboseHelp),
      // Commands extended for watchOS.
      // `upgrade` is overridden so it upgrades the flutter-watchos toolchain to
      // its latest release tag instead of moving the pinned Flutter SDK
      // upstream (which stock UpgradeCommand would do, breaking the
      // engine-artifact pin).
      WatchosUpgradeCommand(verboseHelp: verboseHelp),
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
      WatchosBuildCommand(
        artifacts: globals.artifacts!,
        cache: globals.cache,
        fileSystem: globals.fs,
        flutterVersion: globals.flutterVersion,
        buildSystem: globals.buildSystem,
        osUtils: globals.os,
        logger: globals.logger,
        androidSdk: globals.androidSdk,
        config: globals.config,
        platform: globals.platform,
        processUtils: globals.processUtils,
        processManager: globals.processManager,
        fileSystemUtils: globals.fsUtils,
        templateRenderer: globals.templateRenderer,
        terminal: globals.terminal,
        plistParser: globals.plistParser,
        xcode: globals.xcode,
        verboseHelp: verboseHelp,
      ),
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
    ],
    verbose: verbose,
    verboseHelp: verboseHelp,
    muteCommandLogging: muteCommandLogging,
    reportCrashes: false,
    overrides: <Type, Generator>{
      ApplicationPackageFactory: () => WatchosApplicationPackageFactory(),
      BuildTargets: () => const BuildTargetsImpl(),
      Cache: () => WatchosFlutterCache(
        fileSystem: globals.fs,
        logger: globals.logger,
        platform: globals.platform,
        osUtils: globals.os,
        projectFactory: globals.projectFactory,
        processManager: globals.processManager,
      ),
      TemplateRenderer: () => const MustacheTemplateRenderer(),
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
      // Always wrap the logger with WatchosCategoryRewritingLogger so the
      // device list shows `(watch)` instead of `(mobile)` for watchOS devices.
      // The wrapper is a no-op on every other line. In verbose mode,
      // VerboseLogger sits inside ours so timestamps still apply.
      Logger: () => WatchosCategoryRewritingLogger(
        verbose && !muteCommandLogging
            ? VerboseLogger(
                StdoutLogger(
                  stdio: globals.stdio,
                  terminal: globals.terminal,
                  outputPreferences: globals.outputPreferences,
                ),
              )
            : StdoutLogger(
                stdio: globals.stdio,
                terminal: globals.terminal,
                outputPreferences: globals.outputPreferences,
              ),
      ),
    },
    shutdownHooks: globals.shutdownHooks,
  );
}

/// See: [Cache.defaultFlutterRoot] in `cache.dart`
String get rootPath {
  final String scriptPath = Platform.script.toFilePath();
  return normalize(join(scriptPath, scriptPath.endsWith('.snapshot') ? '../../..' : '../..'));
}
