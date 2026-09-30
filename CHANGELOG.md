# Changelog

## 0.1.0

A watchOS plugin added to an app after its first build is now registered.

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
  was deleted by hand. Adding `firebase_messaging_watchos` to the firebase_auth
  example showed it. Every package pub resolved is now a candidate; the
  `watchos:` block in each plugin's pubspec still decides which are watchOS
  plugins.

- The README's WebKit limitation now says what is possible: no embeddable web
  view, but `url_launcher_watchos` 0.1.0 shows a page full-screen in the system
  browser on the watch.

Changes before 0.1.0 are in this file at the
[earlier release tags](https://github.com/flutterwatch/flutter-watchos/tags).
