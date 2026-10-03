# Changelog

## Unreleased

- **`login` says what you do in the browser.** It waits for you to confirm
  the code it printed, and a code that runs out "expired before it was
  confirmed". It used to wait "for approval", as if someone else had to say
  yes. An engine the service holds back is now "not available, skipped".

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
  keeps the Simulator engine too. A service that wants an account for
  everything still gets a plain error, in its own words, and so does a
  sign-in the service no longer accepts, which now also says to run `login`
  again.

- **A build that lacks its engine says why.** `build` or `run` in profile or
  release, when that engine is one the last download left out, stops before
  compiling anything and says whether the answer is `login` or `precache`.
  It used to fail partway with "libflutter_engine.dylib not found — run
  precache", which for a signed-out machine changes nothing.

- **Which engines an account gets is the service's decision, and its
  wording.** The tool no longer names a programme in its own messages: an
  engine the service holds back is "not available to this account, skipped",
  and any other refusal is passed on as the service wrote it, once, after the
  download. A change of policy reaches every installed CLI without a release.

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
