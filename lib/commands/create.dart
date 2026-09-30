// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/utils.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/commands/create.dart';
import 'package:flutter_tools/src/convert.dart';
import 'package:flutter_tools/src/dart/pub.dart';
import 'package:flutter_tools/src/flutter_project_metadata.dart'
    show FlutterProjectMetadata, FlutterTemplateType;
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/ios/code_signing.dart';
import 'package:flutter_tools/src/project.dart';
import 'package:flutter_tools/src/runner/flutter_command.dart';
import 'package:yaml/yaml.dart';

import '../watchos_host_mode.dart';
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

/// The project types that make no app, each with what it makes: a package or
/// a module has nothing to run on a watch, so `create` adds no `watchos/` to
/// them.
const Map<FlutterTemplateType, String> _typesWithoutApp = <FlutterTemplateType, String>{
  FlutterTemplateType.package: 'a package',
  FlutterTemplateType.packageFfi: 'an FFI package',
  FlutterTemplateType.module: 'a module',
};

// The two guides a companion app's watch layout needs, by absolute URL, as the
// build-registry notice gives its doc: a repository path does not open from a
// terminal.
const String _companionAppsDocUrl =
    'https://github.com/flutterwatch/flutter-watchos/blob/main/doc/companion-apps.md';
const String _layoutDocUrl =
    'https://github.com/flutterwatch/flutter-watchos/blob/main/doc/layout.md';

/// How to run the watch app `create` just made, printed last.
///
/// Stock `flutter create` ends with "\$ flutter run", which runs the other
/// platforms' apps (or is not installed at all, when flutter-watchos is the
/// only Flutter on the machine). [afterStockCreate] says that instruction has
/// just been printed above, and is not the one for the watch.
///
/// Either way the watch runs a layout made for a larger screen: the phone's
/// `lib/main.dart` when the project has an iOS app ([companion]), stock
/// Flutter's counter app otherwise. So the steps end with one line that points
/// to the docs on laying it out for the watch.
String watchosCreateNextSteps(
  String relativeProjectPath, {
  required bool afterStockCreate,
  required bool companion,
}) {
  final cd = relativeProjectPath == '.' ? '' : '  \$ cd $relativeProjectPath\n';
  final layoutAdvice = companion
      ? '\n\nThe watch app runs the same lib/main.dart as the phone app. To lay it '
            'out for the watch, read $_companionAppsDocUrl and $_layoutDocUrl'
      : "\n\nThe app is stock Flutter's counter, made for a larger screen. To lay "
            'it out for the watch, read $_layoutDocUrl';
  return '\n'
      '${afterStockCreate ? 'The `flutter run` above runs the app on the other platforms. ' : ''}'
      'To run the watch app on the watchOS Simulator, type:\n'
      '\n'
      '$cd'
      '  \$ flutter-watchos run\n'
      '\n'
      'To pick a simulator or a watch, list them with `flutter-watchos devices` '
      'and pass -d <id>.'
      '$layoutAdvice';
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
    // A watch-only create makes stock's app only. Stock `flutter create` writes
    // the samples list before it asks for a project directory, so this is
    // refused before then, and nothing is written.
    if (boolArg('watchos-only') && stringArg('list-samples') != null) {
      throwToolExit(
        'flutter-watchos create --platforms=watchos does not take --list-samples. '
        'List the samples with stock `flutter create --list-samples=<path>`.',
      );
    }
    // Mirror stock `flutter create`: print the friendly usage message and exit
    // (code 2) when no output directory is given — or more than one — instead
    // of crashing on `rest.first`.
    validateOutputDirectoryArg();
    // Use CreateBase's getters rather than deriving these from `rest.first`.
    // `projectDirPath` normalizes to an absolute path (a bare `.` would
    // otherwise make `basename` return "."), and `projectName` prefers the
    // pubspec's `name` — which is what makes `create .` work inside an
    // existing project — then validates it as a Dart package name.
    final String projectDirPath = super.projectDirPath;
    final String name = projectName;
    final String templateType = stringArg('template') ?? 'app';

    // Reject plugin templates before upstream `flutter create` runs, so a
    // refused create leaves nothing half-scaffolded on disk.
    final String? templateError = watchosCreateTemplateError(templateType);
    if (templateError != null) {
      throwToolExit(templateError);
    }

    // watchOS-only app: stock `flutter create`'s app, then watchos/. Upstream
    // `flutter create` cannot target watchos and would add an iOS or Android
    // app, so its own app template is rendered here with every platform off:
    // nothing is generated then stripped, and the app is the one stock create
    // writes, unmodified.
    if (boolArg('watchos-only')) {
      _checkWatchOnlyArgs(templateType, projectDirPath);
      validateProjectDir(overwrite: boolArg('overwrite'));
      globals.logger.printStatus('Generating the app and watchos/...');
      await _generateStockApp(projectDirPath, name);
      await _renderWatchosRunner(projectDirPath, name);
      final WatchosHostMode? mode = await _adoptHostMode(projectDirPath);
      // pub get last, as stock create runs it after every folder is written: a
      // failed pub get leaves a whole project, watchos/ included.
      if (shouldCallPubGet) {
        await pub.get(
          context: PubContext.create,
          project: FlutterProject.fromDirectory(globals.fs.directory(projectDirPath)),
          offline: offline,
          outputMode: PubOutputMode.summaryOnly,
        );
      }
      final companion = mode == WatchosHostMode.companion;
      globals.logger.printStatus(
        companion
            ? 'Added watchos/ beside the iOS app in ios/.'
            : 'Created watchOS-only project (shared app + watchos/, no other platforms).',
      );
      _printNextSteps(projectDirPath, templateType, afterStockCreate: false, companion: companion);
      return FlutterCommandResult.success();
    }

    // Standard path: real `flutter create` (all/requested platforms), then add
    // `watchos/` alongside.
    final FlutterCommandResult exitCode = await super.runCommand();
    if (exitCode != FlutterCommandResult.success()) {
      return exitCode;
    }
    // A package or a module has no app to run on a watch. The type is the one
    // stock create just wrote to .metadata, so `create .` in an existing
    // package, which names no --template, gets no watchos/ either.
    final FlutterTemplateType? made = FlutterProjectMetadata(
      globals.fs.directory(projectDirPath).childFile('.metadata'),
      globals.logger,
    ).projectType;
    final String? withoutApp = _typesWithoutApp[made];
    if (withoutApp != null) {
      globals.logger.printStatus(
        'No watchos/ was added: $withoutApp has no app to run on a watch.',
      );
      return FlutterCommandResult.success();
    }
    await _renderWatchosRunner(projectDirPath, name);
    final WatchosHostMode? mode = await _adoptHostMode(projectDirPath);
    _printNextSteps(
      projectDirPath,
      templateType,
      afterStockCreate: true,
      companion: mode == WatchosHostMode.companion,
    );
    return FlutterCommandResult.success();
  }

  /// Ends `create` with how to run the watch app — for the templates that
  /// make one to run.
  void _printNextSteps(
    String projectDirPath,
    String templateType, {
    required bool afterStockCreate,
    required bool companion,
  }) {
    if (templateType != 'app' && templateType != 'skeleton') {
      return;
    }
    globals.logger.printStatus(
      watchosCreateNextSteps(
        globals.fs.path.normalize(globals.fs.path.relative(projectDirPath)),
        afterStockCreate: afterStockCreate,
        companion: companion,
      ),
    );
  }

  /// Refuses, before anything is written, what a watch-only create cannot
  /// make: it makes stock's app only. Another template, an existing project
  /// of another type, or a `--sample` (which stock fetches with its own,
  /// private code) goes to stock `flutter create`.
  void _checkWatchOnlyArgs(String templateType, String projectDirPath) {
    if (templateType != 'app') {
      throwToolExit(
        'flutter-watchos create --platforms=watchos makes an app only. For a '
        '--template=$templateType project, use stock `flutter create`.',
      );
    }
    final Directory directory = globals.fs.directory(projectDirPath);
    final FlutterTemplateType? existing = directory.existsSync() && directory.listSync().isNotEmpty
        ? determineTemplateType()
        : null;
    if (existing != null && existing != FlutterTemplateType.app) {
      throwToolExit(
        'This directory holds a ${existing.cliName} project, and '
        'flutter-watchos create --platforms=watchos makes an app only.',
      );
    }
    if (argResults!.wasParsed('sample')) {
      throwToolExit(
        'flutter-watchos create --platforms=watchos does not take --sample. '
        'Create the app with stock `flutter create --sample`, then run '
        '`flutter-watchos create --platforms=watchos .` in it.',
      );
    }
  }

  /// Applies the host mode the project's shape implies — companion when
  /// `create` scaffolded (or found) an iOS app, standalone otherwise — and
  /// tells the user which one they got and why. Nothing is recorded: like
  /// stock Flutter platforms, the ios/ directory itself is the source of
  /// truth, and build/run re-derive the mode the same way.
  Future<WatchosHostMode?> _adoptHostMode(String projectDirPath) async {
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
    return mode;
  }

  /// Writes the app stock `flutter create` writes, from the pinned SDK's own
  /// `app` template with no platform folders: `lib/main.dart`, the widget
  /// test, `pubspec.yaml`, `analysis_options.yaml`, `README.md` and the rest,
  /// exactly as stock writes them. Like stock, it honours `--empty`,
  /// `--description`, `--org` and `--overwrite`, and pins the SDK's own
  /// versions in `pubspec.lock`. The caller runs `pub get` once `watchos/` is
  /// written too.
  Future<void> _generateStockApp(String projectDirPath, String name) async {
    final bool empty = boolArg('empty');
    final Directory directory = globals.fs.directory(projectDirPath);
    final Map<String, Object?> templateContext = createTemplateContext(
      organization: await getOrganization(),
      projectName: name,
      titleCaseProjectName: snakeCaseToTitleCase(name),
      projectDescription: stringArg('description'),
      flutterRoot: flutterRoot,
      withEmptyMain: empty,
      dartSdkVersionBounds: '^${globals.cache.dartSdkBuild}',
    );
    await generateApp(
      <String>['app', if (!empty) 'app_test_widget'],
      directory,
      templateContext,
      overwrite: boolArg('overwrite'),
      printStatusWhenWriting: false,
      projectType: FlutterTemplateType.app,
    );
    _writeSdkPubspecLock(directory);
  }

  /// Seeds `pubspec.lock` with the versions the Flutter SDK is tested with,
  /// as stock `flutter create` does (its `_generatePubspecLock` is private),
  /// so a broken release of one of those packages cannot break `create`.
  void _writeSdkPubspecLock(Directory directory) {
    final FileSystem fs = directory.fileSystem;
    final sdkLock =
        loadYaml(fs.file(fs.path.join(Cache.flutterRoot!, 'pubspec.lock')).readAsStringSync())
            as YamlMap;
    final sdkPackages = sdkLock['packages'] as YamlMap;
    final packages = <String, Object?>{
      for (final String package in gatherSdkPackageDependencies(directory))
        package: sdkPackages[package],
    };
    directory
        .childFile('pubspec.lock')
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert({'packages': packages}));
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
