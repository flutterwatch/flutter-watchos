// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/file.dart';
import 'package:flutter_tools/src/application_package.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/project.dart';

import 'watchos_project.dart';

/// Represents the built watchOS app product.
///
/// The build product is a single independent watch app, `Runner.app`
/// (`WKWatchOnly`), installed and launched directly on the simulator or a
/// paired watch. [bundlePath] returns that app.
class WatchosApp extends ApplicationPackage {
  WatchosApp({required super.id, required this.projectDirectory});

  final Directory projectDirectory;

  @override
  String get name => projectDirectory.basename;

  /// Returns the path to the watch `Runner.app` for the given build mode.
  String bundlePath(BuildMode buildMode, {bool isSimulator = false}) {
    final configuration = (buildMode == BuildMode.debug) ? 'Debug' : 'Release';
    final platformSuffix = isSimulator ? 'watchsimulator' : 'watchos';

    // This matches the SYMROOT set in application.dart (build/watchos).
    return globals.fs.path.join(
      projectDirectory.parent.path,
      'build',
      'watchos',
      '$configuration-$platformSuffix',
      'Runner.app',
    );
  }

  static Future<WatchosApp?> fromWatchosProject(WatchosProject project) async {
    if (!project.existsSync()) {
      return null;
    }

    // Try to find the bundle identifier in the project.pbxproj file.
    final File projectFile = project.parent.directory
        .childDirectory('watchos')
        .childDirectory('Runner.xcodeproj')
        .childFile('project.pbxproj');

    String? bundleId;
    if (projectFile.existsSync()) {
      final String content = projectFile.readAsStringSync();
      final regex = RegExp(r'PRODUCT_BUNDLE_IDENTIFIER\s*=\s*(.*?);');
      final Iterable<Match> matches = regex.allMatches(content);
      if (matches.isNotEmpty) {
        bundleId = matches.first.group(1)?.trim();
        if (bundleId != null &&
            bundleId.length >= 2 &&
            bundleId.startsWith('"') &&
            bundleId.endsWith('"')) {
          bundleId = bundleId.substring(1, bundleId.length - 1);
        }
      }
    }

    return WatchosApp(
      id: bundleId ?? 'com.example.${project.parent.directory.basename}',
      projectDirectory: project.parent.directory.childDirectory('watchos'),
    );
  }
}

class WatchosApplicationPackageFactory extends ApplicationPackageFactory {
  @override
  Future<ApplicationPackage?> getPackageForPlatform(
    TargetPlatform platform, {
    BuildInfo? buildInfo,
    File? applicationBinary,
  }) async {
    final FlutterProject project = FlutterProject.current();
    final watchosProject = WatchosProject.fromFlutter(project);

    if (watchosProject.existsSync()) {
      return WatchosApp.fromWatchosProject(watchosProject);
    }
    return null;
  }
}
