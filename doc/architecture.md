# Architecture

How flutter-watchos gets Flutter running on a platform Flutter doesn't
support.

## The CLI: flutter_tools with watchOS overrides

flutter-watchos is **not a Flutter fork**. It wraps an unmodified Flutter
SDK (pinned in `bin/internal/flutter.version`) and injects watchOS behaviour
through flutter_tools' dependency-injection seams — custom `Cache`,
`Artifacts`, `DeviceManager`, build targets, and commands. The first run
bootstraps: clone the pinned SDK, compile the tool to a snapshot, go.

Upgrades move the pinned SDK and the engine together (`flutter-watchos
upgrade`); mixing your own Flutter checkout in would break the engine pin.

## The engine: pre-built, closed-source, account-gated

The watchOS engine (a patched Flutter engine built for
`watchos`/`watchsimulator`) ships as pre-built binaries downloaded from
flutterwatch.dev — signing in with `flutter-watchos login` ties downloads to
your account. The engine source is not distributed. Variants:

| Artifact | Runs on | Mode |
|---|---|---|
| `watchos_debug_sim_arm64` | Simulator | Debug (JIT, hot reload) |
| `watchos_profile_arm64` | Physical watch | Profile (AOT, non-product) |
| `watchos_release_arm64` | Physical watch | Release (AOT) |
| `host_debug_unopt`, `host_release` | Your Mac | AOT host SDKs (`gen_snapshot` inputs) |

There is no device-debug variant: the Dart JIT VM cannot exist on watchOS
(the device SDK removes the required Mach exception APIs), which is why
debug is Simulator-only.

## The embedder: a SwiftUI runner

watchOS has no UIKit, so the iOS `Flutter.framework` model doesn't apply.
The `create` template emits a small SwiftUI runner (`watchos/Runner/`) that
hosts the Flutter engine. It is generic glue — identical for every app — and
rendering, input, and text input are handled by the engine, so improvements
ship with engine updates without touching your app project:

- **Rendering.** Your Flutter UI is displayed by the runner. GPU-intensive
  effects (custom fragment shaders, heavy blurs) aren't a good fit for the
  watch — keep visuals lightweight and profile on a real device.
- **Input.** Touch and the Digital Crown work out of the box, with a native
  scroll feel. Raw crown input is available to Dart via the `flutter_watchos`
  package's `WatchCrown` for games, pickers, and custom controls.
- **Text input** works with no app code: tapping a Flutter `TextField` raises
  the watchOS system keyboard, with pre-filled text, `obscureText` masking,
  and edits round-tripping back into your Dart controllers.
- **Lifecycle & channels.** Standard platform messages and
  `WidgetsBindingObserver` lifecycle events work; plugins use Dart FFI or the
  platform messenger.

## Platform identity

Apps see honest-but-compatible platform values:

| Check | Value | Why |
|---|---|---|
| `Platform.operatingSystem` | `"watchos"` | Honest OS name |
| `Platform.isIOS` | `true` | watchOS is iOS-family; keeps Cupertino defaults, fonts, transitions |
| `Platform.isWatchOS` | `true` | First-class watch check |
| `defaultTargetPlatform` | `TargetPlatform.iOS` | Same reason as `isIOS` |

Branch watch-specific UI on `Platform.isWatchOS` (or
`operatingSystem == "watchos"`), never on screen size alone.

## Build pipeline

- **Simulator (debug):** kernel compile (JIT) + `xcodebuild` against
  `watchsimulator`, engine dylib embedded. Hot reload/restart work as usual.
- **Device (profile/release):** `gen_snapshot` AOT-compiles your Dart to an
  `App.dylib` against the patched host SDK, then `xcodebuild` against
  `watchos` with code signing. `--target-os` folding is deliberately
  disabled so platform identity resolves at runtime against the engine.
- **arm64_32:** when `WATCHOS_DEPLOYMENT_TARGET < 27.0` the App Store
  requires an `arm64_32` slice in the watch executable. The engine is
  arm64-only, so the template ships a stub arm64_32 slice with a "Requires
  Apple Watch Series 9 or later" fallback screen; only the executable needs
  the fat slice, not the frameworks.

## Repository layout

```
flutter-watchos/
├── bin/                 # entrypoints + pinned Flutter/engine versions
├── lib/                 # the CLI: DI overrides over flutter_tools
│   ├── commands/        # build, run, create, login, …
│   └── build_targets/   # xcodebuild + AOT orchestration
├── templates/           # `create` scaffold (SwiftUI runner)
└── (flutter/, engine_artifacts/ — gitignored, created by bootstrap)
```
