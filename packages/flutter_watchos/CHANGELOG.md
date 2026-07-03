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
* `WatchCrownScroll` — the full native scroll feel for a subtree: installs
  `WatchScrollPhysics` (firm, shallow watch-style edge bounce instead of the
  iPhone deep stretch) and plays the native "end of content" bump haptic.
* `WatchScrollPhysics` / `WatchScrollBehavior` — the watch-tuned physics on
  their own, per scrollable or app-wide.
* `WatchCrownScrolling` — the native-parity crown scroll options:
  `sensitivity` (low/medium/high) and `detentHaptics` on/off, applied by the
  engine per crown sample.
* `WatchCrown` — raw Digital Crown input (rotation stream or per-frame
  `drain()`) for games and custom controls, switching the crown out of scroll
  mode while active.
