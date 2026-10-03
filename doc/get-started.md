# Getting started

flutter-watchos builds and runs Flutter apps on **Apple Watch**. It is a
standalone CLI that wraps an unmodified Flutter SDK and a pre-built watchOS
engine — you don't need (and shouldn't mix in) a custom Flutter checkout.

## Requirements

- **macOS on an Apple Silicon Mac**, in a native (not Rosetta) terminal — the
  watchOS engine tools are arm64-only — with **Xcode 26+** and the watchOS SDK (`xcodebuild -showsdks`
  should list `watchos` and `watchsimulator`). Accept the license once:

  ```sh
  sudo xcodebuild -license accept
  ```

- A watchOS Simulator runtime (Xcode → Settings → Components), or a paired
  physical Apple Watch for on-device runs: Series 9 or later, Ultra 2 or
  later, or SE 3, on watchOS 26.0 or later.
- A [flutterwatch.dev](https://flutterwatch.dev) account, for anything beyond
  the Simulator. The Simulator engine downloads without one; the engines for a
  physical watch and for release builds need you to be signed in.
  `flutter-watchos login` (step 2) is all it takes: the page it opens signs you
  in with GitHub, and that creates the account — no form, nothing to wait for.

## 1. Install the CLI

Clone the repository and put its `bin/` on your `PATH`. The `export` line
lasts for this shell:

```sh
git clone https://github.com/flutterwatch/flutter-watchos.git
cd flutter-watchos
export PATH="$PWD/bin:$PATH"
```

To make it permanent, run this in the same directory. It adds a line with the
checkout's full path to `~/.zshrc`, so every new terminal finds this
`flutter-watchos` first. (A line with `$PWD` in `~/.zshrc` would name whatever
directory a new terminal starts in.)

```sh
echo "export PATH=\"$(pwd)/bin:\$PATH\"" >> ~/.zshrc
```

The first run bootstraps everything (downloads the pinned Flutter SDK and
compiles the tool); later runs start instantly.

## 2. Sign in and check your setup

`login` connects this machine to your flutterwatch.dev account; skip it if the
Simulator is all you need for now. `precache` downloads the watchOS engine
artifacts, and `doctor` verifies Xcode, SDKs, simulators, and engine.

```sh
flutter-watchos login
flutter-watchos precache
flutter-watchos doctor
```

`login` prints a URL and a short code — open the URL, sign in with GitHub, and
confirm the code. There is nothing to do on the website beforehand.

Signed in, `precache` fetches every engine: debug (Simulator), profile and
release (device), and the two host SDKs the device builds compile against.
Signed out, it fetches the Simulator engine, reports the others as "needs an
account, skipped", and tells you how to get them: after `flutter-watchos
login`, the next build downloads only the missing engines (or run
`flutter-watchos precache` again to fetch them straight away).

`doctor` on a machine that skipped `login` (Android, Chrome and network
entries left out):

```
$ flutter-watchos doctor
Doctor summary (to see all details, run flutter doctor -v):
[✓] Flutter (3.47.5, pinned by flutter-watchos, on macOS …, locale …)
[✓] watchOS toolchain - develop for Apple Watch devices (Simulator engine, not signed in)
[✓] Xcode - develop for iOS and macOS (Xcode 27.0)
[✓] Connected device (3 available)
```

The `watchOS toolchain` entry is the one that matters: it checks Xcode, the
watchOS SDK and Simulator runtime, and says which engines are installed and
whether this machine is signed in (`flutter-watchos doctor -v` lists them).
Signed in with every engine, it reads `(all engines, signed in)`. The
`Flutter` entry is the Flutter SDK flutter-watchos pins: leave it off your
PATH and keep using your own `flutter` for other projects. Android and Chrome
warnings can be ignored.

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

`devices` lists watch simulators and paired watches. `run` on a simulator is
debug (JIT) with hot reload:

```sh
flutter-watchos devices
flutter-watchos run -d <simulator-id>
```

For a physical watch, build in profile or release mode — debug requires a JIT
engine, which watchOS devices cannot run (see
[commands.md](commands.md#build-watchos)). Profile is AOT with logging and
DevTools:

```sh
flutter-watchos run -d <watch-id> --profile
```

Release is AOT and fastest:

```sh
flutter-watchos run -d <watch-id> --release
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

## Fitting phone-designed UIs: content scale

UI designed for a phone often doesn't fit a ~200-logical-pixel watch screen.
Instead of restyling every widget, you can shrink the whole app
proportionally — same layout ratio, smaller components — with one setting in
`watchos/Runner/Info.plist`:

```xml
<key>FlutterWatchOSContentScale</key>
<real>0.6</real>
```

`0.6` means the app lays out in a logical space `1/0.6 ≈ 1.7×` the screen in
each dimension, rendered at 60% size. Physical sharpness is unchanged (the
rendered pixel count is identical); touches, the Digital Crown, and native
overlays are converted automatically. Values are clamped to `0.3 – 1.0`
(default `1.0`); below ~0.5, expect text to be hard to read at watch
distance — purpose-built watch UI at the default scale is always the better
end state, so treat this as a porting aid, not a design strategy.

The same file takes `FlutterWatchOSSafeArea`, which chooses whether the safe
area keeps content below the clock or, by default, only clear of the screen's
rounded corners. [layout.md](layout.md) explains both values.

## Where to go next

- [commands.md](commands.md) — every supported command with examples
- [layout.md](layout.md) — the safe area and the clock, and how to lay out
  lists, fixed screens and games around them
- [architecture.md](architecture.md) — how the embedder works (rendering,
  input, text entry, platform identity)
- [debug-app.md](debug-app.md) — attaching a debugger, logs, common issues
- [publish-app.md](publish-app.md) — release builds and App Store submission
- [accounts.md](accounts.md) — login, credentials, environment variables
- [plugins.md](plugins.md) — using and writing watchOS plugins
