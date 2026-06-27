// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'watchos_ffi_bindings.dart';
import 'watchos_info_platform.dart' as platform;

/// Fallback bindings for platforms where native watchOS symbols are not
/// linked (Web, Android, Linux, Windows).
class _UnsupportedPlatformBindings extends WatchOSNativeBindings {
  _UnsupportedPlatformBindings() : super.forTesting();

  @override
  bool get isWatchOS => false;
  @override
  String get systemVersion => '';
  @override
  String get deviceModel => '';
  @override
  String get machineId => '';
  @override
  bool get isSimulator => false;
  @override
  int get screenWidth => 0;
  @override
  int get screenHeight => 0;
  @override
  double get screenScale => 0.0;
  @override
  void playHaptic(int type) {}
}

/// Provides runtime information about the watchOS platform.
///
/// All properties are synchronous static getters powered by dart:ffi,
/// calling directly into native C functions with zero async overhead.
///
/// On non-Apple platforms (Android, Linux, Windows, Web), all properties
/// return safe defaults ([isWatchOS] returns `false`, strings return `''`,
/// etc.) without attempting FFI symbol lookups.
///
/// Example:
/// ```dart
/// if (WatchOSInfo.isWatchOS) {
///   print('watchOS version: ${WatchOSInfo.watchOSVersion}');
///   print('Device model: ${WatchOSInfo.deviceModel}');
///   print('Screen: ${WatchOSInfo.screenResolution} @${WatchOSInfo.screenScale}x');
/// }
/// ```
class WatchOSInfo {
  WatchOSInfo._();

  static WatchOSNativeBindings? _bindings;

  /// Override the native bindings for testing.
  @visibleForTesting
  static set bindingsOverride(WatchOSNativeBindings? bindings) {
    _bindings = bindings;
  }

  static WatchOSNativeBindings get _native {
    if (_bindings == null) {
      // Only attempt FFI symbol lookup on Apple platforms where the native
      // watchOS library is linked. platform.isApple returns false on Web at
      // compile time via conditional imports, so no dart:io usage reaches the
      // Web compiler.
      if (platform.isApple) {
        _bindings = WatchOSNativeBindings();
      } else {
        _bindings = _UnsupportedPlatformBindings();
      }
    }
    return _bindings!;
  }

  /// Whether the app is running on watchOS (compiled with TARGET_OS_WATCH).
  ///
  /// Returns `false` on iOS, macOS, or any non-watchOS platform.
  static bool get isWatchOS => _native.isWatchOS;

  /// The watchOS version string (e.g., "11.0").
  static String get watchOSVersion => _native.systemVersion;

  /// The device model (e.g., "Apple Watch").
  static String get deviceModel => _native.deviceModel;

  /// The machine identifier (e.g., "Watch7,1").
  static String get machineId => _native.machineId;

  /// Whether the app is running in the watchOS Simulator.
  static bool get isSimulator => _native.isSimulator;

  /// The native screen width in pixels.
  static int get screenWidth => _native.screenWidth;

  /// The native screen height in pixels.
  static int get screenHeight => _native.screenHeight;

  /// The screen scale factor (e.g., 2.0).
  static double get screenScale => _native.screenScale;

  /// The screen resolution as a string (e.g., "396x484").
  static String get screenResolution => _native.screenResolution;
}
