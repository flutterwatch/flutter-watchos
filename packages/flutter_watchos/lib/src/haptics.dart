// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'watchos_ffi_bindings.dart';
import 'watchos_info_platform.dart' as platform;

/// A Taptic Engine haptic pattern.
///
/// Raw values match Apple's `WKHapticType`, so they can be passed straight
/// across FFI without a translation table.
enum WatchHapticType {
  /// A generic notification feel.
  notification(0),

  /// Crown/scroll moved up by one detent.
  directionUp(1),

  /// Crown/scroll moved down by one detent.
  directionDown(2),

  /// A task completed successfully.
  success(3),

  /// A task failed.
  failure(4),

  /// A retriable failure.
  retry(5),

  /// The start of an event (e.g., a timer).
  start(6),

  /// The end of an event.
  stop(7),

  /// A light click, e.g. for selection changes.
  click(8);

  const WatchHapticType(this.rawValue);

  /// The underlying `WKHapticType` raw value.
  final int rawValue;
}

/// Plays haptic feedback on the Apple Watch Taptic Engine.
///
/// This is a thin, synchronous FFI wrapper over
/// `WKInterfaceDevice.playHaptic`. On non-watchOS platforms (and in the
/// simulator, which has no Taptic Engine) it is a safe no-op.
///
/// ```dart
/// import 'package:flutter_watchos/flutter_watchos.dart';
///
/// WatchHaptics.play(WatchHapticType.success);
/// ```
abstract final class WatchHaptics {
  static WatchOSNativeBindings? _bindings;

  static WatchOSNativeBindings get _native {
    if (_bindings == null) {
      if (platform.isApple) {
        _bindings = WatchOSNativeBindings();
      } else {
        _bindings = WatchOSNativeBindings.forTesting();
      }
    }
    return _bindings!;
  }

  /// Plays the given haptic [type]. No-op off-device.
  static void play(WatchHapticType type) {
    if (!platform.isApple) return;
    _native.playHaptic(type.rawValue);
  }

  /// A convenience for the most common selection-feedback tick.
  static void click() => play(WatchHapticType.click);
}
