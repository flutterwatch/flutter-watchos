// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'source_analyzer.dart';
import 'templates.dart' as tmpl;

/// Generates a buildable NATIVE federated `*_watchos` **skeleton** for a
/// dart:ffi / native-assets source (e.g. `path_provider_foundation`).
///
/// The flutter-watchos toolchain can't build native-assets for watchOS and
/// we don't patch Flutter, so reusing the FFI implementation is impossible.
/// Instead — exactly like flutter-tizen/plugins — we emit a Swift
/// method-channel plugin plus a Dart class extending the plugin's
/// platform interface and forwarding to that channel.
///
/// This is intentionally a *scaffold*, never a hand-written
/// implementation: the Swift handler returns
/// `FlutterMethodNotImplemented` and the Dart class inherits the
/// interface's throwing defaults, so it compiles and registers cleanly.
/// `PORTING_REPORT.md` is the checklist of what to implement natively.
/// Finished, maintained implementations live in the **plugins repo**
/// (`plugins/packages/<plugin>_watchos`) — not in this generator.
class NativeSkeleton {
  const NativeSkeleton();

  /// Relative-path → file-content for the whole generated package. Pure
  /// (no I/O) so the scaffolder owns writing and it unit-tests directly.
  Map<String, String> files({
    required PluginSource source,
    required String licenseHolder,
  }) {
    final String out = source.outputPackageName;
    final String swiftClass = source.pluginClass;
    final channel = 'plugins.flutter.io/${source.basePackageName}';

    return <String, String>{
      'pubspec.yaml':
          tmpl.renderPubspec(source: source, licenseHolder: licenseHolder),
      'README.md':
          tmpl.renderReadme(source: source, licenseHolder: licenseHolder),
      'CHANGELOG.md': tmpl.renderChangelog(source: source),
      'analysis_options.yaml': tmpl.renderAnalysisOptions(),
      '.gitignore': tmpl.renderGitignore(),
      'test/${out}_test.dart':
          tmpl.renderTestStub(source: source, licenseHolder: licenseHolder),
      'watchos/$out.podspec':
          tmpl.renderPodspec(source: source, licenseHolder: licenseHolder),
      'lib/$out.dart':
          tmpl.renderDartEntry(source: source, licenseHolder: licenseHolder),
      'watchos/Classes/$swiftClass.swift': _swiftStub(source, channel),
      'PORTING_REPORT.md': _report(source),
      // A runnable, watchOS-only example so the skeleton is testable
      // (`cd example && flutter-watchos run`). The command renders
      // `example/watchos/` on top of these.
      'example/pubspec.yaml': _examplePubspec(source),
      'example/lib/main.dart': _exampleMain(source),
      'example/analysis_options.yaml': tmpl.renderAnalysisOptions(),
      'example/.gitignore': tmpl.renderGitignore(),
      'example/README.md': '# ${source.basePackageName}_example\n\n'
          'watchOS-only example for `$out`. Run with:\n\n'
          '```sh\nflutter-watchos run\n```\n',
    };
  }

  String _swiftStub(PluginSource source, String channel) => '''
// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Native federated watchOS SKELETON for `${source.basePackageName}`.
// TODO(porter): implement each platform-interface method here, then
// override it in lib/${source.outputPackageName}.dart to call the
// channel. Methods with no watchOS equivalent should throw on the Dart
// side. Finished implementations are maintained in the plugins repo.

import Flutter

public class ${source.pluginClass}: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "$channel",
      binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(${source.pluginClass}(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    // TODO(porter): handle the channel methods this plugin's platform
    // interface needs.
    result(FlutterMethodNotImplemented)
  }
}
''';

  String _examplePubspec(PluginSource source) {
    final String base = source.basePackageName;
    final String out = source.outputPackageName;
    return '''
name: ${base}_example
description: "watchOS example for $out."
publish_to: 'none'
version: 1.0.0+1

environment:
  sdk: ">=3.0.0 <4.0.0"

dependencies:
  flutter:
    sdk: flutter
  $base: any
  $out:
    path: ../

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^4.0.0

flutter:
  uses-material-design: true
''';
  }

  String _exampleMain(PluginSource source) => '''
import 'package:flutter/material.dart';

void main() => runApp(const ExampleApp());

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('${source.outputPackageName}')),
        body: const Center(
          child: Text(
            'Native federated watchOS skeleton.\\n'
            'Implement the plugin (see PORTING_REPORT.md), then call it here.',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
''';

  String _report(PluginSource source) {
    final String b = source.basePackageName;
    return '''
# ${source.outputPackageName} — native federated skeleton

Source `${source.packageName}` is a dart:ffi / native-assets plugin.
That implementation cannot be built for watchOS by the flutter-watchos
toolchain, so this package is a **native federated SKELETON**: a Swift
method-channel plugin plus a Dart class extending
`${source.platformInterfacePackage ?? '<platform interface>'}`.

## Status

⚠️ BUILDABLE SKELETON, not a working port:

- `watchos/Classes/${source.pluginClass}.swift` registers its channel and
  returns `FlutterMethodNotImplemented` for every method.
- `lib/${source.outputPackageName}.dart` extends the platform interface
  and inherits its throwing defaults (so it compiles and registers).

## To finish it

Implement each `${b}_platform_interface` method in
`watchos/Classes/${source.pluginClass}.swift`, override it in
`lib/${source.outputPackageName}.dart` to call the channel, and throw
for anything watchOS can't do. Maintain the finished package in the
plugins repo (`plugins/packages/${source.outputPackageName}`), not in
the porter.

---

Generated by `flutter-watchos plugin port`. Native federated model — no
dart:ffi, no Flutter patching.
''';
  }
}
