// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Web stub — dart:ffi is not available on Web. All getters return safe
// defaults that match the non-watchOS fallback in the native implementation.

/// The package's bindings to its native watchOS code.
///
/// Apps do not need this class: `WatchOSInfo`, `WatchHaptics`, `WatchCrown`
/// and the package's other APIs call it for them. It is public so that tests
/// can replace it. Extend it through [WatchOSNativeBindings.forTesting],
/// override the members the code under test reads, and pass the fake to a
/// `bindingsOverride` setter: `WatchOSInfo`, `WatchAlwaysOn`,
/// `WatchStatusBar`, `WatchPlatformView` and `WatchCrown.instance` each have
/// one. In a test on the Dart VM, the members of a `forTesting` object that
/// read the device, play a haptic or report memory throw unless the fake
/// overrides them; the other members return the defaults listed below.
///
/// On watchOS every member is a synchronous FFI call into the app's process.
/// This is the Web version of the class. The Web has no `dart:ffi`, so no
/// member calls native code, and each returns what a platform other than
/// watchOS reports.
class WatchOSNativeBindings {
  /// Creates the bindings the package uses at run time. On the Web there is
  /// no native code to look up.
  WatchOSNativeBindings();

  /// Creates bindings that look up no native code, as the base of a fake.
  WatchOSNativeBindings.forTesting();

  /// Whether the process is a watchOS app. Always false on the Web.
  bool get isWatchOS => false;

  /// The watchOS version, such as "26.0". Empty on the Web.
  String get systemVersion => '';

  /// The device model, such as "Apple Watch". Empty on the Web.
  String get deviceModel => '';

  /// The hardware model identifier, such as "Watch7,1". Empty on the Web.
  String get machineId => '';

  /// Whether the app runs in the watchOS Simulator. Always false on the Web.
  bool get isSimulator => false;

  /// The screen width in pixels. 0 on the Web.
  int get screenWidth => 0;

  /// The screen height in pixels. 0 on the Web.
  int get screenHeight => 0;

  /// The screen's pixels per point, such as 2.0. 0 on the Web.
  double get screenScale => 0.0;

  /// The screen size in pixels as width x height, such as "396x484". "0x0"
  /// on the Web.
  String get screenResolution => '0x0';

  /// Plays the Taptic Engine haptic whose raw `WKHapticType` value is [type].
  /// Does nothing on the Web.
  void playHaptic(int type) {}

  /// The bytes the process may still allocate before watchOS stops it, or 0
  /// when the platform cannot tell. 0 on the Web.
  int availableMemory() => 0;

  /// Whether [availableMemory] reports a real figure. False on the Web.
  bool availableMemorySupported() => false;

  /// The process's memory footprint in bytes, as the kernel counts it. 0 on
  /// the Web.
  int memoryFootprint() => 0;

  /// Whether the app has asked watchOS to hide the clock it draws over every
  /// app. False on the Web.
  bool get statusBarHidden => false;

  /// Asks watchOS to hide or show the clock. Does nothing on the Web.
  set statusBarHidden(bool hidden) {}

  /// Whether the display is dimmed in the Always-On state. False on the Web.
  bool get alwaysOnActive => false;

  /// Whether the watch host reports the Always-On state at all. False on the
  /// Web.
  bool get alwaysOnSupported => false;

  /// The clock band height the watch host reported, in logical pixels, or a
  /// negative value when no host has reported one. -1 on the Web.
  double get clockBandHeight => -1.0;

  /// Where Digital Crown rotation goes: 0 scrolls, 1 delivers it raw to the
  /// app. 0 on the Web.
  int get crownMode => 0;

  /// Sets where Digital Crown rotation goes (0 scroll, 1 raw). Does nothing
  /// on the Web.
  set crownMode(int mode) {}

  /// Returns the raw crown rotation gathered since the last call, and starts
  /// counting again from 0. Always 0 on the Web.
  double consumeCrownDelta() => 0.0;

  /// Whether the running engine can show platform views. False on the Web.
  bool get supportsPlatformViews => false;

  /// Whether the running engine can put a platform view below the Flutter
  /// frame. False on the Web.
  bool get supportsPlatformViewUnderlay => false;

  /// Whether the running engine composites platform views from the layer
  /// tree. False on the Web.
  bool get supportsCompositedPlatformViews => false;

  /// Registers platform view [viewId], of type [viewType] with the creation
  /// parameters [params], with the engine. [belowFrame] puts it below the
  /// Flutter frame. Does nothing on the Web.
  void platformViewCreate(int viewId, String viewType, String params,
      {bool belowFrame = false}) {}

  /// Removes platform view [viewId] from the engine. Does nothing on the Web.
  void platformViewDispose(int viewId) {}

  /// Reports the full layout size of platform view [viewId], in logical
  /// pixels. Does nothing on the Web.
  void platformViewSetSize(int viewId, double width, double height) {}
}
