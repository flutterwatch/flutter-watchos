// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/runner/flutter_command.dart';

import '../plugin_porting/compatibility_database.dart' show Severity;
import '../plugin_porting/example_porter.dart';
import '../plugin_porting/scaffolder.dart';
import '../plugin_porting/source_analyzer.dart';
import '../plugin_porting/source_fetcher.dart';
import '../plugin_porting/templates.dart' show kDefaultLicenseHolder;

/// `flutter-watchos plugin port <source>` — scaffolds a federated
/// `*_watchos` **FFI** package from an existing iOS or macOS plugin.
///
/// Method-channel plugins are not supported on watchOS, so a method-channel
/// plugin cannot run there. The porter emits an FFI scaffold instead: a C
/// stub under `watchos/Classes/`, an FFI `Package.swift`, an
/// `ffiPlugin: true` pubspec, and a Dart class over the platform interface.
/// It also analyses the source's native code so `PORTING_REPORT.md` can tell
/// the developer which iOS APIs the plugin used and their watchOS status.
class WatchosPluginPortCommand extends FlutterCommand {
  WatchosPluginPortCommand() {
    argParser
      ..addOption(
        'from-pub',
        help:
            'Port a package downloaded from pub.dev instead of a local '
            'directory, e.g. --from-pub url_launcher_ios. Mutually '
            'exclusive with a positional path and --from-git.',
      )
      ..addOption(
        'from-git',
        help:
            'Port a plugin from a git repository (cloned shallowly to a '
            'temp dir), e.g. --from-git https://github.com/foo/bar.git. '
            'Mutually exclusive with a positional path and --from-pub.',
      )
      ..addOption(
        'ref',
        help:
            'Git ref (branch/tag/sha) to check out. Only valid with '
            '--from-git.',
      )
      ..addOption(
        'output',
        abbr: 'o',
        help:
            'Where to write the generated `*_watchos` package. Defaults to a '
            'sibling of <source> named `<plugin>_watchos` (or the current '
            'directory for --from-pub / --from-git sources).',
      )
      ..addOption(
        'base-platform',
        defaultsTo: 'ios',
        allowed: <String>['ios', 'macos'],
        help:
            'Which existing platform implementation to model the port on. '
            "Default `ios`. Use `macos` when the source's macOS code is a "
            'closer fit for watchOS than its iOS code (rare — watchOS '
            'follows the iOS API shape).',
      )
      ..addOption(
        'license-holder',
        defaultsTo: kDefaultLicenseHolder,
        help:
            'Copyright holder line baked into generated source files. Set '
            'this to your name or organisation when porting plugins you will '
            'maintain yourself.',
      )
      ..addFlag(
        'force',
        negatable: false,
        help:
            'Overwrite the output directory if it already exists. Without '
            'this flag, the command refuses to clobber existing files.',
      )
      ..addFlag(
        'dry-run',
        negatable: false,
        help:
            'Report what would be written without touching the filesystem. '
            'Useful for previewing the layout on a plugin you are not yet '
            'sure you want to port.',
      )
      ..addFlag(
        'report',
        defaultsTo: true,
        help:
            'Write PORTING_REPORT.md alongside the package. Pass --no-report '
            'to skip it; the FFI scaffold is written either way.',
      )
      ..addFlag(
        'include-example',
        negatable: false,
        help:
            "Also port the app-facing plugin's example/ app to watchOS "
            '(its demo UI + official integration_test), so the package ships '
            'a runnable example you can verify with `flutter-watchos drive`. '
            'The example is fetched from pub when the ported source is a '
            'platform implementation (e.g. geolocator_apple).',
      );
  }

  @override
  final String name = 'port';

  @override
  final String description =
      'Scaffold a federated `*_watchos` FFI package from an existing iOS or '
      'macOS plugin directory.';

  @override
  final String category = 'Tools';

  @override
  String get invocation => 'flutter-watchos plugin port <source-dir> [options]';

  @override
  Future<FlutterCommandResult> runCommand() async {
    final List<String> rest = argResults!.rest;
    final FileSystem fs = globals.fs;
    final Logger log = globals.logger;

    if (rest.length > 1) {
      throwToolExit(
        'Too many positional arguments. Expected at most one source '
        'directory; got ${rest.length} (${rest.join(', ')}).',
      );
    }

    final SourceSpec spec;
    try {
      spec = SourceSpec.parse(
        positional: rest.isEmpty ? null : rest.single,
        fromPub: stringArg('from-pub'),
        fromGit: stringArg('from-git'),
        ref: stringArg('ref'),
      );
    } on SourceFetchError catch (e) {
      throwToolExit(e.message);
    }

    // For --from-pub / --from-git the source is materialised under a temp
    // dir we must clean up no matter how the command exits.
    Directory? tempWork;
    final Directory sourceDir;
    if (spec.mode == FetchMode.localPath) {
      sourceDir = fs.directory(fs.path.absolute(spec.identifier));
      if (!sourceDir.existsSync()) {
        throwToolExit('Source directory does not exist: ${sourceDir.path}');
      }
    } else {
      tempWork = fs.systemTempDirectory.createTempSync('flutter_watchos_port_');
      try {
        sourceDir = await SourceFetcher(
          fileSystem: fs,
          processManager: globals.processManager,
          logger: log,
        ).resolve(spec, workDir: tempWork);
      } on SourceFetchError catch (e) {
        _safeDelete(tempWork);
        throwToolExit(e.message);
      }
    }

    try {
      return await _portResolvedSource(fs, log, sourceDir,
          fetched: tempWork != null);
    } finally {
      _safeDelete(tempWork);
    }
  }

  void _safeDelete(Directory? dir) {
    if (dir != null && dir.existsSync()) {
      try {
        dir.deleteSync(recursive: true);
      } on FileSystemException {
        // Best-effort temp cleanup; never mask the real result.
      }
    }
  }

  Future<FlutterCommandResult> _portResolvedSource(
    FileSystem fs,
    Logger log,
    Directory sourceDir, {
    required bool fetched,
  }) async {
    // Inspect the source. Fatal misconfigurations throw; the analyzer prints
    // any warnings via the supplied sink so the user sees them before any
    // file write happens.
    final analyzer = SourceAnalyzer(
      fileSystem: fs,
      warningSink: (String msg) => log.printWarning('  • $msg'),
    );

    final PluginSource source;
    try {
      source = analyzer.analyze(sourceDir, preferPlatform: stringArg('base-platform')!);
    } on PluginSourceError catch (e) {
      if (e.advisory) {
        // Not a failure — the plugin simply needs no `*_watchos` package.
        log.printStatus(e.message);
        return FlutterCommandResult.success();
      }
      throwToolExit(e.message);
    }

    // Resolve the output directory. Default = sibling of source named after
    // the output package, EXCEPT for fetched sources whose sibling is a temp
    // dir we delete — those default to the current directory. Honours
    // `--output` (path can be relative).
    final String? outputArg = stringArg('output');
    final Directory outputDir = outputArg != null
        ? fs.directory(fs.path.absolute(outputArg))
        : fetched
            ? fs.currentDirectory.childDirectory(source.outputPackageName)
            : sourceDir.parent.childDirectory(source.outputPackageName);

    final bool dryRun = boolArg('dry-run');
    final bool force = boolArg('force');
    final bool emitReport = boolArg('report');

    log.printStatus('Source plugin:    ${source.packageName}');
    log.printStatus('Source platform:  ${source.sourcePlatform} (${source.sourceLanguage.name})');
    if (source.platformInterfacePackage != null) {
      log.printStatus('Platform iface:   ${source.platformInterfacePackage}');
    }
    log.printStatus('Output package:   ${source.outputPackageName} (FFI)');
    log.printStatus('Output directory: ${outputDir.path}');
    if (dryRun) {
      log.printStatus('  (dry run — no files will be written)');
    }
    log.printStatus('');

    final scaffolder = Scaffolder(
      fileSystem: fs,
      logger: log,
      licenseHolder: stringArg('license-holder')!,
    );
    final ScaffoldResult result;
    try {
      result = scaffolder.scaffold(
        source: source,
        outputDirectory: outputDir,
        overwrite: force,
        dryRun: dryRun,
        emitReport: emitReport,
      );
    } on ScaffoldError catch (e) {
      throwToolExit(e.message);
    }

    // Findings are compatibility-database hits in the source's native code —
    // guidance for what to (re)implement, split by whether watchOS supports
    // the API at all.
    final unsupportedApis = <String>{
      for (final f in result.findings)
        if (f.pattern.severity == Severity.unsupported) f.pattern.name,
    };
    final reviewApis = <String>{
      for (final f in result.findings)
        if (f.pattern.severity != Severity.unsupported) f.pattern.name,
    };

    final verb = dryRun ? 'Would write' : 'Wrote';
    log.printStatus('$verb ${result.writtenPaths.length} files'
        '${dryRun ? '' : ' into ${outputDir.path}'}:');
    for (final String path in result.writtenPaths) {
      log.printStatus('  ${dryRun ? path : fs.path.relative(path, from: outputDir.path)}');
    }
    log.printStatus('');
    log.printStatus(
      'This is an FFI scaffold — method-channel plugins are not supported '
      'on watchOS, so native plugin code is reached over dart:ffi. The '
      'exported functions are stubs; fill them in.',
    );
    if (unsupportedApis.isNotEmpty) {
      log.printWarning(
        'The source uses ${unsupportedApis.length} API(s) with no watchOS '
        'equivalent (${(unsupportedApis.toList()..sort()).join(', ')}). Those '
        'capabilities must be omitted or redesigned — see PORTING_REPORT.md.',
      );
    }
    if (reviewApis.isNotEmpty) {
      log.printStatus(
        'Review ${reviewApis.length} watchOS-available API(s) '
        '(${(reviewApis.toList()..sort()).join(', ')}) — behaviour may '
        'differ from iOS. Details in PORTING_REPORT.md.',
      );
    }
    log.printStatus('');
    log.printStatus('Next steps:');
    log.printStatus('  1. Implement the C functions in '
        'watchos/Classes/${source.outputPackageName}_ffi.{h,m} and list every '
        'exported symbol under `ffiSymbols` in pubspec.yaml.');
    log.printStatus('  2. Add a binding + interface override per symbol in '
        'lib/${source.outputPackageName}.dart.');
    log.printStatus('  3. Build an example for `watchsimulator` and `nm` the '
        'binary to confirm your symbols linked.');
    if (result.reportPath != null && !dryRun) {
      log.printStatus('');
      log.printStatus('Read ${outputDir.basename}/PORTING_REPORT.md first.');
    }

    if (boolArg('include-example') && !dryRun) {
      await _portExample(fs, log, source, outputDir, sourceDir);
    }

    return FlutterCommandResult.success();
  }

  /// Ports the app-facing plugin's `example/` app (demo + official
  /// integration_test) to watchOS. Uses the ported source's own example when
  /// the source IS the app-facing package; otherwise fetches the app-facing
  /// package from pub for it.
  Future<void> _portExample(
    FileSystem fs,
    Logger log,
    PluginSource source,
    Directory outputDir,
    Directory sourceDir,
  ) async {
    Directory? exampleSource;
    Directory? tempExample;

    final Directory ownExample = sourceDir.childDirectory('example');
    if (source.packageName == source.basePackageName &&
        ownExample.childDirectory('lib').existsSync()) {
      exampleSource = ownExample;
    } else {
      tempExample =
          fs.systemTempDirectory.createTempSync('flutter_watchos_example_');
      try {
        final Directory baseDir = await SourceFetcher(
          fileSystem: fs,
          processManager: globals.processManager,
          logger: log,
        ).resolve(SourceSpec.parse(fromPub: source.basePackageName),
            workDir: tempExample);
        final Directory ex = baseDir.childDirectory('example');
        if (ex.childDirectory('lib').existsSync()) {
          exampleSource = ex;
        }
      } on SourceFetchError catch (e) {
        log.printWarning('  • Could not fetch ${source.basePackageName} for '
            'its example: ${e.message}');
      }
    }

    if (exampleSource == null) {
      log.printWarning('No example/ found for ${source.basePackageName}; '
          'skipping --include-example.');
      _safeDelete(tempExample);
      return;
    }

    try {
      final List<String> written = await ExamplePorter(
        fileSystem: fs,
        logger: log,
        templateRenderer: globals.templateRenderer,
      ).port(
        source: source,
        outputDirectory: outputDir,
        exampleSource: exampleSource,
        overwrite: boolArg('force'),
      );
      log.printStatus('');
      log.printStatus('Ported example (${written.length} files) into '
          '${outputDir.basename}/example. Verify it on a watch simulator:');
      log.printStatus('  cd ${outputDir.basename}/example');
      log.printStatus('  flutter-watchos drive '
          '--driver=test_driver/integration_test.dart '
          '--target=integration_test/<name>_test.dart -d <watch-sim>');
    } on ExamplePortError catch (e) {
      throwToolExit(e.message);
    } finally {
      _safeDelete(tempExample);
    }
  }
}
