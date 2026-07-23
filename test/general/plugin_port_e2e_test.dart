// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_watchos/plugin_porting/report_emitter.dart';
import 'package:flutter_watchos/plugin_porting/scaffolder.dart';
import 'package:flutter_watchos/plugin_porting/source_analyzer.dart';
import 'package:flutter_watchos/plugin_porting/swift_porter.dart';

import '../src/common.dart';

/// A gadget_ios-shaped Swift plugin whose native code uses one unsupported
/// API (WebKit) and one available-but-different API (CoreLocation) — so the
/// porter's report has something to categorise.
const String _kGadgetSwift = '''
import Flutter
import UIKit
import WebKit
import CoreLocation

public class GadgetPlugin: NSObject, FlutterPlugin {
  let web = WKWebView(frame: .zero)
  let loc = CLLocationManager()

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    result(FlutterMethodNotImplemented)
  }
}
''';

Directory _createGadgetIos(FileSystem fs) {
  final Directory dir = fs.directory('/p')..createSync();
  dir.childFile('pubspec.yaml').writeAsStringSync('''
name: gadget_ios
description: iOS implementation of gadget.
version: 6.3.4

environment:
  sdk: ">=3.0.0 <4.0.0"

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
''');
  dir.childDirectory('ios').childDirectory('Classes').childFile('GadgetPlugin.swift')
    ..createSync(recursive: true)
    ..writeAsStringSync(_kGadgetSwift);
  return dir;
}

void main() {
  late MemoryFileSystem fs;
  setUp(() => fs = MemoryFileSystem.test());

  group('plugin port end-to-end (FFI scaffold)', () {
    testWithoutContext('emits an FFI scaffold and a categorised report', () {
      final Directory src = _createGadgetIos(fs);
      final PluginSource source = SourceAnalyzer(fileSystem: fs).analyze(src);
      final Directory out = fs.directory('/out/gadget_watchos');

      final ScaffoldResult result = Scaffolder(
        fileSystem: fs,
        logger: BufferLogger.test(),
        licenseHolder: 'Test',
      ).scaffold(source: source, outputDirectory: out);

      // The FFI scaffold, not a copy of the source's method-channel code.
      final Directory classes = out.childDirectory('watchos').childDirectory('Classes');
      expect(classes.childFile('gadget_watchos_ffi.h').existsSync(), isTrue);
      expect(classes.childFile('gadget_watchos_ffi.m').existsSync(), isTrue);
      expect(classes.childFile('GadgetPlugin.swift').existsSync(), isFalse);
      expect(out.childFile('pubspec.yaml').readAsStringSync(), contains('ffiPlugin: true'));

      // The report categorises the source's API usage.
      final String report = out.childFile('PORTING_REPORT.md').readAsStringSync();
      expect(report, contains('This is an FFI scaffold'));
      expect(report, contains('Not available on watchOS'));
      expect(report, contains('WebKit'));
      expect(report, contains('Available, but review'));
      expect(report, contains('CoreLocation'));

      // The findings are exposed for the command's summary.
      expect(result.findings.map((f) => f.pattern.name).toSet(),
          containsAll(<String>['WebKit', 'CoreLocation']));
    });

    testWithoutContext('--no-report suppresses the report but still scaffolds', () {
      final Directory src = _createGadgetIos(fs);
      final PluginSource source = SourceAnalyzer(fileSystem: fs).analyze(src);
      final Directory out = fs.directory('/out/gadget_watchos');

      final ScaffoldResult result = Scaffolder(
        fileSystem: fs,
        logger: BufferLogger.test(),
        licenseHolder: 'Test',
      ).scaffold(source: source, outputDirectory: out, emitReport: false);

      expect(result.reportPath, isNull);
      expect(out.childFile('PORTING_REPORT.md').existsSync(), isFalse);
      expect(out.childFile('pubspec.yaml').existsSync(), isTrue);
    });

    testWithoutContext('--dry-run previews findings without writing', () {
      final Directory src = _createGadgetIos(fs);
      final PluginSource source = SourceAnalyzer(fileSystem: fs).analyze(src);
      final Directory out = fs.directory('/out/gadget_watchos');

      final ScaffoldResult result = Scaffolder(
        fileSystem: fs,
        logger: BufferLogger.test(),
        licenseHolder: 'Test',
      ).scaffold(source: source, outputDirectory: out, dryRun: true);

      expect(result.dryRun, isTrue);
      expect(result.findings.map((f) => f.pattern.name), contains('WebKit'));
      expect(out.existsSync(), isFalse);
    });
  });

  group('ReportEmitter', () {
    PortingResult analyze(String swift) =>
        SwiftPorter().port(swift, fileRelativePath: 'ios/Classes/Gadget.swift');

    PluginSource fakeSource() {
      final Directory dir = fs.directory('/p')..createSync();
      dir.childFile('pubspec.yaml').writeAsStringSync('''
name: gadget_ios
version: 1.0.0
environment:
  sdk: ">=3.0.0 <4.0.0"
flutter:
  plugin:
    implements: gadget
    platforms:
      ios:
        pluginClass: GadgetPlugin
''');
      dir.childDirectory('ios').childDirectory('Classes').childFile('G.swift')
        ..createSync(recursive: true)
        ..writeAsStringSync('import Flutter\n');
      return SourceAnalyzer(fileSystem: fs).analyze(dir);
    }

    testWithoutContext('emits a deterministic, well-formed report', () {
      final PortingResult r = analyze(_kGadgetSwift);
      final String report = const ReportEmitter().render(
        source: fakeSource(),
        findings: r.findings,
        today: '2026-01-02',
      );
      expect(report, startsWith('# gadget_watchos — porting report'));
      expect(report, contains('Generated by `flutter-watchos plugin port` on 2026-01-02.'));
      expect(report, contains('This is an FFI scaffold'));
      expect(report, contains('## Checklist'));
    });

    testWithoutContext('separates unsupported APIs from available-but-review', () {
      final PortingResult r = analyze(_kGadgetSwift);
      final String report =
          const ReportEmitter().render(source: fakeSource(), findings: r.findings);
      // WebKit → unsupported; CoreLocation → available/review.
      expect(report, contains('### Not available on watchOS'));
      expect(report, contains('WebKit'));
      expect(report, contains('### Available, but review'));
      expect(report, contains('CoreLocation'));
    });

    testWithoutContext('handles a clean source with no findings', () {
      final String report = const ReportEmitter().render(
        source: fakeSource(),
        findings: const <PortingFinding>[],
      );
      expect(report, contains('No compatibility-database APIs were detected'));
      expect(report, isNot(contains('### Not available on watchOS')));
    });
  });
}
