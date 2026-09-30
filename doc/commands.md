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

  For the Simulator it is always a debug (JIT) build. The default mode is
  lowered automatically, and an explicit `--release` or `--profile` with
  `--simulator` is an error, because there is no AOT Simulator engine:

  ```sh
  flutter-watchos build watchos --simulator
  ```

  For a physical watch, build AOT:

  ```sh
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

  A new app:

  ```sh
  flutter-watchos create my_app --platforms=watchos
  ```

  To add watchOS to an existing Flutter project, run this in the project
  directory:

  ```sh
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

  Verify the toolchain: Xcode + watchOS SDKs, simulator runtimes, which
  engines are installed, whether this machine is signed in, and CLI health.
  It reads local files only. The `Flutter` entry shows the SDK flutter-watchos
  pins; leave that SDK off your PATH and keep your own `flutter` there.

  ```sh
  flutter-watchos doctor -v
  ```

- ### `drive`

  Run integration tests (`integration_test/`) on a simulator.

  ```sh
  flutter-watchos drive --driver=test_driver/integration_test.dart \
      --target=integration_test/app_test.dart -d <simulator-id>
  ```

  `--driver` is not optional unless the driver file is named after the target.
  Without it the tool looks for `test_driver/<target-basename>_test.dart` and
  fails with "Test file not found" — the convention in this repo's examples is
  a single `test_driver/integration_test.dart` shared by every target.

  Near the end of a run the app prints this warning:
  `Warning: integration_test plugin was not detected.` It is expected: the
  `integration_test` plugin has no watchOS registration, and the test
  results still arrive. For the same reason `binding.takeScreenshot` does
  not work on watchOS, under `drive` or under `test`.

  To run the same tests without a driver file, see [`test`](#test).

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

  `host` reports the mode and reconciles the wiring:

  ```sh
  flutter-watchos host
  ```

  There is nothing to configure: add an iOS app (`flutter create
  --platforms=ios .`) and the watch app becomes its companion on the next
  `create`/`build`/`run`; remove `ios/` and it is watch-only again. In
  companion mode, build the watch app first (`flutter-watchos build watchos
  --release`), then archive the `ios/` project as usual — see
  [publish-app.md](publish-app.md).

  For how to structure the shared Dart and how the two apps talk to each
  other, see [companion-apps.md](companion-apps.md).

- ### `build-registry`

  Show or change whether release builds are registered with your
  flutterwatch.dev account (what fills "My apps" in the console).

  On its own, the command shows the current state and what is sent:

  ```sh
  flutter-watchos build-registry
  ```

  `--disable` stops registering builds from this machine:

  ```sh
  flutter-watchos build-registry --disable
  ```

  `--enable` turns it back on:

  ```sh
  flutter-watchos build-registry --enable
  ```

  On by default. A registered build sends four fields — bundle id, app
  version, engine id, build mode — and prints a line saying so. See
  [the build registry](build-registry.md). `FLUTTER_WATCHOS_BUILD_REGISTRY=0`
  does the same for a CI job, and `build watchos --no-register-build` for a
  single build.

- ### `login` / `logout`

  Connect this machine to your flutterwatch.dev account. The Simulator
  engine downloads without one; the engines for a physical watch and for
  release builds need it. `login` is all it takes to get an account: the
  page it opens signs you in with GitHub, and that creates the account.

  ```sh
  flutter-watchos login
  flutter-watchos logout
  ```

  `login` prints a URL plus a short code; approve it in a browser and the
  CLI finishes automatically. Credentials are stored in
  `~/.flutter-watchos/credentials.json`, and the next build downloads the
  engines the machine was missing. `logout` revokes this machine's sign-in
  on the service, then removes the file. See [accounts.md](accounts.md).

- ### `precache`

  Download the watchOS engine artifacts ahead of time (otherwise fetched on
  first build). `--force` downloads them all again, and keeps the engine you
  had if that fails.

  ```sh
  flutter-watchos precache
  ```

- ### `plugin`

  Authoring helpers for watchOS plugins. Today the only one is `port`, which
  scaffolds a federated `*_watchos` FFI package from an existing iOS or
  macOS plugin (see [plugin-porting.md](plugin-porting.md)).

  ```sh
  flutter-watchos plugin port --from-pub url_launcher_ios
  ```

- ### `run`

  Build, install, and launch. On a simulator this is the full debug
  experience: hot reload (`r`), hot restart (`R`), DevTools.

  On a simulator, debug with hot reload:

  ```sh
  flutter-watchos run -d <simulator-id>
  ```

  On a physical watch, AOT:

  ```sh
  flutter-watchos run -d <watch-id> --profile
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

  With a device id, `test` runs an integration test in the app on a watch
  Simulator, with no `test_driver/` file. This works on the Simulator only.

  ```sh
  flutter-watchos test integration_test/<file>.dart -d <simulator-id>
  ```

  `binding.takeScreenshot` does not work on watchOS here either (see
  [`drive`](#drive)).

- ### `upgrade`

  Upgrade the flutter-watchos toolchain to its latest release tag (this
  moves the pinned Flutter SDK and engine together — never upgrade the
  vendored Flutter SDK yourself). The engine downloads again only when the
  new release pins a different one.

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
  ```

  `--validate-only` runs the App Store checks without uploading:

  ```sh
  flutter-watchos upload --validate-only
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
