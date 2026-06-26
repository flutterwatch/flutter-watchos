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
│   └── app/swift/watchos.tmpl/   # iOS host container + embedded Watch/Runner.app
├── pubspec.yaml  analysis_options.yaml  LICENSE
└── (flutter/, engine_artifacts/ — gitignored runtime)
```

Supporting material (engine packaging scripts, demo apps, federated plugins)
lives **outside** this repo in the surrounding workspace so the CLI stays
CLI-only — see the workspace README one level up.

## How watchOS differs from a normal Flutter target

- The shippable product is an **iOS host container** (`ITSWatchOnlyContainer`)
  that embeds the watch app at `Watch/Runner.app`.
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
engine-artifacts releases (or extracts local zips from the workspace
`artifacts/` directory).
