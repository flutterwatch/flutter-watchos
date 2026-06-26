// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/base/logger.dart';
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

    await WatchosBuilder.buildBundle(
      project: project,
      watchosBuildInfo: watchosBuildInfo,
      targetFile: targetFile,
    );
    return FlutterCommandResult.success();
  }
}
