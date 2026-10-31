// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/template.dart';
import 'package:flutter_watchos/plugin_porting/example_porter.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// The asset copy renders nothing.
class _NoRenderer extends TemplateRenderer {
  const _NoRenderer();

  @override
  String renderString(String template, dynamic context, {bool htmlEscapeValues = false}) =>
      template;
}

void main() {
  group('ExamplePorter.extraHostedDeps', () {
    test('keeps hosted deps, drops the plugin/self/flutter and non-hosted deps', () {
      const pubspec = '''
name: network_info_plus_example
dependencies:
  flutter:
    sdk: flutter
  network_info_plus:
    path: ../
  network_info_plus_watchos:
    path: ../../network_info_plus_watchos
  permission_handler: ^12.0.0+1
  provider: ^6.0.0
  some_git_dep:
    git: https://example.com/x.git
dev_dependencies:
  flutter_test:
    sdk: flutter
''';

      final Map<String, String> extras = ExamplePorter.extraHostedDeps(
        pubspec,
        base: 'network_info_plus',
        output: 'network_info_plus_watchos',
      );

      // Hosted extras survive; the app-facing plugin, the *_watchos package,
      // flutter, and the git/path deps are all excluded.
      expect(extras, <String, String>{'permission_handler': '^12.0.0+1', 'provider': '^6.0.0'});
    });

    test('returns empty for blank or malformed pubspec', () {
      expect(ExamplePorter.extraHostedDeps('', base: 'a', output: 'a_watchos'), isEmpty);
      expect(
        ExamplePorter.extraHostedDeps(': : not yaml : :', base: 'a', output: 'a_watchos'),
        isEmpty,
      );
    });

    test('reads dev_dependencies when asked (integration-test-only deps)', () {
      const pubspec = '''
name: package_info_plus_example
dependencies:
  package_info_plus:
    path: ../
dev_dependencies:
  flutter_test:
    sdk: flutter
  integration_test:
    sdk: flutter
  device_info_plus: ^10.0.0
''';
      expect(
        ExamplePorter.extraHostedDeps(
          pubspec,
          section: 'dev_dependencies',
          base: 'package_info_plus',
          output: 'package_info_plus_watchos',
        ),
        <String, String>{'device_info_plus': '^10.0.0'},
      );
    });
  });

  group('ExamplePorter.buildPubspec', () {
    test('wires the plugin from pub and the *_watchos package by path', () {
      final String yaml = ExamplePorter.buildPubspec(
        exampleName: 'geolocator_example',
        base: 'geolocator',
        output: 'geolocator_watchos',
        extraHostedDeps: const <String, String>{
          'baseflow_plugin_template': '^2.0.0',
          // A range constraint with spaces/`<`/`>` must be quoted or the
          // generated pubspec is invalid YAML.
          'http': '>=0.13.5 <2.0.0',
        },
        includeIntegrationTest: true,
      );

      expect(yaml, contains('name: geolocator_example'));
      expect(yaml, contains('  geolocator: any'));
      expect(yaml, contains('  geolocator_watchos:\n    path: ../'));
      expect(yaml, contains('  baseflow_plugin_template: "^2.0.0"'));
      expect(yaml, contains('  http: ">=0.13.5 <2.0.0"'));
      expect(yaml, contains('  integration_test:\n    sdk: flutter'));
    });

    test('omits integration_test dev dep when the example has no tests', () {
      final String yaml = ExamplePorter.buildPubspec(
        exampleName: 'x_example',
        base: 'x',
        output: 'x_watchos',
        extraHostedDeps: const <String, String>{},
        includeIntegrationTest: false,
      );
      expect(yaml, isNot(contains('integration_test')));
    });

    test('pins the plugin at the version the example came with', () {
      final String yaml = ExamplePorter.buildPubspec(
        exampleName: 'geolocator_example',
        base: 'geolocator',
        baseVersion: '14.1.2',
        output: 'geolocator_watchos',
        extraHostedDeps: const <String, String>{},
        includeIntegrationTest: false,
      );
      expect(yaml, contains('  geolocator: ^14.1.2'));
      expect(yaml, isNot(contains(': any')));
    });

    test('declares the assets and fonts the upstream example declares', () {
      final String yaml = ExamplePorter.buildPubspec(
        exampleName: 'x_example',
        base: 'x',
        output: 'x_watchos',
        extraHostedDeps: const <String, String>{},
        includeIntegrationTest: false,
        assets: const <String>['assets/logo.png', 'assets/images/'],
        fonts: const <ExampleFont>[
          ExampleFont(
            family: 'Display',
            files: <ExampleFontFile>[
              ExampleFontFile(asset: 'fonts/Display-Regular.ttf'),
              ExampleFontFile(asset: 'fonts/Display-Bold.ttf', weight: 700, style: 'italic'),
            ],
          ),
        ],
      );
      final flutter = (loadYaml(yaml) as YamlMap)['flutter'] as YamlMap;
      expect(flutter['uses-material-design'], isTrue);
      expect(flutter['assets'], <String>['assets/logo.png', 'assets/images/']);
      final font = (flutter['fonts'] as YamlList).single as YamlMap;
      expect(font['family'], 'Display');
      expect((font['fonts'] as YamlList).length, 2);
      final bold = (font['fonts'] as YamlList)[1] as YamlMap;
      expect(bold['asset'], 'fonts/Display-Bold.ttf');
      expect(bold['weight'], 700);
      expect(bold['style'], 'italic');
    });
  });

  group('ExamplePorter reads the upstream pubspec', () {
    test('packageVersion reads version, or null', () {
      expect(ExamplePorter.packageVersion('name: x\nversion: 5.3.0\n'), '5.3.0');
      expect(ExamplePorter.packageVersion('name: x\n'), isNull);
      expect(ExamplePorter.packageVersion('name: [\n'), isNull);
    });

    test('flutterAssets takes plain entries and the path of map entries', () {
      expect(
        ExamplePorter.flutterAssets('''
flutter:
  uses-material-design: true
  assets:
    - assets/logo.png
    - path: assets/flavored/
      flavors: [free]
'''),
        <String>['assets/logo.png', 'assets/flavored/'],
      );
      expect(ExamplePorter.flutterAssets('flutter:\n  uses-material-design: true\n'), isEmpty);
    });

    test('flutterFonts reads each family and its files', () {
      final List<ExampleFont> fonts = ExamplePorter.flutterFonts('''
flutter:
  fonts:
    - family: Display
      fonts:
        - asset: fonts/Display-Regular.ttf
        - asset: fonts/Display-Bold.ttf
          weight: 700
''');
      expect(fonts.single.family, 'Display');
      expect(fonts.single.files.map((ExampleFontFile f) => f.asset), <String>[
        'fonts/Display-Regular.ttf',
        'fonts/Display-Bold.ttf',
      ]);
      expect(fonts.single.files.last.weight, 700);
    });
  });

  group('ExamplePorter.copyDeclaredAssets', () {
    late FileSystem fs;
    late ExamplePorter porter;

    setUp(() {
      fs = MemoryFileSystem.test();
      porter = ExamplePorter(
        fileSystem: fs,
        logger: BufferLogger.test(),
        templateRenderer: const _NoRenderer(),
      );
    });

    test('copies files, the files of a directory entry, and font files', () {
      final Directory source = fs.directory('/upstream/example')..createSync(recursive: true);
      source.childDirectory('assets').childFile('logo.png')
        ..createSync(recursive: true)
        ..writeAsStringSync('png');
      source.childDirectory('assets').childDirectory('images').childFile('a.png')
        ..createSync(recursive: true)
        ..writeAsStringSync('a');
      // Flutter bundles a directory entry's files, not its subdirectories.
      source
          .childDirectory('assets')
          .childDirectory('images')
          .childDirectory('deep')
          .childFile('b.png')
        ..createSync(recursive: true)
        ..writeAsStringSync('b');
      source.childDirectory('fonts').childFile('Display-Regular.ttf')
        ..createSync(recursive: true)
        ..writeAsStringSync('ttf');
      final Directory dest = fs.directory('/out/example');

      final AssetCopy copy = porter.copyDeclaredAssets(
        exampleSource: source,
        exampleDir: dest,
        assets: const <String>['assets/logo.png', 'assets/images/'],
        fonts: const <ExampleFont>[
          ExampleFont(
            family: 'Display',
            files: <ExampleFontFile>[ExampleFontFile(asset: 'fonts/Display-Regular.ttf')],
          ),
        ],
      );

      expect(copy.missing, isEmpty);
      expect(dest.childFile('assets/logo.png').readAsStringSync(), 'png');
      expect(dest.childFile('assets/images/a.png').readAsStringSync(), 'a');
      expect(dest.childFile('assets/images/deep/b.png').existsSync(), isFalse);
      expect(dest.childFile('fonts/Display-Regular.ttf').readAsStringSync(), 'ttf');
      expect(copy.written.length, 3);
    });

    test('reports declared paths the example does not have', () {
      final Directory source = fs.directory('/upstream/example')..createSync(recursive: true);
      final AssetCopy copy = porter.copyDeclaredAssets(
        exampleSource: source,
        exampleDir: fs.directory('/out/example'),
        assets: const <String>['assets/gone.png', 'assets/none/'],
        fonts: const <ExampleFont>[],
      );
      expect(copy.written, isEmpty);
      expect(copy.missing, <String>['assets/gone.png', 'assets/none/']);
    });
  });
}
