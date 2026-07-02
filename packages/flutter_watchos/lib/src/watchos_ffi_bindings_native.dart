// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:ffi';
import 'package:ffi/ffi.dart';

/// FFI bindings to the native flutter_watchos C functions.
///
/// On watchOS, the native code is statically linked into the app process, so
/// we use [DynamicLibrary.process()] to look up symbols. The CLI emits a
/// forced reference for each exported symbol (declared under
/// `flutter.plugin.platforms.watchos.ffiSymbols` in pubspec.yaml) so they
/// survive the static link and stay resolvable via dlsym.
///
/// For testing, subclass this and override the getters. Use the
/// [WatchOSNativeBindings.forTesting] named constructor to skip FFI init.
class WatchOSNativeBindings {
  /// Creates bindings that look up native symbols in the current process.
  ///
  /// This will throw if the native library is not loaded (e.g., in unit
  /// tests). For testing, use [WatchOSInfo.bindingsOverride] with a fake.
  WatchOSNativeBindings() : _lib = DynamicLibrary.process();

  /// Constructor for fakes/mocks — skips FFI initialization.
  WatchOSNativeBindings.forTesting() : _lib = null;

  final DynamicLibrary? _lib;

  // Lazy-loaded function pointers.

  late final bool Function() _isWatchOS = _lib!
      .lookupFunction<Bool Function(), bool Function()>(
          'flutter_watchos_is_watchos');

  late final Pointer<Utf8> Function() _systemVersion = _lib!
      .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
          'flutter_watchos_system_version');

  late final Pointer<Utf8> Function() _deviceModel = _lib!
      .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
          'flutter_watchos_device_model');

  late final Pointer<Utf8> Function() _machineId = _lib!
      .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
          'flutter_watchos_machine_id');

  late final bool Function() _isSimulator = _lib!
      .lookupFunction<Bool Function(), bool Function()>(
          'flutter_watchos_is_simulator');

  late final int Function() _screenWidth = _lib!
      .lookupFunction<Int32 Function(), int Function()>(
          'flutter_watchos_screen_width');

  late final int Function() _screenHeight = _lib!
      .lookupFunction<Int32 Function(), int Function()>(
          'flutter_watchos_screen_height');

  late final double Function() _screenScale = _lib!
      .lookupFunction<Float Function(), double Function()>(
          'flutter_watchos_screen_scale');

  late final void Function(int) _playHaptic = _lib!
      .lookupFunction<Void Function(Int32), void Function(int)>(
          'flutter_watchos_play_haptic');

  late final bool Function() _statusBarHidden = _lib!
      .lookupFunction<Bool Function(), bool Function()>(
          'flutter_watchos_status_bar_hidden');

  late final void Function(bool) _setStatusBarHidden = _lib!
      .lookupFunction<Void Function(Bool), void Function(bool)>(
          'flutter_watchos_set_status_bar_hidden');

  late final int Function() _crownMode = _lib!
      .lookupFunction<Int32 Function(), int Function()>(
          'flutter_watchos_crown_mode');

  late final void Function(int) _crownSetMode = _lib!
      .lookupFunction<Void Function(Int32), void Function(int)>(
          'flutter_watchos_crown_set_mode');

  late final double Function() _crownConsumeDelta = _lib!
      .lookupFunction<Double Function(), double Function()>(
          'flutter_watchos_crown_consume_delta');

  // Public API — override these in fakes for testing.

  bool get isWatchOS => _isWatchOS();
  String get systemVersion => _systemVersion().toDartString();
  String get deviceModel => _deviceModel().toDartString();
  String get machineId => _machineId().toDartString();
  bool get isSimulator => _isSimulator();
  int get screenWidth => _screenWidth();
  int get screenHeight => _screenHeight();
  double get screenScale => _screenScale();
  String get screenResolution => '${screenWidth}x$screenHeight';

  /// Plays a Taptic Engine haptic by raw `WKHapticType` value.
  void playHaptic(int type) => _playHaptic(type);

  // --- System status bar (the time overlay) ---
  // Null-safe against [WatchOSNativeBindings.forTesting] (no linked library):
  // reads return the system default (visible), writes are no-ops.

  /// Whether the app has requested the system status bar (time) hidden.
  bool get statusBarHidden => _lib == null ? false : _statusBarHidden();

  /// Requests the system status bar (time) hidden or shown.
  set statusBarHidden(bool hidden) {
    if (_lib != null) _setStatusBarHidden(hidden);
  }

  // --- Raw Digital Crown bridge ---
  // Null-safe against the [WatchOSNativeBindings.forTesting] constructor (no
  // linked library): the crown getters/setter become no-ops returning defaults,
  // so off-watchOS callers don't have to guard.

  /// Current crown routing mode (0 = scroll, 1 = raw/exclusive).
  int get crownMode => _lib == null ? 0 : _crownMode();

  /// Sets the crown routing mode (0 = scroll, 1 = raw/exclusive).
  set crownMode(int mode) {
    if (_lib != null) _crownSetMode(mode);
  }

  /// Drains the crown rotation accumulated since the last call (0 when idle).
  double consumeCrownDelta() => _lib == null ? 0.0 : _crownConsumeDelta();
}
