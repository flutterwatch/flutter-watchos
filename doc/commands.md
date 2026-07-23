# Supported commands

The commands below mirror the [Flutter CLI](https://docs.flutter.dev/reference/flutter-cli)
where possible; watchOS-specific behaviour is called out per command.

## Global options

- ### `-d`, `--device-id`

  Target device ID. Without it the tool lists connected devices and prompts.

  ```sh
  flutter-watchos -d <device_id> [command]
  ```

- ### `-v`, `--verbose`

  Verbose output (`-vv` for maximum verbosity, including tool internals).

## Commands and examples

- ### `attach`

  Attach to an already-running app (debug/profile) for hot reload and
  DevTools.

  ```sh
  flutter-watchos attach --debug-url http://127.0.0.1:56342/abc123=/
  ```

  The VM Service URI is printed when the app is launched via
  `flutter-watchos run`; it is also visible in the device console logs.

- ### `build watchos`

  Build the watch app bundle (`Runner.app`).

  ```sh
  # Simulator — always a debug (JIT) build; the default mode is lowered
  # automatically (an explicit --release/--profile with --simulator errors,
  # because there is no AOT Simulator engine)
  flutter-watchos build watchos --simulator

  # Physical watch, AOT
  flutter-watchos build watchos --profile
  flutter-watchos build watchos --release
  ```

  **Debug mode is not supported on a physical watch.** Debug requires a JIT
  engine, and the watchOS device SDK removes the Mach APIs the Dart JIT VM
  needs. The Simulator is the debug/hot-reload path; use `--profile` for
  realistic on-device testing and `--release` for shipping. Device builds
  require Xcode code signing with a valid development team.

  To ship to the App Store, `build watchos --release` first, then archive in
  Xcode (Product → Archive) and distribute from the Organizer — see
  [publish-app.md](publish-app.md).

- ### `clean`

  Remove the project's build artifacts and intermediates.

  ```sh
  flutter-watchos clean
  ```

- ### `create`

  Create a new Flutter project with a watchOS runner.

  ```sh
  # New app
  flutter-watchos create my_app --platforms=watchos

  # Add watchOS to an existing Flutter project (run in the project dir)
  flutter-watchos create . --platforms=watchos
  ```

  `--platforms=watchos` is accepted even though stock Flutter would reject
  it; combined lists like `--platforms=ios,watchos` work too.

  `--template=plugin` / `--template=plugin_ffi` are **not** supported:
  stock Flutter's plugin templates generate method-channel (or
  native-assets) code, and neither model runs on watchOS. To create a
  watchOS plugin, port an existing one (`flutter-watchos plugin port`) or
  author an FFI package by hand — see [plugins.md](plugins.md).

  `create` also wires up the app's **host mode** from the project shape: a
  watchOS-only project is *standalone* (watch-only app inside a thin iOS
  container), while a project with an `ios/` app gets the watch app embedded
  as its *companion*. Nothing is configured anywhere — like stock Flutter
  platforms, the `ios/` directory is the source of truth, and
  `build`/`run` re-derive the mode the same way. See the `host` command.

- ### `devices`

  List available watch targets: Simulators (via `simctl`) and paired
  physical watches (via `devicectl`).

  ```sh
  flutter-watchos devices
  ```

- ### `doctor`

  Verify the toolchain: Xcode + watchOS SDKs, simulator runtimes, engine
  artifacts, and CLI health.

  ```sh
  flutter-watchos doctor -v
  ```

- ### `drive`

  Run integration tests (`integration_test/`) on a simulator.

  ```sh
  flutter-watchos drive --target=integration_test/app_test.dart -d <simulator-id>
  ```

- ### `host`

  Report how the watch app ships to the App Store, and heal the wiring if
  it has drifted. Apple has no watch-only submission path — every watch app
  lives inside an iOS app's `Watch/` folder; what varies is what that iOS
  app is, and the project shape decides it:

  - **standalone** (no iOS app) — the watch app is watch-only
    (`WKWatchOnly`) and ships inside the thin `HostApp` container generated
    in `watchos/`.
  - **companion** (`ios/` Flutter app present) — the watch app ships inside
    it: the iOS Runner gets an "Embed Prebuilt watchOS App" build phase and
    the watch Info.plist declares `WKCompanionAppBundleIdentifier`.

  ```sh
  flutter-watchos host    # report the mode + reconcile the wiring
  ```

  There is nothing to configure: add an iOS app (`flutter create
  --platforms=ios .`) and the watch app becomes its companion on the next
  `create`/`build`/`run`; remove `ios/` and it is watch-only again. In
  companion mode, build the watch app first (`flutter-watchos build watchos
  --release`), then archive the `ios/` project as usual — see
  [publish-app.md](publish-app.md).

- ### `login` / `logout`

  Connect this machine to your flutterwatch.dev account (required to
  download engine artifacts; joining the closed beta is self-serve at
  flutterwatch.dev).

  ```sh
  flutter-watchos login
  flutter-watchos logout
  ```

  `login` prints a URL plus a short code; approve it in a browser and the
  CLI finishes automatically. Credentials are stored in
  `~/.flutter-watchos/credentials.json`. See [accounts.md](accounts.md).

- ### `precache`

  Download the watchOS engine artifacts ahead of time (otherwise fetched on
  first build). `--force` re-downloads.

  ```sh
  flutter-watchos precache
  ```

- ### `plugin`

  Inspect the plugins a project uses and their watchOS support, or
  scaffold a `*_watchos` FFI package from an existing iOS/macOS plugin
  (see [plugin-porting.md](plugin-porting.md)).

  ```sh
  flutter-watchos plugin list
  flutter-watchos plugin port --from-pub url_launcher_ios
  ```

- ### `run`

  Build, install, and launch. On a simulator this is the full debug
  experience: hot reload (`r`), hot restart (`R`), DevTools.

  ```sh
  flutter-watchos run -d <simulator-id>            # debug + hot reload
  flutter-watchos run -d <watch-id> --profile      # AOT on a physical watch
  ```

  Mode and target must agree: a physical watch needs `--profile` or
  `--release` (there is no device debug/JIT engine), and a simulator run is
  always debug (its engine is JIT-only). The tool rejects the impossible
  combinations with guidance instead of attempting the build.

  Physical-watch installs go through `devicectl` to the paired watch; see
  [debug-app.md](debug-app.md) for pairing/tunnel troubleshooting.

- ### `test`

  Run Dart unit/widget tests (host-side, no watch needed).

  ```sh
  flutter-watchos test
  ```

- ### `upgrade`

  Upgrade the flutter-watchos toolchain to its latest release tag (this
  moves the pinned Flutter SDK and engine together — never upgrade the
  vendored Flutter SDK yourself).

  ```sh
  flutter-watchos upgrade
  ```

- ### `upload`

  Validate and upload an `.ipa` (exported from Xcode's Archive →
  Distribute, or passed with `--ipa`) to App Store Connect, authenticated
  with an App Store Connect API key. Optional — you can also upload straight
  from the Xcode Organizer.

  ```sh
  flutter-watchos upload --api-key-id ABC123XYZ --api-issuer 12345678-...
  flutter-watchos upload --validate-only    # App Store checks, no upload
  ```

  The key id/issuer can also come from `APP_STORE_CONNECT_API_KEY_ID` /
  `APP_STORE_CONNECT_API_ISSUER`; the `.p8` secret is read by Apple's
  tooling from `~/.appstoreconnect/private_keys/` and never touched by
  flutter-watchos.

## Forwarded commands

These stock Flutter commands work unchanged: `assemble`, `channel`,
`config`, `daemon`, `downgrade`, `emulators`, `generate`, `gen-l10n`,
`install`, `logs`, `pub` / `packages`, `screenshot`, `shell-completion`,
`symbolize`.
