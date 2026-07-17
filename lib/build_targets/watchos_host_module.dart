// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// The FlutterWatchOS host module: the generic Swift glue around the engine
/// (frame display, touch + Digital Crown forwarding, the text-input and
/// platform-view overlays), compiled by the CLI instead of shipped as app
/// template source — the same split as stock Flutter, whose iOS Runner is a
/// dozen lines because the machinery lives in `Flutter.framework`.
///
/// The sources live in the CLI's own `host/` directory (`FlutterRunner.swift`,
/// `FlutterHostView.swift`, plus the C declarations `flutter_watchos_host.h`
/// behind the `FlutterWatchOSHostC` clang module). At build time they are
/// compiled with the USER'S toolchain — one `swiftc` invocation per
/// architecture — into `watchos/Flutter/`:
///
///   Flutter/libFlutterWatchOSHost.a          the (fat) static archive
///   Flutter/FlutterWatchOS.swiftmodule/…     one .swiftmodule per triple
///   Flutter/module.modulemap + …host.h       the C module, staged alongside
///
/// and the app's `App.swift` just does `import FlutterWatchOS` and shows
/// `FlutterHostView()`. Compiling locally (rather than shipping a binary
/// module) sidesteps Swift module compatibility entirely: `xcrun swiftc` and
/// `xcodebuild` resolve to the same toolchain. Because the archive ships with
/// the CLI, glue fixes reach EXISTING apps on their next build — template
/// source only ever reached newly `create`d ones.
///
/// Apps created before the host module existed compile their own
/// `Runner/FlutterRunner.swift` with a bridging header; the presence of that
/// file marks a legacy project and skips all of this (see
/// [isLegacyRunnerProject]) so the two glue copies never collide.
library;

import 'package:flutter_tools/src/base/file_system.dart';

/// Whether the app's watchOS project predates the CLI-compiled host module:
/// its runner glue is template source (`Runner/FlutterRunner.swift`) compiled
/// into the app target, so the host module must NOT be built or linked —
/// the duplicate symbols would collide.
bool isLegacyRunnerProject(Directory watchosProjectDir) {
  return watchosProjectDir
      .childDirectory('Runner')
      .childFile('FlutterRunner.swift')
      .existsSync();
}

/// The watch deployment target declared by the app's Xcode project, used as
/// the host module's `-target` OS version so its `.swiftmodule` never claims
/// a NEWER deployment target than the `App.swift` that imports it (Swift
/// rejects such imports). Falls back to the template's floor when the project
/// file is missing or unparseable.
String parseWatchosDeploymentTarget(File pbxproj) {
  const fallback = '26.0';
  if (!pbxproj.existsSync()) {
    return fallback;
  }
  final Match? match = RegExp(
    r'WATCHOS_DEPLOYMENT_TARGET\s*=\s*([0-9.]+)\s*;',
  ).firstMatch(pbxproj.readAsStringSync());
  return match?.group(1) ?? fallback;
}

/// The host module's Swift sources: every `.swift` in the CLI's `host/`
/// directory, sorted for a deterministic compile.
List<String> collectHostModuleSources(Directory hostDir) {
  final List<String> sources = hostDir
      .listSync()
      .whereType<File>()
      .map((File f) => f.path)
      .where((String p) => p.endsWith('.swift'))
      .toList();
  sources.sort();
  return sources;
}

/// The `swiftc` command line that compiles the host module for one
/// architecture: emits the `.swiftmodule` (what `import FlutterWatchOS`
/// resolves) and the object file that becomes the linked archive.
List<String> hostModuleSwiftcArgs({
  required String sdkName,
  required bool simulator,
  required String arch,
  required String deploymentTarget,
  required String moduleOutputPath,
  required String objectOutputPath,
  required String cModuleSearchPath,
  required List<String> sources,
}) {
  final suffix = simulator ? '-simulator' : '';
  return <String>[
    'xcrun',
    '-sdk',
    sdkName,
    'swiftc',
    '-target',
    '$arch-apple-watchos$deploymentTarget$suffix',
    '-parse-as-library',
    '-whole-module-optimization',
    '-module-name',
    'FlutterWatchOS',
    '-emit-module-path',
    moduleOutputPath,
    '-emit-object',
    '-o',
    objectOutputPath,
    // Resolves the FlutterWatchOSHostC clang module (module.modulemap +
    // flutter_watchos_host.h, staged into Flutter/ before this runs).
    '-I',
    cModuleSearchPath,
    ...sources,
  ];
}

/// The `.swiftmodule` file name Swift expects for a triple: arch + platform,
/// no OS version (e.g. `arm64-apple-watchos-simulator.swiftmodule`).
String swiftmoduleFileName({required String arch, required bool simulator}) {
  return simulator
      ? '$arch-apple-watchos-simulator.swiftmodule'
      : '$arch-apple-watchos.swiftmodule';
}
