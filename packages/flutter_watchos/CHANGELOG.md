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
