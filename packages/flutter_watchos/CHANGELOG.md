## 0.1.0

The Digital Crown now scrolls the way it scrolls a native watchOS scroll
view, in every app, and `WatchScrollPhysics` moves like a native scroll view
under the finger, as measured on a watch. The crown API changes with it:

* **The crown needs no code.** An app built with flutter-watchos 0.1.0
  scrolls with a hidden native scroll view behind the Flutter content, so
  watchOS supplies the acceleration, the momentum, the detent haptics, the
  spring at either end and the crown scroll indicator. The crown drives the
  vertical scrollable that fills most of the screen in the frontmost route.
* **`WatchCrownScroll`** now chooses that scrollable, for a screen with more
  than one, and still gives its subtree `WatchScrollPhysics`. `enabled: false`
  keeps the crown off the scrollables under it, and `scrollIndicator: false`
  hides the crown scroll indicator.
* **`WatchScrollPhysics`** follows a native scroll view: UIKit's rubber band
  (0.55 of the finger's travel at the edge), a critically damped spring at
  either end, UIKit's fling deceleration. The `maxStretchFraction` and
  `edgeRelaxation` parameters are removed.
* **`WatchCrownScrolling` and `WatchCrownSensitivity` are removed.** A native
  scroll view's crown sensitivity and detent haptics belong to the system,
  so there is nothing left for them to set. Remove the calls.
* **`WatchCrown`** is unchanged: while an app reads the raw crown, the crown
  goes to it and does not scroll.

The example and the API docs changed too:

* **Example:** the home list no longer sits inside a `SafeArea`. It covers
  the whole screen and adds the safe-area insets to its padding, so its rows
  scroll under the clock and down to the bottom edge, as in a native watchOS
  list. The crown screen, which does not scroll, keeps its `SafeArea`.
* **Docs:** every public member now has API documentation, the Web side of
  `WatchOSNativeBindings` included.

An app on the last published build removes its `WatchCrownScrolling` calls
and any `WatchScrollPhysics` arguments. An app on an older build also checks
two things:

* **Web only:** `extension FlutterWatchosPlatformExt on Platform` exists only
  where `dart:io` does, so Web code cannot use it. Code that also builds for
  the Web uses the static `FlutterWatchosPlatform` getters, which work on
  every platform.
* **`WatchPlatformView`:** on engines that composite platform views
  (`WatchPlatformView.isComposited`), the native view is drawn in paint order
  with the Flutter content around it, and `layer:` only decides which side
  owns the touches inside the view. On engines that do not, `layer:` also
  still picks whether the view is drawn above or below Flutter.

What the package gives a Flutter app on Apple Watch:

* `FlutterWatchosPlatform.isWatch`, `isIos` and `isAppleMobile` tell Apple
  Watch apart from iPhone and iPad, which both report `Platform.isIOS`. They
  are safe to call from shared code on every platform, the Web included,
  where all three are `false`.
* `WatchOSInfo`: synchronous device information (watchOS version, model,
  machine id, Simulator flag, screen size and scale).
* `WatchHaptics`: Taptic Engine feedback through
  `WKInterfaceDevice.playHaptic`.
* `WatchStatusBar`: shows or hides the clock watchOS draws over every app.
* `WatchCrownScroll`, `WatchScrollPhysics` and `WatchScrollBehavior`: the
  native watch scroll feel, a firm, shallow edge bounce with no haptic at
  the list edges. `WatchCrownScrolling` sets the crown's scroll sensitivity
  and turns its detent clicks on or off.
* `WatchCrown`: raw Digital Crown rotation, as a stream or per frame with
  `drain()`, for games and custom controls.
* `WatchPlatformView`: a native SwiftUI view at its place in the Flutter
  layout, composited in paint order with the Flutter content around it.
* `WatchAlwaysOn` and `WatchAlwaysOnBuilder`: whether watchOS is showing
  the app dimmed in the Always-On state.
* `WatchMemory`: how much memory the process may still allocate before
  watchOS stops it, and its current footprint.

On other platforms the package calls no native code: the device getters
return defaults, and haptics, clock and crown calls do nothing.
