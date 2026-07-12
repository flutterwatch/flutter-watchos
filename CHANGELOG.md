# Changelog

## Unreleased

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
