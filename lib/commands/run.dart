// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/commands/run.dart';
import 'package:flutter_tools/src/device.dart';
import 'package:flutter_tools/src/project.dart';

import '../watchos_cache.dart';
import '../watchos_mode_guidance.dart';
import '../watchos_plugins.dart';
import 'launch_checks.dart';
import 'port_help.dart';

class WatchosRunCommand extends RunCommand with WatchosRequiredArtifacts, UnusedPortHelp {
  WatchosRunCommand({required super.verboseHelp});

  @override
  Future<void> validateCommand() async {
    await refuseFlavorForWatch(this);
    final FlutterProject project = FlutterProject.current();
    await ensureReadyForWatchosTooling(project);
    await super.validateCommand();
    // super found the target devices; a watch that cannot run the mode stops
    // here, before anything is built.
    final List<Device> targets = devices ?? const <Device>[];
    throwIfWatchCannotRunMode(
      command: WatchosModeCommand.run,
      mode: getBuildMode(),
      devices: targets,
    );
    warnIfWatchIgnoresDefaultFlavor(
      cliFlavor: stringArg('flavor'),
      defaultFlavor: project.manifest.defaultFlavor,
      devices: targets,
    );
  }

  // Let the base RunCommand.runCommand() handle everything:
  // 1. Creates FlutterDevice wrappers around our WatchosDevice
  // 2. Creates HotRunner (debug) or ColdRunner (release)
  // 3. HotRunner calls WatchosDevice.startApp() which builds, installs, launches
  // 4. WatchosDevice.startApp() discovers VM service URI via ProtocolDiscovery
  // 5. HotRunner connects to VM service → enables DevTools + hot reload
  // 6. TerminalHandler provides interactive terminal (r/R/d/q)
}
