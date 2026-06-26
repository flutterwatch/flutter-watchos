# flutter-watchos

An independent toolchain for building Flutter apps that run on **Apple Watch
(watchOS)** — a standalone CLI wrapping an unmodified Flutter SDK with pre-built
watchOS engine artifacts. Flutter has no official watchOS support; this provides
it via a custom embedder.

> The watchOS engine is **closed-source** and never committed here. The CLI
> consumes pre-built engine bundles only.

## Repository layout

```
flutter-watchos/
├── bin/                 # Shell + Dart entrypoints, pinned Flutter version, shared.sh
├── lib/                 # The CLI (Dart) — DI overrides over flutter_tools
│   ├── commands/        # build, run, create, devices, doctor, upgrade, plugin, …
│   └── build_targets/   # xcodebuild orchestration + AOT
├── templates/           # watchOS app scaffold emitted by `create`
│   └── app/swift/watchos.tmpl/   # iOS host container + embedded Watch/Runner.app
├── demo/                # Demo apps for testing the toolchain
│   └── counter/
├── plugins/             # Federated *_watchos plugins (see plugins/README.md)
├── engine_artifacts/    # Extracted engine bundles (gitignored, closed-source)
└── artifacts/           # Local engine zips for dev (gitignored)
```

## How watchOS differs from a normal Flutter target

- The shippable product is an **iOS host container** (`ITSWatchOnlyContainer`)
  that embeds the watch app at `Watch/Runner.app`.
- The watch app is a **SwiftUI app driving the Flutter embedder C API with
  software rendering** (no GPU on Apple Watch) — `Runner/FlutterRunner.swift`
  hosts the engine, publishes CGImage frames, and forwards Digital Crown + touch
  input. This is **not** the iOS `Flutter.framework` / plugin-registrar model.
- The watch executable needs an **arm64_32** slice when
  `WATCHOS_DEPLOYMENT_TARGET < 27.0` (App Store gate); the engine is arm64-only,
  so the template ships a stub arm64_32 slice + a "Requires Apple Watch Series 9
  or later" fallback screen (`#if arch(arm64_32)`).

## Quick commands

```bash
flutter-watchos doctor
flutter-watchos create my_app --platforms=watchos
flutter-watchos build watchos --simulator --debug
flutter-watchos run -d <watch-simulator-id>
```

## Engine artifacts

For local development, point the CLI at a packaged engine output:

```bash
export WATCHOS_ENGINE_ARTIFACTS=/path/to/engine_artifacts
```

Otherwise the CLI downloads pre-built bundles from the `flutterwatch`
engine-artifacts releases.
