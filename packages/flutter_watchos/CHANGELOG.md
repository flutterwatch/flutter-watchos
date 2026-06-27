## 0.1.0

* Initial release.
* `WatchOSInfo` — synchronous FFI device info (version, model, machine id,
  simulator, screen size/scale).
* `FlutterWatchosPlatform` — cheap `isWatch` / `isIos` platform detection that
  disambiguates Apple Watch from iPhone/iPad (both report `Platform.isIOS`).
* `WatchHaptics` — Taptic Engine feedback via `WKInterfaceDevice.playHaptic`.
