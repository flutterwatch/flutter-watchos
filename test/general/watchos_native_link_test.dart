// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/memory.dart';
import 'package:flutter_watchos/build_targets/watchos_native_link.dart';

import '../src/common.dart';

void main() {
  group('nativeLinkFlagsXcconfig', () {
    testWithoutContext('force-loads the host archive for the active SDK only', () {
      final String xcconfig = nativeLinkFlagsXcconfig(
        sdkName: 'watchsimulator',
        hostArchive: '/app/watchos/Flutter/libFlutterWatchOSHost.a',
        pluginArchive: null,
      );
      expect(xcconfig, startsWith(r'OTHER_LDFLAGS[sdk=watchsimulator*]=$(inherited)'));
      expect(
        xcconfig,
        contains('-force_load "/app/watchos/Flutter/libFlutterWatchOSHost.a"'),
      );
      expect(xcconfig, contains('-framework SwiftUI'));
      expect(xcconfig, contains('-framework WatchKit'));
      expect(xcconfig, contains('STRIP_STYLE = non-global\n'));
    });

    // Xcode splits the value on whitespace when it builds the linker command
    // line. An unquoted path with a space became two arguments and the link
    // failed on a file that does not exist — for a project that lived under
    // a perfectly ordinary directory name.
    testWithoutContext('quotes archive paths, so a directory with a space links', () {
      const host = '/Users/me/My Projects/app/watchos/Flutter/libFlutterWatchOSHost.a';
      const plugins =
          '/Users/me/My Projects/app/watchos/Flutter/libflutter_watchos_plugins.a';
      final String xcconfig = nativeLinkFlagsXcconfig(
        sdkName: 'watchos',
        hostArchive: host,
        pluginArchive: (plugins, <String>{}, <String>{}),
      );
      expect(xcconfig, contains('-force_load "$host"'));
      expect(xcconfig, contains('-force_load "$plugins"'));
      // The include path is a path list too, and $(PROJECT_DIR) can carry a
      // space just as easily.
      expect(xcconfig, contains(r'SWIFT_INCLUDE_PATHS[sdk=watch*] = "$(PROJECT_DIR)/Flutter"'));
    });

    testWithoutContext('links the frameworks and libraries the plugins declare', () {
      final String xcconfig = nativeLinkFlagsXcconfig(
        sdkName: 'watchos',
        hostArchive: null,
        pluginArchive: (
          '/app/watchos/Flutter/libflutter_watchos_plugins.a',
          <String>{'HealthKit', 'WatchKit'},
          <String>{'z'},
        ),
      );
      expect(xcconfig, contains('-framework HealthKit'));
      expect(xcconfig, contains('-framework WatchKit'));
      expect(xcconfig, contains(' -lz'));
      expect(xcconfig, isNot(contains('-framework SwiftUI')));
    });
  });

  group('pluginObjectName', () {
    final fs = MemoryFileSystem.test();

    // Two plugins each shipping `watchos/Classes/plugin.m` produced the same
    // `plugin.m.o`; the second compile overwrote the first and the app failed
    // on its first FFI call into whichever plugin lost.
    testWithoutContext('keeps two plugins with the same source name apart', () {
      final String a = pluginObjectName(
        pluginName: 'battery_plus_watchos',
        pluginRoot: '/pub/battery_plus_watchos/watchos',
        source: '/pub/battery_plus_watchos/watchos/Classes/plugin.m',
        fileSystem: fs,
      );
      final String b = pluginObjectName(
        pluginName: 'haptics_watchos',
        pluginRoot: '/pub/haptics_watchos/watchos',
        source: '/pub/haptics_watchos/watchos/Classes/plugin.m',
        fileSystem: fs,
      );
      expect(a, 'battery_plus_watchos__Classes_plugin.m.o');
      expect(b, 'haptics_watchos__Classes_plugin.m.o');
      expect(a, isNot(b));
    });

    testWithoutContext('keeps two same-named sources of one plugin apart', () {
      final String a = pluginObjectName(
        pluginName: 'p',
        pluginRoot: '/p/watchos',
        source: '/p/watchos/Classes/util.c',
        fileSystem: fs,
      );
      final String b = pluginObjectName(
        pluginName: 'p',
        pluginRoot: '/p/watchos',
        source: '/p/watchos/Classes/vendor/util.c',
        fileSystem: fs,
      );
      expect(a, isNot(b));
    });
  });
}
