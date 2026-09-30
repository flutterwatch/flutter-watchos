// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/device.dart';

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
