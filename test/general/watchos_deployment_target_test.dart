// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// The watchOS deployment target in one place (spec 0002, criteria 11 and 17):
// the named supported minimum and template default, the template and example
// project literals they must match, the MinimumOSVersion stamped into the
// staged frameworks, and the `-target` of every compile the CLI runs itself.

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

    testWithoutContext('the project parse falls back to the supported minimum', () {
      final fileSystem = MemoryFileSystem.test();
      expect(
        parseWatchosDeploymentTarget(fileSystem.file('/missing/project.pbxproj')),
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
      // deliberately not tied to the watch's default (spec 0002, P1-E).
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

  // Plugin sources compile at the app's own target (spec 0002, P1-B (a)), on
  // both paths the CLI runs itself: clang for C and Objective-C, swiftc for
  // SwiftUI platform views.
  group('plugin sources compile at the project target', () {
    late MemoryFileSystem fileSystem;
    late FakeProcessManager processManager;

    setUp(() {
      fileSystem = MemoryFileSystem.test();
      processManager = FakeProcessManager.empty();
    });

    /// An app at [deploymentTarget] with one watchOS plugin that ships a C
    /// source and a SwiftUI view source.
    FlutterProject appWithPlugin(String deploymentTarget) {
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
        ..writeAsStringSync('WATCHOS_DEPLOYMENT_TARGET = $deploymentTarget;\n');

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

    for (final (String deploymentTarget, WatchosBuildInfo buildInfo, String triple)
        in <(String, WatchosBuildInfo, String)>[
          ('26.0', _simulatorDebug, 'arm64-apple-watchos26.0-simulator'),
          ('26.0', _deviceRelease, 'arm64-apple-watchos26.0'),
          ('27.0', _simulatorDebug, 'arm64-apple-watchos27.0-simulator'),
          ('27.0', _deviceRelease, 'arm64-apple-watchos27.0'),
        ]) {
      testUsingContext(
        'at $deploymentTarget, ${buildInfo.sdkName}: $triple',
        () async {
          final FlutterProject project = appWithPlugin(deploymentTarget);
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
        },
      );
    }
  });
}
