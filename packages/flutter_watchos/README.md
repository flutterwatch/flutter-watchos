# flutter_watchos

Platform detection and utilities for Flutter apps running on **Apple Watch
(watchOS)**, built for the
[flutter-watchos](https://github.com/flutterwatch/flutter-watchos) toolchain.

A small FFI package with zero-overhead, synchronous native calls — no method
channels, no async.

**Source & issues:** https://github.com/flutterwatch/flutter-watchos

## Features

- **Platform detection** — `FlutterWatchosPlatform.isWatch` disambiguates Apple
  Watch from iPhone/iPad. (Both report `Platform.isIOS == true`, because
  watchOS is an iOS-family OS — see the toolchain's platform-identity notes.)
- **Device info** — `WatchOSInfo` exposes the watchOS version, device model,
  machine id (e.g. `Watch7,18`; resolves correctly in the Simulator too),
  simulator flag, and native screen size/scale.
- **Haptics** — `WatchHaptics.play(...)` drives the Taptic Engine via
  `WKInterfaceDevice.playHaptic`.
- **Status bar** — `WatchStatusBar.hidden` shows/hides the system clock the
  watch draws over every app (visible by default, per the HIG; hide it for
  games and full-bleed UIs — watchOS cannot reposition it, so a custom
  placement means hiding it and drawing your own).
- **Digital Crown** — `WatchCrownScroll` gives scrollables the native feel:
  watch-tuned scroll physics (`WatchScrollPhysics` — a firm, live, shallow
  edge bounce instead of the iPhone-style deep stretch; no edge haptic, just
  like native watchOS 26). `WatchCrownScrolling` exposes the same knobs
  native developers get (`sensitivity`, detent haptics on/off). `WatchCrown`
  gives the crown as a *raw* input (a rotation stream, or a per-frame
  `drain()`) for games, value pickers, and custom controls — without it
  driving scroll.

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

### Digital Crown

By default the crown scrolls. Wrap a scrollable (usually a whole screen) to
give it the native watch feel — watch-tuned physics with a firm, live,
shallow edge bounce (and, matching native watchOS 26, no haptic at the list
edges):

```dart
WatchCrownScroll(child: ListView(children: const [/* ... */]));
```

App-wide instead: `MaterialApp(scrollBehavior: const WatchScrollBehavior())`,
or pass `physics: const WatchScrollPhysics()` to a single scrollable.

Scroll behavior has the same options native (SwiftUI) developers get on
`.digitalCrownRotation` — they apply app-wide, from the next crown movement:

```dart
WatchCrownScrolling.sensitivity = WatchCrownSensitivity.medium; // low/medium/high
WatchCrownScrolling.detentHaptics = false; // silent scrolling
```

For a game or custom control, take the crown as **raw** input instead. While a
`WatchCrown` subscription (or `enable()`) is active, the crown stops scrolling
and delivers rotation directly:

```dart
// Stream (frame-polled). Subscribing switches the crown to raw mode;
// cancelling the last listener returns it to scroll.
final sub = WatchCrown.instance.rotations.listen((e) {
  setState(() => paddleX += e.delta * sensitivity); // e.velocity also available
});
// ...later: await sub.cancel();

// Or, for an app with its own game loop — zero stream overhead:
WatchCrown.instance.enable();
final delta = WatchCrown.instance.drain(); // call each tick
WatchCrown.instance.disable();
```

On non-watchOS platforms the stream never emits and `drain()` returns 0, so it's
safe to leave in cross-platform code.

## How it links

This is an **FFI plugin** (`ffiPlugin: true`). The native C functions in
`watchos/Classes/flutter_watchos_ffi.{h,m}` are statically linked into the
watch app. Because FFI symbols have no compile-time caller, each one is listed
under `flutter.plugin.platforms.watchos.ffiSymbols` in `pubspec.yaml`; the
flutter-watchos CLI emits a forced reference so they survive `-dead_strip` and
remain resolvable via `DynamicLibrary.process()`.

On non-Apple platforms (Web, Android, desktop) every API returns a safe
default and performs no FFI lookup.
