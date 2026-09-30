## 0.1.0

The package's code and API are the same as in the last published build.
The example and the API docs changed:

* **Example:** the home list no longer sits inside a `SafeArea`. It covers
  the whole screen and adds the safe-area insets to its padding, so its rows
  scroll under the clock and down to the bottom edge, as in a native watchOS
  list. The crown screen, which does not scroll, keeps its `SafeArea`.
* **Docs:** every public member now has API documentation, the Web side of
  `WatchOSNativeBindings` included.

An app already on the last published build needs no change. An app on an
older build should check two things:

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
