// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_watchos/plugin_porting/scaffolder.dart';
import 'package:flutter_watchos/plugin_porting/source_analyzer.dart';

import '../src/common.dart';

void main() {
  late MemoryFileSystem fs;

  setUp(() {
    fs = MemoryFileSystem.test();
  });

  group('SourceAnalyzer', () {
    testWithoutContext('reads a federated iOS plugin pubspec', () {
      final Directory dir = _createIosPlugin(fs, name: 'gadget_ios');

      final analyzer = SourceAnalyzer(fileSystem: fs);
      final PluginSource source = analyzer.analyze(dir);

      expect(source.packageName, 'gadget_ios');
      expect(source.basePackageName, 'gadget');
      expect(source.outputPackageName, 'gadget_watchos');
      expect(source.sourcePlatform, 'ios');
      expect(source.pluginClass, 'GadgetPlugin');
      expect(source.dartPluginClass, 'GadgetIOS');
      expect(source.platformInterfacePackage, 'gadget_platform_interface');
      expect(source.sourceLanguage, SourceLanguage.swift);
    });

    testWithoutContext('strips _foundation suffix on shared iOS/macOS packages', () {
      final Directory dir = _createIosPlugin(fs, name: 'prefsbox_foundation');

      final PluginSource source = SourceAnalyzer(fileSystem: fs).analyze(dir);

      expect(source.basePackageName, 'prefsbox');
      expect(source.outputPackageName, 'prefsbox_watchos');
    });

    testWithoutContext('rejects pure-Dart plugins with no native impl', () {
      final Directory dir = fs.directory('/p')..createSync();
      dir.childFile('pubspec.yaml').writeAsStringSync('''
name: my_pure_dart_plugin
flutter:
  plugin:
    platforms:
      web:
        pluginClass: MyPlugin
''');

      expect(
        () => SourceAnalyzer(fileSystem: fs).analyze(dir),
        throwsA(
          isA<PluginSourceError>().having(
            (PluginSourceError e) => e.message,
            'message',
            contains('neither an `ios` nor a `macos`'),
          ),
        ),
      );
    });

    testWithoutContext('rejects packages already targeting watchOS', () {
      final Directory dir = fs.directory('/p')..createSync();
      dir.childFile('pubspec.yaml').writeAsStringSync('name: foo_watchos\n');

      expect(
        () => SourceAnalyzer(fileSystem: fs).analyze(dir),
        throwsA(
          isA<PluginSourceError>().having(
            (PluginSourceError e) => e.message,
            'message',
            contains('already targets watchOS'),
          ),
        ),
      );
    });

    testWithoutContext('refuses missing pubspec', () {
      final Directory dir = fs.directory('/p')..createSync();

      expect(
        () => SourceAnalyzer(fileSystem: fs).analyze(dir),
        throwsA(isA<PluginSourceError>()),
      );
    });

    testWithoutContext('detects Objective-C sources', () {
      final Directory dir = _createIosPlugin(fs, name: 'audio_session', objc: true);

      final PluginSource source = SourceAnalyzer(fileSystem: fs).analyze(dir);

      expect(source.sourceLanguage, SourceLanguage.objc);
    });

    testWithoutContext('falls back to macOS when iOS is missing and prefer=ios', () {
      final Directory dir = fs.directory('/p')..createSync();
      dir.childFile('pubspec.yaml').writeAsStringSync('''
name: widgetbox_macos
flutter:
  plugin:
    platforms:
      macos:
        pluginClass: WidgetboxPlugin
        dartPluginClass: WidgetboxMacOS
''');
      dir.childDirectory('macos').childDirectory('Classes').createSync(recursive: true);
      dir.childDirectory('macos').childDirectory('Classes').childFile('WidgetboxPlugin.swift').writeAsStringSync('// stub');

      final warnings = <String>[];
      final PluginSource source = SourceAnalyzer(
        fileSystem: fs,
        warningSink: warnings.add,
      ).analyze(dir);

      expect(source.sourcePlatform, 'macos');
      expect(warnings.single, contains('no iOS implementation'));
    });
  });

  group('Scaffolder (FFI)', () {
    testWithoutContext('writes a complete FFI package scaffold', () {
      final Directory sourceDir = _createIosPlugin(fs, name: 'gadget_ios');
      final PluginSource source = SourceAnalyzer(fileSystem: fs).analyze(sourceDir);
      final Directory outputDir = fs.directory('/out/gadget_watchos');

      final scaffolder = Scaffolder(
        fileSystem: fs,
        logger: BufferLogger.test(),
        licenseHolder: 'Test Holder',
      );
      final ScaffoldResult result =
          scaffolder.scaffold(source: source, outputDirectory: outputDir);
      expect(result.dryRun, isFalse);

      // Pubspec declares an FFI plugin — no pluginClass, no method channel.
      final String pubspec = outputDir.childFile('pubspec.yaml').readAsStringSync();
      expect(pubspec, contains('name: gadget_watchos'));
      expect(pubspec, contains('ffiPlugin: true'));
      expect(pubspec, contains('dartPluginClass: GadgetWatchos'));
      expect(pubspec, contains('implements: gadget'));
      expect(pubspec, contains('ffiSymbols:'));
      expect(pubspec, contains('- gadget_watchos_example'));
      expect(pubspec, contains('ffi: ^2.1.0'));
      // The source's own interface constraint is carried over verbatim.
      expect(pubspec, contains('gadget_platform_interface: ^2.4.0'));
      expect(pubspec, isNot(contains('pluginClass:')));

      // A C stub (.h + .m), not copied Swift/ObjC source.
      final Directory classes =
          outputDir.childDirectory('watchos').childDirectory('Classes');
      final String h = classes.childFile('gadget_watchos_ffi.h').readAsStringSync();
      final String m = classes.childFile('gadget_watchos_ffi.m').readAsStringSync();
      expect(h, contains('const char* gadget_watchos_example(void);'));
      expect(h, contains('__attribute__((visibility("default")))'));
      expect(m, contains('#import <WatchKit/WatchKit.h>'));
      expect(m, contains('gadget_watchos_example(void)'));
      // The source plugin's own Swift is NOT copied.
      expect(classes.childFile('GadgetPlugin.swift').existsSync(), isFalse);
      // No CocoaPods podspec — FFI uses Package.swift only.
      expect(
        outputDir.childDirectory('watchos').childFile('gadget_watchos.podspec').existsSync(),
        isFalse,
      );

      // Package.swift is an FFI manifest (watchOS target, no FlutterFramework).
      final String pkg =
          outputDir.childDirectory('watchos').childFile('Package.swift').readAsStringSync();
      expect(pkg, contains('.watchOS("7.0")'));
      expect(pkg, contains('path: "Classes"'));
      expect(pkg, contains('.linkedFramework("WatchKit")'));
      expect(pkg, isNot(contains('FlutterFramework')));

      // Dart entry: a compiling scaffold with FFI bindings + registerWith,
      // and the federated wiring shown as a TODO (the interface class name
      // can't be guessed reliably, so it must not be a hard compile error).
      final String dartEntry =
          outputDir.childDirectory('lib').childFile('gadget_watchos.dart').readAsStringSync();
      expect(dartEntry, contains('class GadgetWatchos {'));
      expect(dartEntry, contains('class GadgetWatchosBindings {'));
      expect(dartEntry, contains('DynamicLibrary.process()'));
      expect(dartEntry, contains('static void registerWith()'));
      expect(dartEntry, contains('gadget_watchos_example'));
      // The scaffold compiles: the guessed platform-interface class appears
      // only inside the TODO comment, never as a real `extends`.
      expect(dartEntry, contains('// TODO(porter)'));
      expect(dartEntry, contains('class GadgetWatchos {'));
      expect(dartEntry, isNot(contains('\nclass GadgetWatchos extends')));

      // Standard package files.
      expect(outputDir.childDirectory('test').childFile('gadget_watchos_test.dart').existsSync(), isTrue);
      expect(outputDir.childFile('README.md').existsSync(), isTrue);
      expect(outputDir.childFile('CHANGELOG.md').existsSync(), isTrue);
      expect(outputDir.childFile('analysis_options.yaml').existsSync(), isTrue);
      expect(outputDir.childFile('.gitignore').existsSync(), isTrue);
    });

    testWithoutContext('--dry-run does not write any files', () {
      final Directory sourceDir = _createIosPlugin(fs, name: 'gadget_ios');
      final PluginSource source = SourceAnalyzer(fileSystem: fs).analyze(sourceDir);
      final Directory outputDir = fs.directory('/out/gadget_watchos');

      final ScaffoldResult result = Scaffolder(
        fileSystem: fs,
        logger: BufferLogger.test(),
        licenseHolder: 'Test',
      ).scaffold(source: source, outputDirectory: outputDir, dryRun: true);

      expect(result.dryRun, isTrue);
      expect(result.writtenPaths, isNotEmpty);
      expect(outputDir.existsSync(), isFalse);
    });

    testWithoutContext('refuses to overwrite without --force', () {
      final Directory sourceDir = _createIosPlugin(fs, name: 'gadget_ios');
      final PluginSource source = SourceAnalyzer(fileSystem: fs).analyze(sourceDir);
      final Directory outputDir = fs.directory('/out/gadget_watchos')..createSync(recursive: true);
      outputDir.childFile('preexisting.txt').writeAsStringSync('do not touch');

      expect(
        () => Scaffolder(
          fileSystem: fs,
          logger: BufferLogger.test(),
          licenseHolder: 'Test',
        ).scaffold(source: source, outputDirectory: outputDir),
        throwsA(isA<ScaffoldError>().having(
          (ScaffoldError e) => e.message,
          'message',
          contains('Output directory already exists'),
        )),
      );
      expect(outputDir.childFile('preexisting.txt').existsSync(), isTrue);
    });

    testWithoutContext('--force overwrites the output directory', () {
      final Directory sourceDir = _createIosPlugin(fs, name: 'gadget_ios');
      final PluginSource source = SourceAnalyzer(fileSystem: fs).analyze(sourceDir);
      final Directory outputDir = fs.directory('/out/gadget_watchos')..createSync(recursive: true);
      outputDir.childFile('preexisting.txt').writeAsStringSync('overwrite me');

      Scaffolder(
        fileSystem: fs,
        logger: BufferLogger.test(),
        licenseHolder: 'Test',
      ).scaffold(source: source, outputDirectory: outputDir, overwrite: true);

      expect(outputDir.childFile('preexisting.txt').existsSync(), isFalse);
      expect(outputDir.childFile('pubspec.yaml').existsSync(), isTrue);
    });

    testWithoutContext('--no-report suppresses PORTING_REPORT.md', () {
      final Directory sourceDir = _createIosPlugin(fs, name: 'gadget_ios');
      final PluginSource source = SourceAnalyzer(fileSystem: fs).analyze(sourceDir);
      final Directory outputDir = fs.directory('/out/gadget_watchos');

      final ScaffoldResult result = Scaffolder(
        fileSystem: fs,
        logger: BufferLogger.test(),
        licenseHolder: 'Test',
      ).scaffold(source: source, outputDirectory: outputDir, emitReport: false);

      expect(result.reportPath, isNull);
      expect(outputDir.childFile('PORTING_REPORT.md').existsSync(), isFalse);
    });

    testWithoutContext('report lists the source APIs and their watchOS status', () {
      // A source that uses one unsupported API (WebKit) and one that is
      // available-but-different (CoreLocation).
      final Directory dir = fs.directory('/p')..createSync();
      dir.childFile('pubspec.yaml').writeAsStringSync('''
name: gizmo_ios
description: iOS implementation of gizmo.
version: 1.0.0

environment:
  sdk: ">=3.0.0 <4.0.0"

dependencies:
  flutter:
    sdk: flutter
  gizmo_platform_interface: ^1.0.0

flutter:
  plugin:
    implements: gizmo
    platforms:
      ios:
        pluginClass: GizmoPlugin
''');
      dir.childDirectory('ios').childDirectory('Classes').childFile('GizmoPlugin.swift')
        ..createSync(recursive: true)
        ..writeAsStringSync('''
import Flutter
import WebKit
import CoreLocation

public class GizmoPlugin: NSObject {
  let web = WKWebView(frame: .zero)
  let loc = CLLocationManager()
}
''');
      final PluginSource source = SourceAnalyzer(fileSystem: fs).analyze(dir);
      final Directory out = fs.directory('/out/gizmo_watchos');
      final ScaffoldResult result = Scaffolder(
        fileSystem: fs,
        logger: BufferLogger.test(),
        licenseHolder: 'Test',
      ).scaffold(source: source, outputDirectory: out);

      // Findings were collected from the source's native code.
      final Set<String> apis =
          result.findings.map((f) => f.pattern.name).toSet();
      expect(apis, containsAll(<String>['WebKit', 'CoreLocation']));

      final String report = out.childFile('PORTING_REPORT.md').readAsStringSync();
      expect(report, contains('This is an FFI scaffold'));
      expect(report, contains('Not available on watchOS'));
      expect(report, contains('WebKit'));
      expect(report, contains('Available, but review'));
      expect(report, contains('CoreLocation'));
    });
  });

  group('SourceAnalyzer modern layouts', () {
    testWithoutContext('resolves a Swift Package Manager layout', () {
      final Directory dir = fs.directory('/p')..createSync();
      dir.childFile('pubspec.yaml').writeAsStringSync('''
name: gadget_ios
flutter:
  plugin:
    platforms:
      ios:
        pluginClass: GadgetPlugin
        dartPluginClass: GadgetIOS
''');
      dir
          .childDirectory('ios')
          .childDirectory('gadget_ios')
          .childDirectory('Sources')
          .childDirectory('gadget_ios')
          .childFile('GadgetPlugin.swift')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('import Flutter\n');
      dir
          .childDirectory('ios')
          .childDirectory('gadget_ios')
          .childFile('Package.swift')
          .writeAsStringSync('// swift-tools-version:5.9\n');

      final PluginSource s = SourceAnalyzer(fileSystem: fs).analyze(dir);
      expect(s.classesDirectory.path, contains('ios/gadget_ios/Sources/gadget_ios'));
      expect(s.pluginClass, 'GadgetPlugin');
      expect(s.isMultiTargetSpm, isFalse,
          reason: 'a lone SwiftPM target is the ordinary single-directory layout');
    });

    testWithoutContext('resolves sharedDarwinSource under darwin/', () {
      final Directory dir = fs.directory('/p')..createSync();
      dir.childFile('pubspec.yaml').writeAsStringSync('''
name: prefsbox_foundation
flutter:
  plugin:
    platforms:
      ios:
        pluginClass: PrefsboxPlugin
        dartPluginClass: PrefsboxFoundation
        sharedDarwinSource: true
      macos:
        pluginClass: PrefsboxPlugin
        dartPluginClass: PrefsboxFoundation
        sharedDarwinSource: true
''');
      dir
          .childDirectory('darwin')
          .childDirectory('prefsbox_foundation')
          .childDirectory('Sources')
          .childDirectory('prefsbox_foundation')
          .childFile('PrefsboxPlugin.swift')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('import Flutter\n');

      final PluginSource s = SourceAnalyzer(fileSystem: fs).analyze(dir);
      expect(s.classesDirectory.path,
          contains('darwin/prefsbox_foundation/Sources'));
      expect(s.basePackageName, 'prefsbox');
    });

    testWithoutContext('infers pluginClass from sources when pubspec omits it', () {
      final Directory dir = fs.directory('/p')..createSync();
      dir.childFile('pubspec.yaml').writeAsStringSync('''
name: foo_ios
flutter:
  plugin:
    platforms:
      ios:
        dartPluginClass: FooIOS
''');
      dir
          .childDirectory('ios')
          .childDirectory('Classes')
          .childFile('FooNativePlugin.swift')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(
            'import Flutter\npublic class FooNativePlugin: NSObject, FlutterPlugin {}\n');

      final warnings = <String>[];
      final PluginSource s = SourceAnalyzer(fileSystem: fs, warningSink: warnings.add).analyze(dir);
      expect(s.pluginClass, 'FooNativePlugin');
      expect(warnings.join(), contains('declares no `pluginClass`'));
    });

    testWithoutContext('genuinely pure-Dart plugin → advisory no _watchos package needed', () {
      final Directory dir = fs.directory('/p')..createSync();
      dir.childFile('pubspec.yaml').writeAsStringSync('''
name: some_thing
dependencies:
  some_thing_platform_interface: ^1.0.0
flutter:
  plugin:
    platforms:
      ios:
        dartPluginClass: SomeThingIos
''');
      expect(
        () => SourceAnalyzer(fileSystem: fs).analyze(dir),
        throwsA(isA<PluginSourceError>()
            .having((PluginSourceError e) => e.advisory, 'advisory', isTrue)
            .having((PluginSourceError e) => e.message, 'm',
                contains('no `some_thing_watchos` package is needed'))),
      );
    });

    testWithoutContext('strips federated Apple impl suffixes for the output name', () {
      for (final (String src, String want) in <(String, String)>[
        ('vidbox_avfoundation', 'vidbox_watchos'),
        ('iapbox_storekit', 'iapbox_watchos'),
        ('geobox_apple', 'geobox_watchos'),
        ('audbox_darwin', 'audbox_watchos'),
        ('signbox_ios', 'signbox_watchos'),
        ('devbox', 'devbox_watchos'),
      ]) {
        final Directory dir = fs.directory('/p_$src')..createSync();
        dir.childFile('pubspec.yaml').writeAsStringSync('''
name: $src
flutter:
  plugin:
    platforms:
      ios:
        pluginClass: SomePlugin
''');
        dir.childDirectory('ios').childDirectory('Classes').childFile('SomePlugin.swift')
          ..parent.createSync(recursive: true)
          ..writeAsStringSync('import Flutter\n');
        final PluginSource s = SourceAnalyzer(fileSystem: fs).analyze(dir);
        expect(s.outputPackageName, want, reason: '$src → $want');
      }
    });

    testWithoutContext('carries the platform-interface constraint; falls back to any', () {
      Directory mk(String depLine) {
        final Directory dir = fs.directory('/pi')..createSync();
        dir.childFile('pubspec.yaml').writeAsStringSync('''
name: thing_ios
dependencies:
$depLine
flutter:
  plugin:
    platforms:
      ios:
        pluginClass: ThingPlugin
''');
        dir.childDirectory('ios').childDirectory('Classes').childFile('ThingPlugin.swift')
          ..parent.createSync(recursive: true)
          ..writeAsStringSync('import Flutter\n');
        return dir;
      }

      final PluginSource pinned =
          SourceAnalyzer(fileSystem: fs).analyze(mk('  thing_platform_interface: ^3.1.0'));
      expect(pinned.platformInterfaceConstraint, '^3.1.0');

      fs.directory('/pi').deleteSync(recursive: true);
      final PluginSource none = SourceAnalyzer(fileSystem: fs)
          .analyze(mk('  thing_platform_interface:\n    git: https://x/y.git'));
      expect(none.platformInterfaceConstraint, isNull,
          reason: 'non-string constraint → null → template uses `any`');
    });

    testWithoutContext('range constraints are quoted in the generated pubspec', () {
      final Directory dir = fs.directory('/r')..createSync();
      dir.childFile('pubspec.yaml').writeAsStringSync('''
name: dbbox_darwin
dependencies:
  dbbox_platform_interface: ">=2.4.0 <3.0.0"
flutter:
  plugin:
    platforms:
      ios:
        pluginClass: DbboxPlugin
''');
      dir.childDirectory('ios').childDirectory('Classes').childFile('DbboxPlugin.swift')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('import Flutter\n');
      final PluginSource source = SourceAnalyzer(fileSystem: fs).analyze(dir);
      final Directory out = fs.directory('/out/dbbox_watchos');
      Scaffolder(fileSystem: fs, logger: BufferLogger.test(), licenseHolder: 'T')
          .scaffold(source: source, outputDirectory: out);

      final String pubspec = out.childFile('pubspec.yaml').readAsStringSync();
      expect(pubspec, contains('dbbox_platform_interface: ">=2.4.0 <3.0.0"'),
          reason: 'range constraint must be quoted or YAML parsing fails');
    });

    testWithoutContext('FFI / native-assets source → same FFI scaffold', () {
      // A dart:ffi / native-assets source has no copyable method-channel
      // code; the porter emits the standard FFI scaffold for it like any
      // other source (no findings, since there is no native code to scan).
      final Directory dir = fs.directory('/p')..createSync();
      dir.childFile('pubspec.yaml').writeAsStringSync('''
name: acme_foundation
version: 1.2.3
dependencies:
  ffi: ^2.1.4
  objective_c: ^9.2.1
  acme_platform_interface: ^2.1.0
flutter:
  plugin:
    platforms:
      ios:
        dartPluginClass: AcmeFoundation
''');
      final PluginSource s = SourceAnalyzer(fileSystem: fs).analyze(dir);
      expect(s.outputPackageName, 'acme_watchos');

      final Directory out = fs.directory('/out/acme_watchos');
      final ScaffoldResult r = Scaffolder(
        fileSystem: fs,
        logger: BufferLogger.test(),
        licenseHolder: 'T',
      ).scaffold(source: s, outputDirectory: out);
      expect(r.findings, isEmpty);

      final String pubspec = out.childFile('pubspec.yaml').readAsStringSync();
      expect(pubspec, contains('name: acme_watchos'));
      expect(pubspec, contains('ffiPlugin: true'));
      expect(pubspec, contains('dartPluginClass: AcmeWatchos'));
      expect(pubspec, contains('acme_platform_interface: ^2.1.0'));

      final Directory classes =
          out.childDirectory('watchos').childDirectory('Classes');
      expect(classes.childFile('acme_watchos_ffi.h').existsSync(), isTrue);
      expect(classes.childFile('acme_watchos_ffi.m').existsSync(), isTrue);
    });

    testWithoutContext(
        'modular multi-target SwiftPM: analyzer resolves it; scaffold stays FFI, '
        'preserves structure, collapses into one module', () {
      // Synthetic fixture mirroring the modern flutter/packages modular
      // SwiftPM layout (a Swift API target + Objective-C `_objc` core +
      // platform `_ios`/`_macos` targets). Plugin-agnostic — no real
      // plugin names anywhere.
      final Directory dir = fs.directory('/p')..createSync();
      dir.childFile('pubspec.yaml').writeAsStringSync('''
name: gizmo_avfoundation
version: 4.5.6
dependencies:
  gizmo_platform_interface: ^2.0.0
flutter:
  plugin:
    implements: gizmo
    platforms:
      ios:
        pluginClass: GizmoPlugin
        dartPluginClass: AvfoundationGizmo
        sharedDarwinSource: true
      macos:
        pluginClass: GizmoPlugin
        dartPluginClass: AvfoundationGizmo
        sharedDarwinSource: true
''');
      final Directory sources = dir
          .childDirectory('darwin')
          .childDirectory('gizmo_avfoundation')
          .childDirectory('Sources');
      dir
          .childDirectory('darwin')
          .childDirectory('gizmo_avfoundation')
          .childFile('Package.swift')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('// swift-tools-version: 5.9\n');

      // Swift API target: branches on os(iOS)/os(macOS) and pulls the
      // ObjC core in via a `canImport` module guard.
      sources
          .childDirectory('gizmo_avfoundation')
          .childFile('GizmoPlugin.swift')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('''
import Foundation

#if os(iOS)
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
#else
  #error("Unsupported platform.")
#endif

#if canImport(gizmo_avfoundation_objc)
  import gizmo_avfoundation_objc
#endif

final class GizmoPlugin: NSObject {
  let core = GizmoCore()
}
''');
      // ObjC core target with modular `include/` headers and a
      // TARGET_OS_IOS/else platform branch.
      final Directory objc = sources.childDirectory('gizmo_avfoundation_objc');
      objc.childFile('GizmoCore.m')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('''
#import "./include/gizmo_avfoundation_objc/GizmoCore.h"
@import Foundation;

@implementation GizmoCore
- (void)tick {
#if TARGET_OS_IOS
  [self iosPath];
#else
  [self macPath];
#endif
}
@end
''');
      objc
          .childDirectory('include')
          .childDirectory('gizmo_avfoundation_objc')
          .childFile('GizmoCore.h')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('@import Foundation;\n@interface GizmoCore : NSObject\n@end\n');
      // iOS platform target: reaches the ObjC core via a cross-target
      // relative path that only resolves if structure is preserved.
      sources
          .childDirectory('gizmo_avfoundation_ios')
          .childFile('GizmoView.m')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(
            '#import "../gizmo_avfoundation_objc/include/gizmo_avfoundation_objc/GizmoCore.h"\n'
            '@import UIKit;\n');
      // macOS platform target: AppKit — must be dropped for watchOS.
      sources
          .childDirectory('gizmo_avfoundation_macos')
          .childFile('GizmoViewMac.m')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('@import Cocoa;\n');

      final PluginSource s = SourceAnalyzer(fileSystem: fs).analyze(dir);
      // The analyzer still resolves the modular multi-target layout (used to
      // find every native file to scan for the report).
      expect(s.isMultiTargetSpm, isTrue);
      expect(s.outputPackageName, 'gizmo_watchos');
      expect(s.spmSourcesRoot, isNotNull);

      final Directory out = fs.directory('/out/gizmo_watchos');
      final ScaffoldResult r = Scaffolder(
        fileSystem: fs,
        logger: BufferLogger.test(),
        licenseHolder: 'T',
      ).scaffold(source: s, outputDirectory: out);

      // The output is an FFI scaffold — none of the source targets are copied.
      final Directory classes =
          out.childDirectory('watchos').childDirectory('Classes');
      expect(classes.childFile('gizmo_watchos_ffi.h').existsSync(), isTrue);
      expect(classes.childDirectory('gizmo_avfoundation').existsSync(), isFalse);
      expect(
        out.childDirectory('watchos').childFile('gizmo_watchos.podspec').existsSync(),
        isFalse,
      );
      expect(out.childFile('pubspec.yaml').readAsStringSync(), contains('ffiPlugin: true'));

      // This fixture uses no compatibility-database APIs, so the report has
      // no findings — the scan ran cleanly across every target.
      expect(r.findings, isEmpty);
    });
  });
}

/// Builds a minimal but valid iOS plugin in [fs] under `/p` and returns it.
///
/// Keeps the fixture inline so test files don't need on-disk artefacts. The
/// pubspec mirrors a real federated plugin (gadget_ios style).
Directory _createIosPlugin(FileSystem fs, {required String name, bool objc = false}) {
  final Directory dir = fs.directory('/p')..createSync();
  dir.childFile('pubspec.yaml').writeAsStringSync('''
name: $name
description: iOS implementation of gadget.
version: 6.3.4
homepage: https://github.com/flutter/packages/

environment:
  sdk: ">=3.0.0 <4.0.0"
  flutter: ">=3.13.0"

dependencies:
  flutter:
    sdk: flutter
  gadget_platform_interface: ^2.4.0

flutter:
  plugin:
    implements: gadget
    platforms:
      ios:
        pluginClass: GadgetPlugin
        dartPluginClass: GadgetIOS
''');
  final Directory classes = dir.childDirectory('ios').childDirectory('Classes')
    ..createSync(recursive: true);
  if (objc) {
    classes.childFile('GadgetPlugin.h').writeAsStringSync(_kRealisticObjcHeader);
    classes.childFile('GadgetPlugin.m').writeAsStringSync(_kRealisticObjcImpl);
  } else {
    classes.childFile('GadgetPlugin.swift').writeAsStringSync(_kRealisticSwiftSource);
  }
  return dir;
}

/// A trimmed-down Swift implementation that looks enough like a real plugin
/// for "copied verbatim" tests to be meaningful. Keep this in sync with the
/// expected-content checks in tests above.
const String _kRealisticSwiftSource = '''
import Flutter
import UIKit

public class GadgetPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "plugins.flutter.io/gadget_ios",
      binaryMessenger: registrar.messenger())
    let instance = GadgetPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    result(FlutterMethodNotImplemented)
  }
}
''';

const String _kRealisticObjcHeader = '''
#import <Flutter/Flutter.h>

@interface GadgetPlugin : NSObject <FlutterPlugin>
@end
''';

const String _kRealisticObjcImpl = '''
#import "GadgetPlugin.h"

@implementation GadgetPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  // Intentionally empty for the test fixture.
}
@end
''';
