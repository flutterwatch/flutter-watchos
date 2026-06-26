// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/commands/attach.dart';
import 'package:flutter_tools/src/project.dart';

import '../watchos_plugins.dart';

class WatchosAttachCommand extends AttachCommand {
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
    return super.validateCommand();
  }
}
