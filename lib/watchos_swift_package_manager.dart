// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:meta/meta.dart';

/// A watchOS plugin whose `watchos/` folder holds a Swift package
/// (`Package.swift`), as `discoverWatchosSpmPlugins` finds it.
///
/// The watch build compiles the plugin's C and Objective-C sources under
/// [packagePath] into the archive it force-loads into the Runner binary. When
/// the package depends on an external native SDK, `xcodebuild -scheme <name>`
/// compiles the package instead, for the active watch SDK, and its objects are
/// force-loaded too (see `build_targets/application.dart`).
@immutable
class WatchosSpmPlugin {
  /// A plugin whose Swift package is named [name] and lives in [packagePath].
  /// [libraryName] defaults to [name] with hyphens for underscores.
  WatchosSpmPlugin({required this.name, required this.packagePath, String? libraryName})
    : libraryName = libraryName ?? name.replaceAll('_', '-');

  /// The Swift package's name, from its `Package(name:)`, or the plugin's
  /// package name when the manifest does not say.
  final String name;

  /// The directory that holds the plugin's `Package.swift`.
  final String packagePath;

  /// The package's library product. Defaults to the hyphenated package name
  /// (the porter convention).
  final String libraryName;
}
