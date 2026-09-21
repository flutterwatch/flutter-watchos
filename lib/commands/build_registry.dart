// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/runner/flutter_command.dart';

import '../watchos_build_registry.dart';

/// `flutter-watchos build-registry [--enable | --disable]` — shows, and
/// changes, whether release builds are registered with flutterwatch.dev.
class WatchosBuildRegistryCommand extends FlutterCommand {
  WatchosBuildRegistryCommand() {
    argParser
      ..addFlag('enable', negatable: false, help: 'Register release builds with your flutterwatch.dev account (the default).')
      ..addFlag('disable', negatable: false, help: 'Never register release builds from this machine.');
  }

  @override
  final String name = 'build-registry';

  @override
  final String description =
      'Show or change whether release builds are registered with flutterwatch.dev.';

  @override
  String get category => FlutterCommandCategory.tools;

  @override
  Future<FlutterCommandResult> runCommand() async {
    final bool enable = boolArg('enable');
    final bool disable = boolArg('disable');
    if (enable && disable) {
      globals.printError('Pass either --enable or --disable, not both.');
      return FlutterCommandResult.fail();
    }
    if (enable || disable) {
      setBuildRegistryEnabled(globals.fs, globals.platform, enabled: enable);
    }

    final BuildRegistryState state = buildRegistryState(globals.fs, globals.platform);
    globals.printStatus(switch (state) {
      BuildRegistryState.enabled => 'Build registry: on.',
      BuildRegistryState.disabledBySetting => 'Build registry: off.',
      BuildRegistryState.disabledByEnvironment =>
        'Build registry: off for this shell ($kBuildRegistryEnv is set)'
            '${enable ? ' — the saved setting is now on, but the environment variable wins' : ''}.',
    });
    globals.printStatus(
      '\nWhen it is on, a successful `flutter-watchos build watchos --release` sends four\n'
      'things to your flutterwatch.dev account: the bundle id, the app version, the\n'
      'engine id and the build mode. Nothing else leaves your machine, nothing is added\n'
      'to your app, and the app itself never contacts flutterwatch.dev.\n'
      '\n'
      '  flutter-watchos build-registry --disable         turn it off on this machine\n'
      '  $kBuildRegistryEnv=0                 turn it off for one shell or a CI job\n'
      '  flutter-watchos build watchos --no-register-build   skip it for one build\n'
      '\n'
      'Details: doc/build-registry.md',
    );
    return FlutterCommandResult.success();
  }
}
