// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Per-app defines for plugin sources: a plugin maps its macros to the app
// Info.plist keys that turn them on, under
// `flutter.plugin.platforms.watchos.defines`, and the build compiles that
// plugin's sources with each macro the watch app's Info.plist turns on, after
// a marker that every plugin source the CLI compiles gets.

import 'dart:convert';

import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/ios/plist_parser.dart';
import 'package:flutter_tools/src/project.dart';
import 'package:flutter_watchos/build_targets/application.dart';
import 'package:flutter_watchos/watchos_build_info.dart';
import 'package:flutter_watchos/watchos_plugin_defines.dart';
import 'package:flutter_watchos/watchos_plugins.dart'
    show discoverWatchosSpmPlugins, ensureReadyForWatchosTooling;
import 'package:flutter_watchos/watchos_swift_package_manager.dart';
import 'package:yaml/yaml.dart';

import '../src/common.dart';
import '../src/context.dart';
import '../src/fake_process_manager.dart';
import '../src/fakes.dart';
import '../src/forbidden_words.dart';

const _simulatorDebug = WatchosBuildInfo(BuildInfo.debug, targetArch: 'arm64', simulator: true);

const _objDir = '/app/watchos/Flutter/.plugins_build';
const _infoPlistPath = '/app/watchos/Runner/Info.plist';
const _marker = '-DFLUTTER_WATCHOS_PLUGIN_DEFINES=1';
const _swiftMarker = '-DFLUTTER_WATCHOS_PLUGIN_DEFINES';

/// The lines a plugin's pubspec adds under `watchos:` to declare [defines]:
/// a macro mapped to a key, or to a list of keys.
String _definesYaml(Map<String, Object> defines) {
  final yaml = StringBuffer('        defines:\n');
  defines.forEach((String macro, Object keys) {
    if (keys is List<String>) {
      yaml.writeln('          $macro:');
      for (final String key in keys) {
        yaml.writeln('            - $key');
      }
    } else {
      yaml.writeln('          $macro: $keys');
    }
  });
  return yaml.toString();
}

/// An app at /app whose watchOS plugins are [plugins], each name mapped to the
/// lines its pubspec adds under `watchos:` after `ffiPlugin: true`.
///
/// Every plugin ships one C source. Those in [views] also ship a SwiftUI view
/// source, and those in [swiftPM] name a SwiftPM package in their
/// Package.swift. The watch app's Info.plist exists unless [infoPlist] is
/// false; what it holds is up to the plist parser the test gives.
FlutterProject _app(
  FileSystem fileSystem,
  Map<String, String> plugins, {
  Set<String> views = const <String>{},
  Set<String> swiftPM = const <String>{},
  bool infoPlist = true,
}) {
  final Directory app = fileSystem.directory('/app')..createSync();
  app.childFile('pubspec.yaml').writeAsStringSync('name: app\n');
  app.childDirectory('watchos').childDirectory('Runner').createSync(recursive: true);
  if (infoPlist) {
    fileSystem.file(_infoPlistPath).writeAsStringSync('<plist/>\n');
  }
  app.childFile('.dart_tool/package_config.json')
    ..createSync(recursive: true)
    ..writeAsStringSync(
      json.encode(<String, Object>{
        'configVersion': 2,
        'packages': <Map<String, String>>[
          for (final String name in plugins.keys)
            <String, String>{'name': name, 'rootUri': 'file:///pub/$name'},
        ],
      }),
    );
  app
      .childFile('.flutter-plugins-dependencies')
      .writeAsStringSync(
        json.encode(<String, Object>{
          'dependencyGraph': <Map<String, String>>[
            for (final String name in plugins.keys) <String, String>{'name': name},
          ],
        }),
      );
  for (final MapEntry<String, String> plugin in plugins.entries) {
    final String name = plugin.key;
    final Directory dir = fileSystem.directory('/pub/$name')..createSync(recursive: true);
    dir
        .childFile('pubspec.yaml')
        .writeAsStringSync(
          'name: $name\n'
          'flutter:\n'
          '  plugin:\n'
          '    platforms:\n'
          '      watchos:\n'
          '        ffiPlugin: true\n'
          '${plugin.value}',
        );
    dir.childFile('watchos/Package.swift')
      ..createSync(recursive: true)
      ..writeAsStringSync(
        swiftPM.contains(name)
            ? 'let package = Package(name: "$name", dependencies: [\n'
                  '  .package(url: "https://example.com/sdk.git", from: "1.0.0"),\n'
                  '])\n'
            : 'let package = Package(name: "$name")\n',
      );
    dir.childFile('watchos/Sources/$name/$name.c')
      ..createSync(recursive: true)
      ..writeAsStringSync('int $name(void) { return 1; }\n');
    if (views.contains(name)) {
      dir.childFile('watchos/Sources/$name/View.swift').writeAsStringSync('import SwiftUI\n');
    }
  }
  return FlutterProject.fromDirectory(app);
}

/// The object the clang pass writes for [plugin]'s C source.
String _object(String plugin) => '$_objDir/${plugin}__Sources_${plugin}_$plugin.c.o';

/// The clang compile of [plugin]'s C source, for a simulator debug build at
/// the supported minimum, with the -D flags [defines].
FakeCommand _clang(String plugin, List<String> defines) {
  return FakeCommand(
    command: <String>[
      'xcrun',
      '-sdk',
      'watchsimulator',
      'clang',
      '-target',
      'arm64-apple-watchos26.0-simulator',
      '-O0',
      '-g',
      '-fobjc-arc',
      '-fmodules',
      ...defines,
      '-c',
      '/pub/$plugin/watchos/Sources/$plugin/$plugin.c',
      '-o',
      _object(plugin),
    ],
  );
}

/// The swiftc compile of [plugin]'s view source, with the -D flags [defines].
FakeCommand _swiftc(String plugin, List<String> defines) {
  return FakeCommand(
    command: <String>[
      'xcrun',
      '-sdk',
      'watchsimulator',
      'swiftc',
      '-target',
      'arm64-apple-watchos26.0-simulator',
      '-parse-as-library',
      '-Onone',
      '-g',
      '-whole-module-optimization',
      ...defines,
      '-module-name',
      '${plugin}_views',
      '-emit-object',
      '-o',
      '$_objDir/${plugin}_views.o',
      '$_objDir/flutter_watchos_plugin_views_shim.swift',
      '/pub/$plugin/watchos/Sources/$plugin/View.swift',
    ],
  );
}

/// The archive step over [objects].
FakeCommand _libtool(List<String> objects) {
  return FakeCommand(
    command: <String>[
      'xcrun',
      '-sdk',
      'watchsimulator',
      'libtool',
      '-static',
      '-o',
      '/app/watchos/Flutter/libflutter_watchos_plugins.a',
      ...objects,
    ],
  );
}

Future<void> _build(FlutterProject project) {
  return NativeWatchosBundle(
    _simulatorDebug,
    'lib/main.dart',
  ).buildPluginStaticArchive(project, project.directory.childDirectory('watchos'));
}

/// A plist parser that answers its values for any file and records each file
/// it reads.
class _RecordingPlistParser extends FakePlistParser {
  _RecordingPlistParser([super.underlyingValues]);

  final reads = <String>[];

  @override
  Map<String, Object> parseFile(String plistFilePath) {
    reads.add(plistFilePath);
    return super.parseFile(plistFilePath);
  }
}

/// The message of the refusal [yaml] gets as the `defines` of the plugin
/// `gadget`.
String _refusal(String yaml) {
  try {
    parseWatchosPluginDefines(
      pluginName: 'gadget',
      pubspecPath: '/pub/gadget/pubspec.yaml',
      yaml: loadYaml(yaml),
    );
  } on ToolExit catch (error) {
    return error.message!;
  }
  fail('`defines` of "$yaml" was accepted');
}

void main() {
  group('parseWatchosPluginDefines', () {
    testWithoutContext('reads a key or a list of keys, in the order the plugin declares them', () {
      final List<WatchosPluginDefine> defines = parseWatchosPluginDefines(
        pluginName: 'gadget',
        pubspecPath: '/pub/gadget/pubspec.yaml',
        yaml: loadYaml('''
PERMISSION_CONTACTS: NSContactsUsageDescription
PERMISSION_LOCATION:
  - NSLocationWhenInUseUsageDescription
  - NSLocationAlwaysAndWhenInUseUsageDescription
_permission_2: PermissionHandlerWatchosSiri
'''),
      );
      expect(defines, const <WatchosPluginDefine>[
        WatchosPluginDefine('PERMISSION_CONTACTS', <String>['NSContactsUsageDescription']),
        WatchosPluginDefine('PERMISSION_LOCATION', <String>[
          'NSLocationWhenInUseUsageDescription',
          'NSLocationAlwaysAndWhenInUseUsageDescription',
        ]),
        WatchosPluginDefine('_permission_2', <String>['PermissionHandlerWatchosSiri']),
      ]);
    });

    testWithoutContext('no defines, or an empty map, declares none', () {
      expect(
        parseWatchosPluginDefines(pluginName: 'gadget', pubspecPath: '/p', yaml: null),
        isEmpty,
      );
      expect(
        parseWatchosPluginDefines(pluginName: 'gadget', pubspecPath: '/p', yaml: loadYaml('{}')),
        isEmpty,
      );
    });

    for (final (String label, String yaml, String problem) in <(String, String, String)>[
      ('a list instead of a map', '- GADGET_CAMERA\n', '`defines` is a list, not a map.'),
      ('a string instead of a map', 'GADGET_CAMERA\n', '`defines` is "GADGET_CAMERA", not a map.'),
      (
        'a macro that starts with a digit',
        '1GADGET: NSCameraUsageDescription\n',
        '`1GADGET` is not a C identifier.',
      ),
      (
        'a macro with a hyphen',
        'GADGET-CAMERA: NSCameraUsageDescription\n',
        '`GADGET-CAMERA` is not a C identifier.',
      ),
      (
        'a macro with a space',
        'GADGET CAMERA: NSCameraUsageDescription\n',
        '`GADGET CAMERA` is not a C identifier.',
      ),
      ('a macro that is a number', '42: NSCameraUsageDescription\n', '`42` is not a C identifier.'),
      (
        'a key that is a number',
        'GADGET_CAMERA: 42\n',
        '`GADGET_CAMERA` maps to 42, not an Info.plist key or a list of keys.',
      ),
      (
        'a key that is a Boolean',
        'GADGET_CAMERA: true\n',
        '`GADGET_CAMERA` maps to true, not an Info.plist key or a list of keys.',
      ),
      (
        'a key that is a map',
        'GADGET_CAMERA: {NSCameraUsageDescription: x}\n',
        '`GADGET_CAMERA` maps to a map, not an Info.plist key or a list of keys.',
      ),
      ('no key', 'GADGET_CAMERA:\n', '`GADGET_CAMERA` names no Info.plist key.'),
      ('an empty key', "GADGET_CAMERA: ''\n", '`GADGET_CAMERA` names an empty Info.plist key.'),
      ('an empty list', 'GADGET_CAMERA: []\n', '`GADGET_CAMERA` lists no Info.plist key.'),
      (
        'a list with a number',
        'GADGET_CAMERA: [NSCameraUsageDescription, 7]\n',
        '`GADGET_CAMERA` lists 7, which is not an Info.plist key.',
      ),
      (
        'a list with an empty key',
        "GADGET_CAMERA: [NSCameraUsageDescription, '']\n",
        '`GADGET_CAMERA` lists an empty string, which is not an Info.plist key.',
      ),
      (
        'a list with an empty entry',
        'GADGET_CAMERA:\n  - NSCameraUsageDescription\n  -\n',
        '`GADGET_CAMERA` lists an empty entry, which is not an Info.plist key.',
      ),
    ]) {
      testWithoutContext('refuses $label, naming the plugin, its pubspec and the entry', () {
        final String message = _refusal(yaml);
        expect(message, contains('The watchOS plugin gadget '));
        expect(message, contains('/pub/gadget/pubspec.yaml'));
        expect(message, contains(problem));
      });
    }

    testWithoutContext('names every problem in one message, which says what an entry is', () {
      expect(
        _refusal('1GADGET: NSCameraUsageDescription\nGADGET_OK: Key\nGADGET_SIRI: []\n'),
        'The watchOS plugin gadget has an invalid `defines` in /pub/gadget/pubspec.yaml:\n'
        '  - `1GADGET` is not a C identifier.\n'
        '  - `GADGET_SIRI` lists no Info.plist key.\n'
        'Each entry maps a macro name, a C identifier, to an app Info.plist key or to a list '
        'of keys.',
      );
    });

    testWithoutContext('the refusal holds no forbidden word', () {
      expect(forbiddenWordsIn(_refusal('1GADGET: 42\n')), isEmpty);
    });
  });

  group('enabledWatchosPluginDefines', () {
    const camera = WatchosPluginDefine('GADGET_CAMERA', <String>['NSCameraUsageDescription']);

    Map<String, String> enabled(Map<String, Object> infoPlist) {
      return enabledWatchosPluginDefines(const <WatchosPluginDefine>[camera], infoPlist);
    }

    testWithoutContext('a non-empty string turns the macro on', () {
      expect(
        enabled(<String, Object>{'NSCameraUsageDescription': 'Scans a code.'}),
        <String, String>{'GADGET_CAMERA': 'NSCameraUsageDescription'},
      );
    });

    testWithoutContext('an empty string leaves it off', () {
      expect(enabled(<String, Object>{'NSCameraUsageDescription': ''}), isEmpty);
    });

    testWithoutContext('true turns it on, and false leaves it off', () {
      expect(enabled(<String, Object>{'NSCameraUsageDescription': true}), <String, String>{
        'GADGET_CAMERA': 'NSCameraUsageDescription',
      });
      expect(enabled(<String, Object>{'NSCameraUsageDescription': false}), isEmpty);
    });

    testWithoutContext('a missing key leaves it off', () {
      expect(enabled(<String, Object>{'CFBundleIdentifier': 'com.example.app'}), isEmpty);
    });

    testWithoutContext('any other value leaves it off', () {
      for (final value in <Object>[
        1,
        0,
        1.5,
        DateTime.utc(2026, 10, 30),
        <int>[1, 2],
        <Object>['Scans a code.'],
        <String, Object>{'Reason': 'Scans a code.'},
      ]) {
        expect(
          enabled(<String, Object>{'NSCameraUsageDescription': value}),
          isEmpty,
          reason: '$value',
        );
      }
    });

    testWithoutContext('a value is read as written, before Xcode expands build settings', () {
      for (final value in <String>[r'$(CAMERA_REASON)', 'NO', ' ']) {
        expect(enabled(<String, Object>{'NSCameraUsageDescription': value}), <String, String>{
          'GADGET_CAMERA': 'NSCameraUsageDescription',
        }, reason: value);
      }
    });

    testWithoutContext('with a list, any one key is enough, and the first that is on is named', () {
      const location = WatchosPluginDefine('GADGET_LOCATION', <String>['WhenInUse', 'Always']);
      Map<String, String> enabledLocation(Map<String, Object> infoPlist) {
        return enabledWatchosPluginDefines(const <WatchosPluginDefine>[location], infoPlist);
      }

      expect(enabledLocation(<String, Object>{'Always': 'Tracks a run.'}), <String, String>{
        'GADGET_LOCATION': 'Always',
      });
      expect(
        enabledLocation(<String, Object>{'WhenInUse': 'Shows a map.', 'Always': true}),
        <String, String>{'GADGET_LOCATION': 'WhenInUse'},
      );
      expect(enabledLocation(<String, Object>{'WhenInUse': '', 'Always': false}), isEmpty);
    });

    testWithoutContext('keeps the order the plugin declares', () {
      final Map<String, String> result = enabledWatchosPluginDefines(
        const <WatchosPluginDefine>[
          WatchosPluginDefine('GADGET_SIRI', <String>['GadgetSiri']),
          WatchosPluginDefine('GADGET_CAMERA', <String>['NSCameraUsageDescription']),
          WatchosPluginDefine('GADGET_CONTACTS', <String>['NSContactsUsageDescription']),
        ],
        <String, Object>{
          'NSContactsUsageDescription': 'Finds a friend.',
          'NSCameraUsageDescription': 'Scans a code.',
          'GadgetSiri': true,
        },
      );
      expect(result.keys, <String>['GADGET_SIRI', 'GADGET_CAMERA', 'GADGET_CONTACTS']);
    });
  });

  group('plugin discovery', () {
    late MemoryFileSystem fileSystem;

    setUp(() {
      fileSystem = MemoryFileSystem.test();
    });

    testUsingContext(
      "hands the build each plugin's defines, under its pub name",
      () {
        final FlutterProject project = _app(fileSystem, <String, String>{
          'gadget': _definesYaml(<String, Object>{
            'GADGET_CAMERA': 'NSCameraUsageDescription',
            'GADGET_LOCATION': <String>['WhenInUse', 'Always'],
          }),
        });
        // A Swift package named apart from its pub package.
        fileSystem
            .file('/pub/gadget/watchos/Package.swift')
            .writeAsStringSync('let package = Package(name: "GadgetKit")\n');

        final WatchosSpmPlugin plugin = discoverWatchosSpmPlugins(project).single;

        expect(plugin.name, 'GadgetKit');
        expect(plugin.pluginName, 'gadget');
        expect(plugin.defines, const <WatchosPluginDefine>[
          WatchosPluginDefine('GADGET_CAMERA', <String>['NSCameraUsageDescription']),
          WatchosPluginDefine('GADGET_LOCATION', <String>['WhenInUse', 'Always']),
        ]);
      },
      overrides: <Type, Generator>{
        FileSystem: () => fileSystem,
        ProcessManager: () => FakeProcessManager.empty(),
      },
    );

    // build, run, drive, attach and test all start with the tooling step. A
    // standalone app whose Info.plist lacks WKWatchOnly would have it added by
    // the host-mode sync, so an unchanged file shows that the refusal came
    // first.
    testUsingContext(
      'an invalid declaration stops the tooling step before it writes a file',
      () async {
        final FlutterProject project = _app(fileSystem, <String, String>{
          'gadget': _definesYaml(<String, Object>{'GADGET-CAMERA': 'NSCameraUsageDescription'}),
        });
        const infoPlist =
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<plist version="1.0">\n'
            '<dict>\n'
            '\t<key>CFBundleName</key>\n'
            '\t<string>app</string>\n'
            '</dict>\n'
            '</plist>\n';
        final File plist = fileSystem.file(_infoPlistPath)..writeAsStringSync(infoPlist);

        await expectLater(
          ensureReadyForWatchosTooling(project),
          throwsToolExit(message: '`GADGET-CAMERA` is not a C identifier.'),
        );
        expect(plist.readAsStringSync(), infoPlist);
        expect(
          project.directory
              .childFile('watchos/Flutter/GeneratedPluginRegistrant.swift')
              .existsSync(),
          isFalse,
        );

        // Once the declaration is fixed, the same step runs and syncs.
        fileSystem
            .file('/pub/gadget/pubspec.yaml')
            .writeAsStringSync(
              'name: gadget\n'
              'flutter:\n'
              '  plugin:\n'
              '    platforms:\n'
              '      watchos:\n'
              '        ffiPlugin: true\n'
              '${_definesYaml(<String, Object>{'GADGET_CAMERA': 'NSCameraUsageDescription'})}',
            );
        await ensureReadyForWatchosTooling(project);
        expect(plist.readAsStringSync(), contains('<key>WKWatchOnly</key>'));
      },
      overrides: <Type, Generator>{
        FileSystem: () => fileSystem,
        ProcessManager: () => FakeProcessManager.any(),
      },
    );
  });

  group('buildPluginStaticArchive', () {
    late MemoryFileSystem fileSystem;
    late FakeProcessManager processManager;
    late _RecordingPlistParser plistParser;

    setUp(() {
      fileSystem = MemoryFileSystem.test();
      processManager = FakeProcessManager.empty();
      plistParser = _RecordingPlistParser(<String, Object>{'CFBundleName': 'app'});
    });

    Map<Type, Generator> overrides() => <Type, Generator>{
      FileSystem: () => fileSystem,
      ProcessManager: () => processManager,
      Platform: () => FakePlatform(environment: <String, String>{}),
      PlistParser: () => plistParser,
    };

    testUsingContext(
      'compiles a plugin with the macros its Info.plist keys turn on, swiftc without values',
      () async {
        final FlutterProject project = _app(
          fileSystem,
          <String, String>{
            'gadget': _definesYaml(<String, Object>{
              'GADGET_CAMERA': 'NSCameraUsageDescription',
              'GADGET_CONTACTS': 'NSContactsUsageDescription',
              'GADGET_SIRI': 'GadgetSiri',
            }),
          },
          views: <String>{'gadget'},
        );
        plistParser
          ..setProperty('NSCameraUsageDescription', 'Scans a code.')
          ..setProperty('GadgetSiri', true);
        processManager.addCommands(<FakeCommand>[
          _clang('gadget', <String>[_marker, '-DGADGET_CAMERA=1', '-DGADGET_SIRI=1']),
          _swiftc('gadget', <String>[_swiftMarker, '-DGADGET_CAMERA', '-DGADGET_SIRI']),
          _libtool(<String>[_object('gadget'), '$_objDir/gadget_views.o']),
        ]);

        await _build(project);

        expect(processManager, hasNoRemainingExpectations);
        expect(plistParser.reads, <String>[_infoPlistPath]);
        // What -v shows.
        expect(
          testLogger.traceText,
          contains(
            'watchOS plugin gadget defines (2 of 3 on, from $_infoPlistPath): '
            'GADGET_CAMERA (NSCameraUsageDescription), GADGET_SIRI (GadgetSiri)\n',
          ),
        );
        expect(forbiddenWordsIn(testLogger.traceText), isEmpty);
        expect(testLogger.warningText, isEmpty);
      },
      overrides: overrides(),
    );

    testUsingContext(
      'gives each plugin its own macros, and the marker to one without defines',
      () async {
        final FlutterProject project = _app(fileSystem, <String, String>{
          'gadget': _definesYaml(<String, Object>{'GADGET_CAMERA': 'NSCameraUsageDescription'}),
          'widget': _definesYaml(<String, Object>{
            'WIDGET_CAMERA': 'NSCameraUsageDescription',
            'WIDGET_HEALTH': 'NSHealthShareUsageDescription',
          }),
          'plain': '',
        });
        plistParser.setProperty('NSCameraUsageDescription', 'Scans a code.');
        processManager.addCommands(<FakeCommand>[
          _clang('gadget', <String>[_marker, '-DGADGET_CAMERA=1']),
          _clang('widget', <String>[_marker, '-DWIDGET_CAMERA=1']),
          _clang('plain', <String>[_marker]),
          _libtool(<String>[_object('gadget'), _object('widget'), _object('plain')]),
        ]);

        await _build(project);

        expect(processManager, hasNoRemainingExpectations);
        // Read once for the whole build.
        expect(plistParser.reads, <String>[_infoPlistPath]);
        expect(
          testLogger.traceText,
          contains(
            'watchOS plugin widget defines (1 of 2 on, from $_infoPlistPath): '
            'WIDGET_CAMERA (NSCameraUsageDescription)\n',
          ),
        );
      },
      overrides: overrides(),
    );

    testUsingContext('with none of its keys set, a plugin gets the marker alone', () async {
      final FlutterProject project = _app(
        fileSystem,
        <String, String>{
          'gadget': _definesYaml(<String, Object>{'GADGET_CAMERA': 'NSCameraUsageDescription'}),
        },
        views: <String>{'gadget'},
      );
      processManager.addCommands(<FakeCommand>[
        _clang('gadget', <String>[_marker]),
        _swiftc('gadget', <String>[_swiftMarker]),
        _libtool(<String>[_object('gadget'), '$_objDir/gadget_views.o']),
      ]);

      await _build(project);

      expect(processManager, hasNoRemainingExpectations);
      expect(
        testLogger.traceText,
        contains('watchOS plugin gadget defines (0 of 1 on, from $_infoPlistPath): none\n'),
      );
    }, overrides: overrides());

    // Plugin objects compile on every build, with no up-to-date check, so the
    // next build after an Info.plist edit compiles the same objects again,
    // with the new flags.
    testUsingContext(
      'an Info.plist edit recompiles the same objects with the new macros',
      () async {
        final FlutterProject project = _app(
          fileSystem,
          <String, String>{
            'gadget': _definesYaml(<String, Object>{
              'GADGET_CAMERA': 'NSCameraUsageDescription',
              'GADGET_SIRI': 'GadgetSiri',
            }),
          },
          views: <String>{'gadget'},
        );
        plistParser.setProperty('NSCameraUsageDescription', 'Scans a code.');
        processManager.addCommands(<FakeCommand>[
          _clang('gadget', <String>[_marker, '-DGADGET_CAMERA=1']),
          _swiftc('gadget', <String>[_swiftMarker, '-DGADGET_CAMERA']),
          _libtool(<String>[_object('gadget'), '$_objDir/gadget_views.o']),
        ]);
        await _build(project);
        expect(processManager, hasNoRemainingExpectations);

        plistParser
          ..replaceKey(_infoPlistPath, key: 'NSCameraUsageDescription')
          ..setProperty('GadgetSiri', true);
        processManager.addCommands(<FakeCommand>[
          _clang('gadget', <String>[_marker, '-DGADGET_SIRI=1']),
          _swiftc('gadget', <String>[_swiftMarker, '-DGADGET_SIRI']),
          _libtool(<String>[_object('gadget'), '$_objDir/gadget_views.o']),
        ]);
        await _build(project);

        expect(processManager, hasNoRemainingExpectations);
        expect(plistParser.reads, <String>[_infoPlistPath, _infoPlistPath]);
      },
      overrides: overrides(),
    );

    testUsingContext('an invalid declaration stops the build before any command runs', () async {
      final FlutterProject project = _app(fileSystem, <String, String>{
        'plain': '',
        'gadget': _definesYaml(<String, Object>{'GADGET_CAMERA': 'NSCameraUsageDescription'}),
      });
      fileSystem
          .file('/pub/gadget/pubspec.yaml')
          .writeAsStringSync(
            'name: gadget\n'
            'flutter:\n'
            '  plugin:\n'
            '    platforms:\n'
            '      watchos:\n'
            '        ffiPlugin: true\n'
            '        defines:\n'
            '          GADGET_CAMERA: 7\n',
          );

      await expectLater(
        _build(project),
        throwsToolExit(
          message: 'The watchOS plugin gadget has an invalid `defines` in /pub/gadget/pubspec.yaml',
        ),
      );
      // FakeProcessManager.empty() fails any command, so none ran.
      expect(processManager, hasNoRemainingExpectations);
      expect(plistParser.reads, isEmpty);
    }, overrides: overrides());

    // Out of scope: none of its sources get a -D, the view sources the CLI
    // compiles itself included, so the whole plugin compiles as under a CLI
    // that predates `defines`.
    testUsingContext('a plugin built through SwiftPM gets no -D at all, and -v says why', () async {
      final FlutterProject project = _app(
        fileSystem,
        <String, String>{
          'cloud': _definesYaml(<String, Object>{'CLOUD_CAMERA': 'NSCameraUsageDescription'}),
        },
        views: <String>{'cloud'},
        swiftPM: <String>{'cloud'},
      );
      plistParser.setProperty('NSCameraUsageDescription', 'Scans a code.');
      const products = '$_objDir/spm_cloud/Build/Products/Debug-watchsimulator';
      fileSystem.file('$products/cloud.o').createSync(recursive: true);
      processManager.addCommands(<FakeCommand>[
        const FakeCommand(
          command: <String>[
            'xcrun',
            'xcodebuild',
            '-scheme',
            'cloud',
            '-destination',
            'generic/platform=watchOS Simulator',
            '-configuration',
            'Debug',
            '-derivedDataPath',
            '$_objDir/spm_cloud',
            '-sdk',
            'watchsimulator',
            'build',
          ],
          workingDirectory: '/pub/cloud/watchos',
        ),
        _swiftc('cloud', const <String>[]),
        _libtool(<String>['$products/cloud.o', '$_objDir/cloud_views.o']),
      ]);

      await _build(project);

      expect(processManager, hasNoRemainingExpectations);
      expect(plistParser.reads, isEmpty);
      expect(
        testLogger.traceText,
        contains(
          'watchOS plugin cloud is built through SwiftPM, so its `defines` are not '
          'applied: its sources compile without FLUTTER_WATCHOS_PLUGIN_DEFINES.\n',
        ),
      );
      expect(forbiddenWordsIn(testLogger.traceText), isEmpty);
    }, overrides: overrides());

    for (final (String label, bool exists) in <(String, bool)>[
      ('without an Info.plist', false),
      ('with an Info.plist that reads as empty', true),
    ]) {
      testUsingContext(
        '$label, a plugin with defines compiles as before, and the build says so',
        () async {
          final FlutterProject project = _app(fileSystem, <String, String>{
            'gadget': _definesYaml(<String, Object>{'GADGET_CAMERA': 'NSCameraUsageDescription'}),
            'plain': '',
          }, infoPlist: exists);
          plistParser.replaceKey(_infoPlistPath, key: 'CFBundleName');
          processManager.addCommands(<FakeCommand>[
            _clang('gadget', const <String>[]),
            _clang('plain', <String>[_marker]),
            _libtool(<String>[_object('gadget'), _object('plain')]),
          ]);

          await _build(project);

          expect(processManager, hasNoRemainingExpectations);
          expect(plistParser.reads, exists ? <String>[_infoPlistPath] : isEmpty);
          expect(
            testLogger.warningText,
            "Could not read the watch app's Info.plist at $_infoPlistPath, so these plugins "
            'are compiled with all of their optional code: gadget. Each chooses that code '
            'from the keys the Info.plist sets, under `defines` in its pubspec.yaml.\n',
          );
          expect(forbiddenWordsIn(testLogger.warningText), isEmpty);
        },
        overrides: overrides(),
      );
    }

    testUsingContext('no plugin with defines, no Info.plist read', () async {
      final FlutterProject project = _app(
        fileSystem,
        <String, String>{'plain': ''},
        views: <String>{'plain'},
      );
      processManager.addCommands(<FakeCommand>[
        _clang('plain', <String>[_marker]),
        _swiftc('plain', <String>[_swiftMarker]),
        _libtool(<String>[_object('plain'), '$_objDir/plain_views.o']),
      ]);

      await _build(project);

      expect(processManager, hasNoRemainingExpectations);
      expect(plistParser.reads, isEmpty);
    }, overrides: overrides());

    // The parser flutter_tools uses converts the file with plutil and reads
    // the XML, so every value type arrives as a Dart value.
    testUsingContext(
      'reads the Info.plist through plutil, as flutter_tools does',
      () async {
        final FlutterProject project = _app(fileSystem, <String, String>{
          'gadget': _definesYaml(<String, Object>{
            'GADGET_STRING': 'KeyString',
            'GADGET_EMPTY': 'KeyEmpty',
            'GADGET_TRUE': 'KeyTrue',
            'GADGET_FALSE': 'KeyFalse',
            'GADGET_NUMBER': 'KeyNumber',
            'GADGET_MISSING': 'KeyMissing',
          }),
        });
        fileSystem.file('/usr/bin/plutil').createSync(recursive: true);
        processManager.addCommands(<FakeCommand>[
          const FakeCommand(
            command: <String>['/usr/bin/plutil', '-convert', 'xml1', '-o', '-', _infoPlistPath],
            stdout: r'''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
	<key>KeyString</key>
	<string>Scans a code.</string>
	<key>KeyEmpty</key>
	<string></string>
	<key>KeyTrue</key>
	<true/>
	<key>KeyFalse</key>
	<false/>
	<key>KeyNumber</key>
	<integer>1</integer>
</dict>
</plist>
''',
          ),
          _clang('gadget', <String>[_marker, '-DGADGET_STRING=1', '-DGADGET_TRUE=1']),
          _libtool(<String>[_object('gadget')]),
        ]);

        await _build(project);

        expect(processManager, hasNoRemainingExpectations);
      },
      overrides: <Type, Generator>{
        ...overrides(),
        PlistParser: () => PlistParser(
          fileSystem: fileSystem,
          logger: BufferLogger.test(),
          processManager: processManager,
        ),
      },
    );
  });
}
