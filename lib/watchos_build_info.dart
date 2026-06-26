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
  /// A stub `arm64_32` slice is added at packaging time when the app's
  /// MinimumOSVersion is below 27.0, because the App Store requires an
  /// arm64_32 slice in the watch executable for older deployment targets —
  /// see the arm64_32 gate in [build_targets/application.dart].
  final String targetArch;

  /// Whether to build for the watchOS Simulator.
  final bool simulator;

  /// The Xcode SDK name for this build configuration.
  String get sdkName => simulator ? 'watchsimulator' : 'watchos';

  /// The Xcode destination for this build configuration.
  String get destination =>
      simulator ? 'generic/platform=watchOS Simulator' : 'generic/platform=watchOS';
}
