// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Contract tests for the Xcode project template. The pbxproj is an
// old-style plist: a setting rendered from an EMPTY template variable is
// only valid when the substitution site is quoted (`FOO = "";` parses,
// `FOO = ;` does not). `create` always resolves a development team, but the
// plugin porter renders example runners with no team at all — an unquoted
// site ships a project Xcode refuses to open.

import 'dart:io' as io;

import '../src/common.dart';

/// Reads a file from the watchOS app template, locating the template by
/// walking up from the current directory (tests may run from the package
/// root or a workspace root).
String _readAppTemplate(String relativePath) {
  io.Directory dir = io.Directory.current.absolute;
  while (true) {
    final candidate = io.File(
      '${dir.path}/templates/app/swift/watchos.tmpl/$relativePath',
    );
    if (candidate.existsSync()) {
      return candidate.readAsStringSync();
    }
    final io.Directory parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('Could not find watchOS app template: $relativePath');
    }
    dir = parent;
  }
}

void main() {
  group('project.pbxproj template', () {
    late String pbxproj;

    setUpAll(() {
      pbxproj = _readAppTemplate('Runner.xcodeproj/project.pbxproj.tmpl');
    });

    test('every DEVELOPMENT_TEAM substitution site is quoted', () {
      final teamSite = RegExp('DEVELOPMENT_TEAM = ([^;\n]*);');
      final Iterable<RegExpMatch> sites = teamSite.allMatches(pbxproj);
      expect(sites, isNotEmpty,
          reason: 'template should declare DEVELOPMENT_TEAM');
      for (final site in sites) {
        expect(site.group(1), '"{{watchosDevelopmentTeam}}"',
            reason: 'an unquoted site renders `DEVELOPMENT_TEAM = ;` for an '
                'empty team (the porter passes none), which is not valid '
                'pbxproj plist syntax');
      }
    });
  });
}
