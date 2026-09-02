## 0.1.0-beta.8

* **New:** `WatchMemory` — how much memory the process has left before watchOS
  kills it. watchOS enforces a hard per-process limit and terminates with a
  bare SIGKILL on the way past it, and Dart's `ProcessInfo.currentRss` cannot
  see it coming: RSS omits the GPU and IOKit allocations the kernel charges to
  the process. A run measured at 111 MB of RSS was killed by jetsam at
  302.4 MB.

  `WatchMemory.available` is `os_proc_available_memory()`, the figure that
  actually governs; `WatchMemory.footprint` is `phys_footprint`, the quantity
  jetsam compares against the limit. `available` returns 0 where the platform
  cannot answer — the Simulator has no jetsam limit to report against — so
  check `WatchMemory.availableIsSupported` to tell "no headroom" apart from
  "no answer".

## 0.1.0-beta.7

* **Fix:** the package is now Web-safe. `FlutterWatchosPlatform` is the guard
  this package tells cross-platform apps to write instead of `Platform.isIOS`,
  but it imported `dart:io` unconditionally, so following that advice broke the
  app's Web build — an `UnsupportedError: Platform._operatingSystem` on the
  first `isWatch` read (a compile error on older SDKs). It now resolves through
  a conditional import: on Web `isWatch`, `isIos`, and `isAppleMobile` are all
  `false`.
* **Breaking (Web only):** `extension FlutterWatchosPlatformExt on Platform` is
  native-only API now — it extends the `dart:io` `Platform` type, which does not
  exist on Web. Nothing changes for iOS/watchOS/Android/desktop code; Web code
  that needs the check should use the static `FlutterWatchosPlatform` getters.

## 0.1.0-beta.6

* **New:** `WatchAlwaysOn` / `WatchAlwaysOnBuilder` — react to the watchOS
  Always-On display, i.e. the wrist going down and the system showing the app
  dimmed instead of blanking it. Apps use it to pause animations, hide private
  content, and drop bright fills, per the watchOS HIG. The state comes from
  SwiftUI's `\.isLuminanceReduced`, so unlike `AppLifecycleState.inactive` it
  does not also fire for notification banners and Control Center.
  `WatchAlwaysOn.isSupported` reports whether the app's watch host reports the
  state at all (false under a host module built by an older CLI, where
  `isActive` would read false regardless of the display).

## 0.1.0-beta.5

* **New:** `WatchPlatformView` — embeds a native SwiftUI view at its slot in
  the Flutter layout. Register a factory per `viewType` with
  `WatchPlatformViewRegistry.register` in the app's runner, then place the
  widget like any other box. `layer:` picks the composition side:
  `WatchPlatformViewLayer.aboveFlutter` (default) for interactive native
  controls, `belowFlutter` to let Flutter content (dialogs, snackbars,
  badges) draw over the view. `WatchPlatformView.isSupported` and
  `isUnderlaySupported` report engine support; the widget renders nothing on
  non-watchOS platforms and on engines that predate the feature.

## 0.1.0-beta.4

* **Meta:** add pub.dev `topics` and a `documentation` link. No API changes.

## 0.1.0-beta.3

* **Docs:** README now links to the GitHub source/issues and drops a broken
  relative link. No API changes.

## 0.1.0-beta.2

* **Fix:** the package now no-ops correctly on iPhone/iPad. The native-symbol
  gate used `Platform.isIOS`, which is also `true` on real iOS, so
  cross-platform apps crashed with "symbol not found" when calling
  `WatchCrown`, `WatchHaptics`, `WatchStatusBar`, `WatchCrownScrolling`, or
  `WatchOSInfo` off-watch. The gate now checks for an actual watchOS process
  (`Platform.operatingSystem == 'watchos'`), so the documented
  "safe no-op on non-watchOS platforms" behavior holds everywhere: haptics and
  status-bar calls do nothing, the crown stream never emits, `drain()`
  returns 0, and `WatchOSInfo.isWatchOS` reports `false`.

## 0.1.0-beta.1

* Initial beta release.
* `WatchStatusBar` — show/hide the system status bar (the clock watchOS
  draws over every app). Visible by default, per the watchOS HIG; set
  `WatchStatusBar.hidden = true` for immersive UIs.
* `WatchOSInfo` — synchronous FFI device info (version, model, machine id,
  simulator, screen size/scale).
* `FlutterWatchosPlatform` — cheap `isWatch` / `isIos` platform detection that
  disambiguates Apple Watch from iPhone/iPad (both report `Platform.isIOS`).
* `WatchHaptics` — Taptic Engine feedback via `WKInterfaceDevice.playHaptic`.
* `WatchCrownScroll` — the native scroll feel for a subtree: installs
  `WatchScrollPhysics` (firm, live, shallow watch-style edge bounce instead
  of the iPhone deep stretch; no haptic at the list edges, matching native
  watchOS 26).
* `WatchScrollPhysics` / `WatchScrollBehavior` — the watch-tuned physics on
  their own, per scrollable or app-wide.
* `WatchCrownScrolling` — the native-parity crown scroll options:
  `sensitivity` (low/medium/high) and `detentHaptics` on/off, applied by the
  engine per crown sample.
* `WatchCrown` — raw Digital Crown input (rotation stream or per-frame
  `drain()`) for games and custom controls, switching the crown out of scroll
  mode while active.
