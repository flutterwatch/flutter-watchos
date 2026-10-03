// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/template.dart';
import 'package:flutter_tools/src/base/utils.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/commands/create_base.dart';
import 'package:flutter_tools/src/template.dart';

final _alphanumeric = RegExp('[A-Za-z0-9]');

/// The project name the watchOS runner is generated under, given the [name] a
/// caller derived and the name of the directory it is being generated into.
///
/// `flutter-watchos create .` used to reach the template with a literal "."
/// here, which spelled `..app` as the product name and `struct .App: App` in
/// App.swift — Swift that does not parse. `create` itself now resolves the
/// name from the pubspec (or the resolved directory), but this helper is the
/// backstop for every caller: anything with no letters or digits in it (".",
/// "..", "") falls back to [directoryName], and then to "runner".
String watchosRunnerProjectName({required String name, required String directoryName}) {
  for (final candidate in <String>[name, directoryName]) {
    if (candidate.contains(_alphanumeric)) {
      return candidate;
    }
  }
  return 'runner';
}

/// Upper-camel-cases [name] into a Swift type identifier, for the
/// `struct <name>App: App` the runner template declares.
///
/// The Info.plist display name can be any string, but this one is code: a
/// project name that is not already a Dart package name (`--skip-name-checks`,
/// or a directory-derived name like `my-app`) has to be reduced to
/// `[A-Za-z0-9]` before it can be spelled in Swift, and Swift identifiers may
/// not start with a digit.
String watchosSwiftTypeName(String name) {
  final String pascalCase = name
      .split(RegExp('[^A-Za-z0-9]+'))
      .where((String word) => word.isNotEmpty)
      .map(sentenceCase)
      .join();
  if (pascalCase.isEmpty) {
    return 'Runner';
  }
  // Legal in Swift, and keeps the digits the user named the project after.
  return pascalCase.startsWith(RegExp('[0-9]')) ? '_$pascalCase' : pascalCase;
}

/// The bundled `watchos/` Xcode runner template,
/// `templates/app/swift/watchos.tmpl` of the flutter-watchos checkout, which
/// is looked for next to the checkout's `flutter/` folder.
///
/// Throws a [ToolExit] that names the path it looked for when the template is
/// not there: the checkout is incomplete, and no `watchos/` can be made.
Directory watchosRunnerTemplate(FileSystem fileSystem) {
  final String path = fileSystem.path.join(
    Cache.flutterRoot!,
    '..',
    'templates',
    'app',
    'swift',
    'watchos.tmpl',
  );
  final Directory template = fileSystem.directory(path);
  if (!template.existsSync()) {
    throwToolExit(
      'Cannot create watchos/: the watchOS app template is not at $path.\n'
      'The flutter-watchos checkout looks incomplete. Its templates/ folder is looked for '
      'next to its flutter/ folder, and when flutter/ is a link to an SDK elsewhere, next to '
      'that SDK.',
    );
  }
  return template;
}

/// Renders the bundled `watchos/` Xcode runner template into
/// [projectDirPath]. Extracted from `WatchosCreateCommand` so the plugin
/// porter can drop a `watchos/` runner into a copied example app too, without
/// re-running `flutter create`.
///
/// No-op when `watchos/` already exists. Throws a [ToolExit] when the template
/// is missing ([watchosRunnerTemplate]), before anything is written.
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
  final Directory targetDir = fileSystem.directory(projectDirPath).childDirectory('watchos');
  if (targetDir.existsSync()) {
    return;
  }
  final Directory templateDir = watchosRunnerTemplate(fileSystem);

  final String projectName = watchosRunnerProjectName(
    name: name,
    directoryName: fileSystem.path.basename(
      fileSystem.path.normalize(fileSystem.directory(projectDirPath).absolute.path),
    ),
  );
  final String watchosIdentifier = CreateBase.createUTIIdentifier(organization, projectName);
  // `Foo Bar` for human-readable display (Info.plist), `FooBar` for the Swift
  // type identifier (App.swift) — matching how stock `flutter create` derives
  // names. titleCaseProjectName must never be used as a code identifier.
  final String titleCaseProjectName = snakeCaseToTitleCase(projectName);
  final String pascalCaseProjectName = watchosSwiftTypeName(projectName);
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
    'projectName': projectName,
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
