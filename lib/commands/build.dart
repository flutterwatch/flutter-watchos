// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/commands/build.dart';
import 'package:flutter_tools/src/project.dart';
import 'package:flutter_tools/src/runner/flutter_command.dart';

import '../watchos_build_info.dart';
import '../watchos_builder.dart';
import '../watchos_cache.dart';
import '../watchos_plugins.dart';

class WatchosBuildCommand extends BuildCommand {
  WatchosBuildCommand({
    required super.artifacts,
    required super.cache,
    required super.fileSystem,
    required super.flutterVersion,
    required super.buildSystem,
    required super.osUtils,
    required Logger logger,
    required super.androidSdk,
    required super.config,
    required super.platform,
    required super.processUtils,
    required super.processManager,
    required super.fileSystemUtils,
    required super.templateRenderer,
    required super.terminal,
    required super.plistParser,
    required super.xcode,
    required bool verboseHelp,
  }) : super(logger: logger, verboseHelp: verboseHelp) {
    addSubcommand(BuildWatchosCommand(logger: logger, verboseHelp: verboseHelp));
  }
}

class BuildWatchosCommand extends BuildSubCommand with WatchosRequiredArtifacts {
  BuildWatchosCommand({required super.logger, required bool verboseHelp})
    : super(verboseHelp: verboseHelp) {
    addCommonDesktopBuildOptions(verboseHelp: verboseHelp);
    argParser.addFlag(
      'simulator',
      help: 'Build for the watchOS Simulator instead of a physical device.',
    );
  }

  @override
  final String name = 'watchos';

  @override
  final String description = 'Build an Apple watchOS application.';

  @override
  Future<void> validateCommand() async {
    final FlutterProject project = FlutterProject.current();
    await ensureReadyForWatchosTooling(project);
    return super.validateCommand();
  }

  @override
  Future<FlutterCommandResult> runCommand() async {
    final FlutterProject project = FlutterProject.current();
    final bool simulator = boolArg('simulator');
    final watchosBuildInfo = WatchosBuildInfo(
      await getBuildInfo(),
      targetArch: 'arm64',
      simulator: simulator,
    );

    // Debug on a physical watch would need a JIT engine, but the Dart JIT VM
    // cannot be built against the watchOS device SDK (Mach exception-port APIs
    // like thread_set_exception_ports are unavailable there). There is no
    // watchos_debug device artifact, so fail early with guidance instead of a
    // generic "engine not found". The Simulator debug build is the debug path.
    if (!simulator && watchosBuildInfo.buildInfo.mode == BuildMode.debug) {
      throwToolExit(
        'Debug mode is not supported on a physical Apple Watch: it requires a '
        'JIT engine, which cannot be built for watchOS (the device SDK removes '
        'the Mach APIs the Dart JIT VM relies on).\n'
        'Use one of:\n'
        '  flutter-watchos build watchos --simulator   # debug, on the Simulator\n'
        '  flutter-watchos build watchos --profile      # AOT, on a physical watch\n'
        '  flutter-watchos build watchos --release      # AOT, on a physical watch',
      );
    }

    await WatchosBuilder.buildBundle(
      project: project,
      watchosBuildInfo: watchosBuildInfo,
      targetFile: targetFile,
    );
    return FlutterCommandResult.success();
  }
}
