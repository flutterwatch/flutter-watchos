// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Guards what a package's build hook is told when it runs for watchOS.
//
// Two things are being held down. First, that a hook is told `watchos` — the
// platform it is actually building for — and not `ios`, which is what going
// through flutter_tools' own target translation would say, because its set of
// target platforms has no watchOS in it.
//
// Second, that it is told anything at all. The hooks protocol carries the
// target OS inside the *code* asset config, so a pass asking for data assets
// alone leaves a hook with no way to know. A package that picks a graphics
// backend from that — a 3D engine compiling shader bundles, say — then guesses,
// and guesses wrong: it compiles GLES for a Metal engine. Nothing throws. The
// app draws a black frame, which is why this is a test and not a comment.

import 'dart:io' as io;

import 'package:code_assets/code_assets.dart';
import 'package:data_assets/data_assets.dart';
import 'package:file/memory.dart';
import 'package:flutter_tools/src/artifacts.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/build_system/build_system.dart' hide BuildResult;
import 'package:flutter_tools/src/build_system/targets/native_assets.dart' show LinkHooks;
import 'package:flutter_tools/src/features.dart';
import 'package:flutter_tools/src/isolated/native_assets/native_assets.dart';
import 'package:flutter_tools/src/isolated/native_assets/targets.dart';
import 'package:flutter_watchos/build_targets/watchos_hooks.dart';
import 'package:hooks/hooks.dart';
import 'package:hooks_runner/hooks_runner.dart';

import '../../flutter/packages/flutter_tools/test/general.shard/isolated/fake_native_assets_build_runner.dart'
    show FakeFlutterNativeAssetsBuilderResult;
import '../../flutter/packages/flutter_tools/test/src/fakes.dart' show TestFeatureFlags;
import '../../flutter/packages/flutter_tools/test/src/package_config.dart';
import '../src/common.dart';
import '../src/context.dart';

/// A build runner that records what the hooks would have been told.
///
/// Upstream's fake is not usable here: it reaches for `Directory.systemTemp`,
/// which the test harness's filesystem guard refuses. This one builds the same
/// input the real runner would, from fixed paths, and never touches disk.
class _RecordingBuildRunner implements FlutterNativeAssetsBuildRunner {
  _RecordingBuildRunner({this.failuresBeforeSuccess = 0, this.alwaysFails = false});

  /// How many attempts refuse to build before one succeeds. One stands for a
  /// hook that cannot cope with being told `watchos` but can build for the iOS
  /// family, which is the case the retry exists for.
  final int failuresBeforeSuccess;

  /// A hook that cannot build under either name.
  final bool alwaysFails;

  /// Every input a hook was handed, in order.
  final inputs = <BuildInput>[];

  BuildInput? get lastInput => inputs.isEmpty ? null : inputs.last;

  @override
  Future<List<String>> packagesWithNativeAssets() async => const <String>['some_package'];

  @override
  Future<BuildResult?> build({
    required List<ProtocolExtension> extensions,
    required bool linkingEnabled,
  }) async {
    // `package:hooks` resolves these against dart:io, not the injected file
    // system, and creates the output directory as a side effect. The harness's
    // filesystem guard only tolerates that inside the system temp directory.
    final base = '${io.Directory.systemTemp.resolveSymbolicLinksSync()}/watchos_build_hooks_test';
    final input = BuildInputBuilder()
      ..setupShared(
        packageRoot: Uri.directory('$base/some_package'),
        packageName: 'some_package',
        outputDirectoryShared: Uri.directory('$base/shared'),
        outputFile: Uri.file('$base/some_package/output.json'),
      )
      ..setupBuildInput()
      ..config.setupBuild(linkingEnabled: linkingEnabled);
    for (final extension in extensions) {
      extension.setupBuildInput(input);
    }
    inputs.add(BuildInput(input.json));
    if (alwaysFails || inputs.length <= failuresBeforeSuccess) {
      return null;
    }
    return const FakeFlutterNativeAssetsBuilderResult();
  }

  @override
  Future<LinkResult?> link({
    required List<ProtocolExtension> extensions,
    required BuildResult buildResult,
    required File? recordedUsesFile,
  }) async => throw StateError('the data pass has no link phase');

  @override
  Future<void> setCCompilerConfig(CodeAssetTarget target) async {
    // The real runner discovers a host compiler here. Nothing is compiled in
    // this test, but the field is `late` and read while building extensions.
    target.cCompilerConfigSync = null;
  }
}

void main() {
  late FileSystem fileSystem;

  setUp(() {
    fileSystem = MemoryFileSystem.test();
    fileSystem.file('pubspec.yaml')
      ..createSync()
      ..writeAsStringSync('name: example\n');
    writePackageConfigFiles(
      directory: fileSystem.currentDirectory,
      mainLibName: 'example',
    );
  });

  Environment buildEnv() {
    final env = Environment.test(
      fileSystem.currentDirectory,
      defines: <String, String>{
        kBuildMode: BuildMode.debug.cliName,
        // watchOS rides the iOS pipeline for everything downstream of here —
        // the AOT snapshot, the Xcode invocation. The hooks are the one place
        // it does not, which is what this file is about.
        kTargetPlatform: getNameForTargetPlatform(TargetPlatform.ios),
        // Only the fallback reads this, to build a faithful iOS input.
        kSdkRoot: '/sdk/iPhoneSimulator.sdk',
      },
      inputs: <String, String>{},
      artifacts: Artifacts.test(),
      processManager: FakeProcessManager.any(),
      fileSystem: fileSystem,
      logger: BufferLogger.test(),
      platform: FakePlatform(),
    );
    env.buildDir.createSync(recursive: true);
    return env;
  }

  group('WatchosBuildHooks', () {
    testUsingContext('tells the hook what it is building for', () async {
      final runner = _RecordingBuildRunner();

      await WatchosBuildHooks(buildRunner: runner).build(buildEnv());

      final BuildInput? recorded = runner.lastInput;
      expect(recorded, isNotNull, reason: 'no hook was invoked at all');
      final BuildInput seen = recorded!;
      expect(
        seen.config.buildCodeAssets,
        isTrue,
        reason: 'without code assets the input carries no target OS, and a '
            'package that reads one falls back to its OS-less default',
      );
      // Read off the wire rather than through `config.code`, which parses the
      // name back into an `OS` — and this version of the library throws on one
      // it does not know, which is the whole reason the extension is hand-held.
      // A hook resolving code_assets 2.0.0 reads the same bytes as an `OS`.
      final code = (seen.config.json['extensions']! as Map<String, Object?>)['code_assets']!
          as Map<String, Object?>;
      expect(
        code['target_os'],
        'watchos',
        reason: 'watchOS is its own platform, and a hook told `ios` cannot '
            'tell the difference or ask',
      );
      expect(code['target_architecture'], Architecture.arm64.name);
      expect(
        code.containsKey('ios'),
        isFalse,
        reason: 'an iPhone SDK and deployment target describe a platform this '
            'is not',
      );
      expect(seen.config.buildDataAssets, isTrue);
    }, overrides: <Type, Generator>{
      FileSystem: () => fileSystem,
      ProcessManager: () => FakeProcessManager.any(),
      FeatureFlags: () => TestFeatureFlags(isNativeAssetsEnabled: true, isDartDataAssetsEnabled: true),
    });

    testUsingContext('falls back to the iOS family when the name is refused', () async {
      // A hook that dies on an unfamiliar target OS is the common case today:
      // code_assets parsed `target_os` eagerly until 2.0.0. The build has to
      // keep working, so the pass is retried under the name such a hook can
      // read — which is what watchOS builds asked for before this.
      final runner = _RecordingBuildRunner(failuresBeforeSuccess: 1);

      await WatchosBuildHooks(buildRunner: runner).build(buildEnv());

      expect(runner.inputs, hasLength(2), reason: 'the pass was not retried');
      Map<String, Object?> code(BuildInput input) =>
          (input.config.json['extensions']! as Map<String, Object?>)['code_assets']!
              as Map<String, Object?>;
      expect(code(runner.inputs.first)['target_os'], 'watchos');
      expect(code(runner.inputs.last)['target_os'], 'ios');
      expect(
        code(runner.inputs.last).containsKey('ios'),
        isTrue,
        reason: 'a hook told `ios` goes on to read the iOS config, so the '
            'fallback has to be a faithful iOS input and not just an iOS name',
      );
    }, overrides: <Type, Generator>{
      FileSystem: () => fileSystem,
      ProcessManager: () => FakeProcessManager.any(),
      FeatureFlags: () => TestFeatureFlags(isNativeAssetsEnabled: true, isDartDataAssetsEnabled: true),
    });

    testUsingContext('writes the result where CopyFlutterBundle reads it', () async {
      final runner = _RecordingBuildRunner();
      final Environment env = buildEnv();

      await WatchosBuildHooks(buildRunner: runner).build(env);

      expect(env.buildDir.childFile(LinkHooks.resultFilename).existsSync(), isTrue);
    }, overrides: <Type, Generator>{
      FileSystem: () => fileSystem,
      ProcessManager: () => FakeProcessManager.any(),
      FeatureFlags: () => TestFeatureFlags(isNativeAssetsEnabled: true, isDartDataAssetsEnabled: true),
    });

    testUsingContext('explains itself when a hook cannot build', () async {
      final runner = _RecordingBuildRunner(alwaysFails: true);

      await expectLater(
        WatchosBuildHooks(buildRunner: runner).build(buildEnv()),
        throwsToolExit(
          message: 'both as watchOS and as the iOS family',
        ),
      );
    }, overrides: <Type, Generator>{
      FileSystem: () => fileSystem,
      ProcessManager: () => FakeProcessManager.any(),
      FeatureFlags: () => TestFeatureFlags(isNativeAssetsEnabled: true, isDartDataAssetsEnabled: true),
    });
  });
}
