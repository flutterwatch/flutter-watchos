# Changelog

## 0.1.0-beta.11 (closed beta)

Three things the watch knew and your app did not — that memory is running out,
what language the wearer reads, and when the first frame is ready — now reach
Dart. Apps also stop launching onto the words "Starting Flutter…".

- **Your app is told when the watch is running out of memory.** watchOS kills a
  process that crosses its per-process limit (300 MB on a Series 10) with a bare
  SIGKILL — no exception, no crash dialog, often not even a jetsam report. Until
  now this platform was the only one where no low-memory signal arrived by any
  route, so `WidgetsBindingObserver.didHaveMemoryPressure` never fired, Flutter's
  image cache was never dropped, and no package holding GPU resources could be
  asked to shed.

  Three things now raise it: the kernel's memory-pressure source, a poll of the
  remaining headroom, and **backgrounding** — the last matching what the iOS
  embedder does, and the one that matters most, because jetsam picks background
  processes first and orders them by footprint.

  The thresholds are measured rather than chosen. On a Series 10, `watchos_demo`
  loading its assets fell from 281 MB of headroom to 23 MB inside one second, so
  the poll runs every 250 ms and acts below 64 MB; it now reports 63 MB left,
  three quarters of a second before the kernel's own critical notice, where the
  first attempt noticed at 23 MB and arrived after it. A burst is a different
  matter: a probe allocating flat out went from 283 MB to killed in 1.7 seconds,
  and nothing a poll can do saves that. The engine says at launch which paths are
  live, so a run can be told apart from a hope.

- **Apps see the watch's language.** `PlatformDispatcher.locales` was never
  populated on watchOS, so `Localizations`, `MaterialApp.localizationsDelegates`,
  `intl` and `DateFormat` all resolved against the framework default — a silent
  wrong answer for every user whose watch is not in English. The full preferred-
  language list is now sent at startup and again whenever it changes, including
  the case that actually happens: the user leaves for Settings, changes the
  language, and comes back.

- **The engine reloads system fonts** when the set of registered fonts changes,
  instead of keeping the collection it built at startup.

- **A host can wait for Flutter's first frame.** `FlutterWatchOSHostSetFirstFrameCallback`
  fires once, on the main thread, when Flutter has **rasterised** its first
  frame. Registering after that has already happened invokes the callback
  immediately rather than never. The engine also logs the launch-to-first-frame
  time (396 ms for `watchos_demo` on a Series 10).

  It reports rasterisation, not presentation, so it is not the cue for taking a
  launch placeholder down — see the next entry. It was originally justified by
  Metal producing no `CGImage`; that is not so on this engine, where Impeller
  renders into an `MTLTexture` read back through a shared `MTLBuffer` and
  presented through the same frame callback as software. Both renderers publish
  frames today.

- **Apps no longer come up on "Starting Flutter…".** That literal string was on
  screen for the ~700 ms the engine takes to reach its first frame, in every app
  this CLI has ever built. `FlutterHostView` now holds a launch placeholder and
  cross-fades it out over 0.2 s once the first frame is on screen — the watchOS
  shape of `FlutterViewController.splashScreenView` on iOS, which
  `onFirstFrameRendered` takes down with the same 0.2 s alpha animation.

  `FlutterHostView()` is unchanged at the call site and fills in plain black,
  which is what watchOS draws behind the app icon while launching, so the
  handover from the system launch screen is invisible. Supply your own with
  `FlutterHostView { MyLaunchScreen() }`, or `FlutterHostView { EmptyView() }`
  to opt out. watchOS has no launch storyboard, so there is nothing to load a
  default from the way iOS does from `UILaunchStoryboardName`.

  The cue is the frame reaching SwiftUI, not the callback above. Measured on a
  simulator at 30 fps, mean luminance per sample: driven by the callback, one
  hard step from black to the app; driven by the frame, the intended six-sample
  ramp.

- **`package:flutter_watchos` 0.1.0-beta.8** adds `WatchMemory`: how much the
  process may still allocate before watchOS kills it
  (`os_proc_available_memory()`), and its resident footprint as the kernel
  accounts it (`phys_footprint`, which includes the GPU memory
  `ProcessInfo.currentRss` omits). See [doc/memory.md](doc/memory.md).

- **`precache` no longer puts your API token in the process list.** The
  download sent it as `--header "Authorization: Bearer …"`, and argv is not
  private: any user on the machine could read the token out of `ps` for as long
  as a download ran, and `precache -v` printed it verbatim — which is exactly
  the output that gets pasted into a bug report. curl reads the same header
  from a `--config` file now, written owner-only inside the temporary directory
  the download already deletes. If a verbose log of yours ever left your
  machine, run `flutter-watchos login` again to replace the token in it.

- **Watch-only apps get their plugin symbols again.** An app with no `ios/` or
  `android/` directory, whose plugins are all watchOS-only, resolved *no*
  plugins at all. `flutter pub get` writes its `dependencyGraph` only once it
  recognises a plugin for a platform it knows about, and it does not know
  watchOS — so the file it left behind was empty, plugin discovery walked that
  empty list, no plugin archive was built, nothing was `-force_load`ed, and the
  app binary shipped without a single FFI export. Every
  `DynamicLibrary.process().lookup` then failed at runtime: one affected app
  linked 0 of its 23 symbols and came up on a red `Failed to lookup symbol`
  screen. Discovery now falls back to `.dart_tool/package_config.json`, which
  pub writes for every resolved package whatever the platform.

## 0.1.0-beta.10 (closed beta)

Moves to Flutter 3.47.1, renders on the watch GPU by default, and gives the
engine the display's own clock — two changes in a row you can see rather than
read about.

- **Your app renders on the GPU now.** Impeller on Metal is the default
  renderer; it used to be Skia's software rasterizer on the CPU. watchOS
  declares no Metal framework in its SDK, which is why this took a while: the
  engine is built against an SDK overlay that supplies the framework watchOS
  ships but does not advertise. Nothing in an app has to change, and nothing
  opts in.

  An app can still opt out — `FLTEnableImpeller` set to `false` in
  `watchos/Runner/Info.plist` — and the key is read in both directions now,
  where before only `true` meant anything. If a watch cannot open a Metal
  device the engine falls back to the software rasterizer on its own, so the
  default cannot leave an app with no renderer. For development,
  `FLUTTER_WATCHOS_RENDERER=software` on the simulator and
  `--watchos-renderer=software` on a device do the same thing per-run.

- **Images with `cacheWidth` or `ResizeImage` decode correctly again.** Metal's
  only scaling blit comes from MetalPerformanceShaders, which watchOS does not
  ship, so `BlitPassMTL::ResizeTexture` had nothing to scale with. It reported
  success anyway and left the caller a texture nothing had written to.
  Downscales now take upstream's own CPU path — the one meant for a backend
  that cannot scale — and the blit reports the failure honestly.

- **The engine is pinned by what it is, not by a Flutter version.**
  `bin/internal/engine.version` now holds an engine id (`engine-…`) derived
  from the sources and build arguments that determine the binary, the way
  flutter-tvos pins its engine. A Flutter release that changes nothing the
  engine depends on no longer forces a rebuild, a re-upload, or a new download
  for you.

- **The engine now runs on the display's clock.** watchOS has no
  `CADisplayLink` — it is `API_UNAVAILABLE(watchos)` in the SDK — so the engine
  had no way to know when the panel refreshes and fell back to a free-running
  60 Hz timer whose phase was fixed at boot. That grid and the display's are
  unrelated clocks, so finished frames were handed to the compositor at a
  walking offset from the latch point. Measured on a Series 10: frame delivery
  p99 of 21.4 ms against native's 17.2 ms, worst case two whole refresh
  periods — while rasterizing needed 2.3 ms of a 16.67 ms budget. Judder with
  13 ms of headroom, which no amount of faster rasterizing would have fixed.
  The runner now drives the engine from `TimelineView(.animation)`, the one
  display-synced schedule SwiftUI vends on this platform (300 consecutive
  entries measured 16.665 ms p50 / 17.22 ms p99), and presents the finished
  frame on the same tick. Both halves are needed: fixing only frame
  *production* moved the app's own intervals (p99 22.2 ms → 19.1 ms) while what
  reached the screen did not improve at all. In Always-On the schedule drops to
  a low frequency by itself and the engine simply produces fewer frames.
  **Needs the engine artifacts in this release** — the host module calls a
  symbol older engines do not export.
- **Packages that generate assets at build time now actually ship them.** The
  watchOS pipeline skips upstream's native-asset targets, because
  flutter_tools cannot build Dart *code* assets for this platform. Data assets
  had been swept up in the same skip, even though they are a different thing
  entirely — produced on the host by ordinary Dart, and what a package like
  `flutter_scene` uses to compile its shader bundles. The result was silent:
  such a package shipped whatever its generated directory happened to contain,
  left over from a macOS or simulator build of the same tree, or nothing at
  all. Neither failed the build; the app just rendered a black scene on the
  device. Data-asset hooks now run as their own build step, and that step tells
  a hook it is building for `watchos` rather than for the iOS family.
  flutter_tools maps its own closed set of target platforms onto the hooks
  protocol and has no watchOS in it, so anything routed through it is announced
  as iOS; the step assembles the protocol input itself instead. A package
  picking a per-platform output now picks the right one rather than guessing,
  and hot reload runs the same pass, so a reload and a build no longer name
  different targets.

  Code assets are requested and then discarded. The protocol keeps the target
  OS *inside* the code-asset config, so asking is the only way to say
  `watchos`; nothing a code-asset hook produces is installed into a watchOS
  app, whose plugins are native and resolved by the package manager, and the
  app bundle is unchanged. An app with no hook-carrying packages is unaffected.
  A hook that cannot cope with an unfamiliar target OS makes the pass retry
  under the iOS-family name it understands, so apps that built before still
  build — `package:code_assets` throws on an OS it does not know until 2.0.0,
  which `objective_c` and so most plugin graphs inherit today.

  **Requires `flutter config --enable-dart-data-assets`.** Dart data assets are
  off by default. With them off the pass does not run at all and says so,
  naming the packages whose hooks were skipped and the command that turns them
  on — running the hooks to collect assets nobody asked for would be cost
  without benefit, and cost that can fail a build.

  **Known boundary: a hook cannot tell a watch from the simulator.** The
  protocol carries that in a per-OS sub-config — `IOSCodeConfig.targetSdk`, and
  there is an Android and a macOS one — and there is no watchOS sub-config to
  carry it in. Both builds are arm64, so the two hand a hook byte-identical
  input and share one hook cache entry. A hook that ships source is unaffected;
  one that precompiles per-platform binaries is not.
- **`--watchos-log-to-file`.** A watch has no console to attach to, and
  `print()` and engine logs both go to stderr, which on a device goes nowhere.
  Launching with this flag redirects them into the app's own container, where
  `devicectl device copy from` can pull them. Opt-in and truncated per run —
  see [doc/debug-app.md](doc/debug-app.md).
- **Flutter 3.47.1** (was 3.44.4). Also picks up an upstream change to how the
  tool attaches LLDB for JIT debugging: it now shells out via `xcrun` obtained
  from the Xcode project interpreter, so the device path falls back to the
  Xcode route when that is unavailable rather than failing.

## 0.1.0-beta.9 (closed beta)

Ships new engine artifacts. `SafeArea` finally works on the watch, and there
is a guide for building an iPhone + Apple Watch app from one codebase.

- **`SafeArea` insets by the real safe area.** `MediaQuery.padding` was pinned
  at zero on watchOS, so `SafeArea` inset nothing and content drew under the
  system clock. The embedder API only carried `physical_view_inset_*`, and
  insets are *subtracted* from padding — they can never produce one, so the
  padding had to be added to the API rather than derived. The runner measures
  its own safe area and reports it, which is what makes this shape-driven
  rather than size-driven: a 45 mm round-corner display and a 45 mm flatter
  one do not inset the same. **Needs the engine artifacts in this release** —
  the host module calls a symbol older engines do not export.
- **A guide to companion apps** ([doc/companion-apps.md](doc/companion-apps.md)).
  Companion mode has worked since the `ios/`-directory shape decided it, but
  the docs only covered submission. This covers the part before that: laying
  out Dart two very different screens share, why two entrypoints beat one
  `main.dart` branching at runtime, sharing a design system across devices
  that are never seen side by side, and how the two apps actually talk —
  including that `reachable` is asymmetric, which catches people out when they
  try to test the queued transport.
- **The generated watchOS runner always names itself in valid Swift.** The
  runner's `App.swift` declares `struct <ProjectName>App: App`, and the
  project name went into it as written — a name that is not already a Dart
  package name emitted Swift that does not parse (`struct .App: App`,
  "Expected identifier in struct declaration"), and the same name went on to
  the product name and bundle display name in the Xcode project. `create .`
  resolved its own name in beta.7; the runner template now derives the name
  defensively for every caller instead, so `flutter-watchos plugin port`
  (which names an example runner after the copied package) and
  `--skip-name-checks` cannot reach it with a bad one either. Non-identifier
  characters are folded into upper camel case (`my-app` → `MyAppApp`), a
  leading digit is escaped (`3d_demo` → `_3dDemoApp`), and a name with
  nothing usable left in it falls back to the project directory's own name.
  Ordinary package names render exactly as before.

## 0.1.0-beta.8 (closed beta)

Ships new engine artifacts (`v0.1.6`). Networking on a physical watch, and
live DevTools, both work for the first time.

- **`HttpClient` works on a physical watch** (engine `v0.1.6`). watchOS denies
  third-party apps the BSD socket path outright — `getaddrinfo` fails with
  `EAI_NONAME` and even a bare-IP connect returns "No route to host" — so
  every Dart HTTP client was dead on device: `NetworkImage`, `package:http`,
  `dio`. `dart:ui` now installs a `URLSession`-backed `HttpClient` before your
  `main()` runs. **Apps need no import and no call**, and an app that installs
  its own `HttpOverrides` still wins. None of this reproduces on the Simulator,
  which is why it went unnoticed for so long: remote images simply never
  appeared on a wrist.

- **Responses stream.** The body arrives in chunks as it lands rather than in
  one event at the end, so `close()` resolves on the response headers and
  progress callbacks (`onBytesReceived`) fire. `followRedirects: false` is
  honoured, `redirects` is populated, `maxRedirects` raises a
  `RedirectException`, and `HttpClientResponse.redirect()` works.

- **Launch flags reach the engine again.** `--vm-service-port` and
  `--disable-service-auth-codes` were silently ignored, so the VM Service came
  up on a random port with an auth code and the DevTools bridge could never
  find it. **Live DevTools on a physical watch now connects.**

- **`--watchos-disable-semantics` works again.** The switch had become inert,
  so any measurement taken with it was measuring nothing.

- **`run --profile` picks a reachable address for the DevTools relay.** The
  watch reaches your Mac through the paired iPhone, so the Mac address it
  dials has to be one that phone can see. A tethered iPhone's hotspot subnet
  now outranks other addresses, and `FLUTTER_WATCHOS_RELAY_HOST` overrides the
  choice on a Mac with several networks. The timeout message names the address
  it advertised, so a wrong pick reads as a wrong pick.

Known limits of the HTTP client, all inherent: `HttpOverrides` is per-isolate,
so a spawned isolate still gets the socket client; TLS, proxy and credential
callbacks are ignored because URLSession owns them; and there is no caching —
`dart:io` does not cache on any platform, and adding it here would make
watchOS the only one serving stale bodies. Use `cached_network_image` if you
want a cache.

## 0.1.0-beta.7 (closed beta)

Ships new engine artifacts (`v0.1.5`). **Upgrading from an earlier beta? Run
`precache` with `--force` one more time — and this should be the last time:**

```sh
flutter-watchos precache --watchos --force
```

Downloaded artifacts really are stamped with their tag now (beta.6 shipped the
mechanism but it was never confirmed on a live download). A stamped install
re-downloads on its own when `engine.version` moves, so no flag is needed from
here on. Installs made at beta.6 or earlier carry no stamp, and an unstamped
engine directory is deliberately treated as a hand-built local engine and never
replaced — hence `--force`, once.

- **`PlatformDispatcher.displays` is no longer empty on the watch** (engine
  `v0.1.5`). The screen is published as a display at startup, so
  `displays.first` — the ordinary way to ask about the screen when sizing a
  layout — no longer throws `Bad state: No element` during the first build.
  Apps that size themselves off `MediaQuery` were never affected; apps that
  reach for the display list crashed before painting a frame.

- **`flutter-watchos create .` works inside an existing project.** It took the
  project name from the argument as written, so `.` became the project name.
  It now resolves the path first and prefers the pubspec's `name`, which is
  what makes adding watchOS to an app you are already in behave like stock
  `flutter create .`.

- **A companion watch app's bundle id is reconciled instead of flagged.**
  watchOS refuses to install a watch app whose id is not prefixed by the
  companion id it declares, so a warning left the project unable to run at all.
  The iOS app id is the source of truth and the existing suffix is kept; the
  HostApp container's own id is untouched.

- **The plugin audit warns about the `Platform.isIOS` trap.** `Platform.isIOS`
  is `true` on watchOS by design — it is what gives you Cupertino styling, the
  SF font and iOS page transitions — so an app that already gates its iOS-only
  plugins correctly still calls every one of them on the watch. The audit now
  says so at the point you are reading it, and [Plugins](doc/plugins.md) shows
  the guard that works.

- **Six compatibility-database entries corrected** for `flutter-watchos plugin
  port`. NetworkExtension hotspot APIs (watchOS 7+) and CallKit (watchOS 9+)
  are available and were wrongly reported as unsupported; LocalAuthentication
  dates from watchOS 3.0, not 9.0; a Wi-Fi-name feature can move to
  `NEHotspotNetwork.fetchCurrent` rather than being dropped; and the WebKit and
  platform-view notes now explain exactly why a webview is out of reach.

- **`package:flutter_watchos` is Web-safe.** It imported `dart:io`
  unconditionally, so following its own advice — guard with
  `FlutterWatchosPlatform` instead of `Platform.isIOS` — broke the app's Web
  build. The check now resolves through a conditional import and reports
  `false` everywhere on Web.

## 0.1.0-beta.6 (closed beta)

Ships new engine artifacts (`v0.1.4`). **Upgrading from an earlier beta? You
still need `--force`:**

```sh
flutter-watchos precache --watchos --force
```

Accessibility needs the matching engine — the host module links its symbols
directly, so an app built against an older engine fails to link rather than
silently losing the feature.

- **Accessibility.** VoiceOver now reads and drives Flutter watch apps. You
  annotate your app the way you would anywhere else — `Semantics`,
  `MergeSemantics`, `ExcludeSemantics`, and the semantics every Material and
  Cupertino widget already carries — and the whole tree comes through: labels,
  values, hints, traits, reading order, activate, adjustable swipes, the
  actions rotor, custom actions, and scrolling past the last visible item in a
  list. Text fields read as named fields rather than anonymous ones. Requires
  the matching engine artifacts.

  The watch's own settings reach `MediaQuery` too: VoiceOver →
  `accessibleNavigation`, Reduce Motion → `disableAnimations`, and Text Size →
  `textScaler`, so an app that respects `MediaQuery.textScaler` now grows with
  the system setting.

  It is not VoiceOver-only: Switch Control, AssistiveTouch, Xcode's
  Accessibility Inspector and XCUITest read the same tree, so it is always
  live. `Semantics(identifier: ...)` becomes the accessibility identifier an
  XCUITest query matches on.

  Two gaps, both for want of a watchOS API: `SemanticsService.announce()` does
  nothing (there is no way to make a watch screen reader speak an arbitrary
  string), and Bold Text / Increase Contrast / Invert Colours are not reported.
  See [Accessibility](doc/accessibility.md).

- **`MediaQuery.platformBrightness` is now `dark`.** It has to be: the same
  system-settings message that carries the text scale is discarded outright
  without it, and watchOS has no light mode. Most apps see no change —
  `MaterialApp` falls back to `theme` when `darkTheme` is null. An app that
  DOES define `darkTheme` (and leaves `themeMode` at its `ThemeMode.system`
  default) will now use it on the watch, which matches every native watch app.
  Pin the old look with `themeMode: ThemeMode.light` if you need it.

- **Downloaded engine artifacts are stamped with their tag** and are no longer
  reused when the stamp does not match `bin/internal/engine.version`. This is a
  partial fix for an install keeping its old engine across a version bump, and
  it is why `--force` is still the instruction above: the stamp is not yet
  proven to take effect on a live upgrade. A local engine
  (`WATCHOS_ENGINE_ARTIFACTS`, or a workspace-root `engine_artifacts/`) carries
  no stamp and stays reusable on purpose, so a hand-built engine is never
  deleted and downloaded over.

## 0.1.0-beta.5 (closed beta)

Ships new engine artifacts (`v0.1.3`). **Upgrading from an earlier beta? You
need `--force`:**

```sh
flutter-watchos precache --watchos --force
```

A plain `precache` will not pick up a new engine on an install that already has
one. The extracted artifacts are reused without being compared against
`bin/internal/engine.version`, so the old engine silently stays in place —
which means this affected earlier releases too, not just this one. `--force`
clears the directory first and downloads cleanly. A fresh install needs
nothing special. Fixing the invalidation itself is the first thing queued for
the next release.

- **The Simulator engine is now built optimised.** It was shipping as an
  unoptimised build, which made every app feel far heavier there than on a
  watch: a shader-heavy screen ran at 13fps on the Simulator and 56fps on an
  Apple Watch Series 10. The same screen now runs at 60fps, and the engine
  download is 24 MB instead of 40 MB. Dart still runs JIT, so **hot reload is
  unaffected** (measured at 263–463 ms).

  This makes the Simulator a better place to *develop* and no better a place to
  *measure*. It runs the same work roughly 3–4x faster than a watch — on the
  app above it reported two thirds of the frame idle while the watch was
  saturated and dropping frames. A/B comparisons still rank correctly; absolute
  timings do not transfer. See
  [Measuring performance on a watch](doc/benchmarking.md).

- **New: [Measuring performance on a watch](doc/benchmarking.md)** and a
  drop-in probe, `tool/benchmarks/frame_bench.dart`. Reports build and raster
  percentiles per window plus a duty cycle — what fraction of each frame was
  actually spent working, which is what tells a comfortable 60fps from a
  saturated one. It discards windows collected while the display was dimmed by
  Always-On, so a run only has to catch a few seconds of real rendering
  rather than being clean end to end.

- **[Fragment shaders](doc/shaders.md)** gains two techniques measured on real
  hardware, worth 56.5fps → 60.0fps on a shader-bound app: hoisting
  frame-constant math out of the shader body (a value derived only from
  uniforms is otherwise recomputed once per covered pixel), and shading through
  an offscreen at reduced resolution — documented as the quality trade it is,
  with the sizes that help and the one that makes things dramatically worse.

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

  The relay's endpoints have to accept connections on every interface — the
  watch reaches the Mac by LAN address — so each run mints a 128-bit token and
  serves only under it. Anything else on the network gets a 404 and changes no
  state. This matters because the app is launched with
  `--disable-service-auth-codes`: without the token the relay would be an
  unauthenticated door into a live debug session.

  Limits worth knowing, all documented in
  [`doc/debug-app.md`](doc/debug-app.md):

  - **Connection setup sometimes fails — expect to retry.** Two launches in
    five did not connect in testing. Once up, a session is stable. A failure
    cannot be recovered in place: once DDS has taken control the VM Service
    stops listening, so a dropped connection ends the session. Note the watch
    suspending the app when its display times out looks the same from the
    terminal — see [`doc/debug-app.md`](doc/debug-app.md).

    A transfer that fails mid-session is retried, and if the data really is
    lost the tunnel is closed so `run` reports a lost connection — rather than
    holding the session open around a hole in the byte stream, which read as
    an indefinite hang.
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

  **Apps created before the host module cannot use this.** A project that still
  has `watchos/Runner/FlutterRunner.swift` builds in legacy mode, which skips
  the host module the bridge lives in. Migrate to the current template
  (`App.swift` importing `FlutterWatchOS`) to attach DevTools.

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
