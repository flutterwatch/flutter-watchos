// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Tests for plugin-shipped native SwiftUI platform views: the CLI-side source
// discovery + registration shim, and the host module's C entry point they
// bridge to. A plugin ships `.swift` view sources next to its FFI classes;
// the CLI compiles them (plus the shim) into the force-loaded plugin archive,
// and the plugin's Dart `registerWith()` triggers registration through
// `FlutterWatchOSPlatformViewRegisterNativeFactory` in the host module.

import 'package:file/memory.dart';
import 'package:flutter_watchos/build_targets/watchos_plugin_views.dart';

import '../src/common.dart';
import '../src/host_sources.dart';

void main() {
  group('collectPluginSwiftViewSources', () {
    late MemoryFileSystem fileSystem;

    setUp(() {
      fileSystem = MemoryFileSystem.test();
    });

    testWithoutContext('returns empty for a missing plugin directory', () {
      expect(
        collectPluginSwiftViewSources(fileSystem.directory('/nope')),
        isEmpty,
      );
    });

    testWithoutContext('collects nested .swift sources, sorted', () {
      fileSystem.file('/p/watchos/Views/b_view.swift')
        ..createSync(recursive: true)
        ..writeAsStringSync('// b');
      fileSystem.file('/p/watchos/Classes/a_view.swift')
        ..createSync(recursive: true)
        ..writeAsStringSync('// a');
      expect(
        collectPluginSwiftViewSources(fileSystem.directory('/p/watchos')),
        <String>['/p/watchos/Classes/a_view.swift', '/p/watchos/Views/b_view.swift'],
      );
    });

    testWithoutContext('excludes the SwiftPM manifest and non-Swift sources', () {
      fileSystem.file('/p/watchos/Package.swift')
        ..createSync(recursive: true)
        ..writeAsStringSync('// manifest');
      fileSystem.file('/p/watchos/Classes/impl.m')
        ..createSync(recursive: true)
        ..writeAsStringSync('// objc');
      expect(
        collectPluginSwiftViewSources(fileSystem.directory('/p/watchos')),
        isEmpty,
      );
    });

    testWithoutContext('excludes CLI-generated and tooling-state Swift files', () {
      // A build against the plugin's example can leave a generated registrant
      // under Flutter/; SwiftPM state lives in .build/.
      fileSystem.file('/p/watchos/Flutter/GeneratedPluginRegistrant.swift')
        ..createSync(recursive: true)
        ..writeAsStringSync('// generated');
      fileSystem.file('/p/watchos/.build/checkouts/dep/Sources/x.swift')
        ..createSync(recursive: true)
        ..writeAsStringSync('// tooling');
      fileSystem.file('/p/watchos/Views/real_view.swift')
        ..createSync(recursive: true)
        ..writeAsStringSync('// view');
      expect(
        collectPluginSwiftViewSources(fileSystem.directory('/p/watchos')),
        <String>['/p/watchos/Views/real_view.swift'],
      );
    });
  });

  group('plugin view registration shim', () {
    test('resolves the runner entry point via dlsym, never a link-time import', () {
      expect(kPluginViewSupportSwift, contains('dlsym'));
      expect(
        kPluginViewSupportSwift,
        contains('FlutterWatchOSPlatformViewRegisterNativeFactory'),
      );
      // RTLD_DEFAULT, matching the template's own dlsym idiom.
      expect(kPluginViewSupportSwift, contains('bitPattern: -2'));
    });

    test('exposes the register(_:factory:) surface plugins code against', () {
      expect(kPluginViewSupportSwift, contains('enum FlutterWatchOSPluginViews'));
      expect(
        kPluginViewSupportSwift,
        contains('static func register('),
      );
      expect(
        kPluginViewSupportSwift,
        contains('factory: @escaping (String) -> AnyView'),
      );
    });

    test('hands the view across the C boundary retained, runtime-boxed', () {
      expect(kPluginViewSupportSwift, contains('@convention(c)'));
      // SwiftUI hard-rejects class-conforming Views at runtime ("views must
      // be value types"), so the crossing must NOT wrap the view in a custom
      // class — it relies on the Swift runtime's own AnyObject boxing, which
      // the runner's `as? any View` cast unwraps.
      expect(
        kPluginViewSupportSwift,
        contains('Unmanaged.passRetained(factory(creationParams) as AnyObject)'),
      );
      expect(kPluginViewSupportSwift, isNot(contains(': View {')));
    });

    test('degrades gracefully on an app runner that predates plugin views', () {
      expect(kPluginViewSupportSwift, contains('NSLog'));
      expect(kPluginViewSupportSwift, contains('predates'));
    });
  });

  group('host module — plugin registration entry point', () {
    final String runner = readHostSource('FlutterRunner.swift');

    test('exports the @_cdecl entry point the shim dlsym-resolves', () {
      expect(
        runner,
        contains('@_cdecl("FlutterWatchOSPlatformViewRegisterNativeFactory")'),
      );
    });

    test('registers on the main thread, where the registry lives', () {
      final int at = runner.indexOf(
        '@_cdecl("FlutterWatchOSPlatformViewRegisterNativeFactory")',
      );
      final String body = runner.substring(at);
      expect(body, contains('DispatchQueue.main.async'));
      expect(body, contains('WatchPlatformViewRegistry.register'));
    });

    test('recovers the plugin view as `any View` from a retained box', () {
      expect(runner, contains('takeRetainedValue()'));
      expect(runner, contains('as? any View'));
    });

    test('keeps the entry point alive under -dead_strip', () {
      // Plugins reach it only via dlsym, invisible to the linker; start()
      // must reference it so it survives dead-code stripping.
      final int at = runner.indexOf('func start()');
      expect(at, greaterThanOrEqualTo(0));
      expect(
        runner.substring(at),
        contains('_ = FlutterWatchOSPlatformViewRegisterNativeFactory'),
      );
    });
  });
}
