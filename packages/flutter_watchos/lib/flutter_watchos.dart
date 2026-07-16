/// Platform detection and utilities for Flutter apps on Apple Watch (watchOS).
///
/// This package provides synchronous runtime checks via dart:ffi to determine
/// if the app is running on watchOS, along with device information, capability
/// queries, and Taptic Engine haptics. All calls are zero-overhead — no async,
/// no platform channels.
///
/// ```dart
/// import 'package:flutter_watchos/flutter_watchos.dart';
///
/// if (WatchOSInfo.isWatchOS) {
///   print('Running on watchOS ${WatchOSInfo.watchOSVersion}');
///   print('Device: ${WatchOSInfo.deviceModel} (${WatchOSInfo.machineId})');
///   print('Screen: ${WatchOSInfo.screenResolution}');
///   WatchHaptics.play(WatchHapticType.success);
/// }
///
/// // Distinguish Apple Watch from iPhone/iPad (both report Platform.isIOS):
/// if (FlutterWatchosPlatform.isWatch) { /* watch-only UI */ }
/// ```
library flutter_watchos;

export 'src/watchos_info.dart';
export 'src/watchos_ffi_bindings.dart' show WatchOSNativeBindings;
export 'src/platform_extension.dart'
    show FlutterWatchosPlatform, FlutterWatchosPlatformExt;
export 'src/haptics.dart' show WatchHaptics, WatchHapticType;
export 'src/status_bar.dart' show WatchStatusBar;
export 'src/scroll_physics.dart' show WatchScrollPhysics, WatchScrollBehavior;
export 'src/crown_scroll.dart'
    show WatchCrownScroll, WatchCrownScrolling, WatchCrownSensitivity;
export 'src/crown.dart' show WatchCrown, CrownRotationEvent;
export 'src/platform_view.dart' show WatchPlatformView, WatchPlatformViewLayer;
