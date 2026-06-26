// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/commands/create.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/ios/code_signing.dart';
import 'package:flutter_tools/src/runner/flutter_command.dart';
import 'package:flutter_tools/src/template.dart';

import 'watchos_app_scaffold.dart';
import 'watchos_runner.dart';

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

    // watchOS-only app: build the shared scaffold + watchos/ ourselves. We do
    // NOT delegate to upstream `flutter create` (it can't target watchos and
    // would force an unwanted iOS/Android app), so nothing is generated then
    // stripped — the project is watchOS-only by construction.
    if (boolArg('watchos-only') && templateType != 'plugin') {
      globals.logger.printStatus('Generating watchOS-only project...');
      WatchosAppScaffold(globals.fs).write(projectDirPath, name);
      await _renderWatchosRunner(projectDirPath, name);
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
    if (templateType == 'plugin') {
      return _createPlugin(projectDirPath, name);
    }
    return _createApp(projectDirPath, name);
  }

  Future<FlutterCommandResult> _createApp(String projectDirPath, String name) async {
    await _renderWatchosRunner(projectDirPath, name);
    return FlutterCommandResult.success();
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

  Future<FlutterCommandResult> _createPlugin(String projectDirPath, String name) async {
    final String pluginTemplatePath = globals.fs.path.join(
      Cache.flutterRoot!,
      '..',
      'templates',
      'plugin',
      'swift',
      'watchos.tmpl',
    );
    final Directory templateDir = globals.fs.directory(pluginTemplatePath);
    final Directory targetDir = globals.fs.directory(projectDirPath).childDirectory('watchos');

    if (!templateDir.existsSync()) {
      globals.logger.printError('watchOS plugin template not found at ${templateDir.path}');
      return FlutterCommandResult.fail();
    }

    if (!targetDir.existsSync()) {
      globals.logger.printStatus('Generating watchOS plugin...');

      // Convert name to plugin class: my_plugin → MyPlugin
      final String pluginClass = name
          .split('_')
          .map((String part) => part.isEmpty ? '' : part[0].toUpperCase() + part.substring(1))
          .join();

      final template = Template(
        templateDir,
        templateDir,
        fileSystem: globals.fs,
        logger: globals.logger,
        templateRenderer: globals.templateRenderer,
      );

      template.render(targetDir, <String, Object>{
        'projectName': name,
        'pluginClass': pluginClass,
        'description': 'A new Flutter watchOS plugin project.',
      });
    }

    // Patch pubspec.yaml to add watchOS platform declaration.
    _patchPluginPubspec(projectDirPath, name);

    return FlutterCommandResult.success();
  }

  /// Adds watchOS platform entry to the plugin's pubspec.yaml.
  void _patchPluginPubspec(String projectDirPath, String name) {
    final File pubspecFile = globals.fs.file(globals.fs.path.join(projectDirPath, 'pubspec.yaml'));

    if (!pubspecFile.existsSync()) {
      return;
    }

    String content = pubspecFile.readAsStringSync();

    // Convert name to plugin class.
    final String pluginClass = name
        .split('_')
        .map((String part) => part.isEmpty ? '' : part[0].toUpperCase() + part.substring(1))
        .join();

    // Add watchOS platform under flutter.plugin.platforms if not already
    // present.
    if (!content.contains('watchos:')) {
      final platformsRegex = RegExp(r'(platforms:\s*\n)', multiLine: true);
      final Match? match = platformsRegex.firstMatch(content);
      if (match != null) {
        final insertion =
            '${match.group(0)}'
            '        watchos:\n'
            '          pluginClass: $pluginClass\n';
        content = content.replaceFirst(match.group(0)!, insertion);
        pubspecFile.writeAsStringSync(content);
        globals.logger.printStatus('Added watchOS platform to pubspec.yaml');
      }
    }
  }
}
