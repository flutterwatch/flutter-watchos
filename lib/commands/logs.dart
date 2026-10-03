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
    if (target is WatchosDevice && target.isShutDown) {
      throwToolExit(shutDownSimulatorGuidance(target));
    }
    return super.runCommand();
  }

  /// What `logs -d <UDID>` prints before it exits, for a Simulator that is
  /// shut down: there is no log to read until something boots it.
  static String shutDownSimulatorGuidance(WatchosDevice simulator) =>
      '${simulator.name} (${simulator.id}) is shut down, so it has no logs to show. '
      'run boots it:\n'
      '  flutter-watchos run -d ${simulator.id}';

  /// What `logs -d <watch>` prints for the watch [id] before it exits.
  ///
  /// Each offered command is a bare command, alone on its line and ready to
  /// paste, with what it is for in the sentence above it. The docs are named
  /// by URL: this is printed in the app's directory, where no doc/ folder
  /// exists.
  static String physicalWatchGuidance(String id) =>
      "logs cannot read a physical Apple Watch: a watch app's output reaches "
      'this Mac only through the console of the launch that run opens.\n'
      'To start the app on this watch and stream its logs, with DevTools:\n'
      '  flutter-watchos run -d $id --profile\n'
      'To have the app write its logs into its own container instead, launch it '
      'with --watchos-log-to-file, as $physicalWatchLogsDocUrl describes.';

  /// Where the docs say how a watch app writes its logs into its container.
  static const String physicalWatchLogsDocUrl =
      'https://github.com/flutterwatch/flutter-watchos/blob/main/doc/debug-app.md'
      '#logs-from-a-physical-watch';
}
