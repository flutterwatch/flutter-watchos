// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/runner/flutter_command.dart';

/// `flutter-watchos plugin port <ios-or-macos-plugin>` — scaffolds a federated
/// `*_watchos` package from an existing iOS or macOS plugin.
///
/// NOTE: This is a placeholder. The full porter subsystem (source analyzer,
/// scaffolder, Swift/ObjC transformers, compatibility database, report
/// emitter) lands in a dedicated pass — it is generic (no plugin-specific
/// code) and self-contained, so it does not block the build/run path. Until
/// then this command exits with a clear message rather than pretending to
/// scaffold.
class WatchosPluginPortCommand extends FlutterCommand {
  WatchosPluginPortCommand() {
    argParser
      ..addFlag('dry-run', help: 'Print what would be written without writing.')
      ..addFlag('force', help: 'Overwrite an existing output package.')
      ..addFlag('report', defaultsTo: true, help: 'Write a PORTING_REPORT.md.')
      ..addFlag('include-example', help: 'Wire the source plugin example for watchOS.')
      ..addOption('from-pub', help: 'Fetch the source plugin from pub.dev.')
      ..addOption('from-git', help: 'Fetch the source plugin from a git URL.');
  }

  @override
  final String name = 'port';

  @override
  final String description =
      'Scaffold a federated *_watchos plugin from an existing iOS or macOS plugin.';

  @override
  Future<FlutterCommandResult> runCommand() async {
    throwToolExit(
      'The watchOS plugin porter is not yet available in this build of '
      'flutter-watchos.\n'
      'When ready it will scaffold a federated `*_watchos` package from an '
      'iOS/macOS plugin.',
    );
  }
}
