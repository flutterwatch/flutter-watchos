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
        recommendWatchosPluginsToInstall,
        warnMethodChannelOnlyWatchosPlugins;

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

  group('warnMethodChannelOnlyWatchosPlugins', () {
    testWithoutContext('warns for a pluginClass-only watchos plugin', () {
      final List<String> lines = warnMethodChannelOnlyWatchosPlugins(
        plugins: <WatchosPlugin>[
          WatchosPlugin(name: 'gadget_watchos', pluginClass: 'GadgetPlugin'),
        ],
      );
      expect(lines, isNotEmpty);
      expect(lines.first, contains('does not support'));
      expect(lines.join('\n'), contains('- gadget_watchos'));
      expect(lines.join('\n'), contains('MissingPluginException'));
      expect(lines.join('\n'), contains('ffiPlugin: true'));
    });

    testWithoutContext('stays silent for FFI and Dart-only plugins', () {
      expect(
        warnMethodChannelOnlyWatchosPlugins(
          plugins: <WatchosPlugin>[
            WatchosPlugin(name: 'ffi_plugin', ffiPlugin: true),
            WatchosPlugin(name: 'dart_only', dartPluginClass: 'DartOnly'),
            // Hybrid: the FFI half carries the native code, so the
            // pluginClass is not a dead end.
            WatchosPlugin(
              name: 'hybrid',
              pluginClass: 'HybridPlugin',
              ffiPlugin: true,
            ),
          ],
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
  });

  group('FFI forced references in GeneratedPluginRegistrant.m', () {
    // Seeds an app with a single FFI plugin `native_gadget` that declares
    // `ffiSymbols` and (optionally) ships a watchos/Package.swift, plus the
    // watchos/Runner/ directory the ObjC registrant is written into.
    FlutterProject seedFfiProject({
      required bool hasPackageSwift,
      List<String> ffiSymbols = const <String>[
        'native_gadget_init',
        'native_gadget_version',
      ],
    }) {
      final Directory projectDir = fileSystem.directory('/p')..createSync();
      projectDir.childDirectory('watchos').childDirectory('Runner').createSync(recursive: true);
      projectDir.childFile('pubspec.yaml').writeAsStringSync('name: app\n');

      final Directory pkgDir = fileSystem.directory('/pubcache/native_gadget')
        ..createSync(recursive: true);
      final String symbolsYaml = ffiSymbols.map((String s) => '          - $s').join('\n');
      pkgDir.childFile('pubspec.yaml').writeAsStringSync('''
name: native_gadget
flutter:
  plugin:
    platforms:
      watchos:
        ffiPlugin: true
        ffiSymbols:
$symbolsYaml
''');
      final Directory watchosDir = pkgDir.childDirectory('watchos')..createSync();
      watchosDir.childFile('native_gadget.podspec').writeAsStringSync('# podspec');
      if (hasPackageSwift) {
        watchosDir.childFile('Package.swift').writeAsStringSync(
          'let package = Package(name: "native_gadget")\n',
        );
      }

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
      return FlutterProject.fromDirectory(projectDir);
    }

    String registrantOf(FlutterProject project) => project.directory
        .childDirectory('watchos')
        .childDirectory('Runner')
        .childFile('GeneratedPluginRegistrant.m')
        .readAsStringSync();

    testUsingContext(
      'emits a forced reference per symbol for an SPM FFI plugin',
      () async {
        final FlutterProject project = seedFfiProject(hasPackageSwift: true);
        await ensureReadyForWatchosTooling(project);

        final String m = registrantOf(project);
        // File-scope forward declarations.
        expect(m, contains('extern void native_gadget_init(void);'));
        expect(m, contains('extern void native_gadget_version(void);'));
        // The anchor array + asm sink live INSIDE registerWithRegistry: so the
        // linker keeps them (a file-scope used-anchor gets dead-stripped).
        expect(m, contains('const void *_flutterWatchosFfiForcedReferences[]'));
        expect(m, contains('(const void *)&native_gadget_init,'));
        expect(m, contains('(const void *)&native_gadget_version,'));
        expect(
          m,
          contains('__asm__ volatile("" : : "r"(_flutterWatchosFfiForcedReferences[_i]));'),
        );
        // The array reference must sit within the method body, not at file scope.
        final int bodyStart = m.indexOf('+ (void)registerWithRegistry:');
        expect(bodyStart, greaterThanOrEqualTo(0));
        expect(
          m.indexOf('_flutterWatchosFfiForcedReferences[] ='),
          greaterThan(bodyStart),
          reason: 'anchor array must be emitted inside registerWithRegistry:',
        );
      },
      overrides: <Type, Generator>{
        FileSystem: () => fileSystem,
        ProcessManager: () => processManager,
      },
    );

    testUsingContext(
      'emits NO forced references for a CocoaPods-only FFI plugin',
      () async {
        // No watchos/Package.swift → resolved via CocoaPods as a dynamic
        // framework whose exports already survive; forcing a reference to a
        // symbol that isn't on the link line would be a hard link error.
        final FlutterProject project = seedFfiProject(hasPackageSwift: false);
        await ensureReadyForWatchosTooling(project);

        final String m = registrantOf(project);
        expect(m, isNot(contains('_flutterWatchosFfiForcedReferences')));
        expect(m, isNot(contains('native_gadget_init')));
      },
      overrides: <Type, Generator>{
        FileSystem: () => fileSystem,
        ProcessManager: () => processManager,
      },
    );

    testUsingContext(
      'drops symbols that are not valid C identifiers',
      () async {
        final FlutterProject project = seedFfiProject(
          hasPackageSwift: true,
          ffiSymbols: <String>['good_symbol', 'bad symbol', '0bad', 'also_good'],
        );
        await ensureReadyForWatchosTooling(project);

        final String m = registrantOf(project);
        expect(m, contains('(const void *)&good_symbol,'));
        expect(m, contains('(const void *)&also_good,'));
        // The invalid entries must never reach the generated C.
        expect(m, isNot(contains('bad symbol')));
        expect(m, isNot(contains('0bad')));
      },
      overrides: <Type, Generator>{
        FileSystem: () => fileSystem,
        ProcessManager: () => processManager,
      },
    );

    testUsingContext(
      'omits the forced-reference block entirely when there are no FFI plugins',
      () async {
        final Directory projectDir = fileSystem.directory('/p')..createSync();
        projectDir
            .childDirectory('watchos')
            .childDirectory('Runner')
            .createSync(recursive: true);
        projectDir.childFile('pubspec.yaml').writeAsStringSync('name: app\n');
        fileSystem.directory('/p/.dart_tool').childFile('package_config.json')
          ..createSync(recursive: true)
          ..writeAsStringSync(json.encode(<String, dynamic>{'packages': <dynamic>[]}));
        projectDir.childFile('.flutter-plugins-dependencies').writeAsStringSync(
          json.encode(<String, dynamic>{'dependencyGraph': <dynamic>[]}),
        );

        final FlutterProject project = FlutterProject.fromDirectory(projectDir);
        await ensureReadyForWatchosTooling(project);

        expect(registrantOf(project), isNot(contains('_flutterWatchosFfiForcedReferences')));
      },
      overrides: <Type, Generator>{
        FileSystem: () => fileSystem,
        ProcessManager: () => processManager,
      },
    );
  });
}
