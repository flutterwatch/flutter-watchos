// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/commands/attach.dart';
import 'package:flutter_tools/src/device.dart';
import 'package:flutter_tools/src/project.dart';

import '../watchos_device.dart';
import '../watchos_mode_guidance.dart';
import '../watchos_plugins.dart';
import 'launch_checks.dart';
import 'port_help.dart';

class WatchosAttachCommand extends AttachCommand with UnusedPortHelp {
  WatchosAttachCommand({
    required super.verboseHelp,
    required super.stdio,
    required super.logger,
    required super.terminal,
    required super.signals,
    required super.platform,
    required super.processInfo,
    required super.fileSystem,
  });

  @override
  Future<void> validateCommand() async {
    final FlutterProject project = FlutterProject.current();
    await ensureReadyForWatchosTooling(project);
    await super.validateCommand();
    // super found the target device, or stopped; this lookup is cached.
    final Device? device = await findTargetDevice();
    throwIfShutDownSimulator(device, reason: 'no app is running on it to attach to');
    if (device is WatchosDevice && !device.isSimulator) {
      // attach cannot find an app on a physical watch by itself: the watch's
      // log, which carries the VM Service URI, reaches the tool only through
      // the run that started the app. Given a URL or a port, attach connects
      // as stock does, in any mode.
      if (debugUri == null && debugPort == null) {
        throwToolExit(watchosAttachWatchRefusal(deviceId: device.id));
      }
      return;
    }
    throwIfWatchCannotRunMode(
      command: WatchosModeCommand.attach,
      mode: getBuildMode(),
      devices: <Device>[?device],
    );
  }
}
