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
  # Simulator, debug (JIT — the only debug target)
  flutter-watchos build watchos --simulator --debug

  # Physical watch, AOT
  flutter-watchos build watchos --profile
  flutter-watchos build watchos --release
  ```

  **Debug mode is not supported on a physical watch.** Debug requires a JIT
  engine, and the watchOS device SDK removes the Mach APIs the Dart JIT VM
  needs. The Simulator is the debug/hot-reload path; use `--profile` for
  realistic on-device testing and `--release` for shipping. Device builds
  require Xcode code signing with a valid development team.

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

  # New plugin project
  flutter-watchos create --template=plugin --platforms=watchos my_plugin
  ```

  `--platforms=watchos` is accepted even though stock Flutter would reject
  it; combined lists like `--platforms=ios,watchos` work too.

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

- ### `login` / `logout`

  Connect this machine to your flutterwatch.dev account (required to
  download engine artifacts; during the closed beta, access is by invite).

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

  Inspect the plugins a project uses and their watchOS support.

  ```sh
  flutter-watchos plugin list
  ```

- ### `run`

  Build, install, and launch. On a simulator this is the full debug
  experience: hot reload (`r`), hot restart (`R`), DevTools.

  ```sh
  flutter-watchos run -d <simulator-id>            # debug + hot reload
  flutter-watchos run -d <watch-id> --profile      # AOT on a physical watch
  ```

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

## Forwarded commands

These stock Flutter commands work unchanged: `assemble`, `channel`,
`config`, `daemon`, `downgrade`, `emulators`, `generate`, `gen-l10n`,
`install`, `logs`, `pub` / `packages`, `screenshot`, `shell-completion`,
`symbolize`.
