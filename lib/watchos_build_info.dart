// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/build_info.dart';

/// Build configuration for watchOS targets.
class WatchosBuildInfo {
  const WatchosBuildInfo(this.buildInfo, {required this.targetArch, this.simulator = false});

  final BuildInfo buildInfo;

  /// The target architecture for the watch executable.
  ///
  /// Device builds are `arm64` (the engine and AOT snapshot are arm64-only).
  /// Below watchOS 27.0 the App Store also requires an `arm64_32` slice in the
  /// watch executable. Xcode builds it: a device build passes no `ARCHS` to
  /// xcodebuild (`watchosXcodebuildArgs` in `build_targets/application.dart`),
  /// so Xcode's Standard Architectures include arm64_32 below 27.0, and the
  /// CLI compiles the host module for it too. The template's
  /// `#if arch(arm64_32)` makes that slice a stub that links no engine and
  /// shows a fallback screen on Series 6–8, SE (2nd generation) and Ultra
  /// (1st generation).
  final String targetArch;

  /// Whether to build for the watchOS Simulator.
  final bool simulator;

  /// The Xcode SDK name for this build configuration.
  String get sdkName => simulator ? 'watchsimulator' : 'watchos';

  /// The Xcode destination for this build configuration.
  String get destination =>
      simulator ? 'generic/platform=watchOS Simulator' : 'generic/platform=watchOS';

  /// The Xcode build configuration (`Debug`/`Release`) for this build.
  String get configuration => buildInfo.isDebug ? 'Debug' : 'Release';

  /// The products directory under `build/watchos/` that xcodebuild (SYMROOT)
  /// writes the built `Runner.app` into, e.g. `Debug-watchsimulator` or
  /// `Release-watchos`. A companion iOS app's "Embed Prebuilt watchOS App"
  /// build phase reads from the same location.
  String get productsDirName => '$configuration-$sdkName';
}
