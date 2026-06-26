// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/file.dart';
import 'package:flutter_tools/src/base/analyze_size.dart';
import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/build_system/build_system.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/dart/package_map.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/project.dart';

import 'build_targets/application.dart';
import 'watchos_build_info.dart';
import 'watchos_plugins.dart';
import 'watchos_project.dart';

/// The define to control what watchOS target is built for.
const String kTargetBackendType = 'TargetBackendType';

class WatchosBuilder {
  static Future<void> buildBundle({
    required FlutterProject project,
    required WatchosBuildInfo watchosBuildInfo,
    required String targetFile,
    SizeAnalyzer? sizeAnalyzer,
  }) async {
    final watchosProject = WatchosProject.fromFlutter(project);
    if (!watchosProject.existsSync()) {
      throwToolExit(
        'This project is not configured for watchOS.\n'
        'To fix this problem, create a new project by running '
        '`flutter-watchos create <app-dir>`.',
      );
    }

    final Directory outputDir = project.directory.childDirectory('build').childDirectory('watchos');
    final BuildInfo buildInfo = watchosBuildInfo.buildInfo;
    final String buildModeName = buildInfo.mode.cliName;

    // Used by AotElfBase to generate an AOT snapshot. watchOS rides the iOS
    // target platform (it is an iOS-family OS); see "Platform Identity" in
    // CLAUDE.md.
    final String targetPlatformName = getNameForTargetPlatform(TargetPlatform.ios);

    final environment = Environment(
      projectDir: project.directory,
      outputDir: outputDir,
      buildDir: project.dartTool.childDirectory('flutter_build'),
      cacheDir: globals.cache.getRoot(),
      flutterRootDir: globals.fs.directory(Cache.flutterRoot),
      engineVersion: globals.flutterVersion.engineRevision,
      // generateDartPluginRegistry propagates to KernelSnapshot as
      // `checkDartPluginRegistry`, telling frontend-server to link
      // `_PluginRegistrant.register()` into the kernel blob. We need this so
      // the engine's FindAndInvokeDartPluginRegistrant() fires at isolate
      // startup. We substitute WatchosDartPluginRegistrantTarget for the
      // upstream one (see build_targets/application.dart) so the registrant
      // lists watchOS plugins, not iOS ones (Platform.isIOS == true on
      // watchOS).
      generateDartPluginRegistry: true,
      defines: <String, String>{
        kTargetFile: targetFile,
        kBuildMode: buildModeName,
        kTargetPlatform: targetPlatformName,
        ...buildInfo.toBuildSystemEnvironment(),
      },
      artifacts: globals.artifacts!,
      fileSystem: globals.fs,
      logger: globals.logger,
      processManager: globals.processManager,
      platform: globals.platform,
      analytics: globals.analytics,
      packageConfigPath: findPackageConfigFileOrDefault(project.directory).path,
    );

    final Target target = buildInfo.isDebug
        ? DebugWatchosApplication(watchosBuildInfo)
        : ReleaseWatchosApplication(watchosBuildInfo);

    // Write the watchOS dart plugin registrant BEFORE the kernel compiles so
    // that Dart-side federated plugins call registerWith() instead of the iOS
    // implementations (Platform.isIOS == true on watchOS).
    writeWatchosDartPluginRegistrant(project);

    final Status status = globals.logger.startProgress(
      'Building a watchOS application in $buildModeName mode for '
      '${watchosBuildInfo.targetArch} target...',
    );
    try {
      final BuildResult result = await globals.buildSystem.build(target, environment);
      if (!result.success) {
        for (final ExceptionMeasurement measurement in result.exceptions.values) {
          globals.printError(measurement.exception.toString());
        }
        throwToolExit('The build failed.');
      }

      // These pseudo targets cannot be skipped and should be invoked whenever
      // the build is run.
      await NativeWatchosBundle(watchosBuildInfo, targetFile).build(environment);
    } finally {
      status.stop();
    }
  }
}
