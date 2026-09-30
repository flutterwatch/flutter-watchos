// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/commands/logs.dart';
import 'package:flutter_tools/src/device.dart';
import 'package:flutter_tools/src/runner/flutter_command.dart';

import '../watchos_device.dart';

/// Stock `logs`, which refuses a physical Apple Watch with guidance.
///
/// On a watch Simulator it streams the app's unified-log lines, as stock does
/// for an iOS Simulator. A physical watch has no log stream to attach to: its
/// output reaches this Mac only through the console of the launch that `run`
/// opens, so `logs -d <watch>` exits non-zero and says where to look instead
/// (spec 0005 D7 (a)).
class WatchosLogsCommand extends LogsCommand {
  /// Creates the command. [sigint] and [sigterm] end the stream, as in stock.
  WatchosLogsCommand({required super.sigint, required super.sigterm});

  @override
  Future<FlutterCommandResult> runCommand() async {
    final Device? target = device;
    if (target is WatchosDevice && !target.isSimulator) {
      throwToolExit(physicalWatchGuidance(target.id));
    }
    return super.runCommand();
  }

  /// What `logs -d <watch>` prints for the watch [id] before it exits.
  static String physicalWatchGuidance(String id) =>
      "logs cannot read a physical Apple Watch: a watch app's output reaches "
      'this Mac only through the console of the launch that run opens.\n'
      'Use one of:\n'
      "  flutter-watchos run -d $id --profile   # streams the app's logs, with DevTools\n"
      '  launch the app with --watchos-log-to-file, which writes its logs into '
      "the app's container (see doc/debug-app.md, 'Logs from a physical watch')";
}
