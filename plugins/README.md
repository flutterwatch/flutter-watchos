# Federated watchOS plugins

This directory holds federated `*_watchos` plugin implementations the
`flutter-watchos` CLI can consume (a plugin declares
`flutter.plugin.platforms.watchos` in its pubspec).

It is the watchOS analogue of the `fluttertv/plugins` repository. As the
`flutterwatch.dev` publisher gains packages, add or submodule them here.

The CLI itself contains **no plugin-specific code** — working plugin
implementations live here, not in `lib/`.
