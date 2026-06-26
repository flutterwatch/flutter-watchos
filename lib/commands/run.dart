// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/commands/run.dart';
import 'package:flutter_tools/src/project.dart';

import '../watchos_cache.dart';
import '../watchos_plugins.dart';

class WatchosRunCommand extends RunCommand with WatchosRequiredArtifacts {
  WatchosRunCommand({required super.verboseHelp});

  @override
  Future<void> validateCommand() async {
    final FlutterProject project = FlutterProject.current();
    await ensureReadyForWatchosTooling(project);
    return super.validateCommand();
  }

  // Let the base RunCommand.runCommand() handle everything:
  // 1. Creates FlutterDevice wrappers around our WatchosDevice
  // 2. Creates HotRunner (debug) or ColdRunner (release)
  // 3. HotRunner calls WatchosDevice.startApp() which builds, installs, launches
  // 4. WatchosDevice.startApp() discovers VM service URI via ProtocolDiscovery
  // 5. HotRunner connects to VM service → enables DevTools + hot reload
  // 6. TerminalHandler provides interactive terminal (r/R/d/q)
}
