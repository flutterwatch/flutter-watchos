// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/memory.dart';
import 'package:flutter_tools/src/artifacts.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_watchos/watchos_artifacts.dart';

import '../src/common.dart';
import '../src/context.dart';
import '../src/fakes.dart';

void main() {
  late MemoryFileSystem fileSystem;
  late FakeProcessManager processManager;
  late Cache cache;
  late WatchosArtifacts artifacts;

  setUp(() {
    fileSystem = MemoryFileSystem.test();
    processManager = FakeProcessManager.any();
    // watchosArtifactDirectory resolves as `<flutterRoot>/../engine_artifacts`.
    Cache.flutterRoot = '/flutter';
    cache = Cache.test(fileSystem: fileSystem, processManager: processManager);
    artifacts = WatchosArtifacts(
      fileSystem: fileSystem,
      cache: cache,
      platform: FakePlatform(operatingSystem: 'macos'),
      operatingSystemUtils: FakeOperatingSystemUtils(),
    );

    // Lay down the patched host SDKs the override points at.
    fileSystem
        .directory('/engine_artifacts/host_release/flutter_patched_sdk')
        .createSync(recursive: true);
    fileSystem
        .directory('/engine_artifacts/host_debug_unopt/flutter_patched_sdk')
        .createSync(recursive: true);
  });

  group('WatchosArtifacts patched-SDK override (AOT platform identity)', () {
    test('release uses the product SDK (host_release)', () {
      // Release rides the product SDK, matching stock flutter_patched_sdk_product.
      expect(
        artifacts.getArtifactPath(Artifact.flutterPatchedSdkPath, mode: BuildMode.release),
        '/engine_artifacts/host_release/flutter_patched_sdk',
      );
      expect(
        artifacts.getArtifactPath(Artifact.platformKernelDill, mode: BuildMode.release),
        '/engine_artifacts/host_release/flutter_patched_sdk/platform_strong.dill',
      );
    });

    test('profile uses the NON-product SDK (host_debug_unopt)', () {
      // Profile must compile against the non-product SDK so AOT retains
      // entry-point classes the profile engine looks up natively (e.g.
      // dart:io _NetworkProfiling). Using the product SDK aborts at startup.
      expect(
        artifacts.getArtifactPath(Artifact.flutterPatchedSdkPath, mode: BuildMode.profile),
        '/engine_artifacts/host_debug_unopt/flutter_patched_sdk',
      );
      expect(
        artifacts.getArtifactPath(Artifact.platformKernelDill, mode: BuildMode.profile),
        '/engine_artifacts/host_debug_unopt/flutter_patched_sdk/platform_strong.dill',
      );
    });

    test('debug flutterPatchedSdkPath falls through to stock resolution', () {
      // Debug resolves platform identity at runtime via the device engine, so
      // the override is intentionally NOT applied — the path must come from
      // the stock CachedArtifacts logic, not our engine_artifacts host SDK.
      final String path = artifacts.getArtifactPath(
        Artifact.flutterPatchedSdkPath,
        mode: BuildMode.debug,
      );
      expect(path, isNot(contains('engine_artifacts')));
    });

    test('debug platformKernelDill falls through to stock resolution', () {
      final String path = artifacts.getArtifactPath(
        Artifact.platformKernelDill,
        mode: BuildMode.debug,
      );
      expect(path, isNot(contains('engine_artifacts')));
    });

    test('handles the nested directory layout from zip extraction', () {
      fileSystem
          .directory('/engine_artifacts/host_release/host_release/flutter_patched_sdk')
          .createSync(recursive: true);
      final String path = artifacts.getArtifactPath(
        Artifact.flutterPatchedSdkPath,
        mode: BuildMode.release,
      );
      expect(
        path,
        '/engine_artifacts/host_release/host_release/flutter_patched_sdk',
      );
    });
  });

  group('engine variant selection per build mode', () {
    // Guards that each run mode resolves the correct engine artifact dir — a
    // wrong mapping here is how debug_sim / debug / profile / release silently
    // break (e.g. a device build picking up the simulator engine).
    String variantFor(BuildMode mode, EnvironmentType env) {
      return artifacts
          .engineDirectory(mode: mode, environmentType: env)
          .split('/engine_artifacts/')
          .last;
    }

    test('debug + simulator → watchos_debug_sim_arm64', () {
      expect(variantFor(BuildMode.debug, EnvironmentType.simulator),
          'watchos_debug_sim_arm64');
    });
    test('debug + device → watchos_debug_arm64', () {
      expect(variantFor(BuildMode.debug, EnvironmentType.physical),
          'watchos_debug_arm64');
    });
    test('profile + device → watchos_profile_arm64', () {
      expect(variantFor(BuildMode.profile, EnvironmentType.physical),
          'watchos_profile_arm64');
    });
    test('release + device → watchos_release_arm64', () {
      expect(variantFor(BuildMode.release, EnvironmentType.physical),
          'watchos_release_arm64');
    });
  });
}
