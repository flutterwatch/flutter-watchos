// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert' show json;

import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/build_system/build_system.dart';
import 'package:flutter_tools/src/build_system/depfile.dart';
import 'package:flutter_tools/src/build_system/exceptions.dart' show MissingDefineException;
import 'package:flutter_tools/src/build_system/targets/native_assets.dart'
    show LinkHooks, createFlutterNativeAssetsBuildRunner;
import 'package:flutter_tools/src/isolated/native_assets/dart_hook_result.dart';
import 'package:flutter_tools/src/isolated/native_assets/native_assets.dart';

/// Runs each package's build hook for its **data** assets only.
///
/// The watchOS pipeline skips upstream's native-asset targets because
/// flutter_tools cannot build Dart *code* assets for this platform — its
/// code-asset path is iOS/macOS-only, and watchOS does not use those FFI
/// implementations anyway (see `WatchosCopyFlutterBundle`). Data assets are a
/// different thing that happened to share the same pass: they are produced on
/// the host by ordinary Dart code and are what packages like `flutter_scene`
/// use to compile their shader bundles.
///
/// Skipping them wholesale meant such a package silently shipped whatever its
/// generated directory happened to contain — assets left behind by a macOS or
/// simulator build of the same tree, or nothing at all. Neither failed the
/// build; the app just rendered a black scene on device.
///
/// So this target runs the same hooks with `buildCodeAssets: null`, which is
/// the supported way to ask for data assets alone. The hooks write into each
/// package's own generated directory, which that package already declares as
/// assets, so the normal asset bundling carries them the rest of the way.
class WatchosBuildDataHooks extends Target {
  const WatchosBuildDataHooks();

  @override
  String get name => 'watchos_build_data_hooks';

  @override
  List<Target> get dependencies => const <Target>[];

  @override
  List<Source> get inputs => const <Source>[
    Source.pattern('{WORKSPACE_DIR}/.dart_tool/package_config.json'),
  ];

  /// Written where [LinkHooks] would have written it, because that is where
  /// `CopyFlutterBundle` looks for the hooks' result. There is no link phase
  /// here — linking only concerns code assets — so the build result is the
  /// whole result.
  @override
  List<Source> get outputs => const <Source>[
    Source.pattern('{BUILD_DIR}/${LinkHooks.resultFilename}'),
  ];

  @override
  List<String> get depfiles => const <String>[depFilename];

  static const depFilename = 'watchos_data_hooks.d';

  @override
  Future<void> build(Environment environment) async {
    final FileSystem fileSystem = environment.fileSystem;

    if (environment.defines[kBuildMode] == null) {
      throw MissingDefineException(kBuildMode, name);
    }
    final String? targetPlatformEnvironment = environment.defines[kTargetPlatform];
    if (targetPlatformEnvironment == null) {
      throw MissingDefineException(kTargetPlatform, name);
    }

    final FlutterNativeAssetsBuildRunner buildRunner =
        await createFlutterNativeAssetsBuildRunner(environment);

    final (results: _, :DartHooksResult buildResult) = await runFlutterSpecificBuildHooks(
          environmentDefines: environment.defines,
          buildRunner: buildRunner,
          // watchOS rides the iOS pipeline, so this is what the build reports.
          targetPlatform: TargetPlatform.fromName(targetPlatformEnvironment),
          projectUri: environment.projectDir.uri,
          fileSystem: fileSystem,
          // Data assets only. Note what this costs: the hooks protocol carries
          // the target OS inside the *code* asset config, so a package that
          // picks a graphics backend from the target OS sees none here and
          // falls back to its OS-less default. Asking for code assets to get
          // the OS named is the wrong trade — it needs an iOS SdkRoot and puts
          // every FFI package through a native build for a platform this
          // toolchain cannot target. The fix belongs in the protocol, which
          // should name the target on data-asset-only inputs.
          buildCodeAssets: null,
          buildDataAssets: true,
        );

    final File resultFile = environment.buildDir.childFile(LinkHooks.resultFilename);
    if (!resultFile.parent.existsSync()) {
      resultFile.parent.createSync(recursive: true);
    }
    resultFile.writeAsStringSync(json.encode(buildResult.toJson()));

    final Set<Uri> buildDependencies = buildResult.dependencies.toSet();
    final depfile = Depfile(
      <File>[for (final Uri dependency in buildResult.dependencies) fileSystem.file(dependency)],
      <File>[
        resultFile,
        for (final Uri uri in buildResult.filesToBeBundled)
          if (!buildDependencies.contains(uri)) fileSystem.file(uri),
      ],
    );
    final File outputDepfile = environment.buildDir.childFile(depFilename);
    if (!outputDepfile.parent.existsSync()) {
      outputDepfile.parent.createSync(recursive: true);
    }
    environment.depFileService.writeToFile(depfile, outputDepfile, filterOutputs: true);
  }
}
