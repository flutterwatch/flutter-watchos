// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/runner/flutter_command.dart';

import 'channel.dart';

/// The message `downgrade` exits with.
const String kWatchosDowngradeRefusal =
    'Downgrading is not supported. $kWatchosPinSentence\n'
    '$kWatchosUpgradeAdvice';

/// `flutter-watchos downgrade`: exits 1 and says to use `upgrade`.
///
/// Stock `downgrade` resets the SDK checkout to the last version of its
/// channel. flutter-watchos pins one Flutter commit, and its next run would
/// undo the reset, so this command stops before any git or other process
/// call. The stock options are accepted, hidden, and change nothing.
class WatchosDowngradeCommand extends FlutterCommand {
  /// Creates the command with the stock `--working-directory` and `--prompt`
  /// options, so scripts that pass them get the refusal, not a usage error.
  WatchosDowngradeCommand() {
    argParser.addOption(
      'working-directory',
      hide: true,
      help: 'Has no effect: flutter-watchos does not downgrade.',
    );
    argParser.addFlag(
      'prompt',
      defaultsTo: true,
      hide: true,
      help: 'Has no effect: flutter-watchos does not downgrade.',
    );
  }

  @override
  final String name = 'downgrade';

  @override
  final String description =
      'Not supported: flutter-watchos pins its Flutter version.\n'
      '\n'
      'Run "flutter-watchos upgrade" to move to a newer release.';

  @override
  final String category = FlutterCommandCategory.sdk;

  @override
  bool get shouldUpdateCache => false;

  @override
  Future<Set<DevelopmentArtifact>> get requiredArtifacts async => const <DevelopmentArtifact>{};

  @override
  Future<FlutterCommandResult> runCommand() async {
    throwToolExit(kWatchosDowngradeRefusal);
  }
}
