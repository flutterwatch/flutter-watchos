// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'watchos_ffi_bindings.dart';
import 'watchos_info_platform.dart' as platform;

/// Controls the watchOS system status bar — the clock the system draws over
/// every app.
///
/// By default the time stays **visible**, matching the watchOS Human
/// Interface Guidelines: users expect to see the time on their watch. An
/// immersive app (a game, media playback, a full-bleed UI) can request it
/// hidden:
///
/// ```dart
/// import 'package:flutter_watchos/flutter_watchos.dart';
///
/// WatchStatusBar.hidden = true;   // immersive moment
/// WatchStatusBar.hidden = false;  // back to the system default
/// ```
///
/// watchOS offers no way to *reposition* the clock — it is fixed by the
/// system. An app that wants the time in a custom place hides the system one
/// and renders its own clock widget in Flutter.
///
/// On non-watchOS platforms this is a safe no-op ([hidden] reads `false`).
abstract final class WatchStatusBar {
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

  /// Whether the app has requested the system time hidden.
  static bool get hidden => platform.isApple && _native.statusBarHidden;

  /// Requests the system time hidden (`true`) or shown (`false`, default).
  ///
  /// The watch host applies the change on the next rendered frame.
  static set hidden(bool value) {
    if (!platform.isApple) return;
    _native.statusBarHidden = value;
  }
}
