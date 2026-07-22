# flutter-watchos

A Flutter toolchain for building and running Flutter apps on **Apple Watch (watchOS)**.

`flutter-watchos` is a drop-in CLI companion to the Flutter SDK — same commands, same hot reload (on the Simulator), same DevTools — targeting watchOS instead of iOS.

> **macOS only.** Xcode is required.

> **Closed beta.** The watchOS engine ships as pre-built binaries tied to your account. Joining is self-serve and instant — sign in with GitHub at [flutterwatch.dev](https://flutterwatch.dev), then `flutter-watchos login`.

## Current version

- flutter-watchos: `0.1.0`
- Flutter SDK: `3.44.4` (`ad70ec4617166f1c38e5d2bfd388af71fda14f06`)
- watchOS engine artifacts: `v0.1.0-flutter3.44.4`

## Installation

```sh
git clone https://github.com/flutterwatch/flutter-watchos.git
cd flutter-watchos
export PATH="$PATH:$PWD/bin"
flutter-watchos login      # connect your flutterwatch.dev account (beta access)
flutter-watchos precache   # download the watchOS engine
flutter-watchos doctor
```

See [Getting started](doc/get-started.md) for the full setup guide.

## Usage

`flutter-watchos` substitutes the original [`flutter`](https://docs.flutter.dev/reference/flutter-cli) CLI command.

```sh
# Check the installed tooling and list all connected devices.
flutter-watchos doctor -v
flutter-watchos devices

# Create a new app project.
flutter-watchos create my_watch_app --platforms=watchos
cd my_watch_app

# Build and run on a watchOS Simulator (debug — hot reload + DevTools).
flutter-watchos run -d <simulator_id>

# Build and run on a paired Apple Watch (AOT — profile has logging + DevTools).
flutter-watchos run -d <watch_id> --profile
flutter-watchos run -d <watch_id> --release
```

- See [Supported commands](doc/commands.md) for all available commands and usage examples.
- See [Getting started](doc/get-started.md) to create your first app and try **hot reload**.
- To **update** flutter-watchos to the latest released version, run `flutter-watchos upgrade` (use `flutter-watchos upgrade --verify-only` to just check).

## Platform identity & limitations

flutter-watchos treats watchOS as its **own platform** at both the build and runtime layers. Read this section before adding dependencies to an existing iOS codebase — the separation has real consequences for plugins and cross-platform apps.

### Runtime identity

On a watchOS build, the Dart VM reports:

| API | Value on watchOS | Value on iOS |
|---|---|---|
| `Platform.operatingSystem` | `"watchos"` | `"ios"` |
| `Platform.isIOS` | **`true`** | `true` |
| `Platform.isWatchOS` | `true` | `false` |
| `defaultTargetPlatform` | `TargetPlatform.iOS` | `TargetPlatform.iOS` |

**`Platform.isWatchOS` exists only inside this toolchain — don't put it in shared code.** The getter comes from our Dart VM patch, so it is real when *we* build the watch app, but it is absent from the stock Dart SDK. That has two consequences, and the second one is the serious one:

- Your IDE reports `The getter 'isWatchOS' isn't defined for the type 'Platform'`, because the analyzer resolves `dart:io` from the stock SDK even here.
- **Building the same file with regular Flutter fails outright** — `Error: Member not found: 'isWatchOS'`. Not a warning; the iOS and Android builds stop. Any `lib/` file shared with your iPhone or Android target must never name it.

Write `FlutterWatchosPlatform.isWatch` (from the `flutter_watchos` package) instead. It is a plain `operatingSystem == "watchos"` comparison, so it compiles under every toolchain and answers `false` off the watch. Reach for `Platform.isWatchOS` only in watch-only code that no stock Flutter build ever compiles.

**`Platform.isIOS` is `true` on watchOS.** Apple Watch runs the same Darwin kernel and Foundation as iPhone and iPad — it's part of the iOS family. Standard Flutter widgets that branch on `Platform.isIOS` or `defaultTargetPlatform` already render with iOS styling (Cupertino, SF font) on the watch, with no Flutter framework changes required.

The Flutter framework that flutter-watchos uses is unmodified. watchOS identity is contributed entirely by the Dart VM in our engine build and by the `flutter-watchos` CLI itself.

### Plugin platform key

A Flutter plugin advertises which platforms it supports under `flutter.plugin.platforms` in its `pubspec.yaml`. Plugins target watchOS by adding a `watchos:` entry there:

```yaml
flutter:
  plugin:
    platforms:
      watchos:
        pluginClass: MyPlugin
```

A watchOS build only loads plugins that declare this key. Plugins targeting only `ios:` are not picked up — Apple Watch has a different surface (no WebKit, Digital Crown input, a tiny screen), so the safe default is to require explicit opt-in.

The first-party [`flutter_watchos`](packages/flutter_watchos) package adds the watch-specific APIs the framework doesn't cover: Digital Crown scrolling and raw input, Taptic Engine haptics, device info, and the system-clock toggle. A plugin that only implements iOS or macOS needs a watchOS implementation added under this key — see [Using and writing watchOS plugins](doc/plugins.md). `flutter-watchos plugin port --from-pub <package>` scaffolds that federated `*_watchos` package for you, along with a report of how each API the plugin uses fares on watchOS — you supply the native implementation.

### Writing cross-platform apps (iOS + Android + watchOS)

If your app already targets iOS/Android and you're adding watchOS support, keep these patterns in mind:

**1. Don't rely on `Platform.isIOS` alone for "phone/tablet iOS" logic.** It's also `true` on Apple Watch. Refine with the `flutter_watchos` helpers:

```dart
import 'package:flutter_watchos/flutter_watchos.dart';

if (FlutterWatchosPlatform.isIos) {        // iPhone / iPad only (NOT watchOS)
  // Use iPhone-specific plugin
}

if (FlutterWatchosPlatform.isWatch) {      // Apple Watch only
  // compact, crown-driven UI
}

if (FlutterWatchosPlatform.isAppleMobile) {// iPhone, iPad, OR Apple Watch
  // Any iOS-family OS (Foundation present)
}
```

**2. Design for the watch screen and the Digital Crown.** Apps are small, scrollable, single-focus. Wrap scrollables in `WatchCrownScroll` for the native crown feel, or take the crown as raw input with `WatchCrown` for games and pickers. Handle the wrist going down with `WatchAlwaysOnBuilder` — watchOS keeps your app on screen, dimmed, so pause animations and hide private content. See the [`flutter_watchos`](packages/flutter_watchos) README.

**3. Plugin dependencies:** if your iOS app uses `url_launcher`, `shared_preferences`, `path_provider`, etc., each one needs a watchOS federated package or your watch build will compile but calls will throw `MissingPluginException` at runtime. Audit your `pubspec.yaml` for plugins with native iOS code before porting.

**4. `ios/` and `watchos/` directories are independent.** `flutter-watchos create` scaffolds a `watchos/` project with its own Info.plist and SwiftUI runner. Don't share it with `ios/` — the build settings diverge (watchOS SDK, arm64-only).

### Known limitations

- **Apple Watch Series 9 / Ultra 2 or later** for on-device runs. The engine is arm64-only; when `WATCHOS_DEPLOYMENT_TARGET < 27.0` the executable needs an arm64_32 slice, so the template ships a stub slice and a "Requires Apple Watch Series 9 or later" fallback screen for older watches.
- **No debug (JIT) on a physical watch.** The watchOS device SDK removes the Mach APIs the Dart JIT VM needs, so device-debug cannot even be built. **Debug + hot reload run on the Simulator; a physical watch runs AOT** (`--profile` for logging/DevTools, `--release` for shipping).
- **Profile on a physical watch.** The Simulator does not reflect real on-device performance — always validate on an actual Apple Watch before shipping.
- **iOS plugins don't automatically work.** Packages need a watchOS implementation (see the plugin key above); pure-Dart packages are unaffected.
- **No WebKit / `webview_flutter`.** watchOS does not ship WebKit; plugins depending on `WKWebView` will not compile.
- **App Store submission needs an iOS container.** `create` scaffolds a single independent watch app for `build`/`run`; wrapping it in an iOS companion archive for submission is handled separately — see [Publishing](doc/publish-app.md).

Text input (the system keyboard), Digital Crown scrolling and haptics, and app-lifecycle events (`WidgetsBindingObserver`) are all supported.

## Docs

#### App development

- [Getting started](doc/get-started.md)
- [Supported commands](doc/commands.md)
- [Debugging apps](doc/debug-app.md)
- [Fragment shaders](doc/shaders.md)
- [Publishing to the App Store](doc/publish-app.md)
- [Accounts & engine artifacts](doc/accounts.md)

#### Plugin development

- [Using and writing watchOS plugins](doc/plugins.md)

#### Project internals

- [Architecture](doc/architecture.md)

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for details.

```sh
# Run tests
flutter/bin/dart test test/general
```

## License

BSD 3-Clause — see [LICENSE](LICENSE).

This project incorporates code from Flutter and flutter-tizen (both BSD 3-Clause). The pre-built engine artifacts bundle the Flutter engine and Dart SDK; their aggregated open-source license ships inside each artifact. See [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md) for full attribution.

---

_flutter-watchos is an independent project and is not affiliated with, endorsed by, or sponsored by Google LLC or Apple Inc. Flutter and Dart are trademarks of Google LLC. Apple Watch and watchOS are trademarks of Apple Inc._
