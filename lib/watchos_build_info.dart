// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/base/version.dart';
import 'package:flutter_tools/src/build_info.dart';

/// The oldest watchOS the CLI supports: 26.0.
///
/// The engine is arm64-only, and clang raises an arm64 watchOS device minimum
/// below 26.0 to 26.0, so nothing older can run it. The staged
/// `Flutter.framework` and `App.framework` declare it as their
/// `MinimumOSVersion`, every App.framework compile and link targets it, and
/// the CLI falls back to it when it cannot read the project's own
/// `WATCHOS_DEPLOYMENT_TARGET`: a host module or plugin object built for an
/// older OS than `App.swift` still imports and links, a newer one does not.
///
/// When the minimum is updated, update [kWatchosTemplateDeploymentTarget], the
/// template and example `project.pbxproj`, and the project migration together.
const Version kWatchosSupportedMinimum = Version.withText(26, 0, 0, '26.0');

/// The `WATCHOS_DEPLOYMENT_TARGET` that `create` writes into the watch
/// Runner's Debug and Release configurations.
///
/// It is never below [kWatchosSupportedMinimum]. When it is updated, update
/// the template and example `project.pbxproj` literals together; a test ties
/// the three.
const Version kWatchosTemplateDeploymentTarget = Version.withText(26, 0, 0, '26.0');

/// The oldest Xcode the CLI supports: 26.0.
///
/// App Store Connect takes watchOS apps built with the watchOS 26 SDK or
/// later, which comes with Xcode 26. `doctor` reports an older Xcode as an
/// error, and a build stops on one before it compiles anything native, like
/// stock `xcodeRequiredVersion`. Xcode 26.0 itself is not on offer anywhere
/// for a test: the oldest Xcode 26 that CI runs is 26.0.1.
const Version kWatchosXcodeRequiredVersion = Version.withText(26, 0, 0, '26.0');

/// How `doctor` and the build name an Xcode [version]: `Xcode 26.0`, or
/// `Xcode 26.0.1` when it has a patch number.
String watchosXcodeName(Version version) =>
    'Xcode ${version.major}.${version.minor}${version.patch == 0 ? '' : '.${version.patch}'}';

/// What `doctor` and the build say about an Xcode [found] older than
/// [kWatchosXcodeRequiredVersion].
String watchosXcodeTooOldMessage(Version found) =>
    'flutter-watchos requires Xcode $kWatchosXcodeRequiredVersion or later; found '
    '${watchosXcodeName(found)}.\n'
    'Download the latest version or update via the Mac App Store.';

/// The clang and swiftc `-target` triple for [arch] on watchOS [osVersion],
/// with the `-simulator` suffix when [simulator] is true: for example
/// `arm64-apple-watchos26.0-simulator`.
String watchosTargetTriple({
  String arch = 'arm64',
  required String osVersion,
  required bool simulator,
}) {
  return '$arch-apple-watchos$osVersion${simulator ? '-simulator' : ''}';
}

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
