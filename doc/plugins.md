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

`ffiSymbols` lists every exported C function; the CLI force-references
each so it survives the static link. Finished examples live in the
[flutterwatch/plugins](https://github.com/flutterwatch/plugins) repo —
`path_provider_watchos` is the reference, and its `AUTHORING.md` walks
through the full recipe.

## Porting an existing iOS plugin

`flutter-watchos plugin port` scaffolds a federated `*_watchos` FFI
package from an existing iOS/macOS plugin, and generates a
`PORTING_REPORT.md` mapping the source's API usage to watchOS
availability:

```sh
flutter-watchos plugin port --from-pub url_launcher_ios
```

See [plugin-porting.md](plugin-porting.md) for the full workflow.
