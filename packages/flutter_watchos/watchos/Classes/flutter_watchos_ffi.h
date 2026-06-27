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

#endif /* FLUTTER_WATCHOS_FFI_H */
