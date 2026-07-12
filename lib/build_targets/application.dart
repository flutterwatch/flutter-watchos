// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/artifacts.dart';
import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/io.dart';
import 'package:flutter_tools/src/base/logger.dart' show Status;
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/build_system/build_system.dart';
import 'package:flutter_tools/src/build_system/exceptions.dart';
import 'package:flutter_tools/src/build_system/targets/common.dart';
import 'package:flutter_tools/src/build_system/targets/localizations.dart';
import 'package:flutter_tools/src/compile.dart';
import 'package:flutter_tools/src/dart/package_map.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/project.dart';
import 'package:meta/meta.dart';
import 'package:package_config/package_config.dart';

import '../watchos_artifacts.dart';
import '../watchos_build_info.dart';
import '../watchos_plugins.dart';
import '../watchos_swift_package_manager.dart';

/// Writes `.dart_tool/flutter_build/dart_plugin_registrant.dart` with watchOS-
/// aware plugin registrations, as a proper build target.
///
/// This replaces Flutter's stock `DartPluginRegistrantTarget` in our build
/// graph (via [WatchosKernelSnapshot]) so that the file the frontend-server
/// reads via `--source=dart_plugin_registrant.dart` contains entries for
/// plugins declared under `flutter.plugin.platforms.watchos` — not the iOS
/// entries Flutter would otherwise emit (since `Platform.isIOS` is true under
/// our Dart VM patch, and the `watchos` platform key is unknown to upstream
/// `generateMainDartWithPluginRegistrant`).
class WatchosDartPluginRegistrantTarget extends Target {
  const WatchosDartPluginRegistrantTarget();

  @override
  String get name => 'gen_watchos_dart_plugin_registrant';

  @override
  List<Target> get dependencies => const <Target>[];

  @override
  List<Source> get inputs => const <Source>[
    Source.pattern('{WORKSPACE_DIR}/.dart_tool/package_config.json'),
  ];

  @override
  List<Source> get outputs => const <Source>[
    Source.pattern('{BUILD_DIR}/../dart_plugin_registrant.dart'),
  ];

  @override
  Future<void> build(Environment environment) async {
    final FlutterProject project = FlutterProject.fromDirectory(environment.projectDir);
    writeWatchosDartPluginRegistrant(project);
  }
}

/// A [KernelSnapshot] subclass that swaps in our watchOS-aware registrant
/// target and forces `targetOS: null` for correct AOT platform identity.
///
/// See "Platform Identity" and "Dart Plugin Registrant Build Graph" in
/// CLAUDE.md. Kept in sync with upstream `KernelSnapshot.build`; re-mirror any
/// change on a Flutter upgrade.
class WatchosKernelSnapshot extends KernelSnapshot {
  const WatchosKernelSnapshot();

  @override
  List<Target> get dependencies => const <Target>[
    GenerateLocalizationsTarget(),
    WatchosDartPluginRegistrantTarget(),
  ];

  /// Mirrors [KernelSnapshot.build] but forces `targetOS: null` so the
  /// frontend-server does **not** const-fold `Platform.operatingSystem` to
  /// `"ios"` in AOT (profile/release) builds. The getters then resolve at
  /// runtime against the engine's patched native VM
  /// (`kHostOperatingSystemName == "watchos"`), exactly as JIT/debug does.
  ///
  /// The companion half is in [WatchosArtifacts]: the AOT kernel is compiled
  /// against our **patched** `flutter_patched_sdk`, so the (now un-folded)
  /// `isIOS` initializer is `operatingSystem == "ios" || == "watchos"` and the
  /// `isWatch` getter exists.
  ///
  /// watchOS rides the iOS pipeline (`TargetPlatform.ios`), so `targetModel` is
  /// `flutter`, `forceLinkPlatform` is false, and app flavors are not wired.
  @override
  Future<void> build(Environment environment) async {
    final compiler = KernelCompiler(
      fileSystem: environment.fileSystem,
      logger: environment.logger,
      processManager: environment.processManager,
      artifacts: environment.artifacts,
      fileSystemRoots: <String>[],
    );
    final String? buildModeEnvironment = environment.defines[kBuildMode];
    if (buildModeEnvironment == null) {
      throw MissingDefineException(kBuildMode, 'kernel_snapshot');
    }
    final String? targetPlatformEnvironment = environment.defines[kTargetPlatform];
    if (targetPlatformEnvironment == null) {
      throw MissingDefineException(kTargetPlatform, 'kernel_snapshot');
    }
    final buildMode = BuildMode.fromCliName(buildModeEnvironment);
    final String targetFile =
        environment.defines[kTargetFile] ?? environment.fileSystem.path.join('lib', 'main.dart');
    final File packagesFile = findPackageConfigFileOrDefault(environment.projectDir);
    final String targetFileAbsolute = environment.fileSystem.file(targetFile).absolute.path;
    final trackWidgetCreation = environment.defines[kTrackWidgetCreation] != 'false';
    final TargetPlatform targetPlatform = getTargetPlatformForName(targetPlatformEnvironment);

    final String? frontendServerStarterPath = environment.defines[kFrontendServerStarterPath];
    final List<String> extraFrontEndOptions = decodeCommaSeparated(
      environment.defines,
      kExtraFrontEndOptions,
    );
    final List<String>? fileSystemRoots = environment.defines[kFileSystemRoots]?.split(',');
    final String? fileSystemScheme = environment.defines[kFileSystemScheme];

    // watchOS always rides the iOS pipeline (TargetPlatform.ios).
    const forceLinkPlatform = false;

    final PackageConfig packageConfig = await loadPackageConfigWithLogging(
      packagesFile,
      logger: environment.logger,
    );

    final String dillPath = environment.buildDir.childFile(KernelSnapshot.dillName).path;
    final List<String> dartDefines = decodeDartDefines(environment.defines, kDartDefines);

    final CompilerOutput? output = await compiler.compile(
      sdkRoot: environment.artifacts.getArtifactPath(
        Artifact.flutterPatchedSdkPath,
        platform: targetPlatform,
        mode: buildMode,
      ),
      aot: buildMode.isPrecompiled,
      buildMode: buildMode,
      trackWidgetCreation: trackWidgetCreation && buildMode != BuildMode.release,
      outputFilePath: dillPath,
      initializeFromDill: buildMode.isPrecompiled ? null : dillPath,
      packagesPath: packagesFile.path,
      linkPlatformKernelIn: forceLinkPlatform || buildMode.isPrecompiled,
      mainPath: targetFileAbsolute,
      depFilePath: environment.buildDir.childFile(KernelSnapshot.depfile).path,
      frontendServerStarterPath: frontendServerStarterPath,
      extraFrontEndOptions: extraFrontEndOptions,
      fileSystemRoots: fileSystemRoots,
      fileSystemScheme: fileSystemScheme,
      dartDefines: dartDefines,
      packageConfig: packageConfig,
      buildDir: environment.buildDir,
      // The watchOS fix. Stock Flutter passes `ios` here for TargetPlatform.ios,
      // which const-folds platform identity to iOS in AOT. Passing null keeps
      // the platform-const getters live so they resolve at runtime to "watchos".
      // ignore: avoid_redundant_argument_values
      targetOS: null,
      checkDartPluginRegistry: environment.generateDartPluginRegistry,
    );
    if (output == null || output.errorCount != 0) {
      throw Exception();
    }
  }
}

/// [AotElfRelease] subclass that uses [WatchosKernelSnapshot] instead of the
/// stock [KernelSnapshot], so AOT release builds also link the watchOS
/// registrant into the compiled kernel.
class WatchosAotElfRelease extends AotElfRelease {
  const WatchosAotElfRelease(super.targetPlatform);

  @override
  List<Target> get dependencies => const <Target>[WatchosKernelSnapshot()];
}

/// [CopyFlutterBundle] subclass that depends on [WatchosKernelSnapshot] instead
/// of the stock [KernelSnapshot], so the upstream `DartPluginRegistrantTarget`
/// never re-enters the graph and overwrites our watchOS-correct registrant.
class WatchosCopyFlutterBundle extends CopyFlutterBundle {
  const WatchosCopyFlutterBundle();

  @override
  List<Target> get dependencies => const <Target>[
    // NOTE: deliberately NOT depending on DartBuildForNative() /
    // InstallCodeAssets(). The flutter-watchos toolchain cannot build Dart
    // native-assets / code-assets for watchOS (flutter_tools' code-asset path
    // is iOS/macOS-only and we don't patch it). On watchOS those FFI Dart
    // implementations are never used anyway: WatchosDartPluginRegistrantTarget
    // routes federated plugins to their native `*_watchos` package instead.
    WatchosKernelSnapshot(),
  ];

  @override
  Future<void> build(Environment environment) async {
    // We skip the native-assets targets for watchOS (see `dependencies`), so
    // `native_assets.json` is never produced. Upstream CopyFlutterBundle.build()
    // unconditionally bundles it as `NativeAssetsManifest.json` and throws
    // PathNotFound without it. Write the canonical empty manifest first.
    final File manifest = environment.buildDir.childFile('native_assets.json');
    if (!manifest.existsSync()) {
      manifest.parent.createSync(recursive: true);
      manifest.writeAsStringSync('{"format-version":[1,0,0],"native-assets":{}}');
    }
    await super.build(environment);
  }
}

class DebugWatchosApplication extends Target {
  DebugWatchosApplication(this.buildInfo);

  final WatchosBuildInfo buildInfo;

  @override
  String get name => 'debug_watchos_application';

  @override
  List<Target> get dependencies => const <Target>[
    WatchosKernelSnapshot(),
    WatchosCopyFlutterBundle(),
  ];

  @override
  List<Source> get inputs => const <Source>[];

  @override
  List<Source> get outputs => const <Source>[];

  @override
  Future<void> build(Environment environment) async {
    globals.logger.printTrace('Assembling debug watchOS application...');
  }
}

class ReleaseWatchosApplication extends Target {
  ReleaseWatchosApplication(this.buildInfo);

  final WatchosBuildInfo buildInfo;

  @override
  String get name => 'release_watchos_application';

  @override
  List<Target> get dependencies => const <Target>[
    // We do AOT compilation ourselves in NativeWatchosBundle._compileAotSnapshot
    // (gen_snapshot → assembly → clang → App.framework) because upstream
    // AotElfRelease throws "Null check operator used on a null value" when
    // TargetPlatform == ios but no darwinArch is plumbed through.
    WatchosKernelSnapshot(),
    WatchosCopyFlutterBundle(),
  ];

  @override
  List<Source> get inputs => const <Source>[];

  @override
  List<Source> get outputs => const <Source>[];

  @override
  Future<void> build(Environment environment) async {
    globals.logger.printTrace('Assembling release watchOS application...');
  }
}

/// Orchestrates the native watchOS build via xcodebuild.
///
/// The build product is a single independent watch app, `Runner.app`
/// (`WKWatchOnly`), installed directly on the simulator or a paired watch.
/// The arm64_32 stub slice (required when WATCHOS_DEPLOYMENT_TARGET < 27.0,
/// because the engine is arm64-only) is handled by the Xcode project template
/// — see CLAUDE.md. This target copies the engine + assets, generates the
/// registrants / xcconfigs / SPM packages, and drives xcodebuild.
///
/// Note: App Store distribution additionally requires wrapping this watch app
/// in an iOS container archive; that packaging is intentionally not part of the
/// `run`-focused template and is handled separately at submit time.
class NativeWatchosBundle extends Target {
  NativeWatchosBundle(this.buildInfo, this.targetFile);

  final WatchosBuildInfo buildInfo;
  final String targetFile;

  @override
  String get name => 'watchos_native_bundle';

  @override
  List<Target> get dependencies => <Target>[
    if (buildInfo.buildInfo.isDebug) DebugWatchosApplication(buildInfo),
    if (!buildInfo.buildInfo.isDebug) ReleaseWatchosApplication(buildInfo),
  ];

  @override
  List<Source> get inputs => const <Source>[];

  @override
  List<Source> get outputs => const <Source>[];

  @override
  Future<void> build(Environment environment) async {
    final FlutterProject project = FlutterProject.current();
    final Directory watchosProjectDir = project.directory.childDirectory('watchos');

    if (!watchosProjectDir.existsSync()) {
      globals.logger.printError('watchOS project not found. Did you run flutter-watchos create?');
      throw Exception('Missing watchOS project directory');
    }

    // 1. Stage the engine into watchos/Flutter/ as Flutter.framework, alongside
    //    flutter_embedder.h + icudtl.dat + the core snapshots. watchOS uses the
    //    Flutter embedder C API with software rendering (driven by
    //    Runner/FlutterRunner.swift); the engine ships as a real framework the
    //    Xcode project links and embeds.
    await _copyEngine(watchosProjectDir);

    // 2. Copy flutter_assets into watchos/Flutter/
    _copyFlutterAssets(project, watchosProjectDir);

    // 3. App.framework — the compiled Dart the engine loads.
    //    - Release/device (AOT): gen_snapshot → assembly → App.framework/App
    //      exporting kDartVm/IsolateSnapshot symbols the engine binds.
    //    - Debug/simulator (JIT): a tiny stub App.framework so the Xcode embed
    //      phase always has its input; real snapshots come from the .bin files.
    if (!buildInfo.buildInfo.isDebug) {
      await _buildAotAppDylib(project, watchosProjectDir, environment);
    } else {
      await _buildJitStubAppDylib(watchosProjectDir);
    }

    // 4. Generate xcconfig files
    _generateXcconfigs(project, watchosProjectDir);

    // 5. Generate watchOS plugin dependencies + the Dart plugin registrant
    //    (must run AFTER Flutter's pub get which overwrites
    //    .flutter-plugins-dependencies without the watchos key).
    await ensureReadyForWatchosTooling(project);

    // 6. Compile federated watchOS plugin native code (FFI plugins) into a
    //    static archive and wire its watch-scoped force-load flag into
    //    Generated.xcconfig (so it survives the HostApp-scheme archive too).
    await _buildPluginStaticArchive(project, watchosProjectDir);

    // 7. Run pod install if Podfile exists
    if (watchosProjectDir.childFile('Podfile').existsSync()) {
      final Status podStatus = globals.logger.startProgress('Running pod install...');
      try {
        final ProcessResult podResult = await globals.processManager.run(
          <String>['pod', 'install'],
          workingDirectory: watchosProjectDir.path,
          environment: <String, String>{'LANG': 'en_US.UTF-8', 'LC_ALL': 'en_US.UTF-8'},
        );
        if (podResult.exitCode != 0) {
          throw Exception('pod install failed:\n${podResult.stderr}');
        }
      } finally {
        podStatus.stop();
      }
    }

    // 8. Run xcodebuild.
    globals.logger.printTrace('Executing xcodebuild for watchOS (${buildInfo.sdkName})...');

    final String configuration = buildInfo.configuration;
    final String symroot = project.directory.childDirectory('build').childDirectory('watchos').path;

    final bool hasWorkspace = watchosProjectDir.childDirectory('Runner.xcworkspace').existsSync();

    final List<String> signingArgs = await _resolveSigningArgs(
      watchosProjectDir,
      buildInfo.simulator,
    );

    final Status xcodeStatus = globals.logger.startProgress('Running Xcode build...');
    ProcessResult result;
    try {
      result = await globals.processManager.run(<String>[
        'xcodebuild',
        if (hasWorkspace) ...<String>['-workspace', 'Runner.xcworkspace'] else ...<String>[
          '-project',
          'Runner.xcodeproj',
        ],
        '-scheme',
        'Runner',
        '-configuration',
        configuration,
        '-sdk',
        buildInfo.sdkName,
        '-destination',
        buildInfo.destination,
        'SYMROOT=$symroot',
        'COMPILER_INDEX_STORE_ENABLE=NO',
        // Simulator is arm64-only. For a physical watch we deliberately do NOT
        // force `ARCHS=arm64`: when WATCHOS_DEPLOYMENT_TARGET < 27.0 the App
        // Store requires an `arm64_32` slice in the watch executable, and the
        // project template supplies that slice (a stub, since the engine is
        // arm64-only, plus a "Requires Apple Watch Series 9 or later" fallback).
        // Letting the project's Standard Architectures apply preserves the fat
        // executable; forcing arm64 here would strip the required slice. See
        // the arm64_32 gate in CLAUDE.md.
        if (buildInfo.simulator) 'ARCHS=arm64',
        ...signingArgs,
        if (!buildInfo.simulator) '-allowProvisioningUpdates',
        'build',
      ], workingDirectory: watchosProjectDir.path);
    } finally {
      xcodeStatus.stop();
    }

    if (result.exitCode != 0) {
      globals.logger.printError('Xcode build failed:');
      globals.logger.printError(result.stdout as String);
      globals.logger.printError(result.stderr as String);
      throw Exception('Xcode build failed');
    }
    globals.logger.printStatus('Xcode build done.');

    // The Xcode project links Flutter.framework and embeds both
    // Flutter.framework and App.framework via its embed-frameworks phase, and
    // copies icudtl.dat + the core snapshots to the app root via its resources
    // phase — Xcode does the signing and thinning, so no post-build wrapping.
    // The "✓ Built <path>" close is printed by WatchosBuilder once the
    // overall build progress stops, matching stock `flutter build ios`.

    globals.logger.printTrace(
      'watchOS application built: build/watchos/${buildInfo.productsDirName}/Runner.app',
    );
  }

  /// Resolves code signing arguments for xcodebuild (device builds only).
  Future<List<String>> _resolveSigningArgs(Directory watchosProjectDir, bool isSimulator) async {
    if (isSimulator) {
      return const <String>[];
    }

    // Status-level like stock `flutter build ios`'s "Automatically signing
    // iOS for device deployment using specified development team in Xcode
    // project" — which team signs (and where it came from) is the first thing
    // to check when a device install fails.
    final String? envTeam = globals.platform.environment['DEVELOPMENT_TEAM'];
    if (envTeam != null && envTeam.isNotEmpty) {
      globals.logger.printStatus(
        'Automatically signing watchOS for device deployment using development '
        'team from the DEVELOPMENT_TEAM environment variable: $envTeam',
      );
      return <String>['DEVELOPMENT_TEAM=$envTeam', 'CODE_SIGN_STYLE=Automatic'];
    }

    final String? pbxprojTeam = _readTeamFromPbxproj(watchosProjectDir);
    if (pbxprojTeam != null) {
      globals.logger.printStatus(
        'Automatically signing watchOS for device deployment using specified '
        'development team in Xcode project: $pbxprojTeam',
      );
      return <String>['DEVELOPMENT_TEAM=$pbxprojTeam', 'CODE_SIGN_STYLE=Automatic'];
    }

    final String? keychainTeam = await _discoverTeamFromKeychain();
    if (keychainTeam != null) {
      globals.logger.printStatus(
        'Automatically signing watchOS for device deployment using development '
        'team auto-detected from the keychain: $keychainTeam',
      );
      return <String>['DEVELOPMENT_TEAM=$keychainTeam', 'CODE_SIGN_STYLE=Automatic'];
    }

    globals.logger.printError(
      'No code signing identity found for physical device build.\n'
      'To fix this, either:\n'
      '  1. Set DEVELOPMENT_TEAM=<your_team_id> environment variable\n'
      '  2. Open watchos/Runner.xcodeproj in Xcode and configure signing\n'
      '  3. Ensure you have an Apple Development certificate in your keychain',
    );
    return const <String>[];
  }

  /// Reads DEVELOPMENT_TEAM from the Xcode project's build settings.
  String? _readTeamFromPbxproj(Directory watchosProjectDir) {
    final File pbxproj = watchosProjectDir
        .childDirectory('Runner.xcodeproj')
        .childFile('project.pbxproj');
    if (!pbxproj.existsSync()) {
      return null;
    }

    final String content = pbxproj.readAsStringSync();
    final teamRegex = RegExp(r'DEVELOPMENT_TEAM\s*=\s*([A-Z0-9]{10});');
    final Match? match = teamRegex.firstMatch(content);
    return match?.group(1);
  }

  /// Discovers the development team ID from the first valid Apple Development
  /// signing identity in the login keychain.
  Future<String?> _discoverTeamFromKeychain() async {
    try {
      final ProcessResult result = await globals.processManager.run(<String>[
        'security',
        'find-identity',
        '-v',
        '-p',
        'codesigning',
      ]);
      if (result.exitCode != 0) {
        return null;
      }

      final output = result.stdout as String;
      final identityRegex = RegExp(r'Apple Development:.*\(([A-Z0-9]{10})\)');
      final Match? match = identityRegex.firstMatch(output);
      return match?.group(1);
    } on Exception {
      return null;
    }
  }

  /// Stages the embedder engine bits into the watchos project's `Flutter/`
  /// directory: the engine dylib as `Flutter.framework/Flutter`,
  /// `flutter_embedder.h`, `clang_arm64/icudtl.dat`, and the core snapshots
  /// (`gen/flutter/lib/snapshot/{vm_isolate_snapshot,isolate_snapshot}.bin`).
  ///
  /// watchOS consumes the Flutter **embedder C API** (software rendering, driven
  /// by `Runner/FlutterRunner.swift`), but the engine ships as a real
  /// `Flutter.framework` bundle — the Xcode project links and embeds it, and
  /// App Store packages must contain framework bundles, not bare dylibs.
  /// `icudtl.dat` and the snapshots stay as loose files here; the Xcode
  /// resources phase copies them to the watch app bundle root, where the engine
  /// resolves them relative to `Bundle.main.bundlePath`.
  Future<void> _copyEngine(Directory watchosProjectDir) async {
    final watchosArtifacts = globals.artifacts! as WatchosArtifacts;
    final EnvironmentType envType = buildInfo.simulator
        ? EnvironmentType.simulator
        : EnvironmentType.physical;
    final String engineDir = watchosArtifacts.engineDirectory(
      mode: buildInfo.buildInfo.mode,
      environmentType: envType,
    );
    // The JIT core snapshots are produced by the simulator (JIT) engine build.
    final String simEngineDir = watchosArtifacts.engineDirectory(
      mode: BuildMode.debug,
      environmentType: EnvironmentType.simulator,
    );

    final Directory flutterDir = watchosProjectDir.childDirectory('Flutter')
      ..createSync(recursive: true);

    final File engineDylib = globals.fs.file(
      globals.fs.path.join(engineDir, 'libflutter_engine.dylib'),
    );
    if (!engineDylib.existsSync()) {
      throwToolExit(
        'libflutter_engine.dylib not found at ${engineDylib.path}.\n'
        'Run "flutter-watchos precache" (or set WATCHOS_ENGINE_ARTIFACTS) to '
        'provide the watchOS engine first.',
      );
    }

    void copyInto(String sourcePath, String destName) {
      final File src = globals.fs.file(sourcePath);
      if (!src.existsSync()) {
        globals.logger.printTrace('engine file missing, skipping: $sourcePath');
        return;
      }
      final String dest = globals.fs.path.join(flutterDir.path, destName);
      src.copySync(dest);
    }

    // Stage the engine as a real Flutter.framework (Frameworks/Flutter.framework
    // in the built app), not a bare dylib. The Xcode project links `-framework
    // Flutter` and embeds it with CodeSignOnCopy.
    _stageFramework(
      sourceDylib: engineDylib,
      flutterDir: flutterDir,
      frameworkName: 'Flutter',
      bundleId: _flutterFrameworkBundleId,
    );
    // Sweep away any bare engine dylib left by an earlier toolchain version so
    // the framework is the single source of the engine binary.
    final File staleEngineDylib =
        globals.fs.file(globals.fs.path.join(flutterDir.path, 'libflutter_engine.dylib'));
    if (staleEngineDylib.existsSync()) {
      staleEngineDylib.deleteSync();
    }
    copyInto(globals.fs.path.join(engineDir, 'flutter_embedder.h'), 'flutter_embedder.h');
    copyInto(globals.fs.path.join(engineDir, 'clang_arm64', 'icudtl.dat'), 'icudtl.dat');
    copyInto(
      globals.fs.path.join(
        simEngineDir,
        'gen',
        'flutter',
        'lib',
        'snapshot',
        'vm_isolate_snapshot.bin',
      ),
      'vm_isolate_snapshot.bin',
    );
    copyInto(
      globals.fs.path.join(
        simEngineDir,
        'gen',
        'flutter',
        'lib',
        'snapshot',
        'isolate_snapshot.bin',
      ),
      'isolate_snapshot.bin',
    );
    globals.logger.printTrace('Copied watchOS embedder engine into ${flutterDir.path}');
  }

  /// Assembles flutter_assets from the build output into
  /// watchos/Flutter/flutter_assets/.
  void _copyFlutterAssets(FlutterProject project, Directory watchosProjectDir) {
    final Directory buildDir = project.directory.childDirectory('build');

    Directory? flutterAssetsSource;
    final Directory watchosOutputDir = buildDir.childDirectory('watchos');
    final Directory defaultDir = buildDir.childDirectory('flutter_assets');

    // Detect the bundle by AssetManifest.bin: EVERY build mode produces it
    // (kernel_blob.bin exists only in debug bundles, and keying on it made
    // release builds silently skip the copy below).
    if (watchosOutputDir.childFile('AssetManifest.bin').existsSync()) {
      flutterAssetsSource = watchosOutputDir;
    } else if (defaultDir.childFile('AssetManifest.bin').existsSync()) {
      flutterAssetsSource = defaultDir;
    }

    final Directory flutterAssetsTarget = watchosProjectDir
        .childDirectory('Flutter')
        .childDirectory('flutter_assets');

    if (flutterAssetsSource == null) {
      // NEVER fall through silently: the Xcode copy phase would bundle
      // whatever stale flutter_assets was staged by an earlier build, and the
      // app would run old Dart with no error anywhere.
      throwToolExit(
        'flutter_assets missing from the build output '
        '(${watchosOutputDir.path}) — cannot stage ${flutterAssetsTarget.path}.',
      );
    }
    // AOT (profile/release) runs from App.framework; the JIT kernel + VM
    // snapshots must not ship (they are debug-only and, for this app, ~52 MB —
    // enough to blow past the App Store's 75 MB watch-app thinning limit).
    copyFlutterAssetsTree(
      source: flutterAssetsSource,
      target: flutterAssetsTarget,
      stripJitArtifacts: !buildInfo.buildInfo.isDebug,
    );
    globals.logger.printTrace('Copied flutter_assets to ${flutterAssetsTarget.path}');
  }

  /// JIT-only Dart payload that must not ship in an AOT (profile/release)
  /// bundle: the release engine runs `App.framework`, so the kernel and VM/
  /// isolate snapshot data are dead weight. Stock Flutter's release bundle
  /// omits them; for this app they were ~52 MB, tripping the App Store's
  /// 75 MB watch-app size limit (ITMS-90389).
  static const Set<String> _jitOnlyAssets = <String>{
    'kernel_blob.bin',
    'vm_snapshot_data',
    'isolate_snapshot_data',
  };

  /// Mirrors the build output's flutter_assets tree into [target].
  ///
  /// The target is wiped first so the result is an exact mirror of [source].
  /// xcodebuild output dirs (`Debug-*`, `Release-*`) that may sit alongside the
  /// assets in `build/watchos/` are skipped — they are not Flutter assets.
  /// When [stripJitArtifacts] is set (AOT builds) the JIT-only Dart payload in
  /// [_jitOnlyAssets] is skipped too.
  @visibleForTesting
  static void copyFlutterAssetsTree({
    required Directory source,
    required Directory target,
    required bool stripJitArtifacts,
  }) {
    if (target.existsSync()) {
      target.deleteSync(recursive: true);
    }
    target.createSync(recursive: true);

    for (final FileSystemEntity entity in source.listSync()) {
      final String name = source.fileSystem.path.basename(entity.path);
      // Not Flutter assets, even though they sit in `build/watchos/`:
      //  - `Debug-*` / `Release-*`: xcodebuild SYMROOT products
      //  - `aot`: gen_snapshot intermediates (snapshot_assembly.S/.o, ~22 MB)
      //    from _compileAotSnapshot — copying them shipped 22 MB of assembly
      //    text inside every release app bundle.
      //  - `ipa`: the `flutter-watchos build ipa` output (archive + store
      //    package) — it must never be swept into the next build's assets.
      //  - `*.xcarchive` / `Exported` / `*xportOptions.plist` / `.DS_Store`:
      //    manual archive/export runs and Finder droppings left in the build
      //    dir. Sweeping an old .xcarchive into flutter_assets shipped a
      //    stale copy of the whole app inside itself and broke `xcodebuild
      //    archive` (strip chokes on the nested dSYM).
      if (entity is Directory &&
          (name == 'aot' ||
              name == 'ipa' ||
              name == 'Exported' ||
              name.endsWith('.xcarchive') ||
              name.contains('Debug-') ||
              name.contains('Release-'))) {
        continue;
      }
      if (entity is File &&
          (name == '.DS_Store' ||
              name == 'exportOptions.plist' ||
              name == 'ExportOptions.plist' ||
              (stripJitArtifacts && _jitOnlyAssets.contains(name)))) {
        continue;
      }
      final String destPath = target.fileSystem.path.join(target.path, name);
      if (entity is File) {
        entity.copySync(destPath);
      } else if (entity is Directory) {
        copyDirectory(entity, target.fileSystem.directory(destPath));
      }
    }
  }

  /// Fixed, app-independent bundle identifiers for the embedded engine/Dart
  /// frameworks. Like stock Flutter's `io.flutter.flutter`, these need not be
  /// prefixed by the host app's id — every watchOS app embeds the same two
  /// framework bundles, and App Store Connect accepts them.
  static const String _flutterFrameworkBundleId = 'dev.flutterwatch.Flutter';
  static const String _appFrameworkBundleId = 'dev.flutterwatch.App';

  /// `MinimumOSVersion` stamped into the staged framework Info.plists. Tracks
  /// the template's `WATCHOS_DEPLOYMENT_TARGET` (the arm64 engine is Series 9+ /
  /// watchOS 26). Kept ≤ the watch app's own minimum so validation never sees a
  /// framework that demands a newer OS than its host.
  static const String _frameworkMinimumOSVersion = '26.0';

  /// Wraps [sourceDylib] as `<frameworkName>.framework/<frameworkName>` under
  /// [flutterDir], with an `@rpath/<name>.framework/<name>` install name and an
  /// FMWK Info.plist — the exact structure the Xcode "Embed Frameworks" phase
  /// and App Store Connect require. Any pre-existing framework dir is replaced.
  void _stageFramework({
    required File sourceDylib,
    required Directory flutterDir,
    required String frameworkName,
    required String bundleId,
  }) {
    final Directory fw = flutterDir.childDirectory('$frameworkName.framework');
    if (fw.existsSync()) {
      fw.deleteSync(recursive: true);
    }
    fw.createSync(recursive: true);
    final File binary = fw.childFile(frameworkName);
    sourceDylib.copySync(binary.path);
    final ProcessResult idResult = globals.processManager.runSync(<String>[
      'install_name_tool',
      '-id',
      '@rpath/$frameworkName.framework/$frameworkName',
      binary.path,
    ]);
    if (idResult.exitCode != 0) {
      throwToolExit(
        'Setting the install name for $frameworkName.framework failed:\n'
        '${idResult.stderr}',
      );
    }
    fw.childFile('Info.plist').writeAsStringSync(
      _frameworkInfoPlist(executable: frameworkName, bundleId: bundleId),
    );
  }

  /// FMWK Info.plist for a staged engine/Dart framework. The supported platform
  /// follows the build SDK (WatchSimulator for the debug/JIT simulator loop,
  /// WatchOS for AOT device/App Store builds).
  String _frameworkInfoPlist({
    required String executable,
    required String bundleId,
  }) {
    final platform = buildInfo.simulator ? 'WatchSimulator' : 'WatchOS';
    return '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>CFBundleExecutable</key><string>$executable</string>
\t<key>CFBundleIdentifier</key><string>$bundleId</string>
\t<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
\t<key>CFBundleName</key><string>$executable</string>
\t<key>CFBundlePackageType</key><string>FMWK</string>
\t<key>CFBundleShortVersionString</key><string>1.0</string>
\t<key>CFBundleSupportedPlatforms</key><array><string>$platform</string></array>
\t<key>CFBundleVersion</key><string>1</string>
\t<key>MinimumOSVersion</key><string>$_frameworkMinimumOSVersion</string>
</dict>
</plist>
''';
  }

  /// Builds `App.framework/App` for release/device (AOT): gen_snapshot →
  /// assembly → clang dylib exporting the `kDartVmSnapshot*` /
  /// `kDartIsolateSnapshot*` symbols the engine's App loader binds at runtime.
  /// Reuses the `app.dill` produced by [WatchosKernelSnapshot].
  Future<void> _buildAotAppDylib(
    FlutterProject project,
    Directory watchosProjectDir,
    Environment environment,
  ) async {
    globals.logger.printTrace('Compiling AOT App.framework for watchOS...');

    final watchosArtifacts = globals.artifacts! as WatchosArtifacts;
    final String genSnapshotPath = watchosArtifacts.getGenSnapshotPath(buildInfo.buildInfo.mode);
    if (!globals.fs.file(genSnapshotPath).existsSync()) {
      throwToolExit(
        'gen_snapshot not found at $genSnapshotPath.\n'
        'Run flutter-watchos precache to download watchOS engine artifacts.',
      );
    }

    File kernelSnapshot = environment.buildDir.childFile('app.dill');
    if (!kernelSnapshot.existsSync()) {
      kernelSnapshot = environment.outputDir.childFile('app.dill');
    }
    if (!kernelSnapshot.existsSync()) {
      throw Exception(
        'Kernel snapshot (app.dill) not found at ${kernelSnapshot.path}.\n'
        'The Dart compilation step may have failed.',
      );
    }

    final Directory aotDir = environment.outputDir.childDirectory('aot')
      ..createSync(recursive: true);
    final String assemblyPath = globals.fs.path.join(aotDir.path, 'snapshot_assembly.S');

    final String? splitDebugInfo = environment.defines[kSplitDebugInfo];
    if (splitDebugInfo != null && splitDebugInfo.isNotEmpty) {
      globals.fs.directory(splitDebugInfo).createSync(recursive: true);
    }

    final ProcessResult genSnapshotResult = await globals.processManager.run(
      watchosGenSnapshotArgs(
        fileSystem: globals.fs,
        genSnapshotPath: genSnapshotPath,
        assemblyPath: assemblyPath,
        kernelSnapshotPath: kernelSnapshot.path,
        defines: environment.defines,
      ),
    );
    if (genSnapshotResult.exitCode != 0) {
      globals.logger.printError('gen_snapshot failed:');
      globals.logger.printError(genSnapshotResult.stderr as String);
      throw Exception('gen_snapshot failed');
    }

    const clangTarget = 'arm64-apple-watchos9.0';
    final String objectPath = globals.fs.path.join(aotDir.path, 'snapshot_assembly.o');
    final ProcessResult ccResult = await globals.processManager.run(<String>[
      'xcrun',
      '-sdk',
      buildInfo.sdkName,
      'clang',
      '-target',
      clangTarget,
      '-c',
      assemblyPath,
      '-o',
      objectPath,
    ]);
    if (ccResult.exitCode != 0) {
      globals.logger.printError('Assembly compilation failed:');
      globals.logger.printError(ccResult.stderr as String);
      throw Exception('Assembly compilation failed');
    }

    final File appBinary =
        _prepareAppFramework(watchosProjectDir).childFile('App');
    final ProcessResult linkResult = await globals.processManager.run(<String>[
      'xcrun',
      '-sdk',
      buildInfo.sdkName,
      'clang',
      '-target',
      clangTarget,
      '-dynamiclib',
      '-install_name',
      '@rpath/App.framework/App',
      '-o',
      appBinary.path,
      objectPath,
    ]);
    if (linkResult.exitCode != 0) {
      globals.logger.printError('Linking App.framework failed:');
      globals.logger.printError(linkResult.stderr as String);
      throw Exception('Linking App.framework failed');
    }
    _finalizeAppFramework(appBinary.parent);
    globals.logger.printTrace('AOT App.framework built: ${appBinary.path}');
  }

  /// Creates a clean `Flutter/App.framework/` directory (removing any prior
  /// framework or bare `App.dylib`) ready to receive the linked `App` binary.
  Directory _prepareAppFramework(Directory watchosProjectDir) {
    final Directory flutterDir = watchosProjectDir.childDirectory('Flutter');
    final Directory appFramework = flutterDir.childDirectory('App.framework');
    if (appFramework.existsSync()) {
      appFramework.deleteSync(recursive: true);
    }
    appFramework.createSync(recursive: true);
    final File staleAppDylib = flutterDir.childFile('App.dylib');
    if (staleAppDylib.existsSync()) {
      staleAppDylib.deleteSync();
    }
    return appFramework;
  }

  /// Writes the FMWK Info.plist alongside the linked `App` binary.
  void _finalizeAppFramework(Directory appFramework) {
    appFramework.childFile('Info.plist').writeAsStringSync(
      _frameworkInfoPlist(executable: 'App', bundleId: _appFrameworkBundleId),
    );
  }

  /// Builds a tiny stub `App.framework/App` for debug/JIT builds so the Xcode
  /// embed phase always has its input. The real Dart code runs from the JIT
  /// core snapshots (`*_snapshot.bin`) + `kernel_blob.bin` in flutter_assets;
  /// nothing binds this stub.
  Future<void> _buildJitStubAppDylib(Directory watchosProjectDir) async {
    final Directory tmp = globals.fs.systemTempDirectory.createTempSync('fw_stub.');
    try {
      final File stubC = tmp.childFile('stub.c')
        ..writeAsStringSync(
          '__attribute__((visibility("default"))) int flutter_watchos_jit_stub;\n',
        );
      final File appBinary =
          _prepareAppFramework(watchosProjectDir).childFile('App');
      final clangTarget = buildInfo.simulator
          ? 'arm64-apple-watchos9.0-simulator'
          : 'arm64-apple-watchos9.0';
      final ProcessResult r = await globals.processManager.run(<String>[
        'xcrun',
        '-sdk',
        buildInfo.sdkName,
        'clang',
        '-target',
        clangTarget,
        '-dynamiclib',
        '-install_name',
        '@rpath/App.framework/App',
        '-o',
        appBinary.path,
        stubC.path,
      ]);
      if (r.exitCode != 0) {
        globals.logger.printError('Building JIT stub App.framework failed: ${r.stderr}');
        throw Exception('Building JIT stub App.framework failed');
      }
      _finalizeAppFramework(appBinary.parent);
      globals.logger.printTrace('JIT stub App.framework built: ${appBinary.path}');
    } finally {
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        /* ignore */
      }
    }
  }

  /// Compiles the native sources of every federated watchOS plugin that ships
  /// a `watchos/Package.swift` into a single static archive and wires an
  /// `OTHER_LDFLAGS` assignment into `Generated.xcconfig` that force-loads it
  /// into the watch (Runner) link. No-op when there are no such plugins.
  ///
  /// watchOS plugins here are **FFI-only** (the software-rendering embedder
  /// exposes no `Flutter` Swift module or plugin registrar), so instead of
  /// resolving an SPM graph we compile the C/ObjC sources directly and
  /// `-force_load` the archive into Runner. `-force_load` keeps every member —
  /// FFI symbols have no compile-time caller, so they would otherwise be
  /// dead-stripped — and the exports' `used` + default-visibility attributes
  /// land them in the binary's dynamic symbol table for
  /// `DynamicLibrary.process()` / dlsym.
  ///
  /// The flag is written into the xcconfig — not passed on the `xcodebuild`
  /// command line — with an `[sdk=watch…*]` qualifier so it applies ONLY to
  /// the watch target. That is what lets `flutter-watchos archive` build the
  /// `HostApp` scheme (Runner + the iOS container) in one pass: a global
  /// `OTHER_LDFLAGS` would try to force-load this watchOS archive into the iOS
  /// host's link and fail.
  Future<void> _buildPluginStaticArchive(
    FlutterProject project,
    Directory watchosProjectDir,
  ) async {
    final List<WatchosSpmPlugin> plugins = discoverWatchosSpmPlugins(project);
    if (plugins.isEmpty) {
      return;
    }

    final sources = <String>[];
    final headerDirs = <String>{};
    final frameworks = <String>{};
    for (final plugin in plugins) {
      final Directory pluginDir = globals.fs.directory(plugin.packagePath);
      if (!pluginDir.existsSync()) {
        continue;
      }
      for (final FileSystemEntity entity in pluginDir.listSync(recursive: true)) {
        if (entity is! File) {
          continue;
        }
        final String p = entity.path;
        if (p.endsWith('.m') || p.endsWith('.mm') || p.endsWith('.c')) {
          sources.add(p);
        } else if (p.endsWith('.h')) {
          headerDirs.add(entity.parent.path);
        }
      }
      frameworks.addAll(parseLinkedFrameworks(pluginDir.childFile('Package.swift')));
    }
    if (sources.isEmpty) {
      return;
    }
    // watchOS plugins virtually always need these; harmless if already linked.
    frameworks.addAll(<String>['WatchKit', 'Foundation']);

    final Directory flutterDir = watchosProjectDir.childDirectory('Flutter');
    final Directory objDir = flutterDir.childDirectory('.plugins_build')
      ..createSync(recursive: true);
    final clangTarget = buildInfo.simulator
        ? 'arm64-apple-watchos9.0-simulator'
        : 'arm64-apple-watchos9.0';

    final objects = <String>[];
    for (final src in sources) {
      final String obj = globals.fs.path.join(objDir.path, '${globals.fs.path.basename(src)}.o');
      final ProcessResult r = await globals.processManager.run(<String>[
        'xcrun',
        '-sdk',
        buildInfo.sdkName,
        'clang',
        '-target',
        clangTarget,
        '-fobjc-arc',
        '-fmodules',
        for (final String dir in headerDirs) '-I$dir',
        '-c',
        src,
        '-o',
        obj,
      ]);
      if (r.exitCode != 0) {
        globals.logger.printError('Compiling watchOS plugin source $src failed:\n${r.stderr}');
        throw Exception('Compiling watchOS plugin source failed');
      }
      objects.add(obj);
    }

    final String archive = globals.fs.path.join(flutterDir.path, 'libflutter_watchos_plugins.a');
    final File archiveFile = globals.fs.file(archive);
    if (archiveFile.existsSync()) {
      archiveFile.deleteSync();
    }
    final ProcessResult libR = await globals.processManager.run(<String>[
      'xcrun',
      '-sdk',
      buildInfo.sdkName,
      'libtool',
      '-static',
      '-o',
      archive,
      ...objects,
    ]);
    if (libR.exitCode != 0) {
      globals.logger.printError('Linking watchOS plugin archive failed:\n${libR.stderr}');
      throw Exception('Linking watchOS plugin archive failed');
    }
    globals.logger.printTrace(
      'Built watchOS plugin archive ($archive) from ${objects.length} object(s); '
      'force-loading into Runner with frameworks: ${frameworks.join(', ')}',
    );

    // Force-load flags, qualified to the watch SDK so they never reach the iOS
    // HostApp link during `flutter-watchos archive` (which builds both targets
    // via the HostApp scheme).
    final ldflags = StringBuffer(r'$(inherited) -force_load ');
    ldflags.write(archive);
    for (final fw in frameworks) {
      ldflags.write(' -framework $fw');
    }
    // `_generateXcconfigs` (step 4) already rewrote Generated.xcconfig this
    // build; append the qualified assignment so the watch target picks it up
    // via its base configuration. Debug builds link the simulator SDK, device
    // builds link `watchos` — qualify to the active one.
    final sdkQualifier = '${buildInfo.sdkName}*';
    flutterDir.childFile('Generated.xcconfig').writeAsStringSync(
          'OTHER_LDFLAGS[sdk=$sdkQualifier]=$ldflags\n'
          // The FFI exports above are reached only via dlsym(RTLD_DEFAULT) at
          // runtime, so they have no link-time caller. `xcodebuild archive`
          // runs the install-time strip (DEPLOYMENT_POSTPROCESSING /
          // STRIP_INSTALLED_PRODUCT=YES) which, with the default
          // STRIP_STYLE=all, prunes them from the symbol table — the app then
          // throws "Failed to lookup symbol …: symbol not found" on the first
          // FFI call, its root widget's initState blows up, and it renders a
          // blank/gray screen. This ONLY bites archived/TestFlight builds:
          // `flutter-watchos run` builds without the install strip, so the
          // symbols survive there (which is why on-device run works but the
          // App Store build is gray). Keep global symbols so the exports
          // survive the strip; locals are still stripped.
          'STRIP_STYLE = non-global\n',
          mode: FileMode.append,
        );
  }

  /// Parses `.linkedFramework("X")` entries from a plugin's `Package.swift`.
  @visibleForTesting
  static List<String> parseLinkedFrameworks(File packageSwift) {
    if (!packageSwift.existsSync()) {
      return const <String>[];
    }
    final String content = packageSwift.readAsStringSync();
    return RegExp(
      r'\.linkedFramework\(\s*"([^"]+)"\s*\)',
    ).allMatches(content).map((Match m) => m.group(1)!).toList();
  }

  /// Builds the gen_snapshot command line for the watchOS AOT assembly step.
  @visibleForTesting
  static List<String> watchosGenSnapshotArgs({
    required FileSystem fileSystem,
    required String genSnapshotPath,
    required String assemblyPath,
    required String kernelSnapshotPath,
    required Map<String, String> defines,
  }) {
    final dartObfuscation = defines[kDartObfuscation] == 'true';
    final String? splitDebugInfo = defines[kSplitDebugInfo];
    final bool shouldSplitDebugInfo = splitDebugInfo != null && splitDebugInfo.isNotEmpty;
    final List<String> extraGenSnapshotOptions = decodeCommaSeparated(
      defines,
      kExtraGenSnapshotOptions,
    );
    final String? saveDebuggingInfoArg = shouldSplitDebugInfo
        ? '--save-debugging-info=${fileSystem.path.join(splitDebugInfo, 'app.watchos-arm64.symbols')}'
        : null;
    return <String>[
      genSnapshotPath,
      '--deterministic',
      '--snapshot_kind=app-aot-assembly',
      '--assembly=$assemblyPath',
      ...extraGenSnapshotOptions,
      if (shouldSplitDebugInfo) ...<String>[
        '--dwarf-stack-traces',
        '--resolve-dwarf-paths',
        saveDebuggingInfoArg!,
      ],
      if (dartObfuscation) '--obfuscate',
      kernelSnapshotPath,
    ];
  }

  /// Generates Generated.xcconfig, Debug.xcconfig, and Release.xcconfig.
  void _generateXcconfigs(FlutterProject project, Directory watchosProjectDir) {
    final Directory flutterDir = watchosProjectDir.childDirectory('Flutter');
    flutterDir.createSync(recursive: true);

    final String buildName = buildInfo.buildInfo.buildName ?? project.manifest.buildName ?? '1.0.0';
    final String buildNumber =
        buildInfo.buildInfo.buildNumber ?? project.manifest.buildNumber ?? '1';

    final xcconfig = StringBuffer();
    xcconfig.writeln('FLUTTER_APPLICATION_PATH=${project.directory.path}');
    xcconfig.writeln('FLUTTER_TARGET=$targetFile');
    xcconfig.writeln('FLUTTER_BUILD_DIR=${project.directory.childDirectory('build').path}');
    xcconfig.writeln('FLUTTER_BUILD_NAME=$buildName');
    xcconfig.writeln('FLUTTER_BUILD_NUMBER=$buildNumber');

    flutterDir.childFile('Generated.xcconfig').writeAsStringSync(xcconfig.toString());

    flutterDir
        .childFile('Debug.xcconfig')
        .writeAsStringSync(
          '#include "Generated.xcconfig"\n'
          '#include? "Pods/Target Support Files/Pods-Runner/Pods-Runner.debug.xcconfig"\n',
        );

    flutterDir
        .childFile('Release.xcconfig')
        .writeAsStringSync(
          '#include "Generated.xcconfig"\n'
          '#include? "Pods/Target Support Files/Pods-Runner/Pods-Runner.release.xcconfig"\n',
        );
  }
}
