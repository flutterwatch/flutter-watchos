// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Device builds pick a signing team from, in order: the DEVELOPMENT_TEAM
// environment variable, the Xcode project, then the keychain. Failing to read
// the project is not a soft failure — it falls through to whatever signing
// identity the keychain happens to list first, so the build is signed by a
// team the developer never chose and xcodebuild fails with "No Account for
// Team" naming an id that appears nowhere in their project.

import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/logger.dart';
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

  group('parseKeychainTeams', () {
    test('returns nothing when the keychain has no identity', () {
      expect(
        NativeWatchosBundle.parseKeychainTeams('     0 valid identities found'),
        isEmpty,
      );
    });

    test('collapses several certificates of one team to a single team', () {
      // A team accumulates an identity per certificate; that is not a choice
      // between teams, so it must not read as an ambiguous keychain.
      const output = '''
  1) AAAA "Apple Development: dev@example.com (5JRCVYT8MY)"
  2) BBBB "Apple Development: dev@example.com (5JRCVYT8MY)"
     2 valid identities found''';
      expect(
        NativeWatchosBundle.parseKeychainTeams(output),
        <String>['5JRCVYT8MY'],
      );
    });

    test('reports every distinct team, in keychain order', () {
      // Shape of a real keychain where auto-detection picked the wrong team:
      // the defunct personal team sorts first, so signing failed with "No
      // Account for Team" naming an id absent from the project.
      //
      // 866PPL96Z4 must appear even though it holds no Apple Development
      // certificate. It is the team that actually builds on that machine —
      // automatic signing runs with -allowProvisioningUpdates and issues a
      // development certificate for any team with an Xcode account, so
      // listing only development identities omits the right answer.
      const output = '''
  1) AAAA "Apple Development: dev@example.com (5JRCVYT8MY)"
  2) BBBB "Apple Development: dev@example.com (5JRCVYT8MY)"
  3) CCCC "Apple Development: EXAMPLE DEVELOPER (PHVH875RU9)"
  4) DDDD "Apple Distribution: EXAMPLE DEVELOPER (866PPL96Z4)"
  5) EEEE "Developer ID Application: EXAMPLE DEVELOPER (866PPL96Z4)"
     5 valid identities found''';
      expect(
        NativeWatchosBundle.parseKeychainTeams(output),
        <String>['5JRCVYT8MY', 'PHVH875RU9', '866PPL96Z4'],
      );
    });

    test('ignores a ten-character token in a certificate name', () {
      // Only the trailing parenthesised team id counts; anchoring on the
      // closing quote is what keeps a common name from reading as a team.
      const output = '  1) AAAA "Apple Development: (ABCDEFGHIJ) Ltd (5JRCVYT8MY)"';
      expect(
        NativeWatchosBundle.parseKeychainTeams(output),
        <String>['5JRCVYT8MY'],
      );
    });
  });

  group('resolveAuthenticationArgs', () {
    // `-allowProvisioningUpdates` can only create a profile through a
    // signed-in Xcode account. Without one, xcodebuild settles for a cached
    // wildcard profile and any entitled app fails complaining about the
    // capability the wildcard lacks -- never about the credential that is
    // actually missing. An API key is the supported alternative.
    late MemoryFileSystem fileSystem;
    late BufferLogger logger;

    setUp(() {
      fileSystem = MemoryFileSystem.test();
      logger = BufferLogger.test();
    });

    Map<String, String> env({String? path, String? id, String? issuer}) {
      return <String, String>{
        if (path != null) 'APP_STORE_CONNECT_KEY_PATH': path,
        if (id != null) 'APP_STORE_CONNECT_KEY_ID': id,
        if (issuer != null) 'APP_STORE_CONNECT_ISSUER_ID': issuer,
      };
    }

    testWithoutContext('forwards the key when all three are set', () {
      fileSystem.file('/keys/AuthKey_ABC.p8').createSync(recursive: true);

      expect(
        resolveAuthenticationArgs(
          env(path: '/keys/AuthKey_ABC.p8', id: 'ABC1234567', issuer: 'issuer-uuid'),
          fileSystem,
          logger,
        ),
        <String>[
          '-authenticationKeyPath',
          '/keys/AuthKey_ABC.p8',
          '-authenticationKeyID',
          'ABC1234567',
          '-authenticationKeyIssuerID',
          'issuer-uuid',
        ],
      );
    });

    testWithoutContext('is inert when nothing is set', () {
      // The common case. A machine with a working Xcode account has to behave
      // exactly as it did before this existed.
      expect(resolveAuthenticationArgs(<String, String>{}, fileSystem, logger), isEmpty);
      expect(logger.warningText, isEmpty);
    });

    testWithoutContext('is inert when the trio is incomplete', () {
      // Half a flag set is worse than none: xcodebuild rejects the key
      // arguments unless all three are present.
      fileSystem.file('/keys/AuthKey_ABC.p8').createSync(recursive: true);
      expect(
        resolveAuthenticationArgs(
          env(path: '/keys/AuthKey_ABC.p8', id: 'ABC1234567'),
          fileSystem,
          logger,
        ),
        isEmpty,
      );
      expect(
        resolveAuthenticationArgs(
          env(path: '/keys/AuthKey_ABC.p8', issuer: 'issuer-uuid'),
          fileSystem,
          logger,
        ),
        isEmpty,
      );
    });

    testWithoutContext('treats an empty value as unset', () {
      expect(
        resolveAuthenticationArgs(
          env(path: '', id: 'ABC1234567', issuer: 'issuer-uuid'),
          fileSystem,
          logger,
        ),
        isEmpty,
      );
    });

    testWithoutContext('warns, and falls back, when the key file is missing', () {
      // Configured but wrong is the case worth a warning. Staying silent looks
      // identical to never having configured it, and the build then fails much
      // later complaining about a capability rather than a credential.
      expect(
        resolveAuthenticationArgs(
          env(path: '/keys/absent.p8', id: 'ABC1234567', issuer: 'issuer-uuid'),
          fileSystem,
          logger,
        ),
        isEmpty,
      );
      expect(logger.warningText, contains('/keys/absent.p8'));
    });

    testWithoutContext('does not log the key contents', () {
      // The key is a credential. xcodebuild reads the file; this process must
      // never put it, or anything but its id, into the log.
      fileSystem.file('/keys/AuthKey_ABC.p8')
        ..createSync(recursive: true)
        ..writeAsStringSync('-----BEGIN PRIVATE KEY-----\nSECRET\n');
      resolveAuthenticationArgs(
        env(path: '/keys/AuthKey_ABC.p8', id: 'ABC1234567', issuer: 'issuer-uuid'),
        fileSystem,
        logger,
      );
      expect(logger.traceText, contains('ABC1234567'));
      expect(logger.traceText, isNot(contains('SECRET')));
      expect(logger.traceText, isNot(contains('BEGIN PRIVATE KEY')));
    });
  });
}
