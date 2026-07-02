# Changelog

## 0.1.0 (closed beta)

First public (closed-beta) release. Flutter 3.44.4, engine artifacts
`v0.1.0-flutter3.44.4`.

- `create` / `build` / `run` / `attach` / `devices` / `test` / `drive` for
  watchOS: Simulator debug (JIT, hot reload) and physical-watch
  profile/release (AOT). Debug on a physical watch is not possible
  (no JIT on watchOS) and fails with guidance.
- SwiftUI runner template: software rendering, touch + Digital Crown input
  (native scroll feel, raw crown API via the `flutter_watchos` package),
  arm64_32 stub gate with a Series 9+ fallback screen.
- Engine-side text input: tapping a Flutter `TextField` raises the native
  keyboard (single tap), with pre-filled text, `obscureText` masking, and
  round-tripped edits — no app-side code needed.
- Platform identity: `Platform.operatingSystem == "watchos"`,
  `Platform.isWatchOS == true`, with `Platform.isIOS == true` retained for
  iOS-family widget behaviour.
- `login` / `logout`: flutterwatch.dev account connection; engine artifact
  downloads are account-gated (closed beta: invite required).
- `doctor`, `precache`, `upgrade`, plugin listing, and the forwarded stock
  Flutter commands.
