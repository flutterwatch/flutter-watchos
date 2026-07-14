// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_watchos/plugin_porting/objc_porter.dart';
import 'package:flutter_watchos/plugin_porting/porting_result.dart';
import 'package:flutter_watchos/plugin_porting/scaffolder.dart';
import 'package:flutter_watchos/plugin_porting/source_analyzer.dart';

import '../src/common.dart';

/// A gadget_ios-shaped Objective-C plugin: clean handlers plus one
/// (`launchInWebView`) that touches WebKit, an angle-import and a module
/// import of WebKit.
const String _kObjcImpl = '''
#import "GadgetPlugin.h"
#import <WebKit/WebKit.h>
@import WebKit;

@implementation GadgetPlugin

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  FlutterMethodChannel* channel =
      [FlutterMethodChannel methodChannelWithName:@"plugins.flutter.io/gadget_ios"
                                  binaryMessenger:[registrar messenger]];
  GadgetPlugin* instance = [[GadgetPlugin alloc] init];
  [registrar addMethodCallDelegate:instance channel:channel];
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  if ([call.method isEqualToString:@"canLaunch"]) {
    result(@YES);
  } else if ([call.method isEqualToString:@"launch"]) {
    [self launchURL:call.arguments result:result];
  } else if ([call.method isEqualToString:@"launchInWebView"]) {
    WKWebView* webView = [[WKWebView alloc] initWithFrame:CGRectZero];
    [self presentWebView:webView];
    result(@YES);
  } else {
    result(FlutterMethodNotImplemented);
  }
}

@end
''';

const String _kObjcHeader = '''
#import <Flutter/Flutter.h>

@interface GadgetPlugin : NSObject <FlutterPlugin>
@end
''';

Directory _createObjcPlugin(FileSystem fs) {
  final Directory dir = fs.directory('/src/gadget_ios')..createSync(recursive: true);
  dir.childFile('pubspec.yaml').writeAsStringSync('''
name: gadget_ios
description: iOS implementation of gadget.
version: 6.3.4

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
''');
  final Directory classes = dir.childDirectory('ios').childDirectory('Classes')
    ..createSync(recursive: true);
  classes.childFile('GadgetPlugin.h').writeAsStringSync(_kObjcHeader);
  classes.childFile('GadgetPlugin.m').writeAsStringSync(_kObjcImpl);
  return dir;
}

void main() {
  group('ObjcPorter', () {
    testWithoutContext('strips <Framework/...> and @import framework imports', () {
      final PortingResult r =
          ObjcPorter().port(_kObjcImpl, fileRelativePath: 'watchos/Classes/GadgetPlugin.m');

      expect(r.transformed,
          contains('// #import <WebKit/WebKit.h>  // removed by `flutter-watchos plugin port`'));
      expect(r.transformed,
          contains('// @import WebKit;  // removed by `flutter-watchos plugin port`'));
      // Local quoted import and Flutter stay.
      expect(r.transformed, contains('#import "GadgetPlugin.h"'));
      expect(
        r.strippedImports,
        containsAll(<String>['#import <WebKit/WebKit.h>', '@import WebKit;']),
      );
      final Iterable<PortingFinding> imports = r.findings
          .where((PortingFinding f) => f.action == FindingAction.importStripped);
      expect(imports.map((PortingFinding f) => f.pattern.name).toSet(), <String>{'WebKit'});
    });

    testWithoutContext('stubs the handler that uses WKWebView, keeps the rest', () {
      final PortingResult r =
          ObjcPorter().port(_kObjcImpl, fileRelativePath: 'watchos/Classes/GadgetPlugin.m');

      expect(r.detectedMethods,
          containsAll(<String>['canLaunch', 'launch', 'launchInWebView']));
      expect(r.stubbedCases, <String>['launchInWebView']);
      expect(
        r.transformed,
        contains('result(FlutterMethodNotImplemented);  // TODO(porter): watchOS-incompatible API stubbed'),
      );
      // Original WKWebView line retained but commented, not live.
      expect(r.transformed, contains('WKWebView* webView'));
      expect(
        r.transformed,
        isNot(contains('\n    WKWebView* webView = [[WKWebView alloc]')),
        reason: 'the WKWebView line must be commented out, not active',
      );
      // Clean handlers untouched.
      expect(r.transformed, contains('[self launchURL:call.arguments result:result];'));

      final PortingFinding stub = r.findings
          .firstWhere((PortingFinding f) => f.action == FindingAction.stubbedMethod);
      expect(stub.enclosingMethod, 'launchInWebView');
      expect(stub.pattern.name, 'WebKit');
    });

    testWithoutContext('clean ObjC ports to identical content (plus newline)', () {
      final PortingResult r =
          ObjcPorter().port(_kObjcHeader, fileRelativePath: 'watchos/Classes/GadgetPlugin.h');
      expect(r.transformed, _kObjcHeader);
      expect(r.findings, isEmpty);
      expect(r.stubbedCases, isEmpty);
    });

    testWithoutContext('always ends with exactly one trailing newline', () {
      expect(
        ObjcPorter().port('int x = 1;', fileRelativePath: 'x.m').transformed,
        'int x = 1;\n',
      );
      expect(
        ObjcPorter().port('int x = 1;\n', fileRelativePath: 'x.m').transformed,
        'int x = 1;\n',
      );
    });

    testWithoutContext('widens ObjC availability annotations to watchOS', () {
      const src = '''
- (void)a API_AVAILABLE(ios(14)) {
  if (@available(iOS 14.0, *)) {
    [info isiOSAppOnMac];
  }
}
- (void)b API_AVAILABLE(ios(16.0), macos(13)) {}
- (void)c API_AVAILABLE(ios(13), watchos(13)) {}
- (void)d API_UNAVAILABLE(watchos) {}
''';
      final PortingResult r =
          ObjcPorter().port(src, fileRelativePath: 'x.m');

      // `@available(iOS …, *)` and `API_AVAILABLE(ios(…))` both gain a
      // watchOS entry at the MAPPED version (offset by 7 in the pre-26
      // era, unlike tvOS); other platforms preserved.
      expect(r.transformed, contains('API_AVAILABLE(ios(14), watchos(7))'));
      expect(r.transformed, contains('if (@available(iOS 14.0, watchOS 7.0, *))'));
      expect(
          r.transformed, contains('API_AVAILABLE(ios(16.0), watchos(9.0), macos(13))'));
      // Idempotent — already names watchos.
      expect(r.transformed, contains('API_AVAILABLE(ios(13), watchos(13))'));
      expect(r.transformed, isNot(contains('watchos(13), watchos(13)')));
      // Explicit unavailability is never fought.
      expect(r.transformed, contains('API_UNAVAILABLE(watchos)'));
    });
  });

  group('plugin port end-to-end (Objective-C source → FFI scaffold)', () {
    late MemoryFileSystem fs;
    setUp(() => fs = MemoryFileSystem.test());

    testWithoutContext('emits an FFI scaffold and reports the source WebKit use', () {
      final Directory src = _createObjcPlugin(fs);
      final PluginSource source = SourceAnalyzer(fileSystem: fs).analyze(src);
      expect(source.sourceLanguage, SourceLanguage.objc);
      final Directory out = fs.directory('/out/gadget_watchos');

      final ScaffoldResult result = Scaffolder(
        fileSystem: fs,
        logger: BufferLogger.test(),
        licenseHolder: 'Test',
      ).scaffold(source: source, outputDirectory: out);

      // The ObjC source is NOT copied — an FFI C stub is emitted instead.
      final Directory watchosClasses =
          out.childDirectory('watchos').childDirectory('Classes');
      expect(watchosClasses.childFile('GadgetPlugin.m').existsSync(), isFalse);
      expect(watchosClasses.childFile('gadget_watchos_ffi.h').existsSync(), isTrue);
      expect(watchosClasses.childFile('gadget_watchos_ffi.m').existsSync(), isTrue);
      expect(out.childFile('pubspec.yaml').readAsStringSync(), contains('ffiPlugin: true'));

      // The report flags the WebKit the source used (Objective-C is analysed
      // for findings even though the code isn't copied).
      final String report = out.childFile('PORTING_REPORT.md').readAsStringSync();
      expect(report, contains('Base platform: ios (Objective-C)'));
      expect(report, contains('### Not available on watchOS'));
      expect(report, contains('WebKit'));

      expect(result.findings.map((f) => f.pattern.name), contains('WebKit'));
    });
  });
}
