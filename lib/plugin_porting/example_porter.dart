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
  }) : _fs = fileSystem,
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
    written.addAll(
      _copyTree(exampleSource.childDirectory('lib'), exampleDir.childDirectory('lib')),
    );

    // 2. Copy the upstream official integration tests, if any, and add the
    //    flutter_driver entrypoint that `flutter-watchos drive` needs.
    final Directory upstreamItest = exampleSource.childDirectory('integration_test');
    final bool hasIntegrationTests =
        upstreamItest.existsSync() &&
        upstreamItest.listSync().whereType<File>().any((File f) => f.path.endsWith('_test.dart'));
    if (hasIntegrationTests) {
      written.addAll(_copyTree(upstreamItest, exampleDir.childDirectory('integration_test')));
      final File driver = exampleDir
          .childDirectory('test_driver')
          .childFile('integration_test.dart');
      _write(driver, _driver, written, exampleDir);
    }

    // 3. Copy the assets and fonts the upstream example's pubspec declares:
    //    its code loads them, and `lib/` alone does not carry them.
    final File upstreamPubspec = exampleSource.childFile('pubspec.yaml');
    final String upstreamYaml = upstreamPubspec.existsSync()
        ? upstreamPubspec.readAsStringSync()
        : '';
    final List<String> assets = flutterAssets(upstreamYaml);
    final List<ExampleFont> fonts = flutterFonts(upstreamYaml);
    final AssetCopy assetCopy = copyDeclaredAssets(
      exampleSource: exampleSource,
      exampleDir: exampleDir,
      assets: assets,
      fonts: fonts,
    );
    written.addAll(assetCopy.written);
    for (final String missing in assetCopy.missing) {
      _logger.printWarning('  • The upstream example declares $missing, which is not in it.');
    }

    // 4. Rewrite the pubspec to pull the app-facing plugin from pub, at the
    //    version the example came with, and the local *_watchos package by
    //    path.
    final File basePubspec = exampleSource.parent.childFile('pubspec.yaml');
    final String? baseVersion = basePubspec.existsSync()
        ? packageVersion(basePubspec.readAsStringSync())
        : null;
    if (baseVersion == null) {
      _logger.printWarning(
        '  • Could not read the version of ${source.basePackageName}; the '
        "example's pubspec names `${source.basePackageName}: any`. Pin it "
        'before you publish.',
      );
    }
    _write(
      exampleDir.childFile('pubspec.yaml'),
      _pubspec(
        source: source,
        exampleName: exampleName,
        upstreamExamplePubspec: upstreamPubspec,
        baseVersion: baseVersion,
        assets: assets,
        fonts: fonts,
        includeIntegrationTest: hasIntegrationTests,
      ),
      written,
      exampleDir,
    );

    // 5. Fill in the remaining shared app files (analysis_options, .gitignore,
    //    README) — the scaffold skips the pubspec/lib we already wrote.
    WatchosAppScaffold(_fs).write(exampleDir.path, exampleName);
    // The scaffold's placeholder widget test references a class the upstream
    // main.dart does not define; the integration tests are the real tests.
    final File placeholderTest = exampleDir.childDirectory('test').childFile('widget_test.dart');
    if (placeholderTest.existsSync()) {
      placeholderTest.deleteSync();
    }

    // 6. Render the watchOS Xcode runner on top.
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
    for (final FileSystemEntity entity in from.listSync(recursive: true, followLinks: false)) {
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

  /// Copies the [assets] and the [fonts]' files the upstream example
  /// declares, from [exampleSource] into [exampleDir]. An asset that ends
  /// with `/` is a directory: its files are copied, not its subdirectories,
  /// as Flutter bundles it. Declared paths that do not exist are returned in
  /// [AssetCopy.missing].
  AssetCopy copyDeclaredAssets({
    required Directory exampleSource,
    required Directory exampleDir,
    required List<String> assets,
    required List<ExampleFont> fonts,
  }) {
    final written = <String>[];
    final missing = <String>[];
    final paths = <String>[
      ...assets,
      for (final ExampleFont font in fonts)
        for (final ExampleFontFile file in font.files) file.asset,
    ];
    for (final path in paths) {
      if (path.endsWith('/')) {
        final Directory from = exampleSource.childDirectory(path);
        if (!from.existsSync()) {
          missing.add(path);
          continue;
        }
        for (final File file in from.listSync().whereType<File>()) {
          final File dest = exampleDir.childDirectory(path).childFile(_fs.path.basename(file.path));
          dest.parent.createSync(recursive: true);
          file.copySync(dest.path);
          written.add(dest.path);
        }
      } else {
        final File from = exampleSource.childFile(path);
        if (!from.existsSync()) {
          missing.add(path);
          continue;
        }
        final File dest = exampleDir.childFile(path);
        dest.parent.createSync(recursive: true);
        from.copySync(dest.path);
        written.add(dest.path);
      }
    }
    return AssetCopy(written: written, missing: missing);
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
    required String? baseVersion,
    required List<String> assets,
    required List<ExampleFont> fonts,
    required bool includeIntegrationTest,
  }) {
    final String yaml = upstreamExamplePubspec.existsSync()
        ? upstreamExamplePubspec.readAsStringSync()
        : '';
    return buildPubspec(
      exampleName: exampleName,
      base: source.basePackageName,
      baseVersion: baseVersion,
      output: source.outputPackageName,
      extraHostedDeps: extraHostedDeps(
        yaml,
        base: source.basePackageName,
        output: source.outputPackageName,
      ),
      extraHostedDevDeps: extraHostedDeps(
        yaml,
        section: 'dev_dependencies',
        base: source.basePackageName,
        output: source.outputPackageName,
      ),
      includeIntegrationTest: includeIntegrationTest,
      assets: assets,
      fonts: fonts,
    );
  }

  /// The `version` of the package whose [pubspecYaml] it is, or null.
  static String? packageVersion(String pubspecYaml) {
    final Object? version = _loadMap(pubspecYaml)?['version'];
    return version is String && version.isNotEmpty ? version : null;
  }

  /// The paths under `flutter: assets:` in an upstream example's
  /// [pubspecYaml]: plain strings, and the `path` of map entries.
  static List<String> flutterAssets(String pubspecYaml) {
    final Object? flutter = _loadMap(pubspecYaml)?['flutter'];
    final Object? assets = flutter is YamlMap ? flutter['assets'] : null;
    return <String>[
      if (assets is YamlList)
        for (final Object? entry in assets)
          if (entry is String)
            entry
          else if (entry is YamlMap && entry['path'] is String)
            entry['path'] as String,
    ];
  }

  /// The fonts under `flutter: fonts:` in an upstream example's
  /// [pubspecYaml].
  static List<ExampleFont> flutterFonts(String pubspecYaml) {
    final Object? flutter = _loadMap(pubspecYaml)?['flutter'];
    final Object? fonts = flutter is YamlMap ? flutter['fonts'] : null;
    return <ExampleFont>[
      if (fonts is YamlList)
        for (final Object? font in fonts)
          if (font is YamlMap && font['family'] is String && font['fonts'] is YamlList)
            ExampleFont(
              family: font['family'] as String,
              files: <ExampleFontFile>[
                for (final Object? file in font['fonts'] as YamlList)
                  if (file is YamlMap && file['asset'] is String)
                    ExampleFontFile(
                      asset: file['asset'] as String,
                      weight: file['weight'] is int ? file['weight'] as int : null,
                      style: file['style'] is String ? file['style'] as String : null,
                    ),
              ],
            ),
    ];
  }

  static YamlMap? _loadMap(String yaml) {
    if (yaml.trim().isEmpty) {
      return null;
    }
    try {
      final Object? doc = loadYaml(yaml);
      return doc is YamlMap ? doc : null;
    } on YamlException {
      return null;
    }
  }

  /// Extracts the simple hosted dependencies (name → version string) from
  /// [section] of an upstream example's [pubspecYaml], excluding the app-facing
  /// plugin, the generated `*_watchos` package, the SDK packages we wire
  /// ourselves, and dropping every non-hosted (path/git/sdk) dependency.
  static Map<String, String> extraHostedDeps(
    String pubspecYaml, {
    String section = 'dependencies',
    required String base,
    required String output,
  }) {
    const wiredSdkPackages = <String>{
      'flutter',
      'flutter_test',
      'integration_test',
      'flutter_lints',
      'flutter_driver',
    };
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
    final Object? deps = doc?[section];
    if (deps is YamlMap) {
      for (final MapEntry<dynamic, dynamic> entry in deps.entries) {
        final name = '${entry.key}';
        if (entry.value is String &&
            name != base &&
            name != output &&
            !wiredSdkPackages.contains(name)) {
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
    String? baseVersion,
    required String output,
    required Map<String, String> extraHostedDeps,
    required bool includeIntegrationTest,
    Map<String, String> extraHostedDevDeps = const <String, String>{},
    List<String> assets = const <String>[],
    List<ExampleFont> fonts = const <ExampleFont>[],
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
      ..writeln('  $base: ${baseVersion == null ? 'any' : '^$baseVersion'}')
      ..writeln('  $output:')
      ..writeln('    path: ../');
    for (final MapEntry<String, String> entry in extraHostedDeps.entries) {
      // Quote the constraint: range constraints contain spaces and `<`/`>`,
      // which are invalid as a bare YAML scalar (e.g. `>=0.13.5 <2.0.0`).
      buffer.writeln('  ${entry.key}: "${entry.value}"');
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
    buffer.writeln('  flutter_lints: ^4.0.0');
    // Hosted dev-dependencies the upstream example declared (its integration
    // tests may import them, e.g. package_info_plus's test uses device_info_plus).
    for (final MapEntry<String, String> entry in extraHostedDevDeps.entries) {
      buffer.writeln('  ${entry.key}: "${entry.value}"');
    }
    buffer
      ..writeln()
      ..writeln('flutter:')
      ..writeln('  uses-material-design: true');
    if (assets.isNotEmpty) {
      buffer.writeln('  assets:');
      for (final asset in assets) {
        buffer.writeln('    - "$asset"');
      }
    }
    if (fonts.isNotEmpty) {
      buffer.writeln('  fonts:');
      for (final font in fonts) {
        buffer
          ..writeln('    - family: "${font.family}"')
          ..writeln('      fonts:');
        for (final ExampleFontFile file in font.files) {
          buffer.writeln('        - asset: "${file.asset}"');
          if (file.weight != null) {
            buffer.writeln('          weight: ${file.weight}');
          }
          if (file.style != null) {
            buffer.writeln('          style: ${file.style}');
          }
        }
      }
    }
    return buffer.toString();
  }
}

/// A font family an upstream example declares under `flutter: fonts:`.
class ExampleFont {
  const ExampleFont({required this.family, required this.files});

  /// The family name.
  final String family;

  /// Its files.
  final List<ExampleFontFile> files;
}

/// One file of an [ExampleFont].
class ExampleFontFile {
  const ExampleFontFile({required this.asset, this.weight, this.style});

  /// The file's path in the example.
  final String asset;

  /// Its weight (100 to 900), if declared.
  final int? weight;

  /// Its style (`italic`), if declared.
  final String? style;
}

/// What [ExamplePorter.copyDeclaredAssets] copied, and what it did not find.
class AssetCopy {
  const AssetCopy({required this.written, required this.missing});

  /// The paths written.
  final List<String> written;

  /// The declared paths that do not exist in the upstream example.
  final List<String> missing;
}

/// Thrown when the example cannot be ported (e.g. it already exists).
class ExamplePortError implements Exception {
  ExamplePortError(this.message);
  final String message;
  @override
  String toString() => message;
}
