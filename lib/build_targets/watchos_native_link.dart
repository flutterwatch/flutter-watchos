// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/base/file_system.dart';

/// The `Generated.xcconfig` lines that link the host-module and plugin
/// archives into the watch target. Pure, so the quoting can be tested.
///
/// Every path is double-quoted. Xcode splits an xcconfig value on whitespace
/// when it turns it into linker arguments, so an unquoted archive under a
/// directory with a space in its name (`~/My Projects/…`) reached the linker
/// as two arguments and the link failed on a file that does not exist.
///
/// The flags live in the xcconfig, not on the `xcodebuild` command line,
/// with an `[sdk=watch…*]` qualifier so they apply ONLY to the watch target.
/// That is what lets `flutter-watchos archive` build the `HostApp` scheme
/// (Runner + the iOS container) in one pass: a global `OTHER_LDFLAGS` would
/// try to force-load these watchOS archives into the iOS host's link and
/// fail. Both archives ride ONE assignment: within an xcconfig a later
/// assignment of the same setting replaces the earlier one (`$(inherited)`
/// reaches the level below, not up the same file).
String nativeLinkFlagsXcconfig({
  required String sdkName,
  required String? hostArchive,
  required (String, Set<String>, Set<String>)? pluginArchive,
}) {
  final ldflags = StringBuffer(r'$(inherited)');
  if (hostArchive != null) {
    // -force_load keeps the module's dlsym-reached plugin registration
    // entry point (and everything else) out of dead-strip's reach. The
    // frameworks back the glue's imports; autolink metadata would usually
    // pull them in, but being explicit costs nothing.
    ldflags.write(' -force_load "$hostArchive"');
    for (final fw in <String>['SwiftUI', 'WatchKit', 'Foundation']) {
      ldflags.write(' -framework $fw');
    }
  }
  if (pluginArchive != null) {
    final (String archive, Set<String> frameworks, Set<String> libraries) =
        pluginArchive;
    ldflags.write(' -force_load "$archive"');
    for (final fw in frameworks) {
      ldflags.write(' -framework $fw');
    }
    for (final lib in libraries) {
      ldflags.write(' -l$lib');
    }
  }

  // Debug builds link the simulator SDK, device builds link `watchos`, so the
  // qualifier names the active one.
  return 'OTHER_LDFLAGS[sdk=$sdkName*]=$ldflags\n'
      // FFI exports and the host module's plugin registration entry point
      // are reached only via dlsym(RTLD_DEFAULT) at runtime, so they have
      // no link-time caller. `xcodebuild archive` runs the install-time
      // strip (DEPLOYMENT_POSTPROCESSING / STRIP_INSTALLED_PRODUCT=YES)
      // which, with the default STRIP_STYLE=all, prunes them from the
      // symbol table — the app then throws "Failed to lookup symbol …:
      // symbol not found" on the first FFI call, its root widget's
      // initState blows up, and it renders a blank/gray screen. This ONLY
      // bites archived/TestFlight builds: `flutter-watchos run` builds
      // without the install strip, so the symbols survive there (which is
      // why on-device run works but the App Store build is gray). Keep
      // global symbols so the exports survive the strip; locals are still
      // stripped.
      'STRIP_STYLE = non-global\n'
      // Resolves `import FlutterWatchOS` (the staged .swiftmodule) and
      // its FlutterWatchOSHostC clang module when Xcode compiles
      // App.swift. Harmless for legacy projects (nothing imports it).
      'SWIFT_INCLUDE_PATHS[sdk=watch*] = "\$(PROJECT_DIR)/Flutter"\n';
}

/// The object file name for one native source of a watchOS plugin:
/// `<plugin>__<path within the plugin, separators as underscores>.o`.
///
/// Every plugin's objects land in one directory before they are archived
/// together, and the name used to be the source's bare basename plus `.o`.
/// Two plugins that both ship a `plugin.m` therefore produced the same
/// `plugin.m.o`, the second compile overwrote the first, and the app failed
/// on its first FFI call into whichever plugin lost — with a "symbol not
/// found" that named nothing about the collision.
String pluginObjectName({
  required String pluginName,
  required String pluginRoot,
  required String source,
  required FileSystem fileSystem,
}) {
  final String relative = fileSystem.path.relative(source, from: pluginRoot);
  final String flattened = relative.replaceAll(RegExp(r'[\\/]+'), '_');
  return '${pluginName}__$flattened.o';
}
