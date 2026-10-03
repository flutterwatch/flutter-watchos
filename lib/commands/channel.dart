// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/runner/flutter_command.dart';
import 'package:flutter_tools/src/version.dart';
import 'package:yaml/yaml.dart';

/// The sentence `channel` and `downgrade` give for why the Flutter SDK does
/// not move.
const String kWatchosPinSentence =
    'flutter-watchos pins one Flutter commit and follows no Flutter channel.';

/// How to reach a newer release: the upgrade command alone on its line, with
/// what it does in the sentence above.
const String kWatchosUpgradeAdvice =
    'To move to a newer flutter-watchos release, and the Flutter it pins, run:\n'
    '  flutter-watchos upgrade';

/// The version in flutter-watchos's own `pubspec.yaml`, next to the pinned
/// SDK at [Cache.flutterRoot], or null when it cannot be read.
///
/// Reading the file needs no git call, unlike the release tag `upgrade`
/// shows.
String? flutterWatchosVersion(FileSystem fileSystem) {
  final File pubspec = fileSystem.directory(Cache.flutterRoot).parent.childFile('pubspec.yaml');
  if (!pubspec.existsSync()) {
    return null;
  }
  try {
    final Object? yaml = loadYaml(pubspec.readAsStringSync());
    if (yaml is YamlMap) {
      final Object? version = yaml['version'];
      if (version != null) {
        return version.toString();
      }
    }
  } on YamlException {
    // A pubspec that does not parse gives no version; `channel` still answers.
  }
  return null;
}

/// The text plain `channel` prints: the tool version, the pinned Flutter
/// version and framework revision, the pin sentence and the upgrade advice.
String watchosChannelReport({
  required String? toolVersion,
  required FlutterVersion flutterVersion,
}) {
  return <String>[
    'flutter-watchos ${toolVersion ?? '(version unknown)'}',
    'Flutter ${flutterVersion.frameworkVersion}, framework revision ${flutterVersion.frameworkRevision}',
    '',
    kWatchosPinSentence,
    kWatchosUpgradeAdvice,
  ].join('\n');
}

/// `flutter-watchos channel`: shows the Flutter version the tool pins.
///
/// Stock `channel` lists the SDK checkout's branches, and `channel <name>`
/// checks another branch out, which the next flutter-watchos run resets to
/// the pin. Here the SDK never moves: with no argument the command prints the
/// pin, and with a channel name it exits 1 before any git or other process
/// call. The stock flags are accepted, hidden, and change nothing.
class WatchosChannelCommand extends FlutterCommand {
  /// Creates the command with the stock `--all` and `--cache-artifacts`
  /// flags, so scripts that pass them still parse.
  WatchosChannelCommand() {
    argParser.addFlag(
      'all',
      abbr: 'a',
      hide: true,
      help: 'Has no effect: flutter-watchos lists no channels.',
    );
    argParser.addFlag(
      'cache-artifacts',
      defaultsTo: true,
      hide: true,
      help: 'Has no effect: flutter-watchos switches no channels.',
    );
  }

  @override
  final String name = 'channel';

  @override
  final String description =
      'Show the Flutter version flutter-watchos pins.\n'
      '\n'
      '$kWatchosPinSentence '
      'Run "flutter-watchos upgrade" to move to a newer release.';

  @override
  final String category = FlutterCommandCategory.sdk;

  @override
  String get invocation => '${runner?.executableName} $name';

  @override
  bool get shouldUpdateCache => false;

  @override
  Future<Set<DevelopmentArtifact>> get requiredArtifacts async => const <DevelopmentArtifact>{};

  @override
  Future<FlutterCommandResult> runCommand() async {
    if (argResults!.rest.isNotEmpty) {
      throwToolExit(
        'Switching channels is not supported. $kWatchosPinSentence\n'
        '$kWatchosUpgradeAdvice',
      );
    }
    globals.printStatus(
      watchosChannelReport(
        toolVersion: flutterWatchosVersion(globals.fs),
        flutterVersion: globals.flutterVersion,
      ),
    );
    return FlutterCommandResult.success();
  }
}
