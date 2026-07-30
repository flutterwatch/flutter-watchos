# Changelog

## Unreleased

- **Live DevTools on a physical watch.** `run --profile -d <watch>` now brings
  up a working Dart VM Service connection, so DevTools and the IDE debuggers
  attach to a real watch the way they do to any other device. No flag: profile
  runs on a watch set it up automatically. This closes the remaining half of
  [#2] — beta.4 fixed the crash, but the connection itself still could not be
  made.

  A watch will not accept an inbound socket: third-party apps are denied
  direct socket APIs (`dart:io` and `NWConnection` both fail with `ENETDOWN`),
  which is why every previous attempt to dial *into* the VM Service failed.
  `URLSession` does work, so the app dials *out* instead — the CLI runs a relay
  on the Mac, the app long-polls it over HTTP, and VM Service bytes are tunnelled
  between the two. The relay never parses the protocol, so anything the VM
  Service can say passes through unchanged.

  Verified on an Apple Watch Series 10 (watchOS 26.5): DevTools attaches, the
  Flutter Frames chart populates with per-frame build/raster/vsync timings at a
  sustained 59.4 frames per second, and an 8-second timeline capture of an
  animating app returned ~30,000 events including the whole frame pipeline
  (`Animator::BeginFrame`, `BUILD`/`LAYOUT`/`PAINT`/`COMPOSITING`,
  `Rasterizer::*`).

  Limits worth knowing, all documented in
  [`doc/debug-app.md`](doc/debug-app.md):

  - **Connection setup sometimes fails — expect to retry.** Two launches in
    five did not connect in testing. Once up, a session is stable. A failure
    cannot be recovered in place: once DDS has taken control the VM Service
    stops listening, so a dropped connection ends the session. Note the watch
    suspending the app when its display times out looks the same from the
    terminal — see [`doc/debug-app.md`](doc/debug-app.md).
  - **The CPU profiler is empty.** `getCpuSamples` returns a full function
    table and zero samples — the Dart sampling profiler needs Mach thread APIs
    the watchOS device SDK removes, the same reason there is no JIT on device.
    The timeline is unaffected.
  - **The link is slow, so bulk views take a moment.** Tunnel traffic is
    compressed (~5x live, ~9–10x bulk) and pipelined to hide the phone-proxied
    path's round-trip time: 800–900 KB/s of payload over a ~90 KB/s wire.
    DevTools connects in ~20s, and the Performance page loads in about a
    minute against an app rendering at 60fps, then stays live — frames chart
    included.

  Both devices must share a network: a watch reaches your Mac through its
  paired iPhone, so the iPhone needs to be unlocked, nearby, and on the same
  Wi-Fi as the Mac. When the app cannot reach back, `run` now says so — and
  distinguishes "the VM Service never started" from "it started but the app
  could not reach this Mac".

- **Release builds carry none of the above.** The VM Service bridge is compiled
  only for debug and profile: a release build gets a no-op stub and links no
  `URLSession`, socket or compression code for it (verified by symbol count —
  127 bridge symbols and 3 networking references in profile, 22 stub symbols
  and 0 networking references in release). Release launches also no longer pass
  `--enable-dart-profiling`, `--disable-service-auth-codes` or
  `--vm-service-host`. A release engine has no Dart VM Service, so those were
  already inert — but they are not flags to hand a shipping build on the
  assumption that nothing is listening.

- **`run` on a physical watch takes over a stale instance.** Launches now pass
  `--terminate-existing`. An earlier run that ended without a clean stop used to
  leave an instance holding the VM Service port, after which every later run
  silently came up with no VM Service at all.

## 0.1.0-beta.4 (closed beta)

Ships new engine artifacts (`v0.1.2`). Run `flutter-watchos precache` after
upgrading — the embedder fix below is in the engine, not the CLI.

- **`run`/`attach`/`drive` on a physical watch**: fixed
  `Bad state: Invalid argument(s): serviceUri 'http://127.0.0.1:0' is not an
  IPv6 address`, which aborted every launch that needed a Dart VM Service
  connection on a wirelessly-paired Apple Watch ([#2]). flutter_tools picks the
  DDS bind address from `--ipv6` (off by default) while DDS picks its own
  address family by resolving the watch's VM service host — IPv6-only for a
  wireless watch — and then rejects the IPv4 bind address it was handed. The
  bind family now follows the device. mDNS lookups also retry over IPv6 when
  the watch publishes no A record, and the devicectl address fallback prefers a
  routable address over an unusable link-local one. The app is now launched
  with `--vm-service-host=::0` (dual-stack) rather than IPv4-only `0.0.0.0`.

  This unblocks the crash, but **on-device `drive` still does not complete**:
  the app's Dart VM binds loopback and does not receive the launch arguments
  the tool passes, so DDS reaches the watch and is refused. Verified on an
  Apple Watch Series 10 — the `--vm-service-host` value above has no effect
  until the arguments are forwarded. Issue [#2] stays open for that.

- **Device discovery**: `--device-timeout` now actually waits for a physical
  watch. A wirelessly-paired watch is reported by `devicectl` as unreachable
  until its CoreDevice tunnel comes up, and is hidden until then; discovery
  ignored the timeout entirely, so finding the watch came down to whether the
  one query it made happened to land after the tunnel was ready. It now
  re-queries within the timeout, but only while a paired-yet-unreachable watch
  is actually present — a watch that is simply put away still costs nothing.
  Without the flag, that case now prints a one-line hint instead of being
  silently invisible.

[#2]: https://github.com/flutterwatch/flutter-watchos/issues/2

- **`create`**: a watchOS-only project (`--platforms=watchos`) now starts from
  the same counter app stock `flutter create` generates, instead of a
  placeholder that only printed a line of text. Projects created with another
  platform alongside always got the real starter app — they come from
  `flutter create` itself — so the two paths disagreed on what a new project
  looks like. The labels are shortened to fit a watch ("Pushes:" rather than
  the full sentence), and `test/widget_test.dart` is the standard counter
  smoke test rather than a placeholder that asserted on the removed text.
  Existing projects are unaffected; template changes only reach newly created
  ones.

## 0.1.0-beta.3 (closed beta)

Uses the same engine artifacts as beta.2 (`v0.1.1`); no `precache` needed when
upgrading from beta.2.

- **Plugin porter**: `flutter-watchos plugin port` scaffolds a federated
  `*_watchos` FFI package from an existing iOS or macOS plugin — a pubspec with
  the `watchos:` platform key and `ffiSymbols`, a Dart class over the upstream
  platform interface, the `watchos/Classes/` native skeleton, and a
  `PORTING_REPORT.md` mapping every API the source uses to its watchOS
  availability. Take the source from a local path, `--from-pub`, or
  `--from-git`. The native implementation is yours to write; the porter emits a
  building, linking scaffold, not working code. See doc/plugin-porting.md.
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
