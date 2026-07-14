// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/template.dart';
import 'package:yaml/yaml.dart';

import '../commands/watchos_app_scaffold.dart';
import '../commands/watchos_runner.dart';
import 'source_analyzer.dart' show PluginSource;

/// Ports an upstream plugin's `example/` app to watchOS so the generated
/// `*_watchos` package ships a runnable demo **and** the plugin's official
/// `integration_test/` — verifiable on the watch simulator with
/// `flutter-watchos drive`.
///
/// The upstream example's `lib/` and `integration_test/` are copied verbatim
/// (they call the app-facing plugin, which federates to the `*_watchos`
/// implementation), a watchOS Xcode runner is rendered on top, and the pubspec
/// is rewritten to depend on the app-facing plugin from pub plus the local
/// `*_watchos` package.
class ExamplePorter {
  ExamplePorter({
    required FileSystem fileSystem,
    required Logger logger,
    required TemplateRenderer templateRenderer,
    this.organization = 'com.example',
  })  : _fs = fileSystem,
        _logger = logger,
        _templateRenderer = templateRenderer;

  final FileSystem _fs;
  final Logger _logger;
  final TemplateRenderer _templateRenderer;

  /// Reverse-DNS org seed for the watchOS bundle id (examples are never signed).
  final String organization;

  /// Ports [exampleSource] (an upstream `example/` directory) into
  /// `<outputDirectory>/example`. Returns the paths written, relative to
  /// [outputDirectory]. No-op-safe: pass [overwrite] to replace an existing
  /// example.
  Future<List<String>> port({
    required PluginSource source,
    required Directory outputDirectory,
    required Directory exampleSource,
    bool overwrite = false,
  }) async {
    final Directory exampleDir = outputDirectory.childDirectory('example');
    if (exampleDir.existsSync()) {
      if (!overwrite) {
        throw ExamplePortError(
          'Example already exists at ${exampleDir.path}. Pass --force to '
          'replace it.',
        );
      }
      exampleDir.deleteSync(recursive: true);
    }

    final exampleName = '${source.basePackageName}_example';
    final written = <String>[];

    // 1. Copy the upstream demo UI verbatim.
    written.addAll(_copyTree(
        exampleSource.childDirectory('lib'), exampleDir.childDirectory('lib')));

    // 2. Copy the upstream official integration tests, if any, and add the
    //    flutter_driver entrypoint that `flutter-watchos drive` needs.
    final Directory upstreamItest =
        exampleSource.childDirectory('integration_test');
    final bool hasIntegrationTests = upstreamItest.existsSync() &&
        upstreamItest.listSync().whereType<File>().any(
            (File f) => f.path.endsWith('_test.dart'));
    if (hasIntegrationTests) {
      written.addAll(_copyTree(
          upstreamItest, exampleDir.childDirectory('integration_test')));
      final File driver = exampleDir
          .childDirectory('test_driver')
          .childFile('integration_test.dart');
      _write(driver, _driver, written, exampleDir);
    }

    // 3. Rewrite the pubspec to pull the app-facing plugin from pub and the
    //    local *_watchos package by path.
    _write(
      exampleDir.childFile('pubspec.yaml'),
      _pubspec(
        source: source,
        exampleName: exampleName,
        upstreamExamplePubspec: exampleSource.childFile('pubspec.yaml'),
        includeIntegrationTest: hasIntegrationTests,
      ),
      written,
      exampleDir,
    );

    // 4. Fill in the remaining shared app files (analysis_options, .gitignore,
    //    README) — the scaffold skips the pubspec/lib we already wrote.
    WatchosAppScaffold(_fs).write(exampleDir.path, exampleName);
    // The scaffold's placeholder widget test references a class the upstream
    // main.dart does not define; the integration tests are the real tests.
    final File placeholderTest =
        exampleDir.childDirectory('test').childFile('widget_test.dart');
    if (placeholderTest.existsSync()) {
      placeholderTest.deleteSync();
    }

    // 5. Render the watchOS Xcode runner on top.
    await renderWatchosRunner(
      fileSystem: _fs,
      logger: _logger,
      templateRenderer: _templateRenderer,
      projectDirPath: exampleDir.path,
      name: exampleName,
      organization: organization,
    );

    return written;
  }

  /// Recursively copies [from] into [to], returning the destination paths.
  List<String> _copyTree(Directory from, Directory to) {
    final written = <String>[];
    if (!from.existsSync()) {
      return written;
    }
    for (final FileSystemEntity entity
        in from.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) {
        continue;
      }
      final String rel = _fs.path.relative(entity.path, from: from.path);
      final File dest = to.childFile(rel);
      dest.parent.createSync(recursive: true);
      entity.copySync(dest.path);
      written.add(dest.path);
    }
    return written;
  }

  void _write(File file, String contents, List<String> written, Directory base) {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
    written.add(file.path);
  }

  static const String _driver = '''
// Generated by `flutter-watchos plugin port --include-example`.
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver();
''';

  /// Builds the example pubspec: the app-facing plugin from pub, the local
  /// `*_watchos` package by path, plus any extra *hosted* dependencies the
  /// upstream example declared (path/git/sdk deps are dropped — they point at
  /// the upstream monorepo).
  String _pubspec({
    required PluginSource source,
    required String exampleName,
    required File upstreamExamplePubspec,
    required bool includeIntegrationTest,
  }) {
    final Map<String, String> extras = extraHostedDeps(
      upstreamExamplePubspec.existsSync()
          ? upstreamExamplePubspec.readAsStringSync()
          : '',
      base: source.basePackageName,
      output: source.outputPackageName,
    );
    return buildPubspec(
      exampleName: exampleName,
      base: source.basePackageName,
      output: source.outputPackageName,
      extraHostedDeps: extras,
      includeIntegrationTest: includeIntegrationTest,
    );
  }

  /// Extracts the simple hosted dependencies (name → version string) from an
  /// upstream example's [pubspecYaml], excluding the app-facing plugin, the
  /// generated `*_watchos` package, and `flutter` (all wired separately), and
  /// dropping every non-hosted (path/git/sdk) dependency.
  static Map<String, String> extraHostedDeps(
    String pubspecYaml, {
    required String base,
    required String output,
  }) {
    final extras = <String, String>{};
    if (pubspecYaml.trim().isEmpty) {
      return extras;
    }
    YamlMap? doc;
    try {
      doc = loadYaml(pubspecYaml) as YamlMap?;
    } on YamlException {
      return extras;
    }
    final Object? deps = doc?['dependencies'];
    if (deps is YamlMap) {
      for (final MapEntry<dynamic, dynamic> entry in deps.entries) {
        final name = '${entry.key}';
        if (entry.value is String &&
            name != base &&
            name != output &&
            name != 'flutter') {
          extras[name] = '${entry.value}';
        }
      }
    }
    return extras;
  }

  /// Renders the example `pubspec.yaml` text.
  static String buildPubspec({
    required String exampleName,
    required String base,
    required String output,
    required Map<String, String> extraHostedDeps,
    required bool includeIntegrationTest,
  }) {
    final buffer = StringBuffer()
      ..writeln('name: $exampleName')
      ..writeln('description: "watchOS example for $output."')
      ..writeln("publish_to: 'none'")
      ..writeln('version: 1.0.0+1')
      ..writeln()
      ..writeln('environment:')
      ..writeln('  sdk: ">=3.0.0 <4.0.0"')
      ..writeln()
      ..writeln('dependencies:')
      ..writeln('  flutter:')
      ..writeln('    sdk: flutter')
      ..writeln('  $base: any')
      ..writeln('  $output:')
      ..writeln('    path: ../');
    for (final MapEntry<String, String> entry in extraHostedDeps.entries) {
      buffer.writeln('  ${entry.key}: ${entry.value}');
    }
    buffer
      ..writeln()
      ..writeln('dev_dependencies:')
      ..writeln('  flutter_test:')
      ..writeln('    sdk: flutter');
    if (includeIntegrationTest) {
      buffer
        ..writeln('  integration_test:')
        ..writeln('    sdk: flutter');
    }
    buffer
      ..writeln('  flutter_lints: ^4.0.0')
      ..writeln()
      ..writeln('flutter:')
      ..writeln('  uses-material-design: true');
    return buffer.toString();
  }
}

/// Thrown when the example cannot be ported (e.g. it already exists).
class ExamplePortError implements Exception {
  ExamplePortError(this.message);
  final String message;
  @override
  String toString() => message;
}
