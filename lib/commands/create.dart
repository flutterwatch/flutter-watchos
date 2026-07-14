// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/commands/create.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/ios/code_signing.dart';
import 'package:flutter_tools/src/runner/flutter_command.dart';

import '../watchos_host_mode.dart';
import 'watchos_app_scaffold.dart';
import 'watchos_runner.dart';

/// Why `flutter-watchos create` rejects [templateType], or null when the
/// template is supported.
///
/// The plugin templates are rejected outright: stock Flutter's `plugin`
/// template generates method-channel code and `plugin_ffi` generates a
/// native-assets build, and neither model can run on watchOS — watchOS
/// plugins are dart:ffi packages whose C sources the CLI compiles and links
/// into the watch binary. There is no "new watchOS plugin" template; the
/// supported paths are `flutter-watchos plugin port` and hand-authoring per
/// the plugins repo's AUTHORING.md.
String? watchosCreateTemplateError(String templateType) {
  if (templateType != 'plugin' && templateType != 'plugin_ffi') {
    return null;
  }
  return 'flutter-watchos create does not support --template=$templateType.\n'
      'watchOS plugins are dart:ffi packages (method-channel plugins are not '
      'supported on watchOS), so the stock plugin templates would generate '
      'code that cannot run on the watch. Instead:\n'
      '  * Port an existing iOS/macOS plugin:\n'
      '      flutter-watchos plugin port --from-pub <package>\n'
      '  * Author one from scratch following AUTHORING.md in\n'
      '    https://github.com/flutterwatch/plugins\n'
      'For plugins that target other platforms, use stock `flutter create`.';
}

class WatchosCreateCommand extends CreateCommand {
  WatchosCreateCommand({required super.verboseHelp}) {
    // Internal only. Users say `--platforms=watchos`; the argv shim in
    // executable.dart rewrites that to this flag because upstream Flutter's
    // `--platforms` parser rejects `watchos`. Hidden so it never appears in
    // `--help` as a thing to type.
    argParser.addFlag('watchos-only', negatable: false, hide: true);
  }

  @override
  Future<FlutterCommandResult> runCommand() async {
    // Mirror stock `flutter create`: print the friendly usage message and exit
    // (code 2) when no output directory is given — or more than one — instead
    // of crashing on `rest.first`.
    validateOutputDirectoryArg();
    final String projectDirPath = argResults!.rest.first;
    final String name = stringArg('project-name') ?? globals.fs.path.basename(projectDirPath);
    final String templateType = stringArg('template') ?? 'app';

    // Reject plugin templates before upstream `flutter create` runs, so a
    // refused create leaves nothing half-scaffolded on disk.
    final String? templateError = watchosCreateTemplateError(templateType);
    if (templateError != null) {
      throwToolExit(templateError);
    }

    // watchOS-only app: build the shared scaffold + watchos/ ourselves. We do
    // NOT delegate to upstream `flutter create` (it can't target watchos and
    // would force an unwanted iOS/Android app), so nothing is generated then
    // stripped — the project is watchOS-only by construction.
    if (boolArg('watchos-only')) {
      globals.logger.printStatus('Generating watchOS-only project...');
      WatchosAppScaffold(globals.fs).write(projectDirPath, name);
      await _renderWatchosRunner(projectDirPath, name);
      await _adoptHostMode(projectDirPath);
      globals.logger.printStatus(
        'Created watchOS-only project (shared app + watchos/, no other platforms).',
      );
      return FlutterCommandResult.success();
    }

    // Standard path: real `flutter create` (all/requested platforms), then add
    // `watchos/` alongside.
    final FlutterCommandResult exitCode = await super.runCommand();
    if (exitCode != FlutterCommandResult.success()) {
      return exitCode;
    }
    await _renderWatchosRunner(projectDirPath, name);
    await _adoptHostMode(projectDirPath);
    return FlutterCommandResult.success();
  }

  /// Applies the host mode the project's shape implies — companion when
  /// `create` scaffolded (or found) an iOS app, standalone otherwise — and
  /// tells the user which one they got and why. Nothing is recorded: like
  /// stock Flutter platforms, the ios/ directory itself is the source of
  /// truth, and build/run re-derive the mode the same way.
  Future<void> _adoptHostMode(String projectDirPath) async {
    final WatchosHostMode? mode = await syncWatchosHostMode(
      projectDir: globals.fs.directory(projectDirPath),
      logger: globals.logger,
    );
    switch (mode) {
      case null:
        break;
      case WatchosHostMode.standalone:
        globals.logger.printStatus(
          'Host mode: standalone — this project has no iOS app, so the watch '
          'app is watch-only (WKWatchOnly) and ships inside the thin HostApp '
          'container in watchos/. Adding an iOS app later '
          '(flutter create --platforms=ios .) makes the watch app its '
          'companion automatically.',
        );
      case WatchosHostMode.companion:
        globals.logger.printStatus(
          'Host mode: companion — this project has an iOS app in ios/, so '
          'the watch app ships inside it: the iOS Runner embeds the prebuilt '
          'watch app and the watch Info.plist declares the iOS app as its '
          'companion.',
        );
    }
  }

  /// Renders the `watchos/` Xcode runner into [projectDirPath], detecting the
  /// org and (for on-device signing) a development team the way
  /// `flutter create` does. Delegates the template work to the shared
  /// [renderWatchosRunner] so the plugin porter can reuse it.
  Future<void> _renderWatchosRunner(String projectDirPath, String name) async {
    final String organization = await getOrganization();
    final String? developmentTeam = await getCodeSigningIdentityDevelopmentTeam(
      processManager: globals.processManager,
      platform: globals.platform,
      logger: globals.logger,
      config: globals.config,
      terminal: globals.terminal,
      fileSystem: globals.fs,
      fileSystemUtils: globals.fsUtils,
      plistParser: globals.plistParser,
    );
    await renderWatchosRunner(
      fileSystem: globals.fs,
      logger: globals.logger,
      templateRenderer: globals.templateRenderer,
      projectDirPath: projectDirPath,
      name: name,
      organization: organization,
      developmentTeam: developmentTeam,
    );
  }
}
