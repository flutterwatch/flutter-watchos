// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:io' as io;

import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/project.dart';
import 'package:flutter_watchos/build_targets/application.dart'
    show WatchosBuildTargets, WatchosDartPluginRegistrantTarget;
import 'package:flutter_watchos/watchos_plugins.dart'
    show
        WatchosPlugin,
        auditPluginsWithoutWatchosSupport,
        copyWatchosCrownRuntime,
        ensureReadyForWatchosTooling,
        knownWatchosPluginNames,
        recommendWatchosPluginsToInstall,
        watchosDartPluginRegistrantSource;

import '../src/common.dart';
import '../src/context.dart';
import '../src/host_sources.dart';

/// The table in the plugins repository's README.md ("List of plugins"), row
/// by row: each upstream plugin with a `<name>_watchos` package, and whether
/// the CLI recommends that package yet. Keep it in step with the README when
/// a row is added or its package's state changes.
const Map<String, bool> _pluginsReadmeTable = <String, bool>{
  'path_provider': true,
  'shared_preferences': true,
  'package_info_plus': true,
  'device_info_plus': true,
  'url_launcher': true,
  'battery_plus': true,
  'connectivity_plus': true,
  'flutter_secure_storage': true,
  'network_info_plus': true,
  'sensors_plus': true,
  'local_auth': true,
  'geolocator': true,
  'video_player': true,
  'audioplayers': true,
  'in_app_purchase': true,
  // Not until its package moves to games_services' 5.x interface.
  'games_services': false,
  // Not until their versions are settled.
  'firebase_core': false,
  'firebase_auth': false,
  'firebase_storage': false,
  'firebase_messaging': false,
};

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

  // The CLI names the watchOS package a plugin needs, and how to add it.
  group('recommendWatchosPluginsToInstall', () {
    testWithoutContext('returns no messages for an empty dep graph', () {
      expect(recommendWatchosPluginsToInstall(allPluginNames: const <String>[]), isEmpty);
    });

    testWithoutContext('stays silent for plugins with no listed watchOS package', () {
      expect(
        recommendWatchosPluginsToInstall(
          allPluginNames: const <String>['some_plugin', 'games_services', 'firebase_core'],
        ),
        isEmpty,
      );
    });

    testWithoutContext('names the watchOS package and the command that adds it', () {
      final List<String> messages = recommendWatchosPluginsToInstall(
        allPluginNames: const <String>['shared_preferences', 'some_plugin'],
      );
      expect(messages, hasLength(1));
      expect(messages.single, contains('shared_preferences_watchos'));
      expect(messages.single, contains('\n  flutter-watchos pub add shared_preferences_watchos'));
      expect(messages.single, isNot(contains('#')));
    });

    testWithoutContext('stays silent once the watchOS package is in the graph', () {
      expect(
        recommendWatchosPluginsToInstall(
          allPluginNames: const <String>['shared_preferences', 'shared_preferences_watchos'],
        ),
        isEmpty,
      );
    });

    testWithoutContext('lists exactly the rows of the plugins README table it may list', () {
      expect(knownWatchosPluginNames, <String>{
        for (final MapEntry<String, bool> row in _pluginsReadmeTable.entries)
          if (row.value) row.key,
      });
      for (final String name in knownWatchosPluginNames) {
        expect(
          recommendWatchosPluginsToInstall(allPluginNames: <String>[name]).single,
          contains('flutter-watchos pub add ${name}_watchos'),
          reason: name,
        );
      }
    });
  });

  group('auditPluginsWithoutWatchosSupport', () {
    testWithoutContext('lists a plugin with native platforms but no watchos', () {
      final List<String> lines = auditPluginsWithoutWatchosSupport(
        pluginPlatforms: <String, List<String>>{
          'camera': <String>['ios', 'android', 'web'],
        },
      );
      expect(lines, isNotEmpty);
      expect(lines.first, contains('no watchOS implementation'));
      expect(lines.join('\n'), contains('camera (android, ios, web)'));
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
          'image_picker': <String>['ios', 'android'],
          'image_picker_android': <String>['android'],
          'image_picker_foundation': <String>['ios', 'macos'],
          'image_picker_platform_interface': <String>[],
        },
      );
      final String joined = lines.join('\n');
      expect(joined, contains('- image_picker (android, ios)'));
      expect(joined, isNot(contains('image_picker_android')));
      expect(joined, isNot(contains('image_picker_foundation')));
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

    testWithoutContext('leaves a plugin with a listed watchOS package to the recommendation', () {
      expect(
        auditPluginsWithoutWatchosSupport(
          pluginPlatforms: <String, List<String>>{
            'shared_preferences': <String>['android', 'ios'],
          },
        ),
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
  group('discovery without a dependencyGraph', () {
    // Stock `flutter pub get` writes a dependencyGraph only once it recognises
    // at least one plugin for a platform IT knows, and it does not know
    // watchOS. An app whose plugins are all watchOS-only, with no ios/ or
    // android/ directory to resolve against, gets `dependencyGraph: []` — the
    // shape that silently produced an app binary with none of the plugin's FFI
    // symbols in it, because no archive was built and nothing force-loaded.
    testUsingContext(
      'falls back to package_config.json and still finds the plugin',
      () async {
        final Directory projectDir = fileSystem.directory('/p')..createSync();
        projectDir.childDirectory('watchos').childDirectory('Runner').createSync(recursive: true);
        projectDir.childFile('pubspec.yaml').writeAsStringSync('name: app\n');

        final Directory pkgDir = fileSystem.directory('/pubcache/watch_only')
          ..createSync(recursive: true);
        pkgDir.childFile('pubspec.yaml').writeAsStringSync('''
name: watch_only
flutter:
  plugin:
    platforms:
      watchos:
        ffiPlugin: true
        ffiSymbols:
          - watch_only_init
''');
        pkgDir.childDirectory('watchos').createSync();

        fileSystem.directory('/p/.dart_tool').childFile('package_config.json')
          ..createSync(recursive: true)
          ..writeAsStringSync(
            json.encode(<String, dynamic>{
              'packages': <Map<String, String>>[
                <String, String>{
                  'name': 'watch_only',
                  'rootUri': 'file:///pubcache/watch_only',
                },
              ],
            }),
          );
        // The crown_breaker shape: pub found nothing it considered a plugin.
        projectDir.childFile('.flutter-plugins-dependencies').writeAsStringSync(
          json.encode(<String, dynamic>{
            'plugins': <String, dynamic>{'watchos': <dynamic>[]},
            'dependencyGraph': <dynamic>[],
          }),
        );

        final FlutterProject project = FlutterProject.fromDirectory(projectDir);
        await ensureReadyForWatchosTooling(project);

        final decoded = json.decode(
          projectDir.childFile('.flutter-plugins-dependencies').readAsStringSync(),
        ) as Map<String, dynamic>;
        final plugins = (decoded['plugins'] as Map<String, dynamic>)['watchos']! as List<dynamic>;
        expect(
          plugins.map((dynamic p) => (p as Map<String, dynamic>)['name']),
          contains('watch_only'),
        );
      },
      overrides: <Type, Generator>{
        FileSystem: () => fileSystem,
        ProcessManager: () => processManager,
      },
    );

    // The graph is preserved across builds, so it goes stale: a watchOS-only
    // plugin added after it was written is absent from it, and used to stay
    // unregistered (MissingPluginException at runtime) until the file was
    // deleted by hand.
    testUsingContext(
      'finds a plugin that a non-empty but stale graph is missing',
      () async {
        final Directory projectDir = fileSystem.directory('/p')..createSync();
        projectDir.childDirectory('watchos').childDirectory('Runner').createSync(recursive: true);
        projectDir.childFile('pubspec.yaml').writeAsStringSync('name: app\n');

        for (final name in <String>['old_watch', 'new_watch']) {
          final Directory pkgDir = fileSystem.directory('/pubcache/$name')
            ..createSync(recursive: true);
          pkgDir.childFile('pubspec.yaml').writeAsStringSync('''
name: $name
flutter:
  plugin:
    platforms:
      watchos:
        ffiPlugin: true
        ffiSymbols:
          - ${name}_init
''');
          pkgDir.childDirectory('watchos').createSync();
        }

        fileSystem.directory('/p/.dart_tool').childFile('package_config.json')
          ..createSync(recursive: true)
          ..writeAsStringSync(
            json.encode(<String, dynamic>{
              'packages': <Map<String, String>>[
                for (final name in <String>['old_watch', 'new_watch'])
                  <String, String>{'name': name, 'rootUri': 'file:///pubcache/$name'},
              ],
            }),
          );
        projectDir.childFile('.flutter-plugins-dependencies').writeAsStringSync(
          json.encode(<String, dynamic>{
            'plugins': <String, dynamic>{'watchos': <dynamic>[]},
            'dependencyGraph': <Map<String, String>>[
              <String, String>{'name': 'old_watch'},
            ],
          }),
        );

        final FlutterProject project = FlutterProject.fromDirectory(projectDir);
        await ensureReadyForWatchosTooling(project);

        final decoded = json.decode(
          projectDir.childFile('.flutter-plugins-dependencies').readAsStringSync(),
        ) as Map<String, dynamic>;
        final plugins = (decoded['plugins'] as Map<String, dynamic>)['watchos']! as List<dynamic>;
        expect(
          plugins.map((dynamic p) => (p as Map<String, dynamic>)['name']),
          containsAll(<String>['old_watch', 'new_watch']),
        );
      },
      overrides: <Type, Generator>{
        FileSystem: () => fileSystem,
        ProcessManager: () => processManager,
      },
    );
  });

  group('native crown runtime', () {
    testWithoutContext('the registrant installs it before any plugin', () {
      final String source = watchosDartPluginRegistrantSource(
        <WatchosPlugin>[
          WatchosPlugin(name: 'flutter_watchos', dartPluginClass: 'FlutterWatchos'),
        ],
        crownRuntime: true,
      );
      expect(
        source,
        contains("import 'watchos_crown_runtime.dart' as flutter_watchos_crown_runtime;"),
      );
      final int install = source.indexOf('flutter_watchos_crown_runtime.install();');
      final int plugin = source.indexOf('flutter_watchos.FlutterWatchos.registerWith();');
      expect(install, greaterThan(0));
      expect(plugin, greaterThan(install));
    });

    testWithoutContext('the registrant without a runtime registers plugins only', () {
      final String source = watchosDartPluginRegistrantSource(
        <WatchosPlugin>[],
        crownRuntime: false,
      );
      expect(source, isNot(contains('crown_runtime')));
      expect(source, contains('static void register() {'));
    });

    testWithoutContext('the runtime is copied next to the registrant, and refreshed', () {
      final Directory root = fileSystem.directory('/cli');
      final File runtime = root.childFile('runtime/lib/watchos_crown_runtime.dart')
        ..createSync(recursive: true)
        ..writeAsStringSync('void install() {}');
      final Directory build = fileSystem.directory('/app/.dart_tool/flutter_build')
        ..createSync(recursive: true);

      expect(copyWatchosCrownRuntime(root, build), isTrue);
      expect(
        build.childFile('watchos_crown_runtime.dart').readAsStringSync(),
        'void install() {}',
      );

      runtime.writeAsStringSync('void install() { /* v2 */ }');
      expect(copyWatchosCrownRuntime(root, build), isTrue);
      expect(
        build.childFile('watchos_crown_runtime.dart').readAsStringSync(),
        contains('v2'),
      );
    });

    testWithoutContext('an installation without the runtime removes a stale copy', () {
      final Directory build = fileSystem.directory('/app/.dart_tool/flutter_build')
        ..createSync(recursive: true);
      build.childFile('watchos_crown_runtime.dart').writeAsStringSync('old');
      expect(copyWatchosCrownRuntime(fileSystem.directory('/cli'), build), isFalse);
      expect(build.childFile('watchos_crown_runtime.dart').existsSync(), isFalse);
    });

    testWithoutContext('a run session regenerates the watchOS registrant on reload', () {
      // The stock target would rewrite (or delete) the registrant at every
      // hot reload or restart and drop the runtime and watchOS plugins.
      expect(
        const WatchosBuildTargets().dartPluginRegistrantTarget,
        isA<WatchosDartPluginRegistrantTarget>(),
      );
    });

    testWithoutContext('the shipped runtime is in place', () {
      final shipped = io.File(cliRootPath('runtime/lib/watchos_crown_runtime.dart'));
      final String text = shipped.readAsStringSync();
      expect(text, contains('void install()'));
      // Copied into apps whose own language version may be older.
      expect(text, contains('// @dart = 3.9'));
      // Imports nothing but the SDK and Flutter: an app has no other package
      // the runtime could rely on.
      for (final String line in text.split('\n').where((String l) => l.startsWith('import '))) {
        expect(line, anyOf(startsWith("import 'dart:"), startsWith("import 'package:flutter/")));
      }
    });
  });

  // `flutter-watchos test` in a plugin package writes nothing into it; its
  // watchos/ holds the plugin's own native sources.
  group('ensureReadyForWatchosTooling in a plugin package', () {
    List<String> filesUnder(Directory dir) => <String>[
      for (final FileSystemEntity entity in dir.listSync(recursive: true))
        if (entity is File) fileSystem.path.relative(entity.path, from: dir.path),
    ]..sort();

    Directory projectWith(String pubspec) {
      final Directory projectDir = fileSystem.directory('/gadget_watchos')..createSync();
      projectDir.childFile('pubspec.yaml').writeAsStringSync(pubspec);
      projectDir
          .childDirectory('watchos')
          .childDirectory('Classes')
          .childFile('gadget_watchos_ffi.m')
        ..createSync(recursive: true)
        ..writeAsStringSync('// the C source of the plugin\n');
      return projectDir;
    }

    testUsingContext(
      'writes nothing when the pubspec has a flutter.plugin block',
      () async {
        final Directory projectDir = projectWith('''
name: gadget_watchos
flutter:
  plugin:
    implements: gadget
    platforms:
      watchos:
        ffiPlugin: true
        dartPluginClass: GadgetWatchos
''');
        final List<String> before = filesUnder(projectDir);

        await ensureReadyForWatchosTooling(FlutterProject.fromDirectory(projectDir));

        expect(filesUnder(projectDir), before);
        expect(projectDir.childDirectory('watchos').childDirectory('Flutter').existsSync(), isFalse);
      },
      overrides: <Type, Generator>{
        FileSystem: () => fileSystem,
        ProcessManager: () => processManager,
      },
    );

    testUsingContext(
      'still writes the app wiring for an app with the same layout',
      () async {
        final Directory projectDir = projectWith('name: gadget_app\n');

        await ensureReadyForWatchosTooling(FlutterProject.fromDirectory(projectDir));

        expect(
          projectDir
              .childDirectory('watchos')
              .childDirectory('Flutter')
              .childFile('GeneratedPluginRegistrant.swift')
              .existsSync(),
          isTrue,
        );
      },
      overrides: <Type, Generator>{
        FileSystem: () => fileSystem,
        ProcessManager: () => processManager,
      },
    );
  });

  // Through the tooling step itself: one warning, with the command, and no
  // second line for the same plugin.
  group('ensureReadyForWatchosTooling plugin warnings', () {
    Directory appUsing(Map<String, String> pluginPubspecs) {
      final Directory projectDir = fileSystem.directory('/app')..createSync();
      projectDir.childDirectory('watchos').childDirectory('Runner').createSync(recursive: true);
      projectDir.childFile('pubspec.yaml').writeAsStringSync(
        'name: app\ndependencies:\n'
        '${pluginPubspecs.keys.map((String name) => '  $name: any\n').join()}',
      );
      for (final MapEntry<String, String> plugin in pluginPubspecs.entries) {
        fileSystem.file('/pubcache/${plugin.key}/pubspec.yaml')
          ..createSync(recursive: true)
          ..writeAsStringSync(plugin.value);
      }
      projectDir.childDirectory('.dart_tool').childFile('package_config.json')
        ..createSync(recursive: true)
        ..writeAsStringSync(
          json.encode(<String, dynamic>{
            'packages': <Map<String, String>>[
              for (final String name in pluginPubspecs.keys)
                <String, String>{'name': name, 'rootUri': 'file:///pubcache/$name'},
            ],
          }),
        );
      projectDir.childFile('.flutter-plugins-dependencies').writeAsStringSync(
        json.encode(<String, dynamic>{
          'dependencyGraph': <Map<String, String>>[
            for (final String name in pluginPubspecs.keys) <String, String>{'name': name},
          ],
        }),
      );
      return projectDir;
    }

    const sharedPreferences = '''
name: shared_preferences
flutter:
  plugin:
    platforms:
      android:
        default_package: shared_preferences_android
      ios:
        default_package: shared_preferences_foundation
''';

    testUsingContext(
      'names the missing watchOS package once, with the command that adds it',
      () async {
        final Directory projectDir = appUsing(<String, String>{
          'shared_preferences': sharedPreferences,
        });

        await ensureReadyForWatchosTooling(FlutterProject.fromDirectory(projectDir));

        final String warnings = testLogger.warningText;
        expect(
          'flutter-watchos pub add shared_preferences_watchos'.allMatches(warnings),
          hasLength(1),
        );
        expect(warnings, isNot(contains('no watchOS implementation')));
        expect(warnings, isNot(contains('- shared_preferences (')));
      },
      overrides: <Type, Generator>{
        FileSystem: () => fileSystem,
        ProcessManager: () => processManager,
      },
    );

    testUsingContext(
      'prints nothing once the watchOS package is there',
      () async {
        final Directory projectDir = appUsing(<String, String>{
          'shared_preferences': sharedPreferences,
          'shared_preferences_watchos': '''
name: shared_preferences_watchos
flutter:
  plugin:
    implements: shared_preferences
    platforms:
      watchos:
        ffiPlugin: true
        dartPluginClass: SharedPreferencesWatchos
''',
        });

        await ensureReadyForWatchosTooling(FlutterProject.fromDirectory(projectDir));

        expect(testLogger.warningText, isEmpty);
      },
      overrides: <Type, Generator>{
        FileSystem: () => fileSystem,
        ProcessManager: () => processManager,
      },
    );
  });
}
