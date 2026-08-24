// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert' show json;

import 'package:code_assets/code_assets.dart';
import 'package:data_assets/data_assets.dart';
import 'package:flutter_tools/src/asset.dart' show FlutterHookResult;
import 'package:flutter_tools/src/base/common.dart' show throwToolExit;
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart' show Logger;
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/build_system/build_system.dart' hide BuildResult;
import 'package:flutter_tools/src/build_system/depfile.dart';
import 'package:flutter_tools/src/build_system/exceptions.dart' show MissingDefineException;
import 'package:flutter_tools/src/build_system/targets/native_assets.dart'
    show LinkHooks, createFlutterNativeAssetsBuildRunner;
import 'package:flutter_tools/src/features.dart' show featureFlags;
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/hook_runner.dart' show FlutterHookRunner;
import 'package:flutter_tools/src/isolated/native_assets/dart_hook_result.dart';
import 'package:flutter_tools/src/isolated/native_assets/ios/native_assets.dart'
    show getIOSSdk, targetIOSVersion;
import 'package:flutter_tools/src/isolated/native_assets/macos/native_assets_host.dart'
    show cCompilerConfigMacOS;
import 'package:flutter_tools/src/isolated/native_assets/native_assets.dart'
    show FlutterCodeAsset, FlutterNativeAssetsBuildRunner;
import 'package:flutter_tools/src/macos/xcode.dart' show environmentTypeFromSdkroot;
import 'package:hooks/hooks.dart'
    show BuildInputBuilder, EncodedAsset, LinkInputBuilder, ProtocolExtension;
import 'package:hooks_runner/hooks_runner.dart' show BuildResult;
import 'package:meta/meta.dart' show visibleForTesting;

/// watchOS's name in the Dart hooks protocol.
///
/// The protocol's built-in operating systems are the ones `dart:ffi` can name,
/// and watchOS is not among them: under the `package:code_assets` the Flutter
/// SDK pins, `OS.fromString('watchos')` throws rather than minting a value.
/// (2.0.0 opened that set up, but the tool cannot move to it — it gives `OS` a
/// non-primitive `==`, which makes a `const` map inside flutter_tools fail to
/// compile, and the SDK checkout is never patched.)
///
/// The wire format has no such restriction. `target_os` is a plain string on
/// both sides of the protocol, and a hook resolving code_assets 2.0.0 — which
/// an app is free to do, its dependencies being resolved separately from the
/// tool's — reads an unfamiliar name back as an ordinary [OS]. So watchOS can
/// introduce itself by name even while the tool's own copy of the library has
/// no word for it.
///
/// That distinction is the point. watchOS is an Apple platform and a close
/// relative of iOS, but it is not iOS: different engine, different screen,
/// different SDK, a different set of things a package can do. A hook told
/// `ios` cannot tell the difference and has no way to ask; a hook told
/// `watchos` can.
///
/// What a hook still cannot be told is device versus simulator. The typed side
/// of the protocol carries that in a per-OS sub-config — `IOSCodeConfig` has
/// `targetSdk`, and there is an `AndroidCodeConfig` and a `MacOSCodeConfig` —
/// and there is no watchOS one to carry it in. Naming the simulator as a separate
/// OS would invent vocabulary no hook reads, and the architecture is arm64
/// either way, so the two are indistinguishable here.
///
/// A hook that ships *source* is unaffected; one that precompiles per-platform
/// binaries is not. A Metal library built against `applewatchos` and one built
/// against `appletvsimulator` carry different target triples, and Metal
/// validates that when a pipeline is created rather than degrading, so whichever
/// such a hook produced first would serve both. The iOS-family fallback keeps
/// the distinction — `targetSdk` comes from the SDK root — which leaves the
/// degraded path better off in this one respect than the accurate one.
const String watchOSName = 'watchos';

/// The architecture watchOS builds target.
///
/// The engine and the AOT snapshot are arm64-only, on device and in the
/// simulator alike, so there is one value here rather than a list. (An
/// `arm64_32` slice is added at packaging time for older deployment targets;
/// nothing is compiled for it, so no hook is ever asked to build for it.)
///
/// Which also means the architecture cannot separate the two, and neither can
/// anything else on this path: a device build and a simulator build produce
/// byte-identical hook inputs, and therefore one `hooks_runner` cache entry
/// serving both. See [watchOSName] for why there is nowhere to put the
/// distinction.
const Architecture watchOSArchitecture = Architecture.arm64;

/// The `buildAssetTypes` name for code assets, which is not exported.
const String _codeAssetType = 'code_assets';

/// The protocol's key for the target operating system.
const String _targetOSKey = 'target_os';

/// The code-asset half of a watchOS hook input.
///
/// This wraps `CodeAssetExtension` rather than being one, for a single reason:
/// that class takes an [OS], and the tool's copy of `package:code_assets`
/// cannot construct one that says watchOS. So the config is built by the real
/// thing — which owns the layout, the C compiler block, and everything else —
/// and then the one field its API cannot express is written directly onto the
/// JSON it produced.
///
/// The `iOS` sub-config the wrapped extension would carry is deliberately not
/// supplied. It describes an iPhone SDK and a deployment target that no watchOS
/// hook should be reading, and leaving it out keeps the input from claiming
/// something untrue alongside a target OS that is true.
///
/// The validation callbacks are left at their defaults, which report nothing,
/// instead of being forwarded. `CodeAssetExtension`'s implementations parse
/// `target_os` back into an [OS] and would throw on a name this version does
/// not know; and there is nothing here for them to check anyway, since no code
/// asset produced under this extension is kept. Data assets are validated by
/// `DataAssetsExtension`, which is untouched by any of this.
final class WatchosCodeAssetExtension extends ProtocolExtension {
  WatchosCodeAssetExtension({required CCompilerConfig? cCompiler})
    : _codeAssets = CodeAssetExtension(
        targetArchitecture: watchOSArchitecture,
        // Replaced by [watchOSName] as soon as it has been written; see
        // [_nameWatchOS]. Of the operating systems this library can name, the
        // iOS family is the closest to the truth, but no hook ever reads it.
        targetOS: OS.iOS,
        linkModePreference: LinkModePreference.dynamic,
        // Best effort: a hook that knows about watchOS can use the host
        // toolchain, and one that does not will not get as far as reading it.
        cCompiler: cCompiler,
      );

  final CodeAssetExtension _codeAssets;

  @override
  void setupBuildInput(BuildInputBuilder input) {
    _codeAssets.setupBuildInput(input);
    _nameWatchOS(input.config.json);
  }

  @override
  void setupLinkInput(LinkInputBuilder input) {
    _codeAssets.setupLinkInput(input);
    _nameWatchOS(input.config.json);
  }

  /// Replaces the target OS in the code-asset block with [watchOSName].
  ///
  /// `target_os` is a plain string in the protocol's syntax on both sides, so
  /// this produces an input that is well-formed by the schema and reads back as
  /// an ordinary [OS] wherever the library is new enough to mint one.
  ///
  /// The two casts below are load-bearing. They read the block `setupCode` has
  /// just written, so they hold today by construction; if a future layout kept
  /// the block but moved `target_os` elsewhere, this would write a key nothing
  /// reads, raise nothing, and every build would quietly go back to announcing
  /// iOS. `tells the hook what it is building for` in
  /// `test/general/watchos_build_hooks_test.dart` is what stands between that and
  /// a silent regression, so it asserts the wire and not this function.
  static void _nameWatchOS(Map<String, Object?> config) {
    final extensions = config['extensions']! as Map<String, Object?>;
    final code = extensions[_codeAssetType]! as Map<String, Object?>;
    code[_targetOSKey] = watchOSName;
  }
}

/// The iOS-family code config the fallback needs.
///
/// A hook told `ios` goes on to read this — `objective_c` reaches for
/// `code.iOS.targetSdk` — so the fallback has to be a faithful iOS input, not
/// just an iOS name.
///
/// [kSdkRoot] is only on the environment the one-shot build assembles; a
/// resident session's carries `kTargetFile` and `kBuildMode` and nothing else.
/// Requiring the define meant `run` threw `MissingDefineException` the moment
/// the fallback fired, which is not a `ToolExit` and reads as a broken build
/// rather than as a package that could not be told an OS name. So it is derived
/// when absent, from the same call the builder makes.
///
/// Which SDK that resolves to barely matters: nothing produced under this
/// config is installed, and only a hook reading `code.iOS.targetSdk` sees it at
/// all. A resident session cannot tell device from simulator, so it says
/// device; the alternative is refusing to build.
Future<IOSCodeConfig> _iosFamilyConfig(Environment environment) async {
  final String sdkRoot =
      environment.defines[kSdkRoot] ??
      await globals.xcode!.sdkLocation(EnvironmentType.physical);
  final EnvironmentType? environmentType = environmentTypeFromSdkroot(
    sdkRoot,
    environment.fileSystem,
  );
  return IOSCodeConfig(
    targetVersion: targetIOSVersion,
    // `environmentTypeFromSdkroot` returns null for a path whose basename does
    // not name an iPhone SDK — pointing kSdkRoot at the watchOS SDK, say, which is
    // the natural thing for someone to try. Falling back rather than asserting
    // keeps that from crashing inside a retry.
    targetSdk: getIOSSdk(environmentType ?? EnvironmentType.physical),
  );
}

/// Runs every package's Dart build hook for a watchOS app, and returns the
/// data assets they produced.
///
/// This is watchOS driving the hooks protocol on its own behalf, rather than
/// borrowing the iOS pipeline's driver. flutter_tools translates its own
/// `TargetPlatform`s into protocol targets through a closed set that has no
/// watchOS in it, so going through that path means being announced as `ios`.
/// Assembling the protocol extensions here instead means a hook is told
/// [watchOSName], which is the truth and is what a package needs in order to
/// pick the right output for this platform.
///
/// Code assets are requested and then dropped. Nothing built by a code-asset
/// hook is installed into a watchOS app — its plugins are native and resolved
/// by the package manager — but the protocol keeps the target OS *inside* the
/// code-asset config, so a hook that is not asked for code assets is not told
/// what it is building for at all. Asking is currently the only way to say
/// `watchos`.
///
/// Whether the name lands is a property of the app's packages, so it is tried
/// and not predicted; the fallback is inline below.
Future<DartHooksResult> runWatchosHooks({
  required FlutterNativeAssetsBuildRunner buildRunner,
  required Environment environment,
}) async {
  final buildStart = DateTime.now();

  final List<String> packagesWithHooks = await buildRunner.packagesWithNativeAssets();
  if (packagesWithHooks.isEmpty) {
    environment.logger.printTrace('No packages with Dart build hooks. Skipping.');
    return DartHooksResult.empty();
  }

  // Data assets are the entire product of this pass: the code assets it also
  // asks for exist to carry a target OS and are dropped. So with the feature
  // off there is nothing to collect, and running every package's hook to
  // collect it would be pure cost — worse, it would be cost that also fails
  // builds, since a hook can refuse the target OS.
  //
  // The feature is off by default. `dartDataAssets` declares no
  // `enabledByDefault` on any channel, while `nativeAssets` declares it on all
  // of them, so a guard reading both with `&&` can never fire and this used to
  // run the hooks and silently collect nothing. Say what is off, name the
  // packages it affects and the one command that turns it on.
  if (!featureFlags.isDartDataAssetsEnabled) {
    environment.logger.printWarning(
      'Dart data assets are disabled, so the build hooks in '
      '${packagesWithHooks.join(', ')} were not run.\n'
      'A package that generates assets for the platform it is built for — '
      'shader bundles and the like — will ship whatever its generated '
      'directory already held, which may be output from a build for another '
      'platform, or nothing.\n'
      'Turn them on with `flutter config --enable-dart-data-assets`.',
    );
    return DartHooksResult.empty();
  }

  final CCompilerConfig? cCompiler = await cCompilerConfigMacOS(throwIfNotFound: false);
  final dataAssets = DataAssetsExtension();

  // Ask as watchOS first. Whether that works is a property of the app's
  // packages, not something this build can look up: the name is read on the
  // *hook's* side, by the `package:code_assets` the app resolved, and before
  // 2.0.0 that library's set of operating systems was closed — `config.code`
  // parses `target_os` eagerly and throws on a name it does not know. A hook as
  // ordinary as `objective_c`'s dies on its first line, not with "watchOS is
  // unsupported", which it would handle, but before it can look.
  //
  // A package can be fine on an old code_assets by reading the name off the
  // config JSON, which is a plain string on both sides — flutter_scene does
  // exactly that — so the resolved version does not answer the question either.
  // Asking and seeing is the only thing that does.
  BuildResult? result = await buildRunner.build(
    extensions: <ProtocolExtension>[
      WatchosCodeAssetExtension(cCompiler: cCompiler),
      dataAssets,
    ],
    // Linking only ever concerns code assets, and none survive this function.
    linkingEnabled: false,
  );

  if (result == null) {
    // Fall back to what builds for this platform said before it could name
    // itself. The hooks just printed why they stopped, so say what happens now:
    // an unexplained retry after a stack trace reads as a broken build.
    //
    // What is deliberately *not* said is why it failed. `build` collapses every
    // failure — a missing toolchain, a compile error, a fetch that timed out, a
    // hook that deliberately reports watchOS as unsupported, and one that choked on
    // the name — into a null, so naming the last of those would be a diagnosis
    // nothing here established. The hooks' own error is on screen directly
    // above; this must not talk over it.
    environment.logger.printStatus(
      'A build hook failed while building for watchOS by name. The reason is above.\n'
      'Retrying as the iOS family, which is what watchOS builds asked for before '
      'this platform could introduce itself. That is a guess, and it helps only '
      'if the hook stopped on the target OS rather than on something else: '
      '`package:code_assets` throws on an OS it does not know until 2.0.0, so a '
      'hook reading one through its typed accessor cannot see `watchos` at all.',
    );
    result = await buildRunner.build(
      extensions: <ProtocolExtension>[
        CodeAssetExtension(
          targetArchitecture: watchOSArchitecture,
          targetOS: OS.iOS,
          linkModePreference: LinkModePreference.dynamic,
          cCompiler: cCompiler,
          iOS: await _iosFamilyConfig(environment),
        ),
        dataAssets,
      ],
      linkingEnabled: false,
    );
  }
  if (result == null) {
    _throwHookFailed(packagesWithHooks);
  }

  final int droppedCodeAssets = result.encodedAssets.where((a) => a.isCodeAsset).length;
  if (droppedCodeAssets > 0) {
    // Otherwise "no code assets existed" and "code assets existed and were
    // discarded" look identical from the outside, including in a bug report.
    environment.logger.printTrace(
      'Discarding $droppedCodeAssets code asset(s); a watchOS app installs none.',
    );
  }

  return DartHooksResult(
    buildStart: buildStart,
    buildEnd: DateTime.now(),
    // Deliberately empty; see the note on requesting code assets above.
    codeAssets: const <FlutterCodeAsset>[],
    dataAssets: <DataAsset>[
      for (final EncodedAsset asset in result.encodedAssets)
        if (asset.isDataAsset) DataAsset.fromEncoded(asset),
    ],
    dependencies: result.dependencies,
  );
}

/// Explains a hook failure in terms of what was actually asked for.
///
/// The generic message reads as though the app requested a native build it
/// never requested, which sends people looking in the wrong place. Say why the
/// hooks ran, and what the ways out are, because the answer is a judgement
/// about a dependency rather than something to fix in this build.
Never _throwHookFailed(List<String> packagesWithHooks) {
  throwToolExit(
    'A Dart build hook failed while building for watchOS, both as watchOS and '
    'as the iOS family.\n'
    '\n'
    'Packages with build hooks in this app: ${packagesWithHooks.join(', ')}.\n'
    '\n'
    'The hooks run so that packages generating per-platform *data* — shader\n'
    'bundles and the like — are told which platform. The protocol only carries\n'
    'that alongside a code-asset request, which is why one was made. Nothing a\n'
    'code-asset hook produces is installed into a watchOS app, whose plugins are\n'
    'native and resolved by the package manager, so this failure does not mean\n'
    'the app is missing something it needs.\n'
    '\n'
    'The second attempt built exactly what an iOS build of this app builds, so\n'
    'an iOS build is the quickest way to tell a missing toolchain (a Rust hook\n'
    'wants cargo, a C hook wants its compiler) from something specific to this\n'
    'platform. Either install the toolchain the hook wants, or drop the\n'
    'dependency, whose native half this app cannot use anyway.',
  );
}

/// Runs the Dart build hooks as part of the watchOS build graph.
///
/// The watchOS pipeline skips upstream's native-asset targets: their code-asset
/// half is iOS/macOS-only and a watchOS app does not use those FFI
/// implementations anyway (see `WatchosCopyFlutterBundle`). Data assets were a
/// different thing that happened to share the same pass — produced on the host
/// by ordinary Dart, which is how a package compiles its GPU shader bundles for
/// the platform it is going to run on.
///
/// Skipping them wholesale meant such a package silently shipped whatever its
/// generated directory happened to contain — assets left behind by a macOS or
/// simulator build of the same tree, or nothing at all. Neither failed the
/// build; the app just rendered a black scene on device. So this target runs
/// them, through [runWatchosHooks].
class WatchosBuildHooks extends Target {
  const WatchosBuildHooks({@visibleForTesting FlutterNativeAssetsBuildRunner? buildRunner})
    : _buildRunner = buildRunner;

  /// Injected by tests, which have no hooks to run and want to drive the
  /// result. Mirrors upstream `BuildHooks`' seam.
  final FlutterNativeAssetsBuildRunner? _buildRunner;

  @override
  String get name => 'watchos_build_hooks';

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

  static const depFilename = 'watchos_hooks.d';

  @override
  Future<void> build(Environment environment) async {
    final FileSystem fileSystem = environment.fileSystem;

    if (environment.defines[kBuildMode] == null) {
      throw MissingDefineException(kBuildMode, name);
    }

    final FlutterNativeAssetsBuildRunner buildRunner =
        _buildRunner ?? await createFlutterNativeAssetsBuildRunner(environment);

    final DartHooksResult buildResult = await runWatchosHooks(
      buildRunner: buildRunner,
      environment: environment,
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

/// Runs the same hooks during a resident session, so hot reload rebuilds
/// generated assets the way a full build does.
///
/// Upstream's runner exists and `RunCommand` already threads it through to the
/// resident runner, which calls it whenever the asset bundle needs rebuilding —
/// but it reads the implementation out of the context, so a CLI that does not
/// register one skips the call for the whole session, and a package that
/// generates its assets from a hook keeps serving whatever the last full build
/// left behind.
///
/// This registers one that goes through [runWatchosHooks], so a reload names
/// the same target OS a build does. Upstream's own implementation would name a
/// different one — it asks for data assets alone, which carries no target OS at
/// all — and a package choosing an output from it would swap in a different
/// one every time the two paths took turns.
class WatchosHookRunner implements FlutterHookRunner {
  WatchosHookRunner({@visibleForTesting FlutterNativeAssetsBuildRunner? buildRunner})
    : _buildRunner = buildRunner;

  /// Injected by tests. The same seam [WatchosBuildHooks] has, and for the same
  /// reason: without it nothing could exercise this path, which is how a crash
  /// on the resident environment's missing [kSdkRoot] reached review.
  final FlutterNativeAssetsBuildRunner? _buildRunner;

  FlutterHookResult? _lastResult;

  @override
  Future<FlutterHookResult> runHooks({
    required TargetPlatform targetPlatform,
    required Environment environment,
    Logger? logger,
  }) async {
    final FlutterHookResult? cached = _lastResult;
    if (cached != null && !cached.hasAnyModifiedFiles(environment.fileSystem)) {
      logger?.printTrace('runWatchosHooks() - up-to-date already');
      return cached;
    }
    logger?.printTrace('runWatchosHooks() - will perform dart build');

    final DartHooksResult result = await runWatchosHooks(
      buildRunner: _buildRunner ?? await createFlutterNativeAssetsBuildRunner(environment),
      environment: environment,
    );
    return _lastResult = result.asFlutterResult;
  }
}
