# Getting started

flutter-watchos builds and runs Flutter apps on **Apple Watch**. It is a
standalone CLI that wraps an unmodified Flutter SDK and a pre-built watchOS
engine — you don't need (and shouldn't mix in) a custom Flutter checkout.

## Requirements

- **macOS** with **Xcode 26+** and the watchOS SDK (`xcodebuild -showsdks`
  should list `watchos` and `watchsimulator`). Accept the license once:

  ```sh
  sudo xcodebuild -license accept
  ```

- A watchOS Simulator runtime (Xcode → Settings → Components), or a paired
  physical Apple Watch (Series 9 / Ultra 2 or later) for on-device runs.
- A [flutterwatch.dev](https://flutterwatch.dev) account — engine artifact
  downloads are tied to your account. Joining the closed beta is self-serve:
  sign in with GitHub at [api.flutterwatch.dev](https://api.flutterwatch.dev)
  and click "Join the beta" — you're in immediately. Beta accounts build and
  run in debug and profile modes.

## 1. Install the CLI

```sh
git clone https://github.com/flutterwatch/flutter-watchos.git
cd flutter-watchos
export PATH="$PATH:$PWD/bin"     # add to ~/.zshrc to make it permanent
```

The first run bootstraps everything (downloads the pinned Flutter SDK and
compiles the tool); later runs start instantly.

## 2. Sign in and check your setup

```sh
flutter-watchos login    # connects this machine to your flutterwatch.dev account
flutter-watchos precache # downloads the watchOS engine artifacts
flutter-watchos doctor   # verifies Xcode, SDKs, simulators, and engine
```

`login` prints a URL and a short code — open the URL, sign in with GitHub, and
confirm the code. Only the `Flutter` and `Xcode` entries in `doctor` are
required; Android-related warnings can be ignored.

During the closed beta, `precache` fetches the debug (Simulator) and profile
(device) engines; the release engines are reported as "not in the closed
beta, skipped" — that is expected and everything you need. If your account
later gains release access (your dashboard at
[api.flutterwatch.dev](https://api.flutterwatch.dev) will say "release engine
enabled"), just run `flutter-watchos precache` again — the release engines
download automatically.

```
$ flutter-watchos doctor
Doctor summary (to see all details, run flutter-watchos doctor -v):
[✓] Flutter (3.44.4, on macOS)
[✓] Xcode - develop for iOS and watchOS
[✓] Connected device (1 available)
```

## 3. Set up a watchOS simulator

flutter-watchos does not include a simulator manager — simulators are created
in Xcode:

1. Open Xcode → **Window → Devices and Simulators**.
2. Select the **Simulators** tab, then click **+**.
3. Set **Simulator Type** to an Apple Watch (e.g. *Apple Watch Series 11
   (46mm)*) and pick a watchOS runtime (26.0 or later).

Once booted, it appears in `flutter-watchos devices`. No code signing is needed
for simulator builds; a physical watch needs a `DEVELOPMENT_TEAM` set in Xcode.

## 4. Create an app

```sh
flutter-watchos create my_watch_app --platforms=watchos
cd my_watch_app
```

This scaffolds a standard Flutter project plus a `watchos/` runner: a small
SwiftUI app that hosts the Flutter engine (see
[architecture.md](architecture.md)). Your Dart code lives in `lib/` exactly
like any Flutter app.

## 5. Run it

```sh
flutter-watchos devices                 # list watch simulators + paired watches
flutter-watchos run -d <simulator-id>   # debug (JIT) with hot reload
```

For a physical watch, build in profile or release mode — debug requires a JIT
engine, which watchOS devices cannot run (see
[commands.md](commands.md#build-watchos)):

```sh
flutter-watchos run -d <watch-id> --profile   # AOT, with logging + DevTools
flutter-watchos run -d <watch-id> --release   # AOT, fastest
```

## 6. Try hot reload

Hot reload applies Dart changes to the running app without losing state — it
works on the **watchOS Simulator** (debug/JIT). After `flutter-watchos run`,
the terminal shows:

```
Flutter run key commands.
r Hot reload.
R Hot restart.
h List all available interactive commands.
q Quit (terminate the application on the device).
```

1. Open `lib/main.dart` and make a visible change (e.g. edit a `Text` string).
2. Save, then press **`r`** in the terminal — the change appears immediately.

Press **`R`** for a full restart, or **`q`** to quit. (A physical watch runs
AOT, so hot reload is a Simulator-only workflow; iterate there, then run
`--profile`/`--release` on the watch.)

## Where to go next

- [commands.md](commands.md) — every supported command with examples
- [architecture.md](architecture.md) — how the embedder works (rendering,
  input, text entry, platform identity)
- [debug-app.md](debug-app.md) — attaching a debugger, logs, common issues
- [publish-app.md](publish-app.md) — release builds and App Store submission
- [accounts.md](accounts.md) — login, credentials, environment variables
- [plugins.md](plugins.md) — using and writing watchOS plugins
