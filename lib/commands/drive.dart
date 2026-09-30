// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/commands/drive.dart';
import 'package:flutter_tools/src/device.dart';
import 'package:flutter_tools/src/project.dart';

import '../watchos_cache.dart';
import '../watchos_mode_guidance.dart';
import '../watchos_plugins.dart';
import 'launch_checks.dart';

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
    await super.validateCommand();
    // Stock drive finds its device only in runCommand. Find it here, with the
    // same lookup, so that a watch that cannot run the mode stops before
    // anything is built; the device list is cached for runCommand.
    final Device? device = await targetedDevice;
    if (device == null) {
      throwToolExit(null);
    }
    throwIfWatchCannotRunMode(
      command: WatchosModeCommand.drive,
      mode: getBuildMode(),
      devices: <Device>[device],
    );
  }
}
