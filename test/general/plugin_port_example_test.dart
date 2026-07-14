// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_watchos/plugin_porting/example_porter.dart';
import 'package:test/test.dart';

void main() {
  group('ExamplePorter.extraHostedDeps', () {
    test('keeps hosted deps, drops the plugin/self/flutter and non-hosted deps',
        () {
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
      expect(extras, <String, String>{
        'permission_handler': '^12.0.0+1',
        'provider': '^6.0.0',
      });
    });

    test('returns empty for blank or malformed pubspec', () {
      expect(ExamplePorter.extraHostedDeps('', base: 'a', output: 'a_watchos'),
          isEmpty);
      expect(
        ExamplePorter.extraHostedDeps(': : not yaml : :',
            base: 'a', output: 'a_watchos'),
        isEmpty,
      );
    });
  });

  group('ExamplePorter.buildPubspec', () {
    test('wires the plugin from pub and the *_watchos package by path', () {
      final String yaml = ExamplePorter.buildPubspec(
        exampleName: 'geolocator_example',
        base: 'geolocator',
        output: 'geolocator_watchos',
        extraHostedDeps: const <String, String>{'baseflow_plugin_template': '^2.0.0'},
        includeIntegrationTest: true,
      );

      expect(yaml, contains('name: geolocator_example'));
      expect(yaml, contains('  geolocator: any'));
      expect(yaml, contains('  geolocator_watchos:\n    path: ../'));
      expect(yaml, contains('  baseflow_plugin_template: ^2.0.0'));
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
  });
}
