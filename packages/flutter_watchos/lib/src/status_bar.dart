// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/widgets.dart';

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
      if (platform.isWatch) {
        _bindings = WatchOSNativeBindings();
      } else {
        _bindings = WatchOSNativeBindings.forTesting();
      }
    }
    return _bindings!;
  }

  /// Test seam: replaces the native bindings. `null` restores the real ones.
  @visibleForTesting
  static set bindingsOverride(WatchOSNativeBindings? bindings) {
    _bindings = bindings;
  }

  /// Whether the app has requested the system time hidden.
  static bool get hidden => platform.isWatch && _native.statusBarHidden;

  /// Requests the system time hidden (`true`) or shown (`false`, default).
  ///
  /// The watch host applies the change on the next rendered frame.
  static set hidden(bool value) {
    if (!platform.isWatch) return;
    _native.statusBarHidden = value;
  }

  /// The height of the band at the top of the screen that the clock sits in,
  /// in logical pixels, measured from the top of the view.
  ///
  /// Content that starts at the top of the view and must not sit under the
  /// clock starts at least this far down. Below an `AppBar` or inside a
  /// `SafeArea`, content already starts below its ancestor's top edge, so do
  /// not add this height again.
  ///
  /// On a watch this is the top inset watchOS reports, divided by the content
  /// scale, whether the clock is shown or hidden and whichever safe area the
  /// app's `FlutterWatchOSSafeArea` key selects. Off the watch, and on a watch
  /// whose host does not report it, it is the view's top padding, which a
  /// `SafeArea` or an `AppBar` above [context] does not change.
  ///
  /// Calling it makes [context] depend on the ambient `MediaQuery` padding, so
  /// the caller rebuilds when the insets change.
  ///
  /// A list that covers the whole screen and starts its first row below the
  /// clock:
  ///
  /// ```dart
  /// ListView(
  ///   padding: MediaQuery.paddingOf(context).copyWith(
  ///     top: WatchStatusBar.heightOf(context),
  ///   ),
  ///   children: rows,
  /// )
  /// ```
  ///
  /// See https://github.com/flutterwatch/flutter-watchos/blob/main/doc/layout.md.
  static double heightOf(BuildContext context) {
    // Only for the dependency: `View.of` does not rebuild the caller when the
    // view's insets change, and the ambient padding does.
    MediaQuery.paddingOf(context);
    final double reported = _native.clockBandHeight;
    if (reported >= 0) {
      return reported;
    }
    // The view's own padding, as the root MediaQuery holds it: a SafeArea or
    // a Scaffold under an AppBar removes the top from the ambient padding,
    // not from this.
    return MediaQueryData.fromView(View.of(context)).padding.top;
  }
}
