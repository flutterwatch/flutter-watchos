# flutter_watchos

Platform detection and utilities for Flutter apps running on **Apple Watch
(watchOS)**, built for the [flutter-watchos](../../README.md) toolchain.

It is the watchOS companion to the way `flutter_tvos` serves Apple TV: a small
FFI package with zero-overhead, synchronous native calls — no method channels,
no async.

## Features

- **Platform detection** — `FlutterWatchosPlatform.isWatch` disambiguates Apple
  Watch from iPhone/iPad. (Both report `Platform.isIOS == true`, because
  watchOS is an iOS-family OS — see the toolchain's platform-identity notes.)
- **Device info** — `WatchOSInfo` exposes the watchOS version, device model,
  machine id (e.g. `Watch7,18`; resolves correctly in the Simulator too),
  simulator flag, and native screen size/scale.
- **Haptics** — `WatchHaptics.play(...)` drives the Taptic Engine via
  `WKInterfaceDevice.playHaptic`.

## Usage

```dart
import 'package:flutter_watchos/flutter_watchos.dart';

if (WatchOSInfo.isWatchOS) {
  print('watchOS ${WatchOSInfo.watchOSVersion} on ${WatchOSInfo.deviceModel}');
  print('Screen: ${WatchOSInfo.screenResolution} @${WatchOSInfo.screenScale}x');
  WatchHaptics.play(WatchHapticType.success);
}

// Watch-only branch (excludes iPhone/iPad):
if (FlutterWatchosPlatform.isWatch) {
  // compact, crown-driven UI
}
```

## How it links

This is an **FFI plugin** (`ffiPlugin: true`). The native C functions in
`watchos/Classes/flutter_watchos_ffi.{h,m}` are statically linked into the
watch app. Because FFI symbols have no compile-time caller, each one is listed
under `flutter.plugin.platforms.watchos.ffiSymbols` in `pubspec.yaml`; the
flutter-watchos CLI emits a forced reference so they survive `-dead_strip` and
remain resolvable via `DynamicLibrary.process()`.

On non-Apple platforms (Web, Android, desktop) every API returns a safe
default and performs no FFI lookup.
