// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';

import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/project.dart';
import 'package:flutter_watchos/watchos_plugins.dart'
    show
        WatchosPlugin,
        auditPluginsWithoutWatchosSupport,
        ensureReadyForWatchosTooling,
        recommendWatchosPluginsToInstall;

import '../src/common.dart';
import '../src/context.dart';

void main() {
  late MemoryFileSystem fileSystem;
  late FakeProcessManager processManager;

  setUp(() {
    fileSystem = MemoryFileSystem.test();
    processManager = FakeProcessManager.any();
  });

  group('WatchosPlugin', () {
    group('MethodChannel plugin', () {
      testWithoutContext('hasMethodChannel true when pluginClass set; not FFI/Dart', () {
        final plugin = WatchosPlugin(
          name: 'my_plugin',
          path: '/path/to/my_plugin',
          pluginClass: 'MyPlugin',
        );
        expect(plugin.hasMethodChannel(), isTrue);
        expect(plugin.hasFfi(), isFalse);
        expect(plugin.hasDart(), isFalse);
        expect(plugin.hasNativeBuild(), isTrue);
      });

      testWithoutContext('toMap includes class but not ffiPlugin', () {
        final plugin = WatchosPlugin(name: 'my_plugin', path: '/path', pluginClass: 'MyPlugin');
        final Map<String, dynamic> map = plugin.toMap();
        expect(map['name'], equals('my_plugin'));
        expect(map['class'], equals('MyPlugin'));
        expect(map.containsKey('ffiPlugin'), isFalse);
      });
    });

    group('FFI plugin', () {
      testWithoutContext('hasFfi true when ffiPlugin flag is true', () {
        final plugin = WatchosPlugin(
          name: 'native_crypto',
          path: '/path/to/native_crypto',
          ffiPlugin: true,
        );
        expect(plugin.hasFfi(), isTrue);
        expect(plugin.hasMethodChannel(), isFalse);
        expect(plugin.hasNativeBuild(), isTrue);
      });

      testWithoutContext('hasFfi false when ffiPlugin flag is null', () {
        final plugin = WatchosPlugin(name: 'my_plugin', path: '/path', pluginClass: 'MyPlugin');
        expect(plugin.hasFfi(), isFalse);
      });

      testWithoutContext('hasFfi false when ffiPlugin flag is false', () {
        final plugin = WatchosPlugin(
          name: 'my_plugin',
          path: '/path',
          pluginClass: 'MyPlugin',
          ffiPlugin: false,
        );
        expect(plugin.hasFfi(), isFalse);
      });

      testWithoutContext('toMap includes ffiPlugin key when true', () {
        final plugin = WatchosPlugin(name: 'native_crypto', path: '/path', ffiPlugin: true);
        final Map<String, dynamic> map = plugin.toMap();
        expect(map['name'], equals('native_crypto'));
        expect(map['ffiPlugin'], isTrue);
        expect(map.containsKey('class'), isFalse);
      });

      testWithoutContext('toMap omits ffiPlugin key when false', () {
        final plugin = WatchosPlugin(
          name: 'my_plugin',
          path: '/path',
          pluginClass: 'MyPlugin',
          ffiPlugin: false,
        );
        expect(plugin.toMap().containsKey('ffiPlugin'), isFalse);
      });
    });

    group('Dart-only plugin', () {
      testWithoutContext('hasDart true when dartPluginClass set; no native build', () {
        final plugin = WatchosPlugin(
          name: 'dart_plugin',
          path: '/path',
          dartPluginClass: 'DartPluginImpl',
        );
        expect(plugin.hasDart(), isTrue);
        expect(plugin.hasMethodChannel(), isFalse);
        expect(plugin.hasFfi(), isFalse);
        expect(plugin.hasNativeBuild(), isFalse);
      });
    });

    group('hybrid plugin', () {
      testWithoutContext('MethodChannel + FFI', () {
        final plugin = WatchosPlugin(
          name: 'hybrid_plugin',
          path: '/path',
          pluginClass: 'HybridPlugin',
          ffiPlugin: true,
        );
        expect(plugin.hasMethodChannel(), isTrue);
        expect(plugin.hasFfi(), isTrue);
        expect(plugin.hasNativeBuild(), isTrue);
      });

      testWithoutContext('MethodChannel + FFI + Dart', () {
        final plugin = WatchosPlugin(
          name: 'full_plugin',
          path: '/path',
          pluginClass: 'FullPlugin',
          dartPluginClass: 'FullDartPlugin',
          ffiPlugin: true,
        );
        expect(plugin.hasMethodChannel(), isTrue);
        expect(plugin.hasFfi(), isTrue);
        expect(plugin.hasDart(), isTrue);
        expect(plugin.hasNativeBuild(), isTrue);
      });
    });

    group('ffiSymbols', () {
      testWithoutContext('defaults to an empty list', () {
        final plugin = WatchosPlugin(name: 'm', path: '/p', pluginClass: 'MPlugin');
        expect(plugin.ffiSymbols, isEmpty);
      });

      testWithoutContext('carries declared symbols', () {
        final plugin = WatchosPlugin(
          name: 'native_gadget',
          path: '/p',
          ffiPlugin: true,
          ffiSymbols: <String>['a_sym', 'b_sym'],
        );
        expect(plugin.ffiSymbols, <String>['a_sym', 'b_sym']);
      });
    });
  });

  group('recommendWatchosPluginsToInstall', () {
    // The curated `_kKnownWatchosPlugins` map is currently empty (no
    // flutterwatch.dev-published plugins yet), so no input produces a
    // recommendation. These tests lock that contract; update them when the
    // curated list gains entries.
    testWithoutContext('returns no messages for an empty dep graph', () {
      expect(recommendWatchosPluginsToInstall(allPluginNames: const <String>[]), isEmpty);
    });

    testWithoutContext('stays silent for uncurated plugins', () {
      expect(
        recommendWatchosPluginsToInstall(
          allPluginNames: const <String>['some_plugin', 'url_launcher'],
        ),
        isEmpty,
      );
    });
  });

  group('auditPluginsWithoutWatchosSupport', () {
    testWithoutContext('lists a plugin with native platforms but no watchos', () {
      final List<String> lines = auditPluginsWithoutWatchosSupport(
        pluginPlatforms: <String, List<String>>{
          'sensors_plus': <String>['ios', 'android', 'web'],
        },
      );
      expect(lines, isNotEmpty);
      expect(lines.first, contains('no watchOS implementation'));
      expect(lines.join('\n'), contains('sensors_plus (android, ios, web)'));
      expect(lines.join('\n'), contains('FlutterWatchosPlatform.isWatch'));
    });

    testWithoutContext('skips plugins that declare watchos support', () {
      expect(
        auditPluginsWithoutWatchosSupport(
          pluginPlatforms: <String, List<String>>{
            'flutter_watchos': <String>['watchos'],
            'hybrid': <String>['ios', 'watchos'],
          },
        ),
        isEmpty,
      );
    });

    testWithoutContext('skips federated implementation packages', () {
      // Only the aggregator should be reported — not its per-platform halves,
      // which the user never chose directly.
      final List<String> lines = auditPluginsWithoutWatchosSupport(
        pluginPlatforms: <String, List<String>>{
          'path_provider': <String>['ios', 'android'],
          'path_provider_android': <String>['android'],
          'path_provider_foundation': <String>['ios', 'macos'],
          'path_provider_platform_interface': <String>[],
        },
      );
      final String joined = lines.join('\n');
      expect(joined, contains('- path_provider (android, ios)'));
      expect(joined, isNot(contains('path_provider_android')));
      expect(joined, isNot(contains('path_provider_foundation')));
      expect(joined, isNot(contains('platform_interface')));
    });

    testWithoutContext('a manually added <name>_watchos package silences the aggregator', () {
      expect(
        auditPluginsWithoutWatchosSupport(
          pluginPlatforms: <String, List<String>>{
            'gadget': <String>['ios'],
            'gadget_watchos': <String>['watchos'],
          },
        ),
        isEmpty,
      );
    });

    testWithoutContext('labels legacy plugins with no platforms map', () {
      final List<String> lines = auditPluginsWithoutWatchosSupport(
        pluginPlatforms: <String, List<String>>{'ancient_plugin': <String>[]},
      );
      expect(lines.join('\n'), contains('ancient_plugin (legacy ios/android)'));
    });

    testWithoutContext('returns nothing when every plugin is covered', () {
      expect(
        auditPluginsWithoutWatchosSupport(pluginPlatforms: const <String, List<String>>{}),
        isEmpty,
      );
    });

    testWithoutContext('does not flag integration_test (works via the harness)', () {
      expect(
        auditPluginsWithoutWatchosSupport(
          pluginPlatforms: <String, List<String>>{
            'integration_test': <String>['android', 'ios'],
          },
        ),
        isEmpty,
      );
    });

    testWithoutContext('scopes warnings to direct dependencies', () {
      // `jni`/`jni_flutter` reach the graph only transitively (via
      // path_provider_android); the developer never added them, so they are
      // not flagged when a direct-dependency set is supplied.
      final List<String> lines = auditPluginsWithoutWatchosSupport(
        pluginPlatforms: <String, List<String>>{
          'gadget': <String>['ios', 'android'],
          'jni': <String>['android', 'linux', 'windows'],
          'jni_flutter': <String>['android'],
        },
        directDependencies: <String>{'gadget'},
      );
      final String joined = lines.join('\n');
      expect(joined, contains('- gadget (android, ios)'));
      expect(joined, isNot(contains('jni')));
    });

    testWithoutContext('audits every plugin when no direct-dependency set is given', () {
      final List<String> lines = auditPluginsWithoutWatchosSupport(
        pluginPlatforms: <String, List<String>>{
          'jni': <String>['android', 'linux', 'windows'],
        },
      );
      expect(lines.join('\n'), contains('- jni (android, linux, windows)'));
    });
  });

  group('ObjC GeneratedPluginRegistrant is not emitted', () {
    // watchOS plugins are FFI-only, and the build links their static archive
    // with `-force_load` (see build_targets/application.dart), which keeps
    // every member — so the exported symbols survive without a per-symbol
    // forced-reference registrant. The old Runner/GeneratedPluginRegistrant
    // .{h,m} was never in the Xcode Sources phase and had no caller, so it is
    // no longer written.
    testUsingContext(
      'no Runner/GeneratedPluginRegistrant.{h,m} is written for an FFI plugin',
      () async {
        final Directory projectDir = fileSystem.directory('/p')..createSync();
        projectDir.childDirectory('watchos').childDirectory('Runner').createSync(recursive: true);
        projectDir.childFile('pubspec.yaml').writeAsStringSync('name: app\n');

        final Directory pkgDir = fileSystem.directory('/pubcache/native_gadget')
          ..createSync(recursive: true);
        pkgDir.childFile('pubspec.yaml').writeAsStringSync('''
name: native_gadget
flutter:
  plugin:
    platforms:
      watchos:
        ffiPlugin: true
        ffiSymbols:
          - native_gadget_init
          - native_gadget_version
''');
        final Directory watchosDir = pkgDir.childDirectory('watchos')..createSync();
        watchosDir.childFile('Package.swift').writeAsStringSync(
          'let package = Package(name: "native_gadget")\n',
        );

        fileSystem.directory('/p/.dart_tool').childFile('package_config.json')
          ..createSync(recursive: true)
          ..writeAsStringSync(
            json.encode(<String, dynamic>{
              'packages': <Map<String, String>>[
                <String, String>{
                  'name': 'native_gadget',
                  'rootUri': 'file:///pubcache/native_gadget',
                },
              ],
            }),
          );
        projectDir.childFile('.flutter-plugins-dependencies').writeAsStringSync(
          json.encode(<String, dynamic>{
            'dependencyGraph': <Map<String, String>>[
              <String, String>{'name': 'native_gadget'},
            ],
          }),
        );

        final FlutterProject project = FlutterProject.fromDirectory(projectDir);
        await ensureReadyForWatchosTooling(project);

        final Directory runnerDir =
            project.directory.childDirectory('watchos').childDirectory('Runner');
        expect(runnerDir.childFile('GeneratedPluginRegistrant.m').existsSync(), isFalse);
        expect(runnerDir.childFile('GeneratedPluginRegistrant.h').existsSync(), isFalse);
      },
      overrides: <Type, Generator>{
        FileSystem: () => fileSystem,
        ProcessManager: () => processManager,
      },
    );
  });
}
