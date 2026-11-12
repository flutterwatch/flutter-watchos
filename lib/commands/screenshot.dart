// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/commands/screenshot.dart';

import 'launch_checks.dart';

/// `screenshot`: stock's command, which stops on a watch Simulator that is
/// shut down, since it has no screen to capture.
///
/// Its name and options are stock's, so the command list does not change.
/// A booted Simulator and a paired watch take the screenshot through
/// `WatchosDevice.takeScreenshot`, as stock's command calls it.
class WatchosScreenshotCommand extends ScreenshotCommand {
  /// The `screenshot` command, which reads its file system and the rest of
  /// the tool's services from [toolContext].
  WatchosScreenshotCommand({required super.toolContext});

  @override
  Future<void> validateCommand() async {
    await super.validateCommand();
    // Stock found the target device before this, for a device screenshot.
    throwIfShutDownSimulator(device, reason: 'it has no screen to capture');
  }
}
