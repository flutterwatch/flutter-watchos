# flutter-watchos

A standalone CLI that builds and runs Flutter apps on **Apple Watch
(watchOS)** — a custom embedder wrapping an unmodified Flutter SDK with
pre-built watchOS engine artifacts. Flutter has no official watchOS support;
this provides it.

> The watchOS engine is **closed-source** and never committed here. The CLI
> consumes pre-built engine bundles only.

## This repository (CLI only)

```
flutter-watchos/
├── bin/                 # Shell + Dart entrypoints, pinned Flutter version, shared.sh
├── lib/                 # The CLI (Dart) — DI overrides over flutter_tools
│   ├── commands/        # build, run, create, devices, doctor, upgrade, plugin, …
│   └── build_targets/   # xcodebuild orchestration + AOT (embedder model)
├── templates/           # watchOS app scaffold emitted by `create`
│   └── app/swift/watchos.tmpl/   # single independent watch app (WKWatchOnly)
├── pubspec.yaml  analysis_options.yaml  LICENSE
└── (flutter/, engine_artifacts/ — gitignored runtime)
```

Supporting material (engine packaging scripts, demo apps, federated plugins)
lives **outside** this repo in the surrounding workspace so the CLI stays
CLI-only — see the workspace README one level up.

## How watchOS differs from a normal Flutter target

- `create` scaffolds a **single independent watch app** (`WKWatchOnly`,
  `Runner.app`) — the minimum needed to `build` and `run`. It installs and
  launches directly on the simulator or a paired watch. (App Store submission
  additionally needs an iOS container archive; that wrapping is handled
  separately at submit time, not in the run template.)
- The watch app is a **SwiftUI app driving the Flutter embedder C API with
  software rendering** (no GPU on Apple Watch): `Runner/FlutterRunner.swift`
  hosts the engine, publishes CGImage frames, and forwards Digital Crown + touch
  input. This is **not** the iOS `Flutter.framework` / plugin-registrar model.
- The watch executable needs an **arm64_32** slice when
  `WATCHOS_DEPLOYMENT_TARGET < 27.0`; the engine is arm64-only, so the template
  ships a stub arm64_32 slice + a "Requires Apple Watch Series 9 or later"
  fallback (`#if arch(arm64_32)`).

## Quick commands

```bash
flutter-watchos login    # connect to your flutterwatch.dev account
flutter-watchos doctor
flutter-watchos create my_app --platforms=watchos
flutter-watchos build watchos --simulator --debug
flutter-watchos run -d <watch-simulator-id>
```

## Documentation

| Guide | Covers |
|---|---|
| [doc/get-started.md](doc/get-started.md) | Install → sign in → create → run |
| [doc/commands.md](doc/commands.md) | Every supported command, with examples |
| [doc/architecture.md](doc/architecture.md) | How the embedder works (rendering, input, text entry, platform identity) |
| [doc/debug-app.md](doc/debug-app.md) | Hot reload, attach, logs, device quirks |
| [doc/publish-app.md](doc/publish-app.md) | Release builds, iOS container, App Store |
| [doc/accounts.md](doc/accounts.md) | Login, credentials, environment variables |
| [doc/plugins.md](doc/plugins.md) | Using and writing watchOS plugins |

## Engine artifacts

Engine binaries are downloaded from flutterwatch.dev, tied to your account
(`flutter-watchos login`); during the closed beta, access is by invite. For
local engine development, point the CLI at a packaged engine output instead:

```bash
export WATCHOS_ENGINE_ARTIFACTS=/path/to/engine_artifacts
```

## Beta status & known limitations

flutter-watchos is in **closed beta** (access by invite at
[flutterwatch.dev](https://flutterwatch.dev)). Current limitations:

- **Apple Watch Series 9 / Ultra 2 or later** for on-device runs (the engine
  is arm64-only; older watches get the fallback screen).
- **No debug mode on a physical watch** (watchOS cannot run the Dart JIT) —
  debug + hot reload on the Simulator, `--profile`/`--release` on device.
- **Software rendering** — fine for watch-sized UIs; Simulator performance
  is not representative, profile on a real watch.
- **iOS plugins don't automatically work** — packages need a watchOS
  implementation (see [doc/plugins.md](doc/plugins.md)); pure-Dart packages
  are unaffected.

Found something else? Please file a bug or beta-feedback issue.

## License & attribution

The CLI is BSD-3-Clause ([LICENSE](LICENSE)); it incorporates code from the
Flutter tools and flutter-tizen — see
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md). The pre-built engine
artifacts bundle the Flutter engine and Dart SDK; their aggregated
open-source license file ships inside each artifact.

---

_flutter-watchos is an independent project and is not affiliated with,
endorsed by, or sponsored by Google LLC or Apple Inc. Flutter and Dart are
trademarks of Google LLC. Apple Watch and watchOS are trademarks of
Apple Inc._
