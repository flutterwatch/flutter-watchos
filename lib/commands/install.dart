// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/commands/install.dart';

import 'launch_checks.dart';

/// `install`: stock's command, which first refuses an explicit `--flavor`
/// for a watch target, since the watch build has no flavors.
///
/// Its name and options are stock's, so the command list does not change.
class WatchosInstallCommand extends InstallCommand {
  /// The `install` command.
  WatchosInstallCommand({required super.verboseHelp});

  @override
  Future<void> validateCommand() async {
    await refuseFlavorForWatch(this, noDeviceMessage: 'No target device found');
    return super.validateCommand();
  }
}
