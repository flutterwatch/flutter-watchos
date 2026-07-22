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

  late final bool Function() _alwaysOnActive = _lib!
      .lookupFunction<Bool Function(), bool Function()>(
          'flutter_watchos_always_on_active');

  late final bool Function() _alwaysOnSupported = _lib!
      .lookupFunction<Bool Function(), bool Function()>(
          'flutter_watchos_always_on_supported');

  late final int Function() _crownMode = _lib!
      .lookupFunction<Int32 Function(), int Function()>(
          'flutter_watchos_crown_mode');

  late final void Function(int) _crownSetMode = _lib!
      .lookupFunction<Void Function(Int32), void Function(int)>(
          'flutter_watchos_crown_set_mode');

  late final double Function() _crownConsumeDelta = _lib!
      .lookupFunction<Double Function(), double Function()>(
          'flutter_watchos_crown_consume_delta');

  late final double Function() _crownScrollMultiplier = _lib!
      .lookupFunction<Double Function(), double Function()>(
          'flutter_watchos_crown_scroll_multiplier');

  late final void Function(double) _crownSetScrollMultiplier = _lib!
      .lookupFunction<Void Function(Double), void Function(double)>(
          'flutter_watchos_crown_set_scroll_multiplier');

  late final int Function() _crownDetentHaptics = _lib!
      .lookupFunction<Int32 Function(), int Function()>(
          'flutter_watchos_crown_detent_haptics');

  late final void Function(int) _crownSetDetentHaptics = _lib!
      .lookupFunction<Void Function(Int32), void Function(int)>(
          'flutter_watchos_crown_set_detent_haptics');

  // --- Platform views (ENGINE symbols, not plugin symbols) ---
  // These live in libflutter_engine.dylib (FlutterWatchOSPlatformView*), so
  // they resolve through the same DynamicLibrary.process() lookup but can be
  // missing under an engine older than the platform-view feature. Resolved as
  // a bundle behind one try/catch: on an old engine the bundle is null and
  // every call becomes a no-op instead of throwing mid-frame.

  late final _PlatformViewFns? _platformViewFns = _resolvePlatformViewFns();

  _PlatformViewFns? _resolvePlatformViewFns() {
    final DynamicLibrary? lib = _lib;
    if (lib == null) return null;
    try {
      return _PlatformViewFns(
        create: lib.lookupFunction<
            Void Function(Int64, Pointer<Utf8>, Pointer<Utf8>),
            void Function(int, Pointer<Utf8>, Pointer<Utf8>)>(
          'FlutterWatchOSPlatformViewCreate',
        ),
        dispose: lib.lookupFunction<Void Function(Int64), void Function(int)>(
          'FlutterWatchOSPlatformViewDispose',
        ),
        create2: _resolveCreate2(lib),
        setSize: _resolveSetSize(lib),
      );
    } on ArgumentError {
      // Engine predates platform views.
      return null;
    }
  }

  /// Create2 (the underlay layer) shipped after Create: probe it separately
  /// so an engine with platform views but no underlay support still works
  /// (belowFrame requests silently fall back to the overlay layer).
  static void Function(int, Pointer<Utf8>, Pointer<Utf8>, bool)?
      _resolveCreate2(DynamicLibrary lib) {
    try {
      return lib.lookupFunction<
          Void Function(Int64, Pointer<Utf8>, Pointer<Utf8>, Bool),
          void Function(int, Pointer<Utf8>, Pointer<Utf8>, bool)>(
        'FlutterWatchOSPlatformViewCreate2',
      );
    } on ArgumentError {
      return null;
    }
  }

  /// SetSize (unclipped-rect support) also shipped after Create; without it
  /// the engine publishes viewport-clipped rects (views shrink toward the
  /// screen edge instead of sliding past it) — degraded but functional.
  static void Function(int, double, double)? _resolveSetSize(
      DynamicLibrary lib) {
    try {
      return lib.lookupFunction<Void Function(Int64, Double, Double),
          void Function(int, double, double)>(
        'FlutterWatchOSPlatformViewSetSize',
      );
    } on ArgumentError {
      return null;
    }
  }

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

  // --- Always-On display ---
  // Read-only from Dart: the watch host is the only writer. Null-safe against
  // [WatchOSNativeBindings.forTesting] — off-watch both read false, i.e. "not
  // dimmed, and nothing is reporting".

  /// Whether the display is currently in the dimmed Always-On state.
  bool get alwaysOnActive => _lib == null ? false : _alwaysOnActive();

  /// Whether the watch host reports Always-On state at all (false under a
  /// host module built before the bridge existed).
  bool get alwaysOnSupported => _lib == null ? false : _alwaysOnSupported();

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

  // --- Crown scroll options (native parity) ---
  // Null-safe against [WatchOSNativeBindings.forTesting]: reads return the
  // defaults (1.0 multiplier, haptics on), writes are no-ops.

  /// Scroll-sensitivity multiplier the engine applies per crown delta.
  double get crownScrollMultiplier =>
      _lib == null ? 1.0 : _crownScrollMultiplier();

  /// Sets the scroll-sensitivity multiplier (non-positive values are ignored
  /// by the native side).
  set crownScrollMultiplier(double multiplier) {
    if (_lib != null) _crownSetScrollMultiplier(multiplier);
  }

  /// Whether the crown detent-click haptic plays during scroll.
  bool get crownDetentHaptics =>
      _lib == null ? true : _crownDetentHaptics() != 0;

  /// Enables/disables the crown detent-click haptic.
  set crownDetentHaptics(bool enabled) {
    if (_lib != null) _crownSetDetentHaptics(enabled ? 1 : 0);
  }

  // --- Platform views ---
  // Null-safe against [WatchOSNativeBindings.forTesting] AND against an
  // engine that predates the feature: all three become no-ops.

  /// Whether the running engine exposes the platform-view registry.
  bool get supportsPlatformViews => _lib != null && _platformViewFns != null;

  /// Whether the running engine supports the underlay layer (Create2).
  bool get supportsPlatformViewUnderlay =>
      _lib != null && _platformViewFns?.create2 != null;

  /// Registers platform view [viewId] with the engine registry. With
  /// [belowFrame] the view is composited under the frame image (underlay);
  /// on engines that predate Create2 the flag silently degrades to overlay.
  void platformViewCreate(int viewId, String viewType, String params,
      {bool belowFrame = false}) {
    final _PlatformViewFns? fns = _platformViewFns;
    if (fns == null) return;
    final Pointer<Utf8> type = viewType.toNativeUtf8();
    final Pointer<Utf8> paramsPtr = params.toNativeUtf8();
    try {
      final void Function(int, Pointer<Utf8>, Pointer<Utf8>, bool)? create2 =
          fns.create2;
      if (create2 != null) {
        create2(viewId, type, paramsPtr, belowFrame);
      } else {
        fns.create(viewId, type, paramsPtr);
      }
    } finally {
      malloc.free(type);
      malloc.free(paramsPtr);
    }
  }

  /// Removes platform view [viewId] from the engine registry.
  void platformViewDispose(int viewId) {
    _platformViewFns?.dispose(viewId);
  }

  /// Reports the widget's full layout size (logical units) so the engine can
  /// publish unclipped rects. No-op on engines without SetSize.
  void platformViewSetSize(int viewId, double width, double height) {
    _platformViewFns?.setSize?.call(viewId, width, height);
  }
}

/// The resolved engine platform-view entry points, bundled so a single failed
/// lookup (old engine) disables the whole feature coherently. [create2] is
/// probed separately — null on engines that predate the underlay layer.
class _PlatformViewFns {
  _PlatformViewFns(
      {required this.create,
      required this.dispose,
      this.create2,
      this.setSize});

  final void Function(int, Pointer<Utf8>, Pointer<Utf8>) create;
  final void Function(int) dispose;
  final void Function(int, Pointer<Utf8>, Pointer<Utf8>, bool)? create2;
  final void Function(int, double, double)? setSize;
}
