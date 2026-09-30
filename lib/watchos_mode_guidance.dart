// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// The one source of the build-mode guidance: which build modes a watch
/// target runs, and what a command says when asked for one it does not.
///
/// The watchOS Simulator engine is JIT-only, so the Simulator runs debug
/// only. A physical watch has no JIT engine (the watchOS device SDK removes
/// the Mach APIs the Dart JIT VM relies on), so it runs profile and release
/// only.
///
/// Every command line in a refusal is a bare command, alone on its line and
/// ready to paste: no `#` comment, no parentheses, nothing after its last
/// argument. What it is for is in the sentence above it.
library;

import 'package:flutter_tools/src/build_info.dart';

/// A command that refuses a build mode its target cannot run.
enum WatchosModeCommand {
  /// `build watchos`.
  build,

  /// `run`.
  run,

  /// `drive`.
  drive,

  /// `attach`.
  attach,
}

/// Whether a watch target runs [mode]: the Simulator ([simulator] true)
/// runs debug only, a physical watch profile and release only.
bool watchosTargetRunsMode(BuildMode mode, {required bool simulator}) =>
    simulator ? mode == BuildMode.debug : mode == BuildMode.profile || mode == BuildMode.release;

/// What [command] says when asked for [mode] on a Simulator ([simulator]
/// true) or a physical watch, or null when that target runs [mode].
///
/// For `build watchos`, [simulator] is the `--simulator` flag, and [mode] is
/// the mode the build would use. For `run`, `drive` and `attach` it is the
/// target device, and [deviceId] its id; the guidance names it in `-d`.
String? watchosModeRefusal({
  required WatchosModeCommand command,
  required BuildMode mode,
  required bool simulator,
  String deviceId = '<device>',
}) {
  if (watchosTargetRunsMode(mode, simulator: simulator)) {
    return null;
  }
  return simulator
      ? _simulatorRefusal(command, mode, deviceId)
      : _watchRefusal(command, mode, deviceId);
}

String _simulatorRefusal(WatchosModeCommand command, BuildMode mode, String deviceId) {
  final String flag = _flag(mode);
  if (command == WatchosModeCommand.build) {
    return '$flag is not supported with --simulator: the watchOS Simulator '
        'engine is JIT-only, so Simulator builds are always debug. AOT '
        '(profile and release) builds target a physical watch.\n'
        '$_buildChoices';
  }
  final reason =
      '$flag is not supported on the watchOS Simulator: its engine is '
      'JIT-only, so apps on the Simulator always run in debug. AOT (profile '
      'and release) apps run on a physical watch.';
  final String verb = command.name;
  if (command == WatchosModeCommand.attach) {
    return '$reason\n'
        'To attach in debug on this Simulator:\n'
        '  flutter-watchos attach -d $deviceId';
  }
  // A watch has no JIT engine either, so --jit-release points to --release.
  final watchFlag = mode == BuildMode.jitRelease ? '--release' : flag;
  return '$reason\n'
      'To $verb in debug on this Simulator:\n'
      '  flutter-watchos $verb -d $deviceId\n'
      'To $verb with $watchFlag on a physical watch:\n'
      '  flutter-watchos $verb -d <watch> $watchFlag';
}

String _watchRefusal(WatchosModeCommand command, BuildMode mode, String deviceId) {
  final String what = mode == BuildMode.debug ? 'Debug mode' : _flag(mode);
  final reason =
      '$what is not supported on a physical Apple Watch: it needs a JIT '
      'engine, which cannot be built for watchOS (the device SDK removes the '
      'Mach APIs the Dart JIT VM relies on).';
  switch (command) {
    case WatchosModeCommand.build:
      return '$reason\n$_buildChoices';
    case WatchosModeCommand.attach:
      return '$reason\n'
          'To start the app on this watch with DevTools:\n'
          '  flutter-watchos run -d $deviceId --profile\n'
          'For hot reload, attach on the watchOS Simulator, where debug works:\n'
          '  flutter-watchos attach -d <simulator>';
    case WatchosModeCommand.run:
    case WatchosModeCommand.drive:
      final String verb = command.name;
      return '$reason\n'
          'To $verb on this watch with logging and DevTools:\n'
          '  flutter-watchos $verb -d $deviceId --profile\n'
          'To $verb on this watch at full speed:\n'
          '  flutter-watchos $verb -d $deviceId --release\n'
          'For hot reload and fast iteration, use the watchOS Simulator, where '
          'debug works:\n'
          '  flutter-watchos $verb -d <simulator>';
  }
}

/// The command-line flag for [mode]: `--jit-release`, where [BuildMode.cliName]
/// gives `jit_release`.
String _flag(BuildMode mode) => '--${mode.cliName.replaceAll('_', '-')}';

/// The three `build watchos` commands, each with what it is for.
const String _buildChoices =
    'To build for the Simulator, in debug:\n'
    '  flutter-watchos build watchos --simulator\n'
    'To build for a physical watch, with logging and DevTools:\n'
    '  flutter-watchos build watchos --profile\n'
    'To build for a physical watch, for the App Store:\n'
    '  flutter-watchos build watchos --release';
