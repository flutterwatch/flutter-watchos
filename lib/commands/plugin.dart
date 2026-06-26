// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/runner/flutter_command.dart';

import 'plugin_port.dart';

/// `flutter-watchos plugin …` — umbrella command. Mirrors how upstream Flutter
/// nests sub-tools (`flutter pub …`, `flutter build …`).
///
/// The umbrella itself does not run business logic; it only registers
/// subcommands. Today the only subcommand is `port`.
class WatchosPluginCommand extends FlutterCommand {
  // ignore: avoid_unused_constructor_parameters
  WatchosPluginCommand({required bool verboseHelp}) {
    addSubcommand(WatchosPluginPortCommand());
  }

  @override
  final String name = 'plugin';

  @override
  final String description =
      'Authoring helpers for watchOS plugins. Sub-commands: `port` to scaffold a '
      'federated `*_watchos` package from an existing iOS or macOS plugin.';

  @override
  final String category = 'Tools';

  @override
  Future<FlutterCommandResult> runCommand() async {
    // FlutterCommand routes to subcommands automatically when one is supplied;
    // this body only fires when the user runs `flutter-watchos plugin` with no
    // subcommand. Print the same help banner as `--help` and exit cleanly.
    printUsage();
    return FlutterCommandResult.success();
  }
}
