// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/commands/build.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/project.dart';
import 'package:flutter_tools/src/runner/flutter_command.dart';
import 'package:meta/meta.dart';

import '../watchos_build_info.dart';
import '../watchos_build_registry.dart';
import '../watchos_builder.dart';
import '../watchos_cache.dart';
import '../watchos_mode_guidance.dart';
import '../watchos_plugins.dart';
import 'launch_checks.dart';
import 'stock_build_stub.dart';

/// Builds the watchOS app bundle for `build watchos`.
///
/// [WatchosBuilder.buildBundle] outside tests; command tests pass a fake, so
/// the command runs without Xcode or an engine.
typedef WatchosBundleBuilder =
    Future<void> Function({
      required FlutterProject project,
      required WatchosBuildInfo watchosBuildInfo,
      required String targetFile,
    });

/// What `build watchos` says when asked for a size analysis.
const String kWatchosSizeAnalysisRefusal =
    'Size analysis is not available for watchOS builds: --analyze-size and '
    '--code-size-directory make no report for a watch app.\n'
    'Run the build without them:\n'
    '  flutter-watchos build watchos --release';

/// `build`: the watchOS build, `build watchos`.
///
/// Stock `BuildCommand` adds a subcommand for every stock target, which would
/// run under the watchOS overrides, untested. This command has `watchos`, and
/// a hidden [StockBuildStubCommand] for each stock target name, which says to
/// use stock `flutter build <name>`.
class WatchosBuildCommand extends FlutterCommand {
  /// The `build` command; the seams are passed on to `build watchos`.
  WatchosBuildCommand({
    required Logger logger,
    required bool verboseHelp,
    @visibleForTesting WatchosBundleBuilder? bundleBuilder,
    @visibleForTesting BuildRegistryPost? registryPost,
  }) {
    addSubcommand(
      BuildWatchosCommand(
        logger: logger,
        verboseHelp: verboseHelp,
        bundleBuilder: bundleBuilder,
        registryPost: registryPost,
      ),
    );
    kStockBuildSubcommands.map(StockBuildStubCommand.new).forEach(addSubcommand);
  }

  @override
  final String name = 'build';

  @override
  final String description = 'Build the watchOS app.';

  @override
  String get category => FlutterCommandCategory.project;

  @override
  Future<FlutterCommandResult> runCommand() async => FlutterCommandResult.fail();
}

class BuildWatchosCommand extends BuildSubCommand with WatchosRequiredArtifacts {
  BuildWatchosCommand({
    required super.logger,
    required bool verboseHelp,
    @visibleForTesting WatchosBundleBuilder? bundleBuilder,
    @visibleForTesting BuildRegistryPost? registryPost,
  }) : _bundleBuilder = bundleBuilder ?? WatchosBuilder.buildBundle,
       _registryPost = registryPost,
       super(verboseHelp: verboseHelp) {
    addCommonDesktopBuildOptions(verboseHelp: verboseHelp);
    argParser.addFlag(
      'simulator',
      help: 'Build for the watchOS Simulator instead of a physical device.',
    );
    argParser.addFlag(
      'register-build',
      defaultsTo: true,
      help: 'After a successful release build, register it with your flutterwatch.dev '
          'account (bundle id, app version, engine id, build mode). '
          'See `flutter-watchos build-registry`.',
    );
  }

  final WatchosBundleBuilder _bundleBuilder;

  /// How a registration is sent; null sends it over HTTP.
  final BuildRegistryPost? _registryPost;

  @override
  final String name = 'watchos';

  @override
  final String description = 'Build an Apple watchOS application.';

  /// Adds `--analyze-size` and `--code-size-directory` hidden.
  ///
  /// Stock `addCommonDesktopBuildOptions` adds them for every build, but no
  /// size report is made for a watchOS build, so [validateCommand] refuses
  /// them. They stay parsable, so a script that passes one gets that refusal
  /// rather than a usage error.
  @override
  void usesAnalyzeSizeFlag() {
    argParser.addFlag(FlutterOptions.kAnalyzeSize, hide: true);
    argParser.addOption(FlutterOptions.kCodeSizeDirectory, hide: true);
  }

  @override
  Future<void> validateCommand() async {
    // Before the tooling check, which can rewrite the host-mode wiring: a
    // refused build changes nothing.
    if (boolArg(FlutterOptions.kAnalyzeSize) ||
        stringArg(FlutterOptions.kCodeSizeDirectory) != null) {
      throwToolExit(kWatchosSizeAnalysisRefusal);
    }
    final FlutterProject project = FlutterProject.current();
    await ensureReadyForWatchosTooling(project);
    await super.validateCommand();
    // build watchos has no --flavor; a pubspec default-flavor still reaches
    // FLUTTER_APP_FLAVOR, but not the watch build.
    final String? defaultFlavor = project.manifest.defaultFlavor;
    final WatchosFlavorCheck flavorCheck = watchosFlavorCheck(
      cliFlavor: null,
      defaultFlavor: defaultFlavor,
      watchTarget: true,
    );
    if (flavorCheck == WatchosFlavorCheck.warn) {
      globals.printWarning(watchosDefaultFlavorWarning(defaultFlavor!));
    }
  }

  @override
  Future<FlutterCommandResult> runCommand() async {
    final FlutterProject project = FlutterProject.current();
    final bool simulator = boolArg('simulator');

    // The Simulator engine is JIT-only (there is no AOT watchsimulator engine
    // artifact), so a simulator build is ALWAYS a debug (JIT) build: the app
    // must ship kernel_blob.bin, which only the debug bundle contains. The
    // `build` subcommand defaults to release, so quietly lower the default;
    // an EXPLICIT AOT mode with --simulator is a contradiction, which the
    // guidance below refuses. Without this, a release+simulator build produced
    // an app whose AOT App.dylib the JIT engine ignores, silently running
    // whatever stale kernel was last staged into watchos/Flutter/flutter_assets.
    BuildInfo buildInfo = await getBuildInfo();
    if (simulator && buildInfo.mode != BuildMode.debug) {
      final bool explicitMode = argResults!.wasParsed('release') ||
          argResults!.wasParsed('profile') ||
          (argParser.options.containsKey('jit-release') &&
              argResults!.wasParsed('jit-release'));
      if (!explicitMode) {
        buildInfo = await getBuildInfo(forcedBuildMode: BuildMode.debug);
      }
    }

    // Debug on a physical watch would need a JIT engine, but the Dart JIT VM
    // cannot be built against the watchOS device SDK (Mach exception-port APIs
    // like thread_set_exception_ports are unavailable there). There is no
    // watchos_debug device artifact, so fail early with guidance instead of a
    // generic "engine not found". The Simulator debug build is the debug path.
    final String? refusal = watchosModeRefusal(
      command: WatchosModeCommand.build,
      mode: buildInfo.mode,
      simulator: simulator,
    );
    if (refusal != null) {
      throwToolExit(refusal);
    }

    final watchosBuildInfo = WatchosBuildInfo(
      buildInfo,
      targetArch: 'arm64',
      simulator: simulator,
    );

    await _bundleBuilder(
      project: project,
      watchosBuildInfo: watchosBuildInfo,
      targetFile: targetFile,
    );

    // A release build is the one that gets published, so it is the one worth
    // recording. After the build, never before: only an app that exists is
    // registered, and nothing here can fail or hold up the build itself.
    if (watchosBuildInfo.buildInfo.mode == BuildMode.release && boolArg('register-build')) {
      final ReleaseBuild? build = describeBuiltApp(
        appDir: project.directory
            .childDirectory('build')
            .childDirectory('watchos')
            .childDirectory(watchosBuildInfo.productsDirName)
            .childDirectory('Runner.app'),
        engineVersion: pinnedWatchosEngineVersion(),
        readPlistValue: (String path, String key) =>
            globals.plistParser.getValueFromFile<String>(path, key),
      );
      if (build != null) {
        await registerReleaseBuild(
          fileSystem: globals.fs,
          platform: globals.platform,
          logger: globals.logger,
          build: build,
          post: _registryPost,
        );
      }
    }
    return FlutterCommandResult.success();
  }
}
