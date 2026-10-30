// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Per-app defines for plugin sources: a plugin maps its macros to the app
// Info.plist keys that turn them on, under
// `flutter.plugin.platforms.watchos.defines`, and the build compiles that
// plugin's sources with each macro the watch app's Info.plist turns on, after
// a marker that says the plugin's `defines` were applied. A plugin that
// declares none gets neither, as under a CLI that predates them.

import 'dart:convert';
import 'dart:io' as io;

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
    show discoverWatchosSpmPlugins, ensureReadyForWatchosTooling, writeWatchosDartPluginRegistrant;
import 'package:flutter_watchos/watchos_swift_package_manager.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../src/common.dart';
import '../src/context.dart';
import '../src/fake_process_manager.dart';
import '../src/fakes.dart';
import '../src/forbidden_words.dart';
import '../src/host_sources.dart';

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

/// The pubspec of the watchOS plugin [name], with [watchosLines] under
/// `watchos:` after `ffiPlugin: true`.
String _pluginPubspec(String name, String watchosLines) {
  return 'name: $name\n'
      'flutter:\n'
      '  plugin:\n'
      '    platforms:\n'
      '      watchos:\n'
      '        ffiPlugin: true\n'
      '$watchosLines';
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
    dir.childFile('pubspec.yaml').writeAsStringSync(_pluginPubspec(name, plugin.value));
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

/// What a compile command does when it runs with a [fileSystem]: it writes
/// the object it names after `-o` there, as the real compiler does. Without
/// one, it writes nothing.
void Function(List<String> command)? _writesObject(FileSystem? fileSystem) {
  if (fileSystem == null) {
    return null;
  }
  return (List<String> command) {
    fileSystem.file(command[command.indexOf('-o') + 1]).createSync(recursive: true);
  };
}

/// The clang compile of [plugin]'s C source, for a simulator debug build at
/// the supported minimum, with the -D flags [defines]. With [fileSystem], it
/// writes its object there.
FakeCommand _clang(String plugin, List<String> defines, {FileSystem? fileSystem}) {
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
    onRun: _writesObject(fileSystem),
  );
}

/// The swiftc compile of [plugin]'s view source, with the -D flags [defines].
/// With [fileSystem], it writes its object there.
FakeCommand _swiftc(String plugin, List<String> defines, {FileSystem? fileSystem}) {
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
    onRun: _writesObject(fileSystem),
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

/// Dates [project]'s pubspec.yaml and package config, so the config reads as
/// written before (`pub get` pending) or after the last pubspec.yaml edit.
void _datePubGet(FlutterProject project, {required bool pending}) {
  final edited = DateTime(2026, 10, 30, 12);
  project.pubspecFile.setLastModifiedSync(edited);
  project.directory
      .childFile('.dart_tool/package_config.json')
      .setLastModifiedSync(edited.add(Duration(minutes: pending ? -1 : 1)));
}

/// A watch-only app's Info.plist before the host-mode sync, which adds
/// WKWatchOnly to it.
const _standaloneInfoPlist =
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    '<plist version="1.0">\n'
    '<dict>\n'
    '\t<key>CFBundleName</key>\n'
    '\t<string>app</string>\n'
    '</dict>\n'
    '</plist>\n';

/// The template's watch project.pbxproj, which sets INFOPLIST_FILE to
/// Runner/Info.plist for the watch app and to HostApp/Info.plist for the iOS
/// container.
String _templatePbxproj() => io.File(
  cliRootPath('templates/app/swift/watchos.tmpl/Runner.xcodeproj/project.pbxproj.tmpl'),
).readAsStringSync();

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

    // The last line is for the developer of an app that uses the plugin, who
    // cannot fix its pubspec but can move to a version that fixes it.
    testWithoutContext(
      'names every problem in one message, which says what an entry is and when to run pub get',
      () {
        expect(
          _refusal('1GADGET: NSCameraUsageDescription\nGADGET_OK: Key\nGADGET_SIRI: []\n'),
          'The watchOS plugin gadget has an invalid `defines` in /pub/gadget/pubspec.yaml:\n'
          '  - `1GADGET` is not a C identifier.\n'
          '  - `GADGET_SIRI` lists no Info.plist key.\n'
          'Each entry maps a macro name, a C identifier, to an app Info.plist key or to a list '
          'of keys.\n'
          "If the app's dependency on gadget changed, run `flutter-watchos pub get` to resolve "
          'it again.',
        );
      },
    );

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

  // The build reads defines from watchos/Runner/Info.plist, the file the
  // template's Runner target names. A project whose INFOPLIST_FILE never
  // names it is worth a warning.
  group('otherInfoPlistFiles', () {
    List<String>? others(String pbxproj) {
      return otherInfoPlistFiles(
        pbxproj: pbxproj,
        projectDirectory: '/app/watchos',
        infoPlistPath: _infoPlistPath,
        pathContext: p.posix,
      );
    }

    testWithoutContext('none when the project names Runner/Info.plist, as the template does', () {
      expect(others(_templatePbxproj()), isNull);
    });

    testWithoutContext('each file the project names, once, when none is Runner/Info.plist', () {
      expect(
        others(
          '\t\t\t\tGENERATE_INFOPLIST_FILE = NO;\n'
          '\t\t\t\tINFOPLIST_FILE = Runner/Info-Watch.plist;\n'
          '\t\t\t\tINFOPLIST_FILE = "Runner/Info-Watch.plist";\n'
          '\t\t\t\t"INFOPLIST_FILE[sdk=watchos*]" = "Watch App/Info.plist";\n'
          '\t\t\t\tINFOPLIST_FILE = HostApp/Info.plist;\n',
        ),
        <String>['Runner/Info-Watch.plist', 'Watch App/Info.plist', 'HostApp/Info.plist'],
      );
    });

    testWithoutContext('reads a value from the project directory, as Xcode does', () {
      for (final value in <String>[
        r'"$(SRCROOT)/Runner/Info.plist"',
        r'"${PROJECT_DIR}/Runner/Info.plist"',
        './Runner/Info.plist',
        'Runner/../Runner/Info.plist',
        '/app/watchos/Runner/Info.plist',
      ]) {
        expect(
          others('INFOPLIST_FILE = $value;\nINFOPLIST_FILE = HostApp/Info.plist;\n'),
          isNull,
          reason: value,
        );
      }
    });

    testWithoutContext('none when a value holds a build setting that may name the file', () {
      expect(others('INFOPLIST_FILE = "\$(TARGET_NAME)/Info.plist";\n'), isNull);
    });

    testWithoutContext('none when the project sets no INFOPLIST_FILE', () {
      expect(others('GENERATE_INFOPLIST_FILE = YES;\nINFOPLIST_KEY_CFBundleName = app;\n'), isNull);
      expect(others('INFOPLIST_FILE = "";\n'), isNull);
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
        final File plist = fileSystem.file(_infoPlistPath)..writeAsStringSync(_standaloneInfoPlist);
        _datePubGet(project, pending: false);

        await expectLater(
          ensureReadyForWatchosTooling(project),
          throwsToolExit(message: '`GADGET-CAMERA` is not a C identifier.'),
        );
        expect(plist.readAsStringSync(), _standaloneInfoPlist);
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
              _pluginPubspec(
                'gadget',
                _definesYaml(<String, Object>{'GADGET_CAMERA': 'NSCameraUsageDescription'}),
              ),
            );
        await ensureReadyForWatchosTooling(project);
        expect(plist.readAsStringSync(), contains('<key>WKWatchOnly</key>'));
      },
      overrides: <Type, Generator>{
        FileSystem: () => fileSystem,
        ProcessManager: () => FakeProcessManager.any(),
      },
    );

    // The commands take the tooling step before their `pub get`. Right after
    // the app's pubspec.yaml moves away from a plugin version with an invalid
    // declaration, the package config still resolves that version, and a
    // refusal there would stop the very command whose `pub get` fixes it.
    testUsingContext(
      'with pub get pending, the tooling step leaves the refusal to the build after it',
      () async {
        final FlutterProject project = _app(fileSystem, <String, String>{
          'gadget': _definesYaml(<String, Object>{'GADGET-CAMERA': 'NSCameraUsageDescription'}),
        });
        final File plist = fileSystem.file(_infoPlistPath)..writeAsStringSync(_standaloneInfoPlist);
        _datePubGet(project, pending: true);

        await ensureReadyForWatchosTooling(project);

        expect(plist.readAsStringSync(), contains('<key>WKWatchOnly</key>'));
        expect(
          testLogger.traceText,
          contains(
            'The `defines` of gadget in /pub/gadget/pubspec.yaml are invalid, but pub get has '
            'yet to resolve the last pubspec.yaml edit: the build checks them again after it.\n',
          ),
        );

        // pub get resolves the version the edit asked for, and the build's
        // discovery after it has nothing to refuse.
        fileSystem.file('/pub/gadget-fixed/pubspec.yaml')
          ..createSync(recursive: true)
          ..writeAsStringSync(
            _pluginPubspec(
              'gadget',
              _definesYaml(<String, Object>{'GADGET_CAMERA': 'NSCameraUsageDescription'}),
            ),
          );
        fileSystem.file('/pub/gadget-fixed/watchos/Package.swift')
          ..createSync(recursive: true)
          ..writeAsStringSync('let package = Package(name: "gadget")\n');
        project.directory
            .childFile('.dart_tool/package_config.json')
            .writeAsStringSync(
              json.encode(<String, Object>{
                'configVersion': 2,
                'packages': <Map<String, String>>[
                  <String, String>{'name': 'gadget', 'rootUri': 'file:///pub/gadget-fixed'},
                ],
              }),
            );
        _datePubGet(project, pending: false);

        writeWatchosDartPluginRegistrant(project);
        await ensureReadyForWatchosTooling(project);
        expect(discoverWatchosSpmPlugins(project).single.defines, const <WatchosPluginDefine>[
          WatchosPluginDefine('GADGET_CAMERA', <String>['NSCameraUsageDescription']),
        ]);
      },
      overrides: <Type, Generator>{
        FileSystem: () => fileSystem,
        ProcessManager: () => FakeProcessManager.any(),
      },
    );

    testUsingContext(
      'after pub get, the build refuses a declaration that is still invalid',
      () async {
        final FlutterProject project = _app(fileSystem, <String, String>{
          'gadget': _definesYaml(<String, Object>{'GADGET-CAMERA': 'NSCameraUsageDescription'}),
        });
        fileSystem.file(_infoPlistPath).writeAsStringSync(_standaloneInfoPlist);
        _datePubGet(project, pending: true);
        await ensureReadyForWatchosTooling(project);

        // pub get leaves the same resolution in place.
        _datePubGet(project, pending: false);

        // The build's first discovery after pub get, before the kernel
        // compiles, and the tooling step it takes again before the native
        // compiles.
        expect(
          () => writeWatchosDartPluginRegistrant(project),
          throwsToolExit(message: '`GADGET-CAMERA` is not a C identifier.'),
        );
        await expectLater(
          ensureReadyForWatchosTooling(project),
          throwsToolExit(message: '`GADGET-CAMERA` is not a C identifier.'),
        );
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

    // A plugin without `defines` compiles as under a CLI that predates them:
    // no marker, so whatever it guards with the marker form stays in.
    testUsingContext(
      'gives each plugin its own macros, and no -D to one without defines',
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
          _clang('plain', const <String>[]),
          _libtool(<String>[_object('gadget'), _object('widget'), _object('plain')]),
        ]);

        await _build(project);

        expect(processManager, hasNoRemainingExpectations);
        // Read once for the whole build.
        expect(plistParser.reads, <String>[_infoPlistPath]);
        // -v has a line for every plugin.
        expect(
          testLogger.traceText,
          contains(
            'watchOS plugin gadget defines (1 of 1 on, from $_infoPlistPath): '
            'GADGET_CAMERA (NSCameraUsageDescription)\n',
          ),
        );
        expect(
          testLogger.traceText,
          contains(
            'watchOS plugin widget defines (1 of 2 on, from $_infoPlistPath): '
            'WIDGET_CAMERA (NSCameraUsageDescription)\n',
          ),
        );
        expect(
          testLogger.traceText,
          contains(
            'watchOS plugin plain declares no `defines`: its sources compile without '
            'FLUTTER_WATCHOS_PLUGIN_DEFINES.\n',
          ),
        );
        expect(forbiddenWordsIn(testLogger.traceText), isEmpty);
      },
      overrides: overrides(),
    );

    // The same macro name in two plugins is two macros: each plugin's is on
    // or off by its own keys, in its C sources and in its view sources.
    testUsingContext(
      "a macro name that two plugins declare follows each plugin's own keys, in both passes",
      () async {
        final FlutterProject project = _app(
          fileSystem,
          <String, String>{
            'gadget': _definesYaml(<String, Object>{'SHARED_CAMERA': 'NSCameraUsageDescription'}),
            'widget': _definesYaml(<String, Object>{'SHARED_CAMERA': 'WidgetCamera'}),
          },
          views: <String>{'gadget', 'widget'},
        );
        plistParser.setProperty('NSCameraUsageDescription', 'Scans a code.');
        processManager.addCommands(<FakeCommand>[
          _clang('gadget', <String>[_marker, '-DSHARED_CAMERA=1']),
          _clang('widget', <String>[_marker]),
          _swiftc('gadget', <String>[_swiftMarker, '-DSHARED_CAMERA']),
          _swiftc('widget', <String>[_swiftMarker]),
          _libtool(<String>[
            _object('gadget'),
            _object('widget'),
            '$_objDir/gadget_views.o',
            '$_objDir/widget_views.o',
          ]),
        ]);

        await _build(project);

        expect(processManager, hasNoRemainingExpectations);
        expect(
          testLogger.traceText,
          contains('watchOS plugin widget defines (0 of 1 on, from $_infoPlistPath): none\n'),
        );
      },
      overrides: overrides(),
    );

    // The marker goes only to a plugin that declares `defines`, so a
    // declaration the CLI does not see leaves the plugin as an older CLI
    // compiles it, rather than compiling out all it guards.
    testUsingContext(
      'a misspelled, misplaced or empty defines compiles the plugin as before, and -v says so',
      () async {
        final FlutterProject project = _app(
          fileSystem,
          <String, String>{
            'typo': '        define:\n          TYPO_CAMERA: NSCameraUsageDescription\n',
            'stray': '',
            'empty': '        defines: {}\n',
          },
          views: <String>{'typo'},
        );
        fileSystem
            .file('/pub/stray/pubspec.yaml')
            .writeAsStringSync(
              'name: stray\n'
              'flutter:\n'
              '  plugin:\n'
              '    defines:\n'
              '      STRAY_CAMERA: NSCameraUsageDescription\n'
              '    platforms:\n'
              '      watchos:\n'
              '        ffiPlugin: true\n',
            );
        plistParser.setProperty('NSCameraUsageDescription', 'Scans a code.');
        processManager.addCommands(<FakeCommand>[
          _clang('typo', const <String>[]),
          _clang('stray', const <String>[]),
          _clang('empty', const <String>[]),
          _swiftc('typo', const <String>[]),
          _libtool(<String>[
            _object('typo'),
            _object('stray'),
            _object('empty'),
            '$_objDir/typo_views.o',
          ]),
        ]);

        await _build(project);

        expect(processManager, hasNoRemainingExpectations);
        expect(plistParser.reads, isEmpty);
        for (final plugin in <String>['typo', 'stray', 'empty']) {
          expect(
            testLogger.traceText,
            contains(
              'watchOS plugin $plugin declares no `defines`: its sources compile without '
              'FLUTTER_WATCHOS_PLUGIN_DEFINES.\n',
            ),
          );
        }
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
    // with the new flags. The compiles write their objects, as the real
    // compilers do, so the second build finds the first one's in place and
    // newer than the sources: an up-to-date check that skipped a compile with
    // such an object, without counting the -D flags as an input, would leave
    // the second build's compiles unrun, and this test would fail.
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
          _clang('gadget', <String>[_marker, '-DGADGET_CAMERA=1'], fileSystem: fileSystem),
          _swiftc('gadget', <String>[_swiftMarker, '-DGADGET_CAMERA'], fileSystem: fileSystem),
          _libtool(<String>[_object('gadget'), '$_objDir/gadget_views.o']),
        ]);
        await _build(project);
        expect(processManager, hasNoRemainingExpectations);
        for (final (String object, String source) in <(String, String)>[
          (_object('gadget'), '/pub/gadget/watchos/Sources/gadget/gadget.c'),
          ('$_objDir/gadget_views.o', '/pub/gadget/watchos/Sources/gadget/View.swift'),
        ]) {
          final DateTime written = fileSystem.file(object).lastModifiedSync();
          expect(
            written.isAfter(fileSystem.file(source).lastModifiedSync()),
            isTrue,
            reason: object,
          );
        }

        plistParser
          ..replaceKey(_infoPlistPath, key: 'NSCameraUsageDescription')
          ..setProperty('GadgetSiri', true);
        processManager.addCommands(<FakeCommand>[
          _clang('gadget', <String>[_marker, '-DGADGET_SIRI=1'], fileSystem: fileSystem),
          _swiftc('gadget', <String>[_swiftMarker, '-DGADGET_SIRI'], fileSystem: fileSystem),
          _libtool(<String>[_object('gadget'), '$_objDir/gadget_views.o']),
        ]);
        await _build(project);

        expect(processManager, hasNoRemainingExpectations);
        expect(plistParser.reads, <String>[_infoPlistPath, _infoPlistPath]);
      },
      overrides: overrides(),
    );

    // Only the tooling step before `pub get` waits for it. The plugin compile
    // refuses whatever the package config's age, as under `--no-pub`.
    for (final pending in <bool>[false, true]) {
      final label = pending ? ', with pub get pending' : '';
      testUsingContext(
        'an invalid declaration stops the build before any command runs$label',
        () async {
          final FlutterProject project = _app(fileSystem, <String, String>{
            'plain': '',
            'gadget': _definesYaml(<String, Object>{'GADGET_CAMERA': 'NSCameraUsageDescription'}),
          });
          fileSystem
              .file('/pub/gadget/pubspec.yaml')
              .writeAsStringSync(
                _pluginPubspec('gadget', '        defines:\n          GADGET_CAMERA: 7\n'),
              );
          _datePubGet(project, pending: pending);

          await expectLater(
            _build(project),
            throwsToolExit(
              message:
                  'The watchOS plugin gadget has an invalid `defines` in /pub/gadget/pubspec.yaml',
            ),
          );
          // FakeProcessManager.empty() fails any command, so none ran.
          expect(processManager, hasNoRemainingExpectations);
          expect(plistParser.reads, isEmpty);
        },
        overrides: overrides(),
      );
    }

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
      // The warning says what the compile does, not what the plugin's guards
      // make of it: a plain `#if MACRO` guard leaves its code out.
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
            _clang('plain', const <String>[]),
            _libtool(<String>[_object('gadget'), _object('plain')]),
          ]);

          await _build(project);

          expect(processManager, hasNoRemainingExpectations);
          expect(plistParser.reads, exists ? <String>[_infoPlistPath] : isEmpty);
          expect(
            testLogger.warningText,
            "Could not read the watch app's Info.plist at $_infoPlistPath, so these plugins "
            'are compiled without their `defines` and without FLUTTER_WATCHOS_PLUGIN_DEFINES, '
            'as an older flutter-watchos compiles them: gadget. Code they guard with '
            '`#if !defined(FLUTTER_WATCHOS_PLUGIN_DEFINES) || MACRO` is compiled in.\n',
          );
          expect(forbiddenWordsIn(testLogger.warningText), isEmpty);
          expect(
            testLogger.traceText,
            contains(
              'watchOS plugin gadget defines (not applied, cannot read $_infoPlistPath): its '
              'sources compile without FLUTTER_WATCHOS_PLUGIN_DEFINES.\n',
            ),
          );
        },
        overrides: overrides(),
      );
    }

    testUsingContext('no plugin with defines, no Info.plist read, and no -D', () async {
      final FlutterProject project = _app(
        fileSystem,
        <String, String>{'plain': ''},
        views: <String>{'plain'},
      );
      processManager.addCommands(<FakeCommand>[
        _clang('plain', const <String>[]),
        _swiftc('plain', const <String>[]),
        _libtool(<String>[_object('plain'), '$_objDir/plain_views.o']),
      ]);

      await _build(project);

      expect(processManager, hasNoRemainingExpectations);
      expect(plistParser.reads, isEmpty);
    }, overrides: overrides());

    // Defines are read from watchos/Runner/Info.plist. An app whose project
    // builds with another Info.plist, and keeps this one, is told so, once a
    // build however many plugins declare `defines`.
    for (final (String label, String? Function() pbxproj, bool warns)
        in <(String, String? Function(), bool)>[
          ('a project that names Runner/Info.plist', _templatePbxproj, false),
          (
            'a project that names only other files',
            () => _templatePbxproj().replaceAll(
              'INFOPLIST_FILE = Runner/Info.plist;',
              'INFOPLIST_FILE = Runner/Info-Watch.plist;',
            ),
            true,
          ),
          ('no Xcode project', () => null, false),
        ]) {
      testUsingContext('with $label, ${warns ? 'warns once' : 'no warning'}', () async {
        final FlutterProject project = _app(fileSystem, <String, String>{
          'gadget': _definesYaml(<String, Object>{'GADGET_CAMERA': 'NSCameraUsageDescription'}),
          'widget': _definesYaml(<String, Object>{'WIDGET_CAMERA': 'NSCameraUsageDescription'}),
        });
        final String? text = pbxproj();
        if (text != null) {
          fileSystem.file('/app/watchos/Runner.xcodeproj/project.pbxproj')
            ..createSync(recursive: true)
            ..writeAsStringSync(text);
        }
        plistParser.setProperty('NSCameraUsageDescription', 'Scans a code.');
        processManager.addCommands(<FakeCommand>[
          _clang('gadget', <String>[_marker, '-DGADGET_CAMERA=1']),
          _clang('widget', <String>[_marker, '-DWIDGET_CAMERA=1']),
          _libtool(<String>[_object('gadget'), _object('widget')]),
        ]);

        await _build(project);

        expect(processManager, hasNoRemainingExpectations);
        expect(
          testLogger.warningText,
          warns
              ? "Plugin `defines` are read from $_infoPlistPath, but the watch app's Xcode "
                    'project sets INFOPLIST_FILE only to Runner/Info-Watch.plist, '
                    'HostApp/Info.plist: the plugins that declare them may not follow the keys '
                    'the app is built with.\n'
              : isEmpty,
        );
        expect(forbiddenWordsIn(testLogger.warningText), isEmpty);
      }, overrides: overrides());
    }

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
