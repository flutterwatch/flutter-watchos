# Get started

flutter-watchos builds and runs Flutter apps on **Apple Watch**. It is a
standalone CLI that wraps an unmodified Flutter SDK and a pre-built watchOS
engine — you don't need (and shouldn't mix in) a custom Flutter checkout.

## Requirements

- macOS with **Xcode 26+** and the watchOS SDK (`xcodebuild -showsdks` should
  list `watchos` and `watchsimulator`).
- A watchOS Simulator runtime (Xcode → Settings → Components), or a paired
  physical Apple Watch for on-device runs.
- A [flutterwatch.dev](https://flutterwatch.dev) account — engine artifact
  downloads are tied to your account. During the closed beta, access is by
  invite.

## 1. Install the CLI

```sh
git clone https://github.com/flutterwatch/flutter-watchos.git
export PATH="$PATH:$(pwd)/flutter-watchos/bin"
```

The first run bootstraps everything (downloads the pinned Flutter SDK and
compiles the tool); later runs start instantly.

## 2. Sign in and check your setup

```sh
flutter-watchos login    # connects this machine to your flutterwatch.dev account
flutter-watchos doctor   # verifies Xcode, SDKs, simulators, and engine artifacts
```

`login` prints a URL and a short code — open the URL, sign in with GitHub,
and confirm the code. `doctor` then downloads the engine artifacts on first
use (or run `flutter-watchos precache` explicitly).

## 3. Create an app

```sh
flutter-watchos create my_watch_app --platforms=watchos
cd my_watch_app
```

This scaffolds a standard Flutter project plus a `watchos/` runner: a small
SwiftUI app that hosts the Flutter engine (see
[architecture.md](architecture.md)). Your Dart code lives in `lib/` exactly
like any Flutter app.

## 4. Run it

```sh
flutter-watchos devices                 # list watch simulators + paired watches
flutter-watchos run -d <simulator-id>   # debug (JIT) with hot reload
```

For a physical watch, build in profile or release mode (debug requires a JIT
engine, which watchOS devices cannot run — see
[commands.md](commands.md#build-watchos)):

```sh
flutter-watchos run -d <watch-id> --profile
```

## 5. Where to go next

- [commands.md](commands.md) — every supported command with examples
- [architecture.md](architecture.md) — how the embedder works (rendering,
  input, text entry, platform identity)
- [debug-app.md](debug-app.md) — attaching a debugger, logs, common issues
- [publish-app.md](publish-app.md) — release builds and App Store submission
- [accounts.md](accounts.md) — login, credentials, environment variables
- [plugins.md](plugins.md) — using and writing watchOS plugins
