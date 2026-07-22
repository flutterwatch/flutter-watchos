# Changelog

## Unreleased

- **Always-On**: the host module now reports the watchOS Always-On state (the
  wrist-down, reduced-luminance display) to Dart, where `WatchAlwaysOn` in
  `package:flutter_watchos` exposes it. The state is only readable through
  SwiftUI's `\.isLuminanceReduced`, so it has to come from the host; apps
  built before this ship keep working and report "not dimmed" (their
  `WatchAlwaysOn.isSupported` reads false). Needs `flutter_watchos`
  0.1.0-beta.6 or later; the wiring is skipped for apps that don't link it.
- **Signing**: device builds read `DEVELOPMENT_TEAM` from the Xcode project
  again when the value is quoted — which is how `create` writes it, so this
  affected every freshly created project. The team was silently not found and
  the build fell through to the keychain, signing with whatever identity was
  listed first and failing with `No Account for Team` naming an id that
  appears nowhere in the project. Setting `DEVELOPMENT_TEAM` in the
  environment was the workaround; it is no longer needed.
- **Signing**: when a project sets no team and the keychain holds more than
  one, the build now stops and lists them instead of picking whichever the
  keychain returned first. That order means nothing — an expired or closed
  team sorts ahead of a working one just as easily — so the guess cost a full
  build and then failed inside Xcode with `No Account for Team` naming an id
  from no project. Several certificates belonging to one team are not
  ambiguous and still auto-detect.
- A failed engine-artifact download no longer points at a GitHub repo that
  does not exist. That path is only reachable when `WATCHOS_ENGINE_BASE_URL`
  redirects the CLI at a custom host, so the error now names that host and the
  tag it looked for.

## 0.1.0-beta.2 (closed beta)

Requires engine artifacts **v0.1.1** (`bin/internal/engine.version`), which add
the platform-view embedder ABI. The v0.1.0 artifacts stay in place, so a
checkout pinned to them keeps working — but platform views need the bump.

- **Platform views**: plugins can embed native SwiftUI views in a Flutter
  layout (`WatchPlatformView` in `package:flutter_watchos`), and can ship
  their own SwiftUI sources for the CLI to compile into the app.
- **Host module**: the runner glue is compiled by the CLI into
  `watchos/Flutter/` as the `FlutterWatchOS` module instead of being copied
  into the app template, so host fixes reach existing apps on a CLI update.
  Apps carrying their own `Runner/FlutterRunner.swift` stay in legacy mode.
- **External SwiftPM SDKs**: a plugin's `watchos/Package.swift` may depend on
  an external Swift package (e.g. the Firebase Apple SDK); the CLI resolves
  and builds it through xcodebuild's SwiftPM and force-loads the objects,
  linking one shared copy across plugins.
- **`FlutterWatchOSAppDelegate`**: opt-in remote-notification plumbing (APNs
  token and payload delivery) for plugins such as firebase_messaging. The
  build warns when a plugin needs it but the app has not installed it.
- **Content scale**: `FlutterWatchOSContentScale` fits phone-designed UIs on
  the watch screen without touching Dart code.
- **`plugin port`**: scaffolds a watchOS FFI port of an existing plugin,
  optionally with the upstream example (`--include-example`).
- Standalone vs. companion host modes, derived from the project shape (no
  configuration): a project without an iOS app ships the watch-only
  (`WKWatchOnly`) watch app inside the thin HostApp container in `watchos/`;
  a project with an `ios/` Flutter app ships the watch app inside it — the
  iOS Runner gets an "Embed Prebuilt watchOS App" build phase and the watch
  Info.plist declares `WKCompanionAppBundleIdentifier`. `create` wires the
  right mode up front, `build`/`run` re-derive and self-heal it (add or
  remove `ios/` and the wiring follows), and the new `host` command reports
  the state.
- `build watchos` closes like stock `flutter build ios`: a status-level
  "Automatically signing watchOS…" note naming the development team (and
  where it came from), and a final `✓ Built build/watchos/<config>/Runner.app
  (<size>)` line — the path a companion iOS app's embed phase consumes.

## 0.1.0-beta.1 (closed beta)

First public (closed-beta) release. Flutter 3.44.4, engine artifacts
`v0.1.0-flutter3.44.4`.

- `create` / `build` / `run` / `attach` / `devices` / `test` / `drive` for
  watchOS: Simulator debug (JIT, hot reload) and physical-watch
  profile/release (AOT). Debug on a physical watch is not possible
  (no JIT on watchOS) and fails with guidance.
- SwiftUI runner template: touch + Digital Crown input (native scroll feel,
  raw crown API via the `flutter_watchos` package), arm64_32 stub gate with a
  Series 9+ fallback screen.
- Engine-side text input: tapping a Flutter `TextField` raises the native
  keyboard (single tap), with pre-filled text, `obscureText` masking,
  round-tripped edits, and a working submit — the keyboard's Done fires
  `onSubmitted` and releases focus. No app-side code needed.
- Platform identity: `Platform.operatingSystem == "watchos"`,
  `Platform.isWatchOS == true`, with `Platform.isIOS == true` retained for
  iOS-family widget behaviour.
- `login` / `logout`: flutterwatch.dev account connection; engine artifact
  downloads are account-gated (closed beta: invite required).
- `doctor`, `precache`, `upgrade`, plugin listing, and the forwarded stock
  Flutter commands.
