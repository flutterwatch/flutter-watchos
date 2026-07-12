// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/runner/flutter_command.dart';

import '../watchos_host_mode.dart';

/// Reports how the watch app ships to the App Store and brings the project's
/// wiring in line with it.
///
/// The mode is not a setting — it follows the project shape, the same way
/// stock Flutter treats platform directories as the source of truth:
///
/// * no iOS app → **standalone**: the watch app is `WKWatchOnly` and ships
///   inside the thin `HostApp` container in `watchos/`.
/// * `ios/` Flutter app present → **companion**: the iOS Runner embeds the
///   prebuilt watch app and the watch Info.plist declares
///   `WKCompanionAppBundleIdentifier`.
///
/// `create`/`build`/`run` re-derive and reconcile this automatically; the
/// command exists to inspect the state (and heal it without building).
class WatchosHostCommand extends FlutterCommand {
  @override
  final String name = 'host';

  @override
  final String description =
      'Show how the watch app ships (standalone or companion of the iOS app).';

  @override
  String get invocation => 'flutter-watchos host';

  @override
  String get category => FlutterCommandCategory.project;

  @override
  bool get shouldUpdateCache => false;

  @override
  Future<FlutterCommandResult> runCommand() async {
    final Directory projectDir = globals.fs.currentDirectory;
    if (!projectDir.childDirectory('watchos').existsSync()) {
      throwToolExit('No watchos/ directory here. Run this from a flutter-watchos project.');
    }
    if (argResults!.rest.isNotEmpty) {
      throwToolExit(
        'The host mode is not a setting — it follows the project shape:\n'
        '  * an ios/ Flutter app makes the watch app its companion;\n'
        '  * without one the watch app is standalone (watch-only).\n'
        'Add an iOS app with "flutter create --platforms=ios ." or remove '
        'ios/ to go watch-only; the wiring updates on the next '
        'create/build/run (or by running "flutter-watchos host").',
      );
    }

    final WatchosHostMode? mode = await syncWatchosHostMode(
      projectDir: projectDir,
      logger: globals.logger,
    );
    if (mode == null) {
      throwToolExit(
        'No watch app Info.plist at watchos/Runner/Info.plist. '
        'Is this a flutter-watchos app project?',
      );
    }

    switch (mode) {
      case WatchosHostMode.standalone:
        globals.logger.printStatus(
          'Host mode: standalone (no iOS app in this project).\n'
          'The watch app is watch-only (WKWatchOnly) and ships inside the '
          'thin HostApp container in watchos/. Adding an iOS app '
          '("flutter create --platforms=ios .") makes the watch app its '
          'companion automatically.',
        );
      case WatchosHostMode.companion:
        globals.logger.printStatus(
          'Host mode: companion (iOS app found in ios/).\n'
          'The watch app ships inside the iOS app: the iOS Runner embeds the '
          'prebuilt watch app ("flutter-watchos build watchos --release" '
          'first) and the watch Info.plist declares the iOS app as its '
          'companion.',
        );
    }
    return FlutterCommandResult.success();
  }
}
