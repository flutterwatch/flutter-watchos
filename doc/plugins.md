# Plugins

## The `flutter_watchos` package

Most watch apps only need [`packages/flutter_watchos`](../packages/flutter_watchos/README.md),
the toolchain's first-party package (FFI, no method channels):

- `FlutterWatchosPlatform.isWatch` — watch vs. iPhone/iPad detection
- `WatchOSInfo` — watchOS version, device model, screen size/scale
- `WatchHaptics` — Taptic Engine feedback
- `WatchStatusBar` — show/hide the system clock (visible by default)
- `WatchCrownScroll` / `WatchScrollPhysics` — native watch scroll feel (firm,
  live edge bounce; no edge haptic, matching watchOS 26) for scrollables
- `WatchCrownScrolling` — crown scroll options, same as native SwiftUI:
  sensitivity (low/medium/high) and detent haptics on/off
- `WatchCrown` — Digital Crown as a raw rotation input for games and custom
  controls

During the closed beta the package isn't on pub.dev yet — depend on it from
the repo you cloned (via a git or path dependency):

```yaml
dependencies:
  flutter_watchos:
    git:
      url: https://github.com/flutterwatch/flutter-watchos.git
      path: packages/flutter_watchos
```

## Using existing pub.dev plugins

- **Pure-Dart packages** work unchanged.
- **iOS plugins do not automatically work.** watchOS has no UIKit and the
  runner is not the iOS `Flutter.framework` model, so a plugin's `ios/`
  implementation is never loaded. A plugin needs an explicit watchOS
  implementation (a federated `*_watchos` package) to do native work.
- You don't have to audit this by hand: `flutter-watchos build` / `run`
  print a warning listing every plugin in the dependency graph that has
  native code for other platforms but no `watchos:` implementation.
- Those plugins compile fine — their native code just isn't bundled — and
  throw `MissingPluginException` at runtime on the watch.
- **FFI packages behave the same way, just with a different error.** A
  package that does `DynamicLibrary.open(...)` or process-symbol lookups
  never breaks the *build* — its native library simply isn't bundled into
  the watch target (native-assets build hooks are skipped for watchOS too).
  But the first *call* on the watch throws an `ArgumentError`
  ("Failed to load dynamic library" / "Failed to lookup symbol").
  Watch out for plugins that guard their FFI behind `Platform.isIOS`: that
  is also `true` on watchOS, so they will confidently attempt the load and
  fail. Guard watch code paths with `FlutterWatchosPlatform.isWatch` and
  only call such plugins when it is `false` — or on strict
  `FlutterWatchosPlatform.isIos`.

## Writing a watchOS plugin

Follow the [federated plugin](https://docs.flutter.dev/packages-and-plugins/developing-packages#federated-plugins)
convention — a `<name>_watchos` package that endorses itself as the watchOS
implementation of `<name>`:

```sh
flutter-watchos create --template=plugin --platforms=watchos my_plugin_watchos
```

Native code is Swift compiled into the watch target; talk to it from Dart
via **FFI** (the `flutter_watchos` package is the reference for this
pattern — synchronous calls, no method-channel plumbing). Method channels
also work through the engine's platform messenger if you prefer them for
async APIs.

Declare the platform in the plugin's `pubspec.yaml`:

```yaml
flutter:
  plugin:
    platforms:
      watchos:
        pluginClass: MyPluginWatchos
```

### Plugins with native SwiftUI views

A plugin that needs a native rendering surface (video, maps, …) can ship
SwiftUI **platform-view sources** under `watchos/Views/*.swift` — the CLI
discovers and compiles them into the app automatically, no configuration
keys. The Swift side registers a factory per view type through the
CLI-provided `FlutterWatchOSPluginViews.register(_:factory:)` API from a
C-callable entry point (an `@_cdecl` listed under `ffiSymbols`), the
plugin's Dart `registerWith()` invokes that entry point over FFI, and the
Dart side embeds the view with `WatchPlatformView` from
`package:flutter_watchos`. See
[`video_player_watchos`](https://github.com/flutterwatch/plugins) for a
complete worked example.

## Porting an existing iOS plugin

`flutter-watchos plugin port` will scaffold a federated `*_watchos` package
from an existing iOS/macOS plugin. It is **not yet available** in the
current build — for now, start from `create --template=plugin` and copy the
relevant native code, replacing UIKit APIs with WatchKit/SwiftUI
equivalents.
