// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Device builds pick a signing team from, in order: the DEVELOPMENT_TEAM
// environment variable, the Xcode project, then the keychain. Failing to read
// the project is not a soft failure — it falls through to whatever signing
// identity the keychain happens to list first, so the build is signed by a
// team the developer never chose and xcodebuild fails with "No Account for
// Team" naming an id that appears nowhere in their project.

import 'package:flutter_watchos/build_targets/application.dart';

import '../src/common.dart';

/// A build-settings block as it appears in `project.pbxproj`, with [team]
/// substituted verbatim at the DEVELOPMENT_TEAM site.
String pbxproj(String team) => '''
/* Begin XCBuildConfiguration section */
		97C147061CF9000F007C1 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CODE_SIGN_STYLE = Automatic;
				DEVELOPMENT_TEAM = $team;
				PRODUCT_BUNDLE_IDENTIFIER = com.example.demo.watchkitapp;
			};
			name = Release;
		};
/* End XCBuildConfiguration section */
''';

void main() {
  group('parseDevelopmentTeam', () {
    test('reads a quoted team id', () {
      // The form `create` renders. The substitution site must stay quoted so
      // that an absent team renders `DEVELOPMENT_TEAM = "";` rather than the
      // unparseable `DEVELOPMENT_TEAM = ;` — see
      // watchos_pbxproj_template_test.dart. Reading only the bare form meant
      // the CLI could not read back the project it had just written.
      expect(
        NativeWatchosBundle.parseDevelopmentTeam(pbxproj('"866PPL96Z4"')),
        '866PPL96Z4',
      );
    });

    test('reads a bare team id', () {
      // The form Xcode normalises to when it rewrites the file: in an
      // old-style plist a bare alphanumeric token needs no quotes.
      expect(
        NativeWatchosBundle.parseDevelopmentTeam(pbxproj('866PPL96Z4')),
        '866PPL96Z4',
      );
    });

    test('tolerates whitespace around the assignment', () {
      expect(
        NativeWatchosBundle.parseDevelopmentTeam(
          'DEVELOPMENT_TEAM="866PPL96Z4" ;',
        ),
        '866PPL96Z4',
      );
    });

    test('returns null for a project with no team set', () {
      // `create` without a team, and the runners the plugin porter renders.
      // Null is correct here: it hands over to the keychain, which is the
      // intended behaviour when the developer really has not chosen a team.
      expect(NativeWatchosBundle.parseDevelopmentTeam(pbxproj('""')), isNull);
    });

    test('returns null when DEVELOPMENT_TEAM is absent entirely', () {
      expect(
        NativeWatchosBundle.parseDevelopmentTeam('CODE_SIGN_STYLE = Automatic;'),
        isNull,
      );
    });

    test('ignores a value that is not a team id', () {
      // Team ids are exactly ten uppercase alphanumerics. Anything else is
      // more likely a stray edit than a team, and signing with it would fail
      // later and less legibly than falling through to the keychain.
      expect(
        NativeWatchosBundle.parseDevelopmentTeam(pbxproj('"lowercase1"')),
        isNull,
      );
      expect(
        NativeWatchosBundle.parseDevelopmentTeam(pbxproj('"866PPL96Z"')),
        isNull,
      );
    });

    test('takes the first team when several configurations declare one', () {
      // Debug/Release/Profile blocks each carry the setting; they agree in
      // every project the CLI generates.
      const twoBlocks =
          'DEVELOPMENT_TEAM = "866PPL96Z4";\nDEVELOPMENT_TEAM = "5JRCVYT8MY";';
      expect(
        NativeWatchosBundle.parseDevelopmentTeam(twoBlocks),
        '866PPL96Z4',
      );
    });
  });
}
