// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// The watchOS deployment target: the named supported minimum, template
// default and required Xcode, the template and example project literals they
// must match, the MinimumOSVersion stamped into the staged frameworks, the
// project's own target as Xcode resolves it per configuration, the `-target`
// of every compile the CLI runs itself, and the build's stop on an Xcode
// older than the required one.

import 'dart:convert';
import 'dart:io' as io;

import 'package:file/memory.dart';
import 'package:flutter_tools/src/artifacts.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/base/version.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/build_system/build_system.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/ios/xcodeproj.dart';
import 'package:flutter_tools/src/macos/xcode.dart';
import 'package:flutter_tools/src/project.dart';
import 'package:flutter_watchos/build_targets/application.dart';
import 'package:flutter_watchos/build_targets/watchos_host_module.dart';
import 'package:flutter_watchos/watchos_artifacts.dart';
import 'package:flutter_watchos/watchos_build_info.dart';

import '../src/common.dart';
import '../src/context.dart';
import '../src/fake_process_manager.dart';
import '../src/fakes.dart';
import '../src/host_sources.dart';

const _simulatorDebug = WatchosBuildInfo(BuildInfo.debug, targetArch: 'arm64', simulator: true);
const _deviceDebug = WatchosBuildInfo(BuildInfo.debug, targetArch: 'arm64');
const _deviceProfile = WatchosBuildInfo(BuildInfo.profile, targetArch: 'arm64');
const _deviceRelease = WatchosBuildInfo(BuildInfo.release, targetArch: 'arm64');

/// The `buildSettings` block of each build configuration of the native target
/// [targetName] in [pbxproj], keyed by configuration name.
Map<String, String> _targetBuildSettings(String pbxproj, String targetName) {
  final RegExpMatch? list = RegExp(
    '/\\* Build configuration list for PBXNativeTarget "$targetName" \\*/ = \\{'
    r'\s*isa = XCConfigurationList;\s*buildConfigurations = \(([^)]*)\);',
  ).firstMatch(pbxproj);
  expect(list, isNotNull, reason: 'no configuration list for target $targetName');
  final settings = <String, String>{};
  for (final RegExpMatch entry in RegExp(r'(\w+) /\* (\w+) \*/').allMatches(list!.group(1)!)) {
    final RegExpMatch? block = RegExp(
      '\\t${entry.group(1)} /\\* ${entry.group(2)} \\*/ = \\{'
      r'\s*isa = XCBuildConfiguration;.*?buildSettings = \{(.*?)\n\t\t\t\};',
      dotAll: true,
    ).firstMatch(pbxproj);
    expect(block, isNotNull, reason: 'no configuration ${entry.group(1)} for $targetName');
    settings[entry.group(2)!] = block!.group(1)!;
  }
  return settings;
}

/// An artifacts double whose only job is to name an existing gen_snapshot.
class _FakeWatchosArtifacts extends WatchosArtifacts {
  _FakeWatchosArtifacts(FileSystem fileSystem, FakeProcessManager processManager)
    : super(
        fileSystem: fileSystem,
        cache: Cache.test(fileSystem: fileSystem, processManager: processManager),
        platform: FakePlatform(operatingSystem: 'macos'),
        operatingSystemUtils: FakeOperatingSystemUtils(),
      );

  @override
  String getGenSnapshotPath(BuildMode mode) => '/engine/gen_snapshot';
}

// Object ids of the build configurations in the template's project.pbxproj.
const _projectDebug = 'BB0000000000000000000001';
const _runnerDebug = 'BB0000000000000000000002';
const _projectRelease = 'BB0000000000000000000003';
const _runnerRelease = 'BB0000000000000000000004';
const _hostAppDebug = 'CC0000000000000000000001';
const _hostAppRelease = 'CC0000000000000000000002';

/// The template's project.pbxproj as `create` renders it.
String _renderedTemplatePbxproj() =>
    io.File(cliRootPath('templates/app/swift/watchos.tmpl/Runner.xcodeproj/project.pbxproj.tmpl'))
        .readAsStringSync()
        .replaceAll('{{projectName}}', 'app')
        .replaceAll('{{watchosDevelopmentTeam}}', '')
        .replaceAll('{{watchosIdentifier}}', 'com.example.app');

/// The range of configuration [id]'s `buildSettings` entries in [pbxproj].
(int, int) _settingsRange(String pbxproj, String id) {
  final int block = pbxproj.indexOf('\t\t$id /* ');
  expect(block, isNonNegative, reason: 'no configuration $id');
  final int start = pbxproj.indexOf('buildSettings = {\n', block) + 'buildSettings = {\n'.length;
  return (start, pbxproj.indexOf('\n\t\t\t};', start) + 1);
}

/// [pbxproj] with the `WATCHOS_DEPLOYMENT_TARGET` of configuration [id] set
/// to [value] exactly as written, or removed when [value] is null.
String _withTarget(String pbxproj, String id, String? value) {
  final (int start, int end) = _settingsRange(pbxproj, id);
  final String settings = pbxproj
      .substring(start, end)
      .split('\n')
      .where((String line) => !line.contains('WATCHOS_DEPLOYMENT_TARGET'))
      .join('\n');
  return pbxproj.replaceRange(
    start,
    end,
    '${value == null ? '' : '\t\t\t\tWATCHOS_DEPLOYMENT_TARGET = $value;\n'}$settings',
  );
}

/// [pbxproj] with configuration [id] based on the xcconfig [path], a new file
/// reference [fileRef] in the `Runner` group (or at the project root with
/// [sourceRoot]).
String _withBaseConfiguration(
  String pbxproj,
  String id,
  String fileRef,
  String path, {
  bool sourceRoot = false,
}) {
  final int block = pbxproj.indexOf('\t\t$id /* ');
  final int isa =
      pbxproj.indexOf('isa = XCBuildConfiguration;\n', block) +
      'isa = XCBuildConfiguration;\n'.length;
  final int settings = pbxproj.indexOf('buildSettings = {', isa);
  String result = pbxproj.replaceRange(
    isa,
    settings,
    '\t\t\tbaseConfigurationReference = $fileRef /* $path */;\n\t\t\t',
  );
  result = result.replaceFirst(
    '/* End PBXFileReference section */',
    '\t\t$fileRef /* $path */ = {isa = PBXFileReference; lastKnownFileType = text.xcconfig; '
        'path = $path; sourceTree = ${sourceRoot ? 'SOURCE_ROOT' : '"<group>"'}; };\n'
        '/* End PBXFileReference section */',
  );
  if (!sourceRoot) {
    result = result.replaceFirst(
      'AE0000000000000000000002 /* Runner */ = {\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n',
      'AE0000000000000000000002 /* Runner */ = {\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n'
          '\t\t\t\t$fileRef /* $path */,\n',
    );
  }
  return result;
}

void main() {
  group('named values', () {
    testWithoutContext('the supported minimum is watchOS 26.0', () {
      expect(kWatchosSupportedMinimum, Version(26, 0, null));
      expect(kWatchosSupportedMinimum.toString(), '26.0');
    });

    testWithoutContext('the template default is watchOS 26.0', () {
      expect(kWatchosTemplateDeploymentTarget, Version(26, 0, null));
      expect(kWatchosTemplateDeploymentTarget.toString(), '26.0');
    });

    testWithoutContext('the required Xcode is 26.0', () {
      expect(kWatchosXcodeRequiredVersion, Version(26, 0, null));
      expect(kWatchosXcodeRequiredVersion.toString(), '26.0');
    });

    testWithoutContext('the template default is not below the supported minimum', () {
      expect(kWatchosTemplateDeploymentTarget >= kWatchosSupportedMinimum, isTrue);
    });

    testWithoutContext('watchosTargetTriple spells the device and Simulator triples', () {
      expect(watchosTargetTriple(osVersion: '26.0', simulator: false), 'arm64-apple-watchos26.0');
      expect(
        watchosTargetTriple(osVersion: '27.0', simulator: true),
        'arm64-apple-watchos27.0-simulator',
      );
      expect(
        watchosTargetTriple(arch: 'arm64_32', osVersion: '26.0', simulator: false),
        'arm64_32-apple-watchos26.0',
      );
    });

    testWithoutContext('the project lookup falls back to the supported minimum', () {
      final fileSystem = MemoryFileSystem.test();
      expect(
        resolveWatchosDeploymentTarget(
          watchosProjectDir: fileSystem.directory('/missing/watchos'),
          configuration: 'Release',
        ),
        kWatchosSupportedMinimum.toString(),
      );
    });
  });

  // `create` writes the template, and the example is what the package's
  // users build first. Both must say exactly the named default, in the watch
  // Runner's Debug and Release, and nowhere else.
  for (final (String label, String path) in <(String, String)>[
    ('template', 'templates/app/swift/watchos.tmpl/Runner.xcodeproj/project.pbxproj.tmpl'),
    ('example', 'packages/flutter_watchos/example/watchos/Runner.xcodeproj/project.pbxproj'),
  ]) {
    group('$label project.pbxproj', () {
      late String pbxproj;

      setUpAll(() {
        pbxproj = io.File(cliRootPath(path)).readAsStringSync();
      });

      test('the watch Runner declares the template default in Debug and Release', () {
        final Map<String, String> runner = _targetBuildSettings(pbxproj, 'Runner');
        expect(runner.keys, unorderedEquals(<String>['Debug', 'Release']));
        for (final MapEntry<String, String> configuration in runner.entries) {
          expect(
            RegExp(
              r'WATCHOS_DEPLOYMENT_TARGET = [^;]*;',
            ).allMatches(configuration.value).map((RegExpMatch m) => m.group(0)),
            <String>['WATCHOS_DEPLOYMENT_TARGET = $kWatchosTemplateDeploymentTarget;'],
            reason: '${configuration.key} of the watch Runner',
          );
        }
      });

      test('no other configuration sets WATCHOS_DEPLOYMENT_TARGET', () {
        expect(RegExp('WATCHOS_DEPLOYMENT_TARGET').allMatches(pbxproj), hasLength(2));
      });

      // The HostApp container is an iOS target with its own minimum. It is
      // deliberately not tied to the watch's default.
      test('the HostApp container keeps IPHONEOS_DEPLOYMENT_TARGET = 26.0', () {
        final Map<String, String> hostApp = _targetBuildSettings(pbxproj, 'HostApp');
        expect(hostApp.keys, unorderedEquals(<String>['Debug', 'Release']));
        for (final MapEntry<String, String> configuration in hostApp.entries) {
          expect(
            configuration.value,
            contains('IPHONEOS_DEPLOYMENT_TARGET = 26.0;'),
            reason: '${configuration.key} of the HostApp container',
          );
          expect(configuration.value, isNot(contains('WATCHOS_DEPLOYMENT_TARGET')));
        }
      });
    });
  }

  group('staged frameworks', () {
    for (final buildInfo in <WatchosBuildInfo>[_simulatorDebug, _deviceRelease]) {
      testWithoutContext('declare the supported minimum (${buildInfo.sdkName})', () {
        final String plist = NativeWatchosBundle(
          buildInfo,
          'lib/main.dart',
        ).frameworkInfoPlist(executable: 'App', bundleId: 'dev.flutterwatch.App');
        expect(
          plist,
          contains('<key>MinimumOSVersion</key><string>$kWatchosSupportedMinimum</string>'),
        );
      });
    }
  });

  group('App.framework compile target', () {
    late MemoryFileSystem fileSystem;
    late FakeProcessManager processManager;

    setUp(() {
      fileSystem = MemoryFileSystem.test();
      processManager = FakeProcessManager.empty();
    });

    testWithoutContext('is the supported minimum on device and Simulator', () {
      expect(
        NativeWatchosBundle(_deviceRelease, 'lib/main.dart').appFrameworkTarget,
        'arm64-apple-watchos26.0',
      );
      expect(
        NativeWatchosBundle(_simulatorDebug, 'lib/main.dart').appFrameworkTarget,
        'arm64-apple-watchos26.0-simulator',
      );
    });

    for (final (WatchosBuildInfo buildInfo, String target) in <(WatchosBuildInfo, String)>[
      (_simulatorDebug, 'arm64-apple-watchos26.0-simulator'),
      (_deviceDebug, 'arm64-apple-watchos26.0'),
    ]) {
      testUsingContext(
        'the JIT stub links at $target',
        () async {
          final Directory watchosDir = fileSystem.directory('/app/watchos')
            ..createSync(recursive: true);
          processManager.addCommand(
            FakeCommand(
              command: <Pattern>[
                'xcrun',
                '-sdk',
                buildInfo.sdkName,
                'clang',
                '-target',
                target,
                '-dynamiclib',
                '-install_name',
                '@rpath/App.framework/App',
                '-o',
                '/app/watchos/Flutter/App.framework/App',
                RegExp(r'stub\.c$'),
              ],
            ),
          );

          await NativeWatchosBundle(buildInfo, 'lib/main.dart').buildJitStubAppDylib(watchosDir);

          expect(processManager, hasNoRemainingExpectations);
          expect(
            fileSystem.file('/app/watchos/Flutter/App.framework/Info.plist').readAsStringSync(),
            contains('<key>MinimumOSVersion</key><string>26.0</string>'),
          );
        },
        overrides: <Type, Generator>{
          FileSystem: () => fileSystem,
          ProcessManager: () => processManager,
        },
      );
    }

    testUsingContext(
      'the AOT dylib compiles and links at arm64-apple-watchos26.0',
      () async {
        Cache.flutterRoot = '/flutter';
        fileSystem.file('/engine/gen_snapshot').createSync(recursive: true);
        final Directory watchosDir = fileSystem.directory('/app/watchos')
          ..createSync(recursive: true);
        final environment = Environment.test(
          fileSystem.directory('/app'),
          outputDir: fileSystem.directory('/out'),
          fileSystem: fileSystem,
          logger: BufferLogger.test(),
          artifacts: Artifacts.test(),
          processManager: processManager,
        );
        final File dill = environment.buildDir.childFile('app.dill')..createSync(recursive: true);
        processManager.addCommands(<FakeCommand>[
          FakeCommand(
            command: NativeWatchosBundle.watchosGenSnapshotArgs(
              fileSystem: fileSystem,
              genSnapshotPath: '/engine/gen_snapshot',
              assemblyPath: '/out/aot/snapshot_assembly.S',
              kernelSnapshotPath: dill.path,
              defines: const <String, String>{},
            ),
          ),
          const FakeCommand(
            command: <String>[
              'xcrun',
              '-sdk',
              'watchos',
              'clang',
              '-target',
              'arm64-apple-watchos26.0',
              '-c',
              '/out/aot/snapshot_assembly.S',
              '-o',
              '/out/aot/snapshot_assembly.o',
            ],
          ),
          const FakeCommand(
            command: <String>[
              'xcrun',
              '-sdk',
              'watchos',
              'clang',
              '-target',
              'arm64-apple-watchos26.0',
              '-dynamiclib',
              '-install_name',
              '@rpath/App.framework/App',
              '-o',
              '/app/watchos/Flutter/App.framework/App',
              '/out/aot/snapshot_assembly.o',
            ],
          ),
        ]);

        await NativeWatchosBundle(_deviceRelease, 'lib/main.dart').buildAotAppDylib(
          FlutterProject.fromDirectory(fileSystem.directory('/app')),
          watchosDir,
          environment,
        );

        expect(processManager, hasNoRemainingExpectations);
        expect(
          fileSystem.file('/app/watchos/Flutter/App.framework/Info.plist').readAsStringSync(),
          contains('<key>MinimumOSVersion</key><string>26.0</string>'),
        );
      },
      overrides: <Type, Generator>{
        FileSystem: () => fileSystem,
        ProcessManager: () => processManager,
        Artifacts: () => _FakeWatchosArtifacts(fileSystem, FakeProcessManager.any()),
      },
    );
  });

  // Plugin sources compile at the app's own target, on both paths the CLI
  // runs itself: clang for C and Objective-C, swiftc for SwiftUI platform
  // views.
  group('plugin sources compile at the project target', () {
    late MemoryFileSystem fileSystem;
    late FakeProcessManager processManager;

    setUp(() {
      fileSystem = MemoryFileSystem.test();
      processManager = FakeProcessManager.empty();
    });

    /// An app whose watch target builds Debug at [debug] and Release at
    /// [release], with one watchOS plugin that ships a C source and a SwiftUI
    /// view source.
    FlutterProject appWithPlugin(String debug, String release) {
      final Directory app = fileSystem.directory('/app')..createSync();
      app.childFile('pubspec.yaml').writeAsStringSync('name: app\n');
      app.childFile('.dart_tool/package_config.json')
        ..createSync(recursive: true)
        ..writeAsStringSync(
          json.encode(<String, Object>{
            'configVersion': 2,
            'packages': <Map<String, String>>[
              <String, String>{'name': 'gadget', 'rootUri': 'file:///pub/gadget'},
            ],
          }),
        );
      app
          .childFile('.flutter-plugins-dependencies')
          .writeAsStringSync(
            json.encode(<String, Object>{
              'dependencyGraph': <Map<String, String>>[
                <String, String>{'name': 'gadget'},
              ],
            }),
          );
      app.childFile('watchos/Runner.xcodeproj/project.pbxproj')
        ..createSync(recursive: true)
        ..writeAsStringSync(
          _withTarget(
            _withTarget(_renderedTemplatePbxproj(), _runnerDebug, debug),
            _runnerRelease,
            release,
          ),
        );

      final Directory plugin = fileSystem.directory('/pub/gadget')..createSync(recursive: true);
      plugin.childFile('pubspec.yaml').writeAsStringSync('''
name: gadget
flutter:
  plugin:
    platforms:
      watchos:
        ffiPlugin: true
''');
      plugin.childFile('watchos/Package.swift')
        ..createSync(recursive: true)
        ..writeAsStringSync('let package = Package(name: "gadget")\n');
      plugin.childFile('watchos/Sources/gadget/gadget.c')
        ..createSync(recursive: true)
        ..writeAsStringSync('int gadget(void) { return 1; }\n');
      plugin
          .childFile('watchos/Sources/gadget/GadgetView.swift')
          .writeAsStringSync('import SwiftUI\n');
      return FlutterProject.fromDirectory(app);
    }

    for (final (String debug, String release, WatchosBuildInfo buildInfo, String triple)
        in <(String, String, WatchosBuildInfo, String)>[
          ('26.0', '26.0', _simulatorDebug, 'arm64-apple-watchos26.0-simulator'),
          ('26.0', '26.0', _deviceRelease, 'arm64-apple-watchos26.0'),
          ('27.0', '27.0', _simulatorDebug, 'arm64-apple-watchos27.0-simulator'),
          ('27.0', '27.0', _deviceRelease, 'arm64-apple-watchos27.0'),
          ('26.0', '27.0', _simulatorDebug, 'arm64-apple-watchos26.0-simulator'),
          ('26.0', '27.0', _deviceProfile, 'arm64-apple-watchos27.0'),
        ]) {
      testUsingContext(
        'Debug $debug, Release $release, ${buildInfo.buildInfo.mode.cliName} '
        '${buildInfo.sdkName}: $triple',
        () async {
          final FlutterProject project = appWithPlugin(debug, release);
          processManager.addCommands(<FakeCommand>[
            FakeCommand(
              command: <Pattern>[
                'xcrun',
                '-sdk',
                buildInfo.sdkName,
                'clang',
                '-target',
                triple,
                '-fobjc-arc',
                '-fmodules',
                '-c',
                '/pub/gadget/watchos/Sources/gadget/gadget.c',
                '-o',
                RegExp(r'\.o$'),
              ],
            ),
            FakeCommand(
              command: <Pattern>[
                'xcrun',
                '-sdk',
                buildInfo.sdkName,
                'swiftc',
                '-target',
                triple,
                '-parse-as-library',
                '-whole-module-optimization',
                '-module-name',
                'gadget_views',
                '-emit-object',
                '-o',
                RegExp(r'gadget_views\.o$'),
                RegExp(r'shim\.swift$'),
                '/pub/gadget/watchos/Sources/gadget/GadgetView.swift',
              ],
            ),
            FakeCommand(
              command: <Pattern>[
                'xcrun',
                '-sdk',
                buildInfo.sdkName,
                'libtool',
                '-static',
                '-o',
                '/app/watchos/Flutter/libflutter_watchos_plugins.a',
                RegExp(r'\.o$'),
                RegExp(r'gadget_views\.o$'),
              ],
            ),
          ]);

          await NativeWatchosBundle(
            buildInfo,
            'lib/main.dart',
          ).buildPluginStaticArchive(project, project.directory.childDirectory('watchos'));

          expect(processManager, hasNoRemainingExpectations);
        },
        overrides: <Type, Generator>{
          FileSystem: () => fileSystem,
          ProcessManager: () => processManager,
          Platform: () => FakePlatform(environment: <String, String>{}),
        },
      );
    }
  });

  // The target Xcode builds App.swift with, per configuration, in Xcode's
  // order. The fixtures start from the template as `create` renders it, plus
  // the xcconfigs a build leaves behind.
  group('resolveWatchosDeploymentTarget', () {
    late MemoryFileSystem fileSystem;

    setUp(() {
      fileSystem = MemoryFileSystem.test();
    });

    void writeFile(String path, String contents) {
      fileSystem.file(path)
        ..createSync(recursive: true)
        ..writeAsStringSync(contents);
    }

    /// Writes [pbxproj] and, unless [cliXcconfigs] is false, the three
    /// xcconfigs the CLI writes on every build.
    void writeProject(String pbxproj, {bool cliXcconfigs = true}) {
      writeFile('/app/watchos/Runner.xcodeproj/project.pbxproj', pbxproj);
      if (cliXcconfigs) {
        for (final (String name, String pods) in <(String, String)>[
          ('Debug', 'debug'),
          ('Release', 'release'),
        ]) {
          writeFile(
            '/app/watchos/Flutter/$name.xcconfig',
            '#include "Generated.xcconfig"\n'
                '#include? "Pods/Target Support Files/Pods-Runner/Pods-Runner.$pods.xcconfig"\n',
          );
        }
        writeFile('/app/watchos/Flutter/Generated.xcconfig', 'FLUTTER_BUILD_NAME=1.0.0\n');
      }
    }

    /// The Debug and Release results.
    (String, String) resolve([Map<String, String> environment = const <String, String>{}]) {
      String one(String configuration) => resolveWatchosDeploymentTarget(
        watchosProjectDir: fileSystem.directory('/app/watchos'),
        configuration: configuration,
        environment: environment,
      );
      return (one('Debug'), one('Release'));
    }

    /// The template with the watch Runner's values replaced.
    String runner(String? debug, String? release) => _withTarget(
      _withTarget(_renderedTemplatePbxproj(), _runnerDebug, debug),
      _runnerRelease,
      release,
    );

    testWithoutContext('the template gives 26.0 for Debug and Release', () {
      writeProject(_renderedTemplatePbxproj());
      expect(resolve(), ('26.0', '26.0'));
    });

    testWithoutContext('27.0 in the watch target gives 27.0', () {
      writeProject(runner('27.0', '27.0'));
      expect(resolve(), ('27.0', '27.0'));
    });

    testWithoutContext('Debug 26.0 and Release 27.0 stay apart', () {
      writeProject(runner('26.0', '27.0'));
      expect(resolve(), ('26.0', '27.0'));
    });

    testWithoutContext('a HostApp value is ignored', () {
      String pbxproj = runner(null, null);
      pbxproj = _withTarget(pbxproj, _hostAppDebug, '27.0');
      pbxproj = _withTarget(pbxproj, _hostAppRelease, '27.0');
      pbxproj = _withTarget(pbxproj, _projectDebug, '26.2');
      pbxproj = _withTarget(pbxproj, _projectRelease, '26.2');
      writeProject(pbxproj);
      expect(resolve(), ('26.2', '26.2'));
    });

    testWithoutContext('a value set only at project level is found', () {
      writeProject(
        _withTarget(
          _withTarget(runner(null, null), _projectDebug, '27.0'),
          _projectRelease,
          '27.0',
        ),
      );
      expect(resolve(), ('27.0', '27.0'));
    });

    // The first-match parse this replaces gave 26.0 for both; "the lowest
    // value in the watch target" would give 27.0 for Debug, newer than the
    // App.swift that imports the host module.
    testWithoutContext('Debug unset, Release 27.0 and project-level Debug 26.0', () {
      writeProject(_withTarget(runner(null, '27.0'), _projectDebug, '26.0'));
      expect(resolve(), ('26.0', '27.0'));
    });

    testWithoutContext('a value in the target xcconfig, through the CLI xcconfig #include?', () {
      writeProject(runner(null, null));
      writeFile(
        '/app/watchos/Flutter/Pods/Target Support Files/Pods-Runner/Pods-Runner.debug.xcconfig',
        'WATCHOS_DEPLOYMENT_TARGET = 27.0\n',
      );
      expect(resolve(), ('27.0', '26.0'));
    });

    testWithoutContext('a value in a user xcconfig, through its #include', () {
      writeProject(
        _withBaseConfiguration(
          runner(null, '26.0'),
          _runnerDebug,
          'EE0000000000000000000001',
          'Config.xcconfig',
        ),
      );
      writeFile('/app/watchos/Runner/Config.xcconfig', '#include "Shared.xcconfig"\n');
      writeFile(
        '/app/watchos/Runner/Shared.xcconfig',
        '// The watch minimum.\nWATCHOS_DEPLOYMENT_TARGET = 27.0 // not 26\n',
      );
      expect(resolve(), ('27.0', '26.0'));
    });

    testWithoutContext('a target value beats its xcconfig and the project level', () {
      writeProject(_withTarget(runner('26.0', '26.0'), _projectDebug, '27.0'));
      writeFile(
        '/app/watchos/Flutter/Pods/Target Support Files/Pods-Runner/Pods-Runner.debug.xcconfig',
        'WATCHOS_DEPLOYMENT_TARGET = 27.0\n',
      );
      expect(resolve(), ('26.0', '26.0'));
    });

    testWithoutContext('the target xcconfig beats the project level', () {
      writeProject(_withTarget(runner(null, null), _projectDebug, '27.0'));
      writeFile(
        '/app/watchos/Flutter/Pods/Target Support Files/Pods-Runner/Pods-Runner.debug.xcconfig',
        'WATCHOS_DEPLOYMENT_TARGET = 26.2\n',
      );
      expect(resolve().$1, '26.2');
    });

    testWithoutContext('a project-level xcconfig is the last level', () {
      writeProject(
        _withBaseConfiguration(
          runner(null, null),
          _projectRelease,
          'EE0000000000000000000002',
          'Project.xcconfig',
          sourceRoot: true,
        ),
      );
      writeFile('/app/watchos/Project.xcconfig', 'WATCHOS_DEPLOYMENT_TARGET = 27.0\n');
      expect(resolve(), ('26.0', '27.0'));
    });

    testWithoutContext('XCODE_XCCONFIG_FILE with a value beats the target', () {
      writeProject(runner('26.0', '26.0'));
      writeFile(
        '/tmp/unsigned.xcconfig',
        'CODE_SIGNING_ALLOWED = NO\nWATCHOS_DEPLOYMENT_TARGET = 27.0\n',
      );
      expect(resolve(<String, String>{'XCODE_XCCONFIG_FILE': '/tmp/unsigned.xcconfig'}), (
        '27.0',
        '27.0',
      ));
    });

    testWithoutContext('a relative XCODE_XCCONFIG_FILE is read from the watchos directory', () {
      writeProject(runner('26.0', '26.0'));
      writeFile('/app/watchos/override.xcconfig', 'WATCHOS_DEPLOYMENT_TARGET = 27.0\n');
      expect(resolve(<String, String>{'XCODE_XCCONFIG_FILE': 'override.xcconfig'}), (
        '27.0',
        '27.0',
      ));
    });

    testWithoutContext('an XCODE_XCCONFIG_FILE without the setting passes on to the target', () {
      writeProject(runner('26.0', '27.0'));
      writeFile('/tmp/unsigned.xcconfig', 'CODE_SIGNING_ALLOWED = NO\n');
      expect(resolve(<String, String>{'XCODE_XCCONFIG_FILE': '/tmp/unsigned.xcconfig'}), (
        '26.0',
        '27.0',
      ));
    });

    testWithoutContext(r'$(inherited) passes on to the next level', () {
      writeProject(_withTarget(runner(r'"$(inherited)"', '26.0'), _projectDebug, '27.0'));
      writeFile(
        '/tmp/override.xcconfig',
        r'WATCHOS_DEPLOYMENT_TARGET = $(inherited)'
            '\n',
      );
      expect(resolve(), ('27.0', '26.0'));
      expect(resolve(<String, String>{'XCODE_XCCONFIG_FILE': '/tmp/override.xcconfig'}), (
        '27.0',
        '26.0',
      ));
    });

    testWithoutContext(r'in an xcconfig, $(inherited) reaches the earlier assignment', () {
      writeProject(runner('26.0', '26.0'));
      writeFile(
        '/tmp/override.xcconfig',
        'WATCHOS_DEPLOYMENT_TARGET = 27.0\n'
            r'WATCHOS_DEPLOYMENT_TARGET = $(inherited)'
            '\n',
      );
      expect(resolve(<String, String>{'XCODE_XCCONFIG_FILE': '/tmp/override.xcconfig'}).$1, '27.0');
    });

    testWithoutContext('a quoted version is a value', () {
      writeProject(runner('"27.0"', null));
      writeFile(
        '/app/watchos/Flutter/Pods/Target Support Files/Pods-Runner/Pods-Runner.release.xcconfig',
        'WATCHOS_DEPLOYMENT_TARGET = "27.0";\n',
      );
      expect(resolve(), ('27.0', '27.0'));
    });

    testWithoutContext('a variable reference ends the lookup with the supported minimum', () {
      writeProject(_withTarget(runner(r'"$(MY_TARGET)"', null), _projectDebug, '27.0'));
      writeFile(
        '/app/watchos/Flutter/Pods/Target Support Files/Pods-Runner/Pods-Runner.release.xcconfig',
        r'WATCHOS_DEPLOYMENT_TARGET = ${MY_TARGET}'
            '\n',
      );
      expect(resolve(), ('26.0', '26.0'));
    });

    testWithoutContext('a conditional assignment ends the lookup with the supported minimum', () {
      writeProject(
        _withTarget(runner(null, null), _projectDebug, '27.0').replaceFirst(
          'WATCHOS_DEPLOYMENT_TARGET = 27.0;',
          '"WATCHOS_DEPLOYMENT_TARGET[sdk=watchos*]" = 27.0;',
        ),
      );
      writeFile(
        '/app/watchos/Flutter/Pods/Target Support Files/Pods-Runner/Pods-Runner.release.xcconfig',
        'WATCHOS_DEPLOYMENT_TARGET[sdk=watchos*] = 27.0\n',
      );
      expect(resolve(), ('26.0', '26.0'));
    });

    testWithoutContext('the CLI xcconfigs missing: the lookup goes on to the project level', () {
      writeProject(
        _withTarget(
          _withTarget(runner(null, null), _projectDebug, '27.0'),
          _projectRelease,
          '27.0',
        ),
        cliXcconfigs: false,
      );
      expect(resolve(), ('27.0', '27.0'));
    });

    testWithoutContext('the CLI xcconfigs set nothing themselves', () {
      writeProject(runner(null, null));
      writeFile(
        '/app/watchos/Flutter/Generated.xcconfig',
        'FLUTTER_BUILD_NAME=1.0.0\nWATCHOS_DEPLOYMENT_TARGET=27.0\n',
      );
      writeFile(
        '/app/watchos/Flutter/Release.xcconfig',
        '#include "Generated.xcconfig"\nWATCHOS_DEPLOYMENT_TARGET = 27.0\n',
      );
      expect(resolve(), ('26.0', '26.0'));
    });

    testWithoutContext('a user xcconfig the target names but that is missing', () {
      writeProject(
        _withTarget(
          _withBaseConfiguration(
            runner(null, null),
            _runnerDebug,
            'EE0000000000000000000001',
            'Config.xcconfig',
          ),
          _projectDebug,
          '27.0',
        ),
      );
      expect(resolve().$1, '26.0');
    });

    testWithoutContext('a missing #include ends the lookup, a missing #include? is empty', () {
      writeProject(
        _withTarget(
          _withBaseConfiguration(
            runner(null, null),
            _runnerDebug,
            'EE0000000000000000000001',
            'Config.xcconfig',
          ),
          _projectDebug,
          '27.0',
        ),
      );
      writeFile('/app/watchos/Runner/Config.xcconfig', '#include "Missing.xcconfig"\n');
      expect(resolve().$1, '26.0');
      writeFile('/app/watchos/Runner/Config.xcconfig', '#include? "Missing.xcconfig"\n');
      expect(resolve().$1, '27.0');
    });

    testWithoutContext('no value anywhere gives the supported minimum', () {
      writeProject(runner(null, null));
      expect(resolve(), ('26.0', '26.0'));
    });

    testWithoutContext('a missing project.pbxproj gives the supported minimum', () {
      expect(resolve(), ('26.0', '26.0'));
    });

    testWithoutContext('an unparseable project.pbxproj gives the supported minimum', () {
      writeProject('WATCHOS_DEPLOYMENT_TARGET = 27.0;\n{ objects = (');
      expect(resolve(), ('26.0', '26.0'));
      writeProject(runner('27.0', '27.0').replaceAll('name = Runner;', 'name = Watch;'));
      expect(resolve(), ('26.0', '26.0'));
    });

    testWithoutContext('a configuration the target does not have gives the supported minimum', () {
      writeProject(runner('27.0', '27.0'));
      expect(
        resolveWatchosDeploymentTarget(
          watchosProjectDir: fileSystem.directory('/app/watchos'),
          configuration: 'Profile',
        ),
        '26.0',
      );
    });
  });

  // The host module follows the configuration being built, and leaves out
  // arm64_32 from 27.0.
  group('host module per configuration', () {
    late MemoryFileSystem fileSystem;
    late FakeProcessManager processManager;

    setUp(() {
      fileSystem = MemoryFileSystem.test();
      processManager = FakeProcessManager.empty();
    });

    /// An app whose watch target builds Debug at [debug] and Release at
    /// [release], and a CLI checkout with two host sources.
    FlutterProject app(String debug, String release) {
      Cache.flutterRoot = '/cli/flutter';
      for (final name in <String>[
        'FlutterHostView.swift',
        'FlutterRunner.swift',
        'flutter_watchos_host.h',
        'module.modulemap',
      ]) {
        fileSystem.file('/cli/host/$name')
          ..createSync(recursive: true)
          ..writeAsStringSync('// $name\n');
      }
      final Directory app = fileSystem.directory('/app')..createSync();
      app.childFile('pubspec.yaml').writeAsStringSync('name: app\n');
      app.childFile('.dart_tool/package_config.json')
        ..createSync(recursive: true)
        ..writeAsStringSync('{"configVersion": 2, "packages": []}');
      app.childFile('watchos/Runner.xcodeproj/project.pbxproj')
        ..createSync(recursive: true)
        ..writeAsStringSync(
          _withTarget(
            _withTarget(_renderedTemplatePbxproj(), _runnerDebug, debug),
            _runnerRelease,
            release,
          ),
        );
      return FlutterProject.fromDirectory(app);
    }

    FakeCommand swiftc(WatchosBuildInfo buildInfo, String arch, String deploymentTarget) {
      return FakeCommand(
        command: hostModuleSwiftcArgs(
          sdkName: buildInfo.sdkName,
          simulator: buildInfo.simulator,
          arch: arch,
          deploymentTarget: deploymentTarget,
          moduleOutputPath:
              '/app/watchos/Flutter/FlutterWatchOS.swiftmodule/'
              '${swiftmoduleFileName(arch: arch, simulator: buildInfo.simulator)}',
          objectOutputPath: '/app/watchos/Flutter/.host_build/FlutterWatchOS_$arch.o',
          cModuleSearchPath: '/app/watchos/Flutter',
          sources: <String>['/cli/host/FlutterHostView.swift', '/cli/host/FlutterRunner.swift'],
          enableVmBridge: buildInfo.buildInfo.mode != BuildMode.release,
          optimize: buildInfo.buildInfo.mode != BuildMode.debug,
          enableStatusBarSpi: false,
        ),
      );
    }

    FakeCommand libtool(WatchosBuildInfo buildInfo, String input) => FakeCommand(
      command: <String>[
        'xcrun',
        '-sdk',
        buildInfo.sdkName,
        'libtool',
        '-static',
        '-o',
        '/app/watchos/Flutter/libFlutterWatchOSHost.a',
        '/app/watchos/Flutter/.host_build/$input',
      ],
    );

    Future<void> build(FlutterProject project, WatchosBuildInfo buildInfo) async {
      await NativeWatchosBundle(
        buildInfo,
        'lib/main.dart',
      ).buildHostModule(project, project.directory.childDirectory('watchos'));
    }

    testUsingContext(
      'a Simulator debug build of a Debug 26.0 / Release 27.0 app uses 26.0',
      () async {
        final FlutterProject project = app('26.0', '27.0');
        processManager.addCommands(<FakeCommand>[
          swiftc(_simulatorDebug, 'arm64', '26.0'),
          libtool(_simulatorDebug, 'FlutterWatchOS_arm64.o'),
        ]);
        await build(project, _simulatorDebug);
        expect(processManager, hasNoRemainingExpectations);
      },
      overrides: <Type, Generator>{
        FileSystem: () => fileSystem,
        ProcessManager: () => processManager,
        Platform: () => FakePlatform(environment: <String, String>{}),
      },
    );

    // FakeProcessManager.empty() fails on any command it was not given, so
    // an arm64_32 compile here fails the test.
    testUsingContext(
      'a device profile build of the same app uses 27.0, arm64 only',
      () async {
        final FlutterProject project = app('26.0', '27.0');
        processManager.addCommands(<FakeCommand>[
          swiftc(_deviceProfile, 'arm64', '27.0'),
          libtool(_deviceProfile, 'FlutterWatchOS_arm64.o'),
        ]);
        await build(project, _deviceProfile);
        expect(processManager, hasNoRemainingExpectations);
      },
      overrides: <Type, Generator>{
        FileSystem: () => fileSystem,
        ProcessManager: () => processManager,
        Platform: () => FakePlatform(environment: <String, String>{}),
      },
    );

    testUsingContext(
      'a device release build at 26.0 compiles arm64 and arm64_32',
      () async {
        final FlutterProject project = app('26.0', '26.0');
        processManager.addCommands(<FakeCommand>[
          swiftc(_deviceRelease, 'arm64', '26.0'),
          swiftc(_deviceRelease, 'arm64_32', '26.0'),
          const FakeCommand(
            command: <String>[
              'xcrun',
              'lipo',
              '-create',
              '/app/watchos/Flutter/.host_build/FlutterWatchOS_arm64.o',
              '/app/watchos/Flutter/.host_build/FlutterWatchOS_arm64_32.o',
              '-output',
              '/app/watchos/Flutter/.host_build/FlutterWatchOS.o',
            ],
          ),
          libtool(_deviceRelease, 'FlutterWatchOS.o'),
        ]);
        await build(project, _deviceRelease);
        expect(processManager, hasNoRemainingExpectations);
      },
      overrides: <Type, Generator>{
        FileSystem: () => fileSystem,
        ProcessManager: () => processManager,
        Platform: () => FakePlatform(environment: <String, String>{}),
      },
    );

    testUsingContext(
      'XCODE_XCCONFIG_FILE in the environment sets the target',
      () async {
        final FlutterProject project = app('26.0', '26.0');
        fileSystem.file('/tmp/unsigned.xcconfig')
          ..createSync(recursive: true)
          ..writeAsStringSync('WATCHOS_DEPLOYMENT_TARGET = 27.0\n');
        processManager.addCommands(<FakeCommand>[
          swiftc(_deviceRelease, 'arm64', '27.0'),
          libtool(_deviceRelease, 'FlutterWatchOS_arm64.o'),
        ]);
        await build(project, _deviceRelease);
        expect(processManager, hasNoRemainingExpectations);
      },
      overrides: <Type, Generator>{
        FileSystem: () => fileSystem,
        ProcessManager: () => processManager,
        Platform: () => FakePlatform(
          environment: <String, String>{'XCODE_XCCONFIG_FILE': '/tmp/unsigned.xcconfig'},
        ),
      },
    );
  });

  // A known Xcode older than 26.0 stops the build before anything native is
  // compiled; 26.0 or later, or an unknown version, goes on.
  group('the build on an old Xcode', () {
    Xcode xcode(Version? version) => Xcode.test(
      processManager: FakeProcessManager.any(),
      xcodeProjectInterpreter: XcodeProjectInterpreter.test(
        processManager: FakeProcessManager.any(),
        version: version,
      ),
    );

    testWithoutContext('Xcode 16.4 stops, naming both versions', () {
      expect(
        () => checkWatchosXcodeVersion(xcode(const Version.withText(16, 4, 0, '16.4'))),
        throwsToolExit(message: 'requires Xcode 26.0 or later; found Xcode 16.4.'),
      );
    });

    testWithoutContext('26.0 and later, an unknown version and no Xcode go on', () {
      for (final version in <Version?>[
        const Version.withText(26, 0, 0, '26.0'),
        const Version.withText(26, 0, 1, '26.0.1'),
        const Version.withText(27, 0, 0, '27.0'),
        null,
      ]) {
        checkWatchosXcodeVersion(xcode(version));
      }
      checkWatchosXcodeVersion(null);
    });

    late MemoryFileSystem fileSystem;
    late FakeProcessManager processManager;

    setUp(() {
      fileSystem = MemoryFileSystem.test();
      processManager = FakeProcessManager.empty();
    });

    Future<void> build() => NativeWatchosBundle(_deviceRelease, 'lib/main.dart').build(
      Environment.test(
        fileSystem.currentDirectory,
        fileSystem: fileSystem,
        logger: BufferLogger.test(),
        artifacts: Artifacts.test(),
        processManager: processManager,
      ),
    );

    // The stop comes first: no watchos/ directory here, so a build that went
    // on would stop on that instead, and FakeProcessManager.empty() fails any
    // process it is asked to run.
    testUsingContext(
      'build watchos stops on Xcode 16.4 before running any process',
      () async {
        await expectLater(
          build(),
          throwsToolExit(message: 'requires Xcode 26.0 or later; found Xcode 16.4.'),
        );
        expect(processManager, hasNoRemainingExpectations);
      },
      overrides: <Type, Generator>{
        FileSystem: () => fileSystem,
        ProcessManager: () => processManager,
        Xcode: () => xcode(const Version.withText(16, 4, 0, '16.4')),
      },
    );

    for (final version in <Version?>[const Version.withText(26, 0, 0, '26.0'), null]) {
      testUsingContext(
        'build watchos goes on with ${version == null ? 'an unknown Xcode' : 'Xcode $version'}',
        () async {
          await expectLater(build(), throwsToolExit(message: 'Missing watchOS project directory'));
        },
        overrides: <Type, Generator>{
          FileSystem: () => fileSystem,
          ProcessManager: () => processManager,
          Xcode: () => xcode(version),
        },
      );
    }
  });
}
