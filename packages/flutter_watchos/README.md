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
  The `FlutterWatchosPlatform` getters are safe to call from shared code on
  every platform a Flutter app targets, Web included, where all of them are
  `false`.
- **Device info** — `WatchOSInfo` exposes the watchOS version, device model,
  machine id (e.g. `Watch7,18`; resolves correctly in the Simulator too),
  simulator flag, and native screen size/scale.
- **Haptics** — `WatchHaptics.play(...)` drives the Taptic Engine via
  `WKInterfaceDevice.playHaptic`.
- **Status bar** — `WatchStatusBar.hidden` shows/hides the system clock the
  watch draws over every app (visible by default, per the HIG; hide it for
  games and full-bleed UIs — watchOS cannot reposition it, so a custom
  placement means hiding it and drawing your own). The change shows on the
  next frame, which the setter requests. Hiding the clock does not change
  `MediaQuery.padding`, and by default the padding leaves the clock out:
  content that has to start below the clock takes its top from
  `WatchStatusBar.heightOf(context)`. See [The clock](#the-clock) and
  [doc/layout.md](https://github.com/flutterwatch/flutter-watchos/blob/main/doc/layout.md).
- **Always-On** — `WatchAlwaysOn` / `WatchAlwaysOnBuilder` tell you when the
  wrist is down and watchOS is showing your app dimmed, so you can pause
  animations, hide private content, and drop bright fills (the HIG
  expectation). It reflects SwiftUI's `\.isLuminanceReduced`, which is more
  precise than `AppLifecycleState.inactive` — that also fires for notification
  banners and Control Center.
- **Digital Crown** — every app built with flutter-watchos scrolls with the
  crown the way a native scroll view does, with no code: watchOS itself
  supplies the acceleration, the momentum, the detent haptics, the spring at
  either end and the scroll indicator. `WatchCrownScroll` chooses the list
  the crown drives when a screen has several, and `WatchScrollPhysics` gives
  the finger a native scroll view's feel as well. `WatchCrown` gives the
  crown as a *raw* input (a rotation stream, or a per-frame `drain()`) for
  games, value pickers, and custom controls — without it driving scroll.
- **Platform views** — `WatchPlatformView` embeds a native SwiftUI view
  (a `Gauge`, a `Toggle`, a map, a video surface) at its slot in the Flutter
  layout, composited at its position in paint order like any other content.

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

### Always-On

When the wrist drops, watchOS keeps your app on screen at reduced luminance
rather than blanking it. Your last frame stays visible with no work on your
part — but the HIG expects you to *react*: stop animations that now burn
battery for nobody, and hide anything a bystander shouldn't read.

```dart
WatchAlwaysOnBuilder(
  builder: (context, alwaysOn, _) => alwaysOn
      ? const DimmedFace()   // static, dark, no private data
      : const LiveFace(),    // the full UI
)
```

Outside the widget tree — to pause a controller or cancel a timer — listen to
`WatchAlwaysOn.state`, or read `WatchAlwaysOn.isActive` once.

Don't reach for `AppLifecycleState.inactive` here: watchOS also resigns active
for notification banners and Control Center, so it can't tell "wrist down"
from "something is covering the app". This API reflects SwiftUI's
`\.isLuminanceReduced`, which means exactly the former.

The two do fire together, in no guaranteed order — so **don't read
`WatchAlwaysOn.isActive` from inside your own `didChangeAppLifecycleState`**.
At that instant the watch host may not have reported yet, and a one-shot read
can return the pre-transition value. Listen to `WatchAlwaysOn.state` and let it
settle. Doing so doesn't disturb your own lifecycle observers.

An app that would rather blank than dim opts out in its `Info.plist` with
`WKSupportsAlwaysOnDisplay` = `false`; `isActive` then never becomes true.

### The clock

watchOS draws the time over every app. It stays visible unless the app asks
otherwise:

```dart
WatchStatusBar.hidden = true;   // a game, media, a full-bleed screen
WatchStatusBar.hidden = false;  // back to the default
```

The change shows on the next frame, which the setter requests, so it works
on a screen that does not repaint too.

Hiding the clock does not change `MediaQuery.padding`. By default that
padding leaves the clock out: it keeps content clear of the display's
rounded corners only, so content that starts at the top of the view can sit
under the clock, and an app that hides the clock already has its band.
Content that has to start below the clock takes its top from
`WatchStatusBar.heightOf(context)`, the height of the clock's band measured
from the top of the view:

```dart
ListView(
  padding: MediaQuery.paddingOf(context).copyWith(
    top: WatchStatusBar.heightOf(context),
  ),
  children: rows,
)
```

Below an `AppBar` or inside a `SafeArea`, content already starts below its
ancestor's top edge, so do not add the height again. An app that sets
`FlutterWatchOSSafeArea` to `platform` in its `Info.plist` gets padding that
keeps content below the clock as well. Both safe areas, and how to reclaim
the top when an app hides the clock in `platform`, are in
[doc/layout.md](https://github.com/flutterwatch/flutter-watchos/blob/main/doc/layout.md).

The watch host hides the clock with `_statusBarHidden`, an undocumented,
underscored SwiftUI modifier. The SDK marks it for deprecation in a later
release, and watchOS has no public replacement, so a later SDK could stop
`WatchStatusBar.hidden` from working until the host changes.

### Digital Crown

The crown scrolls with no code. A watch app built with flutter-watchos keeps
a hidden native scroll view behind the Flutter content, shaped like the list
the crown drives, so watchOS supplies the acceleration, the momentum after a
flick, the detent haptics, the spring at either end and the crown scroll
indicator, and the list shows exactly where that view is. Among the vertical
scrollables actually on screen (not in a hidden tab, not under a dialog), the
crown drives the frontmost one that covers at least 40% of the screen, or the
largest when none does. An app that still compiles its own watchOS runner
(`watchos/Runner/FlutterRunner.swift`) keeps the older crown until the runner
moves to the current template; its build says so.

`WatchCrownScroll` settles the cases that rule does not decide your way:

```dart
// Prefer this list, for example one that shares the screen with a bigger one.
WatchCrownScroll(child: ListView(children: const [/* ... */]));

// Keep the crown off these lists.
WatchCrownScroll(enabled: false, child: ...);

// No scroll indicator by the crown (wrap the app to hide it everywhere).
WatchCrownScroll(scrollIndicator: false, child: ...);
```

`WatchCrownScroll` also gives its subtree `WatchScrollPhysics`, which moves
under the finger like a native scroll view: UIKit's rubber band at the edge,
and the same spring as the crown's when a stretch is let go or a fling runs
into the end. App-wide instead: `MaterialApp(scrollBehavior: const
WatchScrollBehavior())`, or pass `physics: const WatchScrollPhysics()` to a
single scrollable. Without either, a drag uses Flutter's iOS rubber band,
which resists a little differently; the release and the bounce at the end are
native either way.

A watchOS list covers the whole screen and scrolls its rows under the clock
and down to the bottom edge. To get that, leave a list's `padding` null, or
add `MediaQuery.paddingOf(context)` to your own, and do not wrap a scrolling
view in a `SafeArea`: that turns the list into a window between the insets.
A `SingleChildScrollView` never pads itself, so give it the insets, and in a
`CustomScrollView` put the slivers in a `SliverSafeArea`:

```dart
SingleChildScrollView(
  padding: MediaQuery.paddingOf(context),
  child: Column(children: rows),
);

CustomScrollView(
  slivers: [SliverSafeArea(sliver: SliverList.list(children: rows))],
);
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

### Platform views

Register a SwiftUI factory per `viewType` in the app's `App.swift`
initializer (`WatchPlatformViewRegistry` comes with the `FlutterWatchOS` host
module every app imports), then place the widget like any other box:

```swift
WatchPlatformViewRegistry.register("gauge") { params in
    AnyView(MyGaugeView(params: params))
}
```

```dart
SizedBox(
  height: 64,
  child: WatchPlatformView(
    viewType: 'gauge',
    creationParams: '{"value": 0.72}',
  ),
)
```

The native view is **composited at the widget's position in paint order**:
Flutter content painted before the widget is below it, content painted after
it — a badge in a `Stack`, a border in a `foregroundDecoration`, a dialog, a
snackbar — draws over it. Ancestor clips, opacity and transforms apply, and
the view hides whenever it is not painted (scrolled out of the viewport,
covered by an opaque route).

`layer:` decides who gets the **touches** inside the view's rect — SwiftUI
has no event forwarding, so whichever side takes the touch-down owns the
whole gesture:

- `WatchPlatformViewLayer.aboveFlutter` (default) — the native view gets
  them, unless Flutter content painted above it covers that point. Use for
  interactive controls (pickers, buttons, toggles).
- `WatchPlatformViewLayer.belowFlutter` — Flutter always gets them; wrap the
  widget in a `GestureDetector` to handle taps in Dart. Use for display views
  (gauges, charts).

`WatchPlatformView.isSupported` is false off-watch and on engines that predate
platform views (the widget then paints nothing), and
`WatchPlatformView.isComposited` tells whether the engine composites from the
layer tree — on older engines the widget falls back to an overlay/underlay
model where `layer:` also picks the composition side (see the API docs).

## How it links

This is an **FFI plugin** (`ffiPlugin: true`). The native C functions in
`watchos/Classes/flutter_watchos_ffi.{h,m}` are statically linked into the
watch app. Because FFI symbols have no compile-time caller, each one is listed
under `flutter.plugin.platforms.watchos.ffiSymbols` in `pubspec.yaml`, marked
`used` + default-visibility in the header, force-loaded into the app by the
flutter-watchos CLI, and kept through the App Store strip, so they survive
`-dead_strip` and remain resolvable via `DynamicLibrary.process()`.

On non-Apple platforms (Web, Android, desktop) every API returns a safe
default and performs no FFI lookup.

---

_flutter_watchos is part of [flutter-watchos](https://flutterwatch.dev), an
independent project that is not affiliated with, endorsed by, or sponsored by
Google LLC or Apple Inc. Flutter and Dart are trademarks of Google LLC. Apple
Watch and watchOS are trademarks of Apple Inc._
