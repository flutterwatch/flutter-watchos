// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// args resolves as a dev dependency of this package and as a dependency of
// flutter_tools; until pubspec.yaml lists it under dependencies, this import
// needs the lint silenced.
// ignore: depend_on_referenced_packages
import 'package:args/args.dart';
import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/base/os.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/runner/flutter_command.dart';

import '../watchos_host_mode.dart';

/// The `build` subcommands of stock Flutter, by their stock names.
///
/// flutter-watchos builds only the watch app, so `build` offers `watchos`
/// and answers each of these with [StockBuildStubCommand].
const List<String> kStockBuildSubcommands = <String>[
  'aar',
  'apk',
  'appbundle',
  'bundle',
  'ios',
  'ios-framework',
  'ipa',
  'linux',
  'macos',
  'macos-framework',
  'swift-package',
  'web',
  'windows',
];

/// The aliases stock Flutter gives some of [kStockBuildSubcommands].
const Map<String, List<String>> kStockBuildSubcommandAliases = <String, List<String>>{
  'appbundle': <String>['aab'],
  'ipa': <String>['xcarchive'],
};

/// What `flutter-watchos build <name>` says for a stock build target [name].
///
/// Every target names stock `flutter build <name>`. `ipa` gives the route
/// that fits the project instead: a [companion] project (one with an iOS
/// app) builds the watch app, then the iOS archive with stock Flutter; a
/// watch-only project archives in Xcode, or uploads an exported `.ipa`.
/// Each command is alone on its line, with what it is for in the sentence
/// above.
String stockBuildRefusal(String name, {required bool companion}) {
  final first =
      'flutter-watchos build $name is not available: flutter-watchos builds '
      'only the watchOS app.';
  if (name != 'ipa') {
    return '$first\n'
        'To build $name, use stock Flutter:\n'
        '  flutter build $name';
  }
  if (companion) {
    return '$first\n'
        'This project has an iOS app, and the watch app ships inside it. '
        'Build the watch app first, then the iOS archive with stock Flutter:\n'
        '  flutter-watchos build watchos --release\n'
        '  flutter build ipa';
  }
  return '$first\n'
      'This project has no iOS app, so Xcode archives the watch app. Build '
      'it, then open watchos/Runner.xcodeproj in Xcode and choose '
      'Product → Archive → Distribute App:\n'
      '  flutter-watchos build watchos --release\n'
      'To upload an .ipa exported from Xcode, run:\n'
      '  flutter-watchos upload --ipa <file>';
}

/// A hidden `build <name>` for a stock build target, which stops with
/// [stockBuildRefusal] and builds nothing.
///
/// It takes any argument, so a stock flag such as `--split-per-abi` reaches
/// the refusal instead of a usage error.
class StockBuildStubCommand extends FlutterCommand {
  /// A stub for the stock build target [name].
  StockBuildStubCommand(this.name) : aliases = kStockBuildSubcommandAliases[name] ?? <String>[];

  @override
  final String name;

  @override
  final List<String> aliases;

  @override
  final ArgParser argParser = ArgParser.allowAnything();

  @override
  String get description => 'Not available for watchOS; use flutter build $name.';

  @override
  bool get hidden => true;

  @override
  bool get shouldUpdateCache => false;

  @override
  Future<FlutterCommandResult> runCommand() async {
    // No pubspec is required, so look for the project as stock does; outside
    // one, there is no iOS app either.
    final String projectRoot = findProjectRoot(globals.fs) ?? globals.fs.currentDirectory.path;
    final WatchosHostMode mode = detectWatchosHostMode(globals.fs.directory(projectRoot));
    throwToolExit(
      stockBuildRefusal(name, companion: mode == WatchosHostMode.companion),
      exitCode: 1,
    );
  }
}
