# Changelog

## 0.1.1

Debugging on the watch Simulator now takes stock Flutter's launch options
and fails plainly when the app does not start, and every command says,
before it builds anything, when a mode, an option or a stock command does
not fit a watch.

- **A new engine, `engine-a0d92ed11913`.** It is built from the same
  Flutter 3.47.5, so the Flutter SDK does not change, and `upgrade`
  downloads the new engine once: about 25 MB signed out, about 66 MB
  signed in. On the watchOS Simulator, DevTools' CPU Profiler now records
  samples; `getCpuSamples` used to return none. On a physical watch it is
  still empty, as
  [Profiling on a physical watch](https://github.com/flutterwatch/flutter-watchos/blob/main/doc/debug-app.md#profiling-on-a-physical-watch)
  says.

- **Each mode runs where it can, and the tool says so before building.** The
  watchOS Simulator engine is JIT only and a physical watch has no JIT
  engine, so the Simulator runs debug and a watch runs profile and release.
  `run`, `drive`, `attach` and `build watchos` now stop with that guidance
  before anything is built; they used to build and then fail, often with a
  stack trace. Each command the guidance offers stands alone on its line,
  with no comment after it, and `test integration_test -d <watch>`, which
  runs debug, stops with the same guidance. `run`, `drive` and `install`
  refuse `--use-application-binary` for a watch or a watch Simulator, in
  every mode, before anything is built: flutter-watchos installs the app it
  builds from the project, and the flag used to be ignored. The lldb launch
  path that a prebuilt debug app took on a watch is gone, with its
  `FLUTTER_WATCHOS_LLDB_ATTACH_TIMEOUT_SECONDS`. `attach -d <watch>` without
  `--debug-url` or `--debug-port` stops and points to `run --profile`, which
  prints a DevTools link.

- **Stock launch options reach a watch app.** On the Simulator, and on a
  watch in profile mode, `--start-paused`, `--dart-flags`, `--trace-startup`
  and the other stock debugging options were dropped; they now reach the app
  as they reach an iOS app, and `--dart-flags` and the trace options arrive
  without the quotes stock adds for iOS. `--device-vmservice-port` chooses
  the VM Service port, and `--enable-software-rendering` selects the
  software renderer. `FLUTTER_WATCHOS_PRESENT`,
  `FLUTTER_WATCHOS_DISPLAY_CLOCK` and `FLUTTER_WATCHOS_CPU_LOG`, set for a
  `run`, now reach the app, as the
  [README](https://github.com/flutterwatch/flutter-watchos#readme) says.
  `--route` has no effect on watchOS, where an app starts at its home route,
  and `run` and `drive` now say so.

- **Hot reload keeps working after an `attach` ends.** An `attach` to an
  app that a `run` session was driving left that session unable to hot
  reload or restart once it ended. On the Simulator the files a reload needs
  now go straight into the app's container, as stock Flutter does for the
  iOS Simulator.

- **A Simulator launch that does not start says so.** A debug launch waited
  30 seconds for the Dart VM Service and then reported success without it,
  so `run` had nothing to connect to and `drive` stopped on an error. It now
  waits 60 seconds and fails, saying whether the log stream was live and
  whether the app is still running. On a physical watch, `run --release` no
  longer waits 30 seconds for a VM Service a release app does not have, nor
  warns about the Local Network permission; it returns as soon as the app's
  console starts.

- **Logs and screenshots on the Simulator.** `logs -d <simulator>` streams
  the app's output (it printed nothing), a message is no longer cut at its
  first escaped quote, and engine lines such as `Unhandled Exception` are no
  longer dropped. `logs` on a physical watch stops and points to
  `run --profile` and `--watchos-log-to-file`. `screenshot -d <simulator>`,
  and `s` in `run`, take a screenshot through `simctl`; `s` used to leave an
  empty file. A paired watch takes one through `devicectl` when it reports
  that it can (Xcode 27 or later).

- **`run -d <UDID>` boots a shut-down watch Simulator**, then opens the app
  that shows it: Device Hub on Xcode 27, Simulator on Xcode 26. `devices`
  still lists booted Simulators only. `attach`, `logs`, `install` and
  `screenshot`, given the UDID of a shut-down Simulator, used to report that
  no device was found; they now say it is shut down and point to `run`.

- **Xcode 26.0 or later is checked.** A build on an older Xcode stops before
  compiling anything native and names both versions. `doctor` reports an
  Xcode or a watchOS SDK older than 26.0 as an error, names the Xcode build
  and the highest available watchOS Simulator runtime, and adds a hint when
  none is 26.0 or later. Its CocoaPods hint now says CocoaPods is needed
  only for a `watchos/Podfile`.

- **The deployment target is read the way Xcode reads it**, per
  configuration and through xcconfig files. A project at watchOS 27.0 no
  longer gets an `arm64_32` host module that Xcode never uses, a project
  whose Debug and Release differ gets the right one for each, and plugin
  sources the tool compiles target the app's own
  `WATCHOS_DEPLOYMENT_TARGET`.

- **`doctor` warns when `flutter-watchos` on your PATH is another
  checkout.** An older checkout earlier on PATH kept answering to
  `flutter-watchos`, and nothing said so. The `Flutter` entry now names both
  and says to put this checkout's `bin/` at the front of PATH, and the
  install steps in the README and in [Getting
  started](https://github.com/flutterwatch/flutter-watchos/blob/main/doc/get-started.md)
  now do that: `export PATH="$PWD/bin:$PATH"`. Getting started also gives
  the line that keeps it there, with the checkout's own path.

- **Stock commands that do not fit a watch say so.** `build` offers only
  `watchos`: `build apk`, `build ipa` and the other stock targets exit
  naming stock `flutter build <target>`, and `build ipa` gives the route
  that fits the project. `build watchos` refuses `--analyze-size` and
  `--code-size-directory`, which never produced a report. `channel` shows
  the pinned Flutter and says flutter-watchos follows no channel;
  `channel <name>` and `downgrade` refuse instead of moving the SDK that the
  next run puts back. `run`, `drive` and `install` refuse `--flavor` for a
  watch, whose build has no flavors, and a pubspec `default-flavor` warns
  once. `analyze` now works, and `update-packages` is no longer offered.
  After a usage error the hint names `flutter-watchos -h`.

- **`daemon`, `--machine` and `debug-adapter` behave as stock's.** `daemon`
  and `--machine` get stock's logger, so `run --machine` and
  `attach --machine` no longer stop at the app start with a logger error,
  and `--prefixed-errors` applies. `debug-adapter` starts `flutter-watchos`
  rather than the pinned SDK's `flutter` for the sessions it runs. Custom
  devices are on inside flutter-watchos, so `daemon` reports them supported
  without `flutter config --enable-custom-devices`. The wrapper prints its
  setup progress on stderr, where a tool reading JSON from stdout does not
  trip on it, and `proxy_root` links the Dart SDK and the Flutter version
  file an IDE looks for.

- **`create` adds `watchos/` only to an app.** A package, an FFI package, a
  module or a plugin, made by `create` or recreated with `create .`, gets no
  watch runner, and one line says so; for a plugin, it names
  `flutter-watchos plugin port`, which makes a watchOS implementation. A
  watch-only `create` refuses `--list-samples`. Commands run in a plugin
  package, `test` for one, no longer write app wiring into the plugin's
  `watchos/`.

- **A missing watchOS plugin package is named.** When an app uses a plugin
  that has a published watchOS package, the tool names it with the command
  that adds it, for example
  `flutter-watchos pub add shared_preferences_watchos`. The data-assets
  notice no longer names `objective_c`, which every app with `path_provider`
  saw and the watch never uses.

- **`login` says what you do in the browser.** It waits for you to confirm
  the code it printed, and a code that runs out "expired before it was
  confirmed". It used to wait "for approval", as if someone else had to say
  yes. An engine the service holds back is now "not available, skipped".

- Smaller things: the notice after the first registered release build, and
  `build-registry`, give each way to turn registration off as a sentence and
  then the command alone on its line, ready to paste
  (`export FLUTTER_WATCHOS_BUILD_REGISTRY=0`, where a bare assignment never
  reached the tool); `upload --ipa` help says the `.ipa` is an App Store
  export from Xcode; the port options of `run`, `drive`, `attach`, `test`
  and `debug-adapter` say "random unused port" in their help; a checkout
  that lacks its `watchos/` template makes `create` stop and name the path
  it looked for, where it used to report a watch project it had not made; a
  command lists the watches and Simulators once, where `attach` listed them
  three times; `channel --help` names `flutter-watchos`.

- Docs: shell blocks hold commands only, and what each one does is in the
  text around it, so no comment is pasted along with a command. The
  supported watches are named in full: Series 9 or later, Ultra 2 or later,
  or SE 3, on watchOS 26.0 or later.
  [doc/publish-app.md](https://github.com/flutterwatch/flutter-watchos/blob/main/doc/publish-app.md)
  says to leave `ARCHS` unset and to expect one `arm64_32` linker warning.
  [doc/debug-app.md](https://github.com/flutterwatch/flutter-watchos/blob/main/doc/debug-app.md)
  says breakpoints and expression evaluation work only on the Simulator,
  and where a watch's logs go.
  [doc/commands.md](https://github.com/flutterwatch/flutter-watchos/blob/main/doc/commands.md)
  adds `test -d` for integration tests on the Simulator without a driver
  file, explains the `integration_test` warning under `drive`, drops
  `plugin list`, which does not exist, and says what `attach`, `logs`,
  `screenshot`, `install` and `channel` do for a watch.
  [doc/accessibility.md](https://github.com/flutterwatch/flutter-watchos/blob/main/doc/accessibility.md)
  says Bold Text and Increase Contrast are not forwarded,
  [doc/architecture.md](https://github.com/flutterwatch/flutter-watchos/blob/main/doc/architecture.md)
  that `Platform.environment` is empty on watchOS, and
  [doc/accounts.md](https://github.com/flutterwatch/flutter-watchos/blob/main/doc/accounts.md)
  that every account gets every engine. The README documents
  `FLUTTER_WATCHOS_DISPLAY_CLOCK` and `FLUTTER_WATCHOS_CPU_LOG`. On GitHub,
  `package:flutter_watchos`'s README says what keeps its FFI symbols in the
  app; pub.dev shows it with the package's next release.

- For contributors: CI runs on macOS 26, typechecks the host sources with
  Xcode 26.0.1 and 26.6, analyses and tests `package:flutter_watchos`, its
  example and the crown runtime, holds each test to 2 seconds, checks that a
  new engine pin is served before it reaches anyone, and runs each release
  tag against the live service. Every source file carries the license
  header, and a test keeps it so. New scripts: `tool/xcode_matrix.sh`,
  `tool/debug_suite/`, `tool/safe_area/` and
  `tool/check_untested_commits.sh`.

## 0.1.0

The Simulator engine downloads without an account; a physical watch and
release builds need one, and signing in with GitHub is all an account takes.

- **The Digital Crown scrolls natively.** Every watch app keeps a hidden
  native scroll view behind the Flutter content and lets it own the crown,
  so watchOS itself supplies the acceleration, the momentum, the detent
  haptics, the spring at either end and the crown scroll indicator, and the
  list follows it exactly. It needs no code: the tool compiles a small
  runtime into the app, next to the plugin registrant, and the runtime picks
  the list the crown drives. Of the vertical scrollables on screen (not in a
  hidden tab, not under a dialog) that have something to scroll, that is the
  frontmost one that covers at least 40% of the screen, or the largest when
  none does. A `NestedScrollView` scrolls as one, its header first, and a
  page view or a wheel settles on whole pages or items. `WatchCrownScroll`
  in `flutter_watchos` picks another, keeps the crown off a list, or hides
  the scroll indicator. A finger and the crown hand over as on a native
  scroll view, and a released stretch or a fling into the end bounces as one
  does. Raw crown input (`WatchCrown`) is unchanged. An app that still
  compiles its own runner (`watchos/Runner/FlutterRunner.swift`) keeps the
  older crown until the runner is migrated to the current template; the
  build says so.

- **The safe area now leaves the clock out.** `MediaQuery.padding` keeps
  content clear of the display's rounded corners only: the same inset on all
  four sides, 9 to 17 points depending on the watch. Content can now sit
  under the clock, and what goes there is up to the app. A `ListView` with
  no `padding` starts its first row under the clock, and an `AppBar` moves
  up into the clock's band. `WatchStatusBar.heightOf(context)` in
  `package:flutter_watchos` gives the height of that band, for content that
  has to start below it. To keep the earlier layout, where the padding also
  keeps content below the clock, add `FlutterWatchOSSafeArea` with the value
  `platform` to `watchos/Runner/Info.plist`. See
  [doc/layout.md](https://github.com/flutterwatch/flutter-watchos/blob/main/doc/layout.md).

- **A watch-only `create` writes stock Flutter's app.**
  `create --platforms=watchos` used to write its own copy of the counter
  app, with shorter comments and labels. It now renders the pinned SDK's own
  app template, as stock `flutter create` does, so the app, its test, the
  pubspec and the README are exactly stock's. Like stock, it also runs
  `pub get` and honours `--empty`, `--description` and `--org`, and it
  refuses other templates and `--sample`, which stock `create` makes. The
  next steps link the layout doc, and the companion-app doc too when the
  project has an iOS app, whose `lib/main.dart` the watch then runs.

- **The Simulator needs no account.** `precache` on a machine that has not
  signed in installs the Simulator engine, lists the others as "needs an
  account, skipped", and says how to get them: after `flutter-watchos login`
  the next build downloads only what is missing (`precache` does it straight
  away). Builds in between leave the missing engines alone instead of asking
  the service for them every time. Before, the first engine that wanted an
  account ended the download and the Simulator engine that had already
  arrived was thrown away with it. An account the service has switched off
  keeps the Simulator engine too. A sign-in the service no longer accepts
  still gets a plain error, in the service's own words, which now also says
  to run `login` again.

- **A build that lacks its engine says why.** `build` or `run` in profile or
  release, when that engine is one the last download left out, stops before
  compiling anything and says whether the answer is `login` or `precache`.
  It used to fail partway with "libflutter_engine.dylib not found — run
  precache", which for a signed-out machine changes nothing.

- **Other download refusals read as the service wrote them.** The tool prints
  the service's own words, once, after the download, so its wording can change
  without a CLI release.

- **Release builds are registered with your account.** After a successful
  `build watchos --release` the tool sends four fields — bundle id, app
  version, engine id, build mode — so the app shows up under "My apps" in your
  console. It is on by default, prints a line when it happens and explains
  itself in full the first time. `flutter-watchos build-registry --disable`,
  `FLUTTER_WATCHOS_BUILD_REGISTRY=0` (for CI) or `--no-register-build` (one
  build) turn it off. Nothing is added to the app, it never delays or fails a
  build, and there is still no usage analytics. See
  [doc/build-registry.md](doc/build-registry.md).

- **`logout` revokes the sign-in.** It used to delete only the local
  credentials file, which left the token valid on the service, and every
  login added one more. It now asks the service to revoke the token first,
  then removes the file, and says whether the revocation went through.

- **`doctor` says where you stand.** The watchOS entry lists the engines
  installed and the modes they build, whether the machine is signed in and
  as whom, and any engines still to download, and the summary line reads,
  for example, "(Simulator engine, not signed in)". It looks where `precache`
  looks, `WATCHOS_ENGINE_ARTIFACTS` included, and makes no network request.
  The `Flutter` entry no longer reads `[!]` on every install: the pinned SDK
  sits on one commit, not a channel, so the "unknown channel" and "`flutter`
  on your path" warnings, and their advice, were wrong for it. It now says
  "pinned by flutter-watchos".

- **`upgrade` downloads the engine only when it changed.** It ran
  `precache --force`, which deleted the working engine and fetched all of it
  again, about 66 MB, even when the new release pins the same engine, and left
  no engine at all when that failed. It now runs a plain `precache`, as stock
  `flutter upgrade` does. `precache --force` only ever touches the engine this
  tool downloaded (never a `WATCHOS_ENGINE_ARTIFACTS` or workspace engine), and
  puts it back if the new download fails.

- **Flutter 3.47.5.** The pinned SDK moves from 3.47.4 to 3.47.5, which rolls
  Dart from 3.13.3 to 3.13.4. No engine source changes, but the engine is
  rebuilt on it and re-pinned as `engine-31ccab0d37ab`: an engine only loads
  kernel compiled by its own Dart, so the two pins move together. 3.47.5 fixes
  a `flutter_tools` crash when the Dart Development Service fails to start. It
  also changes the commands `flutter_tools` sends to lldb: the JIT breakpoint
  now continues through `--auto-continue true` instead of through its hook.
  The tool attaches lldb only when a prebuilt app (`--use-application-binary`)
  is run in debug mode on a physical watch, and a debug app cannot run there:
  debug needs the JIT engine, which exists only for the Simulator.

- **Plugins added later are found.** The tool keeps
  `.flutter-plugins-dependencies` between builds and took its list of plugins
  from the dependency graph that stock `flutter pub get` writes there. That
  graph goes stale: a watchOS-only plugin added to an app that already had one
  was missing from it, so it was never registered and its native code never
  linked, and every call into it threw `MissingPluginException` until the file
  was deleted by hand. Every package pub resolved is now a candidate; the
  `watchos:` block in each plugin's pubspec still decides which are watchOS
  plugins.

- Smaller things: each engine in a download is one line, where a skipped one
  used to take three; a first download that cannot reach the service says so
  instead of suggesting `login`; curl gives up connecting after 15 seconds;
  `create` ends with how to run the watch app (`flutter-watchos run`) rather
  than stock Flutter's `flutter run`; the help for `login` no longer says an
  account is required for every engine; the build-registry notice links its
  doc by URL.

- Docs: they describe accounts as they now are
  ([doc/accounts.md](doc/accounts.md)), and `login` is the whole of signing
  up. The README's WebKit limitation says what is possible: no embeddable web
  view, but `url_launcher_watchos` 0.1.0 shows a page full-screen in the
  system browser on the watch. `package:flutter_watchos` is 0.1.0, and
  [doc/plugins.md](doc/plugins.md) adds it from pub.dev.
  THIRD_PARTY_LICENSES.md carries flutter-tvos's notice and says where the
  engine's `LICENSES.txt` ships. The issue template is "Feedback".

Changes before 0.1.0 are in this file at the
[earlier release tags](https://github.com/flutterwatch/flutter-watchos/tags).
