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
convention — a `<name>_watchos` package that implements `<name>` for the
watch. There is no `create --template=plugin` for watchOS (the command
rejects it): stock Flutter's plugin templates generate method-channel code
that cannot run on the watch. Start from `flutter-watchos plugin port`
(below) or author the package by hand as described here.

watchOS plugins ship native code via **dart:ffi**. Method-channel plugins
are not supported: a `watchos:` block that declares only `pluginClass:`
builds, but every channel call throws `MissingPluginException` at runtime
(`build`/`run` warn when they see one). The FFI model:

1. **Native** — `watchos/Classes/<name>_ffi.{h,m}` exports C functions
   marked `__attribute__((visibility("default"))) __attribute__((used))`.
   The CLI compiles `.m`/`.mm`/`.c` sources and statically links them into
   the watch binary.
2. **Manifest** — `watchos/Package.swift` declares the frameworks to link.
3. **Dart** — a class over the plugin's platform interface resolves the
   symbols via `DynamicLibrary.process()` and registers in `registerWith()`.

Declare the model in the plugin's `pubspec.yaml`:

```yaml
flutter:
  plugin:
    implements: my_plugin
    platforms:
      watchos:
        ffiPlugin: true
        dartPluginClass: MyPluginWatchos
        ffiSymbols:
          - my_plugin_watchos_do_thing
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

### Linking an external native SDK

A plugin's `watchos/Package.swift` can declare external SwiftPM
dependencies (for example the Firebase Apple SDK's `FirebaseMessaging`
product). At build time the CLI resolves and builds the package graph with
xcodebuild's SwiftPM, harvests the resulting objects — deduplicating
modules shared between plugins, so two Firebase plugins link one copy of
`FirebaseCore` — and force-loads them into the watch app. No CocoaPods and
no manual Xcode configuration.

Two requirements: the SDK must build **from source** for watchOS (a
product wrapping a prebuilt binary without a watchOS slice cannot link),
and the `linkerSettings` in `Package.swift` must only name system
frameworks that exist on watchOS. The `firebase_*_watchos` packages in
[`flutterwatch/plugins`](https://github.com/flutterwatch/plugins) are
worked examples.

### Remote notifications

watchOS delivers the APNs device token and remote-notification payloads
only to the app-level `WKApplicationDelegate`, and
`UNUserNotificationCenter` has a single process-global delegate slot. Both
are owned by `FlutterWatchOSAppDelegate` (from the `FlutterWatchOS`
module), which apps created by the current templates install via
`@WKApplicationDelegateAdaptor`. It rebroadcasts each callback on
`NotificationCenter.default` so plugins can observe them with no
compile-time coupling — no plugin should claim either delegate slot
itself:

| Name | userInfo |
|---|---|
| `FlutterWatchOSRemoteNotificationsDidRegister` | `"deviceToken": Data` |
| `FlutterWatchOSRemoteNotificationsDidFail` | `"error": Error` |
| `FlutterWatchOSRemoteNotificationDidReceive` | the raw APNs payload |
| `FlutterWatchOSNotificationWillPresent` | `"payload"` + mutable `"options"` dictionary — set `options["options"]` to a `UNNotificationPresentationOptions` raw value during the (synchronous) post |
| `FlutterWatchOSNotificationDidReceiveResponse` | `"payload"` + `"actionIdentifier"` |

Callbacks that fire before any plugin observer exists (an at-launch APNs
token, the tap that launched the app) are buffered; a plugin posts
`FlutterWatchOSRemoteNotificationObserversReady` once its observers are
installed and the delegate replays the buffered events.

A **host-module** app created before this delegate existed adopts it by
adding one line inside its `App` struct:

```swift
@WKApplicationDelegateAdaptor(FlutterWatchOSAppDelegate.self)
private var flutterAppDelegate
```

A **legacy runner** project (one that still compiles its own
`Runner/FlutterRunner.swift`) does not build the `FlutterWatchOS` module,
so `FlutterWatchOSAppDelegate` does not exist there — migrate the runner
to the current template first. The build prints a warning when a plugin
needs these callbacks and the app cannot deliver them.

## Porting an existing iOS plugin

`flutter-watchos plugin port` scaffolds a federated `*_watchos` package from
an existing iOS/macOS plugin, so you start from a wired-up package instead of
an empty one:

```sh
# from pub.dev
flutter-watchos plugin port --from-pub sensors_plus

# or from a git checkout
flutter-watchos plugin port --from-git https://github.com/… 
```

| Flag | Effect |
|---|---|
| `--from-pub <pkg>` | Fetch the source plugin from pub.dev |
| `--from-git <url>` | Fetch the source plugin from a git URL |
| `--dry-run` | Print what would be written without writing it |
| `--force` | Overwrite an existing output package |
| `--report` | Write a `PORTING_REPORT.md` (on by default) |
| `--include-example` | Wire the source plugin's example app up for watchOS |

What you get is the whole federated shell: `pubspec.yaml` with the `watchos:`
platform key and `ffiSymbols`, the Dart class implementing the upstream
platform interface, the `watchos/Classes/` native skeleton, and a
`PORTING_REPORT.md` listing every API the source plugin used with its watchOS
availability.

**The native implementation is yours to write.** The porter emits a scaffold,
not working code — it cannot know what the WatchKit or SwiftUI equivalent of
a given UIKit call should be. The report tells you which APIs carry over,
which need a substitute, and which have no watch equivalent at all; you fill
in the Swift/Objective-C behind the exported symbols.

See [plugin-porting.md](plugin-porting.md) for the full workflow, and
[flutterwatch/plugins](https://github.com/flutterwatch/plugins) for finished
examples — `path_provider_watchos` is the reference, and its `AUTHORING.md`
walks through the full recipe.
