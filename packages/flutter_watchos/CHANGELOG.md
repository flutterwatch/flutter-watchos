## 0.2.0

* `WatchStatusBar` — control the system status bar (the clock watchOS draws
  over every app). The time is now **visible by default** in apps generated
  by flutter-watchos (per the watchOS HIG); set `WatchStatusBar.hidden =
  true` for immersive UIs. Apps that relied on the template's previous
  always-hidden behaviour must opt in.

## 0.1.0

* Initial release.
* `WatchOSInfo` — synchronous FFI device info (version, model, machine id,
  simulator, screen size/scale).
* `FlutterWatchosPlatform` — cheap `isWatch` / `isIos` platform detection that
  disambiguates Apple Watch from iPhone/iPad (both report `Platform.isIOS`).
* `WatchHaptics` — Taptic Engine feedback via `WKInterfaceDevice.playHaptic`.
* `WatchCrownScroll` — native "end of content" bump haptic for scrollables.
* `WatchCrown` — raw Digital Crown input (rotation stream or per-frame
  `drain()`) for games and custom controls, switching the crown out of scroll
  mode while active.
