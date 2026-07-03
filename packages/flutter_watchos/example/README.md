# flutter_watchos_example

A watchOS-only app that exercises every part of the `flutter_watchos` package
on one screen. Run it on an Apple Watch simulator (or a paired watch) with:

```sh
flutter-watchos run
```

The home screen is itself a `WatchCrownScroll` list, so scrolling it with the
Digital Crown already demonstrates the native scroll feel. Below is what each
part shows and the API behind it.

## Platform detection & device info

The top rows read straight from the package's synchronous, zero-async getters:

```dart
import 'package:flutter_watchos/flutter_watchos.dart';

FlutterWatchosPlatform.isWatch;      // true only on Apple Watch
FlutterWatchosPlatform.isIos;        // true on iPhone/iPad, false on Watch
FlutterWatchosPlatform.isAppleMobile;// true on any iOS-family OS (== Platform.isIOS)

WatchOSInfo.isWatchOS;               // native TARGET_OS_WATCH check
WatchOSInfo.watchOSVersion;          // "26.0"
WatchOSInfo.deviceModel;             // "Apple Watch"
WatchOSInfo.machineId;               // "Watch7,18" (resolves in the Simulator too)
WatchOSInfo.isSimulator;
WatchOSInfo.screenResolution;        // "396x484"
WatchOSInfo.screenScale;             // 2.0
```

`Platform.isIOS` is `true` on both iPhone/iPad **and** Apple Watch (watchOS is
an iOS-family OS), so use `FlutterWatchosPlatform.isWatch` / `.isIos` to branch
between a watch UI and a handheld UI.

## System clock — `WatchStatusBar`

The **system clock: shown/hidden** button toggles the time the watch draws over
every app. It's visible by default (per the watchOS HIG); hide it for a game or
full-bleed screen:

```dart
WatchStatusBar.hidden = true;   // immersive
WatchStatusBar.hidden = false;  // back to default
```

watchOS can't *reposition* the clock, so to place the time yourself, hide the
system one and draw your own clock widget.

## Haptics — `WatchHaptics`

One button per `WatchHapticType`. Each fires the Taptic Engine synchronously
over FFI (no-op in the Simulator, which has no Taptic Engine):

```dart
WatchHaptics.play(WatchHapticType.success); // notification, directionUp/Down,
                                            // success, failure, retry, start,
                                            // stop, click
WatchHaptics.click();                        // shorthand for the selection tick
```

## Digital Crown — scroll mode

`WatchCrownScroll` wraps a scrollable to give it the native watch feel:
watch-tuned physics with a firm, shallow edge bounce (and, matching native
watchOS 26, **no** haptic at the list edges — the rubber-band alone signals the
end).

```dart
WatchCrownScroll(
  child: ListView(children: const [/* ... */]),
)
```

App-wide instead of per-subtree:

```dart
MaterialApp(scrollBehavior: const WatchScrollBehavior(), /* ... */);
// or, on a single scrollable:
ListView(physics: const WatchScrollPhysics(), children: const [/* ... */]);
```

The **crown sensitivity** row and the **detent ticks** button are the same
knobs native (SwiftUI) developers get on `.digitalCrownRotation`. They apply
app-wide from the next crown movement:

```dart
WatchCrownScrolling.sensitivity = WatchCrownSensitivity.medium; // low/medium/high
WatchCrownScrolling.detentHaptics = false;                      // silent scroll
```

## Digital Crown — raw mode (`crown demo →`)

The **crown demo** screen takes the crown as *raw* input via `WatchCrown`: it
drives a 0–100 value directly instead of scrolling, with a haptic at each end.
Subscribing switches the crown into raw mode; cancelling the last listener
hands it back to scroll:

```dart
final sub = WatchCrown.instance.rotations.listen((e) {
  setState(() => value = (value + e.delta * sensitivity).clamp(0, 100));
});
// ...later: await sub.cancel();
```

For an app with its own game loop, poll instead of streaming (zero stream
overhead):

```dart
WatchCrown.instance.enable();
final delta = WatchCrown.instance.drain(); // each tick
WatchCrown.instance.disable();
```

On non-watchOS platforms the stream never emits and `drain()` returns 0, so raw
crown code is safe to leave in a cross-platform tree.

## App lifecycle (no plugin needed)

App lifecycle is stock Flutter — the engine drives the `flutter/lifecycle`
channel, so `WidgetsBindingObserver.didChangeAppLifecycleState` and
`AppLifecycleListener` work as they do on iOS/Android. See the standalone
`demo/lifecycle_demo` for a focused example.
