// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/commands/drive.dart';
import 'package:flutter_tools/src/project.dart';

import '../watchos_cache.dart';
import '../watchos_plugins.dart';

class WatchosDriveCommand extends DriveCommand with WatchosRequiredArtifacts {
  WatchosDriveCommand({
    required super.verboseHelp,
    required super.fileSystem,
    required super.logger,
    required super.platform,
    required super.signals,
    required super.terminal,
    required super.outputPreferences,
  });

  @override
  Future<void> validateCommand() async {
    final FlutterProject project = FlutterProject.current();
    await ensureReadyForWatchosTooling(project);
    return super.validateCommand();
  }
}
