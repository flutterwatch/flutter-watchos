# Plugins

## The `flutter_watchos` package

Most watch apps only need [`packages/flutter_watchos`](../packages/flutter_watchos/README.md),
the toolchain's first-party package (FFI, no method channels):

- `FlutterWatchosPlatform.isWatch` — watch vs. iPhone/iPad detection
- `WatchOSInfo` — watchOS version, device model, screen size/scale
- `WatchHaptics` — Taptic Engine feedback
- `WatchStatusBar` — show/hide the system clock (visible by default)
- `WatchCrownScroll` / `WatchScrollPhysics` — native watch scroll feel (firm
  edge bounce + end-of-content bump haptic) for scrollables
- `WatchCrownScrolling` — crown scroll options, same as native SwiftUI:
  sensitivity (low/medium/high) and detent haptics on/off
- `WatchCrown` — Digital Crown as a raw rotation input for games and custom
  controls

```yaml
dependencies:
  flutter_watchos: ^latest
```

## Using existing pub.dev plugins

- **Pure-Dart packages** work unchanged.
- **iOS plugins do not automatically work.** watchOS has no UIKit and the
  runner is not the iOS `Flutter.framework` model, so a plugin's `ios/`
  implementation is never loaded. A plugin needs an explicit watchOS
  implementation (a federated `*_watchos` package) to do native work.
- Check what a project pulls in with:

  ```sh
  flutter-watchos plugin list
  ```

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

## Porting an existing iOS plugin

`flutter-watchos plugin port` will scaffold a federated `*_watchos` package
from an existing iOS/macOS plugin. It is **not yet available** in the
current build — for now, start from `create --template=plugin` and copy the
relevant native code, replacing UIKit APIs with WatchKit/SwiftUI
equivalents.
