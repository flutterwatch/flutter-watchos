// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/commands/clean.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/project.dart';
import 'package:flutter_tools/src/runner/flutter_command.dart';

class WatchosCleanCommand extends CleanCommand {
  WatchosCleanCommand({required super.verbose});

  @override
  Future<FlutterCommandResult> runCommand() async {
    // Run standard Flutter clean first (removes build/, .dart_tool/, etc.)
    final FlutterCommandResult result = await super.runCommand();

    // Clean watchOS-specific build artifacts
    final FlutterProject project = FlutterProject.current();
    final Directory watchosDir = project.directory.childDirectory('watchos');

    if (watchosDir.existsSync()) {
      _cleanDirectory(watchosDir, 'Pods');
      _cleanDirectory(watchosDir, 'Flutter/Flutter.framework');
      _cleanDirectory(watchosDir, 'Flutter/App.framework');
      _cleanDirectory(watchosDir, 'Flutter/flutter_assets');
      _cleanFile(watchosDir, 'Flutter/Generated.xcconfig');
      _cleanFile(watchosDir, 'Podfile.lock');
      _cleanFile(watchosDir, '.symlinks');

      // Remove GeneratedPluginRegistrant (regenerated at build time)
      _cleanFile(watchosDir, 'Flutter/GeneratedPluginRegistrant.swift');

      globals.logger.printStatus('Cleaned watchOS build artifacts.');
    }

    // Clean watchOS xcodebuild output
    final Directory watchosBuildDir = project.directory
        .childDirectory('build')
        .childDirectory('watchos');
    if (watchosBuildDir.existsSync()) {
      watchosBuildDir.deleteSync(recursive: true);
      globals.logger.printStatus('Removed build/watchos/');
    }

    return result;
  }

  void _cleanDirectory(Directory parent, String relativePath) {
    final Directory dir = parent.fileSystem.directory(
      parent.fileSystem.path.join(parent.path, relativePath),
    );
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
      globals.logger.printTrace('Removed ${dir.path}');
    }
  }

  void _cleanFile(Directory parent, String relativePath) {
    final File file = parent.fileSystem.file(
      parent.fileSystem.path.join(parent.path, relativePath),
    );
    if (file.existsSync()) {
      file.deleteSync();
      globals.logger.printTrace('Removed ${file.path}');
    }
  }
}
