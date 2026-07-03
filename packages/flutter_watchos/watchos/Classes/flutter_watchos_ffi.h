// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef FLUTTER_WATCHOS_FFI_H
#define FLUTTER_WATCHOS_FFI_H

#include <stdbool.h>
#include <stdint.h>

// Each exported symbol is marked `used` + default-visibility so it survives
// the linker's `-dead_strip` and lands in the executable's dynamic symbol
// table, where `DynamicLibrary.process()` / dlsym can resolve it. The watch
// app links this archive statically, so without `used` the linker would drop
// these (FFI has no compile-time caller). The CLI additionally emits a forced
// reference for each symbol listed under `flutter.plugin.platforms.watchos.
// ffiSymbols` in pubspec.yaml — see the "FFI plugins over SPM" notes.
#define FLUTTER_WATCHOS_EXPORT \
  __attribute__((visibility("default"))) __attribute__((used))

/// Returns true if running on watchOS (compiled with TARGET_OS_WATCH).
FLUTTER_WATCHOS_EXPORT bool flutter_watchos_is_watchos(void);

/// Returns the OS version string (e.g., "11.0"). Caller must NOT free.
FLUTTER_WATCHOS_EXPORT const char* flutter_watchos_system_version(void);

/// Returns the device model (e.g., "Apple Watch"). Caller must NOT free.
FLUTTER_WATCHOS_EXPORT const char* flutter_watchos_device_model(void);

/// Returns the machine identifier (e.g., "Watch7,1"). Caller must NOT free.
FLUTTER_WATCHOS_EXPORT const char* flutter_watchos_machine_id(void);

/// Returns true if running in the simulator.
FLUTTER_WATCHOS_EXPORT bool flutter_watchos_is_simulator(void);


/// Returns the native screen width in pixels.
FLUTTER_WATCHOS_EXPORT int32_t flutter_watchos_screen_width(void);

/// Returns the native screen height in pixels.
FLUTTER_WATCHOS_EXPORT int32_t flutter_watchos_screen_height(void);

/// Returns the screen scale factor (e.g., 2.0).
FLUTTER_WATCHOS_EXPORT float flutter_watchos_screen_scale(void);

/// Plays a Taptic Engine haptic. `type` maps to `WKHapticType` raw values
/// (0=notification, 1=directionUp, 2=directionDown, 3=success, 4=failure,
/// 5=retry, 6=start, 7=stop, 8=click). No-op in the simulator.
FLUTTER_WATCHOS_EXPORT void flutter_watchos_play_haptic(int32_t type);

// --- System status bar (the time overlay) ----------------------------------
// watchOS draws the clock over every app. By default it stays visible (the
// HIG expectation); an immersive app (game, media, full-bleed UI) can request
// it hidden via WatchStatusBar. Dart (FFI/UI thread) sets the flag; the watch
// host (Swift, main thread) reads it and applies/removes the hiding. There is
// no system API to reposition the clock — an app wanting a custom placement
// hides the system one and draws its own.

/// Whether the app requests the system status bar (time) hidden.
FLUTTER_WATCHOS_EXPORT bool flutter_watchos_status_bar_hidden(void);

/// Sets the status-bar-hidden request. Called from Dart (WatchStatusBar).
FLUTTER_WATCHOS_EXPORT void flutter_watchos_set_status_bar_hidden(bool hidden);

// --- Raw Digital Crown bridge ---------------------------------------------
// By default the watch host forwards Digital Crown rotation to Flutter as
// trackpad scroll. An app that wants the crown as a direct input (a game, a
// value picker, a custom gauge) switches to "raw" mode via WatchCrown: the host
// then stops scrolling and pushes each rotation sample here, and Dart drains it.
//
// `mode`/`push` are called from the watch host (Swift, main thread); `set_mode`/
// `consume` are called from Dart (FFI/UI thread). A lock guards the shared state.

/// Crown routing mode: 0 = scroll (default), 1 = raw/exclusive. Read by the
/// watch host on each crown sample to decide whether to scroll or push.
FLUTTER_WATCHOS_EXPORT int32_t flutter_watchos_crown_mode(void);

/// Sets the crown routing mode (0 = scroll, 1 = raw). Called from Dart;
/// switching back to scroll also drops any unconsumed rotation.
FLUTTER_WATCHOS_EXPORT void flutter_watchos_crown_set_mode(int32_t mode);

/// Accumulates one raw crown rotation sample (host → here). `delta` is the
/// SwiftUI crown-binding change since the previous sample, in abstract crown
/// units (sign = direction, magnitude grows with turn speed).
FLUTTER_WATCHOS_EXPORT void flutter_watchos_crown_push_delta(double delta);

/// Returns the rotation accumulated since the last call and resets it to 0
/// (0 when idle). Called from Dart per frame / per game tick.
FLUTTER_WATCHOS_EXPORT double flutter_watchos_crown_consume_delta(void);

// --- Crown scroll options (native parity) -----------------------------------
// SwiftUI gives native developers `.digitalCrownRotation(sensitivity:)` and
// `isHapticFeedbackEnabled`. These flags give Dart the same knobs for crown
// scroll mode: Dart sets them (FFI/UI thread) via WatchCrownScrolling, and
// they are read per crown sample on the main thread. Raw mode is unaffected
// (raw consumers get the unscaled delta).

/// Scroll-sensitivity multiplier applied to each crown delta
/// (1.0 = default/high, 0.5 ≈ medium, 0.25 ≈ low).
FLUTTER_WATCHOS_EXPORT double flutter_watchos_crown_scroll_multiplier(void);

/// Sets the scroll-sensitivity multiplier. Non-positive values are ignored.
FLUTTER_WATCHOS_EXPORT void flutter_watchos_crown_set_scroll_multiplier(
    double multiplier);

/// Whether the crown detent-click haptic plays during scroll (1 = on, default).
FLUTTER_WATCHOS_EXPORT int32_t flutter_watchos_crown_detent_haptics(void);

/// Enables/disables the crown detent-click haptic (0 = off, 1 = on).
FLUTTER_WATCHOS_EXPORT void flutter_watchos_crown_set_detent_haptics(
    int32_t enabled);

#endif /* FLUTTER_WATCHOS_FFI_H */
