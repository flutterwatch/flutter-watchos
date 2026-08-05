// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Guards Web-safety of the first-party `flutter_watchos` package.
//
// The package's own docs (doc/plugins.md, the isIOS-trap warning printed by
// lib/watchos_plugins.dart) tell app authors to write
// `FlutterWatchosPlatform.isWatch` instead of `Platform.isIOS`. The audience
// for that advice is cross-platform apps — including ones that also build for
// Web. So every library reachable from the package barrel has to survive a Web
// compile, which means no unconditional `dart:io` or `dart:ffi` import: the
// Web SDK ships those as stubs whose members throw `UnsupportedError` on first
// use (and older SDKs reject the import outright).
//
// The escape hatch is the conditional-import pattern already used throughout
// `lib/src/`: a two-line stub library that exports a `_web.dart` or a
// `_native.dart` implementation on `dart.library.io` / `dart.library.ffi`.
// Only files named `*_native.dart` may reach for the real thing. This test
// exists because neither `dart analyze` nor the VM test suite compiles for
// Web, so nothing else here would notice a regression.

import 'dart:io' as io;

import '../src/common.dart';
import '../src/host_sources.dart';

void main() {
  final libDir = io.Directory(cliRootPath('packages/flutter_watchos/lib'));
  final List<io.File> sources =
      libDir
          .listSync(recursive: true)
          .whereType<io.File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  String name(io.File f) => f.path.split('/').last;

  // A bare `import 'dart:io';` — not the `if (dart.library.io)` of a
  // conditional import/export, which names the library inside a condition.
  final dartIoImport = RegExp(r'''^\s*(?:import|export)\s+'dart:(io|ffi)'.*;''', multiLine: true);

  group('flutter_watchos package Web safety', () {
    test('the test finds the package sources', () {
      expect(sources, isNotEmpty);
      expect(sources.map(name), contains('flutter_watchos.dart'));
    });

    test('only *_native.dart libraries import dart:io / dart:ffi', () {
      final offenders = <String>[];
      for (final source in sources) {
        if (name(source).endsWith('_native.dart')) {
          continue;
        }
        if (dartIoImport.hasMatch(source.readAsStringSync())) {
          offenders.add(name(source));
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'These libraries import dart:io or dart:ffi unconditionally, which '
            'breaks Web builds of any app that imports package:flutter_watchos. '
            "Move the import into a '<name>_native.dart' and reach it "
            'through a conditional export, as '
            'lib/src/platform_extension.dart does.',
      );
    });

    test('FlutterWatchosPlatform has a Web implementation with the same API', () {
      final String web = io.File(
        cliRootPath('packages/flutter_watchos/lib/src/platform_extension_web.dart'),
      ).readAsStringSync();
      expect(web, contains('abstract final class FlutterWatchosPlatform'));
      // On Web none of these can be true: there is no dart:io Platform to ask,
      // and a Web build is not watchOS and not an iOS-family OS.
      for (final getter in <String>['isWatch', 'isIos', 'isAppleMobile']) {
        expect(
          web,
          contains('static bool get $getter => false;'),
          reason: '$getter must be a plain false on Web',
        );
      }
    });

    test('the barrel exports the platform helpers without a show combinator', () {
      final String barrel = io.File(
        cliRootPath('packages/flutter_watchos/lib/flutter_watchos.dart'),
      ).readAsStringSync();
      // `FlutterWatchosPlatformExt` extends the dart:io `Platform` type, so it
      // cannot exist on Web. Naming it in a `show` would be an undefined shown
      // name there; both branches export exactly their public API instead.
      expect(barrel, contains("export 'src/platform_extension.dart';"));
      expect(barrel, isNot(contains('show FlutterWatchosPlatformExt')));
    });
  });
}
