// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/project.dart';

/// Represents the watchOS sub-project within a Flutter project.
///
/// On disk this is the `watchos/` directory, which contains the iOS host
/// container Xcode project (`ITSWatchOnlyContainer`) plus the embedded
/// `Watch/Runner.app` watch app — see [build_targets/application.dart] for the
/// packaging model.
class WatchosProject {
  WatchosProject.fromFlutter(this.parent);

  final FlutterProject parent;

  String get pluginConfigKey => 'watchos';

  Directory get managedDirectory => _directory.childDirectory('flutter');

  Directory get pluginSymlinkDirectory => _directory
      .childDirectory('flutter')
      .childDirectory('ephemeral')
      .childDirectory('.symlinks')
      .childDirectory('plugins');

  bool existsSync() => _directory.existsSync();

  Directory get _directory => parent.directory.childDirectory('watchos');

  /// Ensures that all watchOS-specific files and properties are ready.
  Future<void> ensureReadyForPlatformSpecificTooling() async {
    if (!parent.directory.existsSync() || parent.hasExampleApp || parent.isPlugin) {
      return;
    }
    _directory.createSync(recursive: true);
  }
}
