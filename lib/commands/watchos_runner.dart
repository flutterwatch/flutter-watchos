// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/template.dart';
import 'package:flutter_tools/src/base/utils.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/commands/create_base.dart';
import 'package:flutter_tools/src/template.dart';

/// Renders the bundled `watchos/` Xcode runner template into
/// [projectDirPath]. Extracted from `WatchosCreateCommand` so the plugin
/// porter can drop a `watchos/` runner into a copied example app too, without
/// re-running `flutter create`.
///
/// No-op when the template is missing or `watchos/` already exists.
/// [developmentTeam] is only relevant for on-device signing (left null for
/// example apps).
Future<void> renderWatchosRunner({
  required FileSystem fileSystem,
  required Logger logger,
  required TemplateRenderer templateRenderer,
  required String projectDirPath,
  required String name,
  required String organization,
  String? developmentTeam,
}) async {
  final String watchosTemplatePath = fileSystem.path.join(
    Cache.flutterRoot!,
    '..',
    'templates',
    'app',
    'swift',
    'watchos.tmpl',
  );
  final Directory templateDir = fileSystem.directory(watchosTemplatePath);
  final Directory targetDir = fileSystem.directory(projectDirPath).childDirectory('watchos');
  if (!templateDir.existsSync() || targetDir.existsSync()) {
    return;
  }

  final String watchosIdentifier = CreateBase.createUTIIdentifier(organization, name);
  // `Foo Bar` for human-readable display (Info.plist), `FooBar` for the Swift
  // type identifier (App.swift) — matching how stock `flutter create` derives
  // names. titleCaseProjectName must never be used as a code identifier.
  final String titleCaseProjectName = snakeCaseToTitleCase(name);
  final String pascalCaseProjectName = titleCaseProjectName.replaceAll(' ', '');
  logger.printStatus('Generating watchOS runner...');
  final template = Template(
    templateDir,
    templateDir,
    fileSystem: fileSystem,
    logger: logger,
    templateRenderer: templateRenderer,
  );
  template.render(targetDir, <String, Object>{
    'organization': organization,
    'projectName': name,
    'titleCaseProjectName': titleCaseProjectName,
    'pascalCaseProjectName': pascalCaseProjectName,
    'watchosIdentifier': watchosIdentifier,
    'withRootModule': true,
    'withPlatformChannelPluginHook': true,
    'withPluginHook': true,
    'withFfiPluginHook': true,
    'withFfiPackage': true,
    'withSwiftPackageManager': true,
    'swiftPackageManagerEnabled': true,
    'cocoapodsEnabled': true,
    'pluginClass': 'DummyPlugin',
    'pluginClassSnakeCase': 'dummy_plugin',
    'pluginProjectName': 'dummy_plugin',
    'hasWatchosDevelopmentTeam': developmentTeam != null && developmentTeam.isNotEmpty,
    'watchosDevelopmentTeam': developmentTeam ?? '',
  });
  final File podfileSrc = templateDir.childFile('Podfile');
  if (podfileSrc.existsSync()) {
    podfileSrc.copySync(targetDir.childFile('Podfile').path);
  }
}
