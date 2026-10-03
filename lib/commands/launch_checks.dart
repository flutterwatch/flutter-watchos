// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/device.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/runner/flutter_command.dart';

import '../watchos_device.dart';
import '../watchos_mode_guidance.dart';

/// Refuses, with [watchosModeRefusal]'s guidance, when a watch among
/// [devices] cannot run [mode].
///
/// `run`, `drive` and `attach` call it from `validateCommand`, once they have
/// found their target devices: a tool exit from there prints no stack trace,
/// unlike one from inside the resident runner. A device that is not a watch,
/// such as the iPhone of a companion project, is left to stock.
void throwIfWatchCannotRunMode({
  required WatchosModeCommand command,
  required BuildMode mode,
  required Iterable<Device> devices,
}) {
  for (final WatchosDevice device in devices.whereType<WatchosDevice>()) {
    final String? refusal = watchosModeRefusal(
      command: command,
      mode: mode,
      simulator: device.isSimulator,
      deviceId: device.id,
    );
    if (refusal != null) {
      throwToolExit(refusal);
    }
  }
}

/// What a command prints, before it exits, when `-d` names a watch Simulator
/// by its UDID and that Simulator is shut down.
///
/// [reason] says what the command cannot do there; `run`, which boots the
/// Simulator, is offered alone on its line, ready to paste.
String watchosShutDownSimulatorGuidance(WatchosDevice simulator, {required String reason}) =>
    '${simulator.name} (${simulator.id}) is shut down, so $reason. run boots it:\n'
    '  flutter-watchos run -d ${simulator.id}';

/// Stops with [watchosShutDownSimulatorGuidance] when [device] is a watch
/// Simulator that is shut down.
///
/// Discovery lists a shut-down Simulator only when `-d` names its exact
/// UDID, so that `run` can boot it. `attach`, `logs`, `install` and
/// `screenshot` call this once they have found their device: on a Simulator
/// that is not booted they would otherwise wait for an app that cannot have
/// started, or stop on simctl's own error.
void throwIfShutDownSimulator(Device? device, {required String reason}) {
  if (device is WatchosDevice && device.isShutDown) {
    throwToolExit(watchosShutDownSimulatorGuidance(device, reason: reason));
  }
}

/// What a command does about a flavor, from [watchosFlavorCheck].
enum WatchosFlavorCheck {
  /// Nothing: no flavor, or no watch target.
  none,

  /// Stop: `--flavor` was given for a watch target.
  refuse,

  /// Warn and go on: only the pubspec's `default-flavor` names a flavor, and
  /// the watch build ignores it.
  warn,
}

/// The flavor decision for `run`, `drive`, `install` and `build watchos`.
///
/// [cliFlavor] is the `--flavor` value, [defaultFlavor] the pubspec's
/// `default-flavor`, and [watchTarget] whether a target is a watch. A watch
/// build uses no flavor, so an explicit one is refused; a default flavor
/// usually belongs to the iPhone app of a shared project, so it only warns.
/// A target that is not a watch is left to stock.
WatchosFlavorCheck watchosFlavorCheck({
  required String? cliFlavor,
  required String? defaultFlavor,
  required bool watchTarget,
}) {
  if (!watchTarget) {
    return WatchosFlavorCheck.none;
  }
  if (cliFlavor != null) {
    return WatchosFlavorCheck.refuse;
  }
  return defaultFlavor != null ? WatchosFlavorCheck.warn : WatchosFlavorCheck.none;
}

/// What a command says when `--flavor` is given for a watch target.
const String kWatchosFlavorRefusal =
    '--flavor is not supported for an Apple Watch target: flutter-watchos '
    'builds the watch app without flavors.\n'
    'Run the command again without --flavor.';

/// The warning for a pubspec `default-flavor` [flavor] on a watch build.
String watchosDefaultFlavorWarning(String flavor) =>
    'The watch build ignores default-flavor "$flavor" from pubspec.yaml: '
    'flutter-watchos builds the watch app without flavors. appFlavor still '
    'returns "$flavor".';

/// Refuses an explicit `--flavor` when a target of [command] is a watch.
///
/// `run`, `drive` and `install` call it first in `validateCommand`, before
/// the tooling check and before stock's checks, so nothing is built or
/// installed and stock's flavor warning is never printed next to the error.
/// Only when `--flavor` is given, it finds the targets with the command's
/// own lookup, which stock's later lookup reuses: the device list is cached,
/// and a device picked from a prompt is remembered. When no target is found,
/// it stops as stock would, with [noDeviceMessage].
Future<void> refuseFlavorForWatch(FlutterCommand command, {String? noDeviceMessage}) async {
  final String? cliFlavor = command.argParser.options.containsKey('flavor')
      ? command.stringArg('flavor')
      : null;
  if (cliFlavor == null) {
    return;
  }
  final List<Device>? devices = await command.findAllTargetDevices();
  if (devices == null) {
    throwToolExit(noDeviceMessage);
  }
  final WatchosFlavorCheck check = watchosFlavorCheck(
    cliFlavor: cliFlavor,
    defaultFlavor: null,
    watchTarget: devices.any((Device device) => device is WatchosDevice),
  );
  if (check == WatchosFlavorCheck.refuse) {
    throwToolExit(kWatchosFlavorRefusal);
  }
}

/// Prints [watchosDefaultFlavorWarning] once when [defaultFlavor] is set, no
/// `--flavor` ([cliFlavor]) was given, and a target among [devices] is a
/// watch.
void warnIfWatchIgnoresDefaultFlavor({
  required String? cliFlavor,
  required String? defaultFlavor,
  required Iterable<Device> devices,
}) {
  final WatchosFlavorCheck check = watchosFlavorCheck(
    cliFlavor: cliFlavor,
    defaultFlavor: defaultFlavor,
    watchTarget: devices.any((Device device) => device is WatchosDevice),
  );
  if (check == WatchosFlavorCheck.warn) {
    globals.printWarning(watchosDefaultFlavorWarning(defaultFlavor!));
  }
}
