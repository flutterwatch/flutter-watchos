// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// The watch-only App Store container format is dictated by App Store Connect
// validation — these tests pin the exact shape that passed validation and
// shipped (Crown Breaker 1.1.0), so refactors cannot silently drift from it.

import 'package:flutter_watchos/commands/upload.dart';
import 'package:flutter_watchos/watchos_distribution.dart';

import '../src/common.dart';

void main() {
  group('bundle id normalization', () {
    test('a plain project id maps to itself + .watchkitapp child', () {
      expect(containerBundleIdFor('com.acme.watchapp'), 'com.acme.watchapp');
      expect(watchBundleIdFor('com.acme.watchapp'), 'com.acme.watchapp.watchkitapp');
    });

    test('a .watchkitapp project id maps to its parent container', () {
      expect(containerBundleIdFor('com.acme.watchapp.watchkitapp'), 'com.acme.watchapp');
      expect(watchBundleIdFor('com.acme.watchapp.watchkitapp'),
          'com.acme.watchapp.watchkitapp');
    });
  });

  group('containerInfoPlistXml', () {
    final String xml = containerInfoPlistXml(
      appName: 'Crown Breaker',
      bundleId: 'com.acme.crownbreaker',
      shortVersion: '1.1.0',
      buildNumber: '2',
      executableName: 'CrownBreaker',
      toolchainStamps: <String, String>{
        'DTXcode': '2601',
        'DTSDKName': 'iphoneos26.0',
      },
    );

    test('carries the keys App Store Connect validation demands', () {
      // Each of these was a 409 validation error when missing.
      expect(xml, contains('<key>ITSWatchOnlyContainer</key><true/>'));
      expect(xml, contains('<key>LSApplicationLaunchProhibited</key><true/>'));
      expect(xml,
          contains('<key>UIRequiredDeviceCapabilities</key><array><string>arm64</string></array>'));
      expect(xml,
          contains('<key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>'));
      expect(xml, contains('<key>DTXcode</key><string>2601</string>'));
      expect(xml, contains('<key>DTSDKName</key><string>iphoneos26.0</string>'));
    });

    test('carries identity, version, and executable', () {
      expect(xml, contains('<key>CFBundleIdentifier</key><string>com.acme.crownbreaker</string>'));
      expect(xml, contains('<key>CFBundleShortVersionString</key><string>1.1.0</string>'));
      expect(xml, contains('<key>CFBundleVersion</key><string>2</string>'));
      expect(xml, contains('<key>CFBundleExecutable</key><string>CrownBreaker</string>'));
      expect(xml,
          contains('<key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>'));
    });

    test('escapes XML-special characters in names', () {
      final String escaped = containerInfoPlistXml(
        appName: 'Rock & Roll <Watch>',
        bundleId: 'com.acme.app',
        shortVersion: '1.0.0',
        buildNumber: '1',
        executableName: 'App',
        toolchainStamps: const <String, String>{},
      );
      expect(escaped, contains('Rock &amp; Roll &lt;Watch&gt;'));
      expect(escaped, isNot(contains('Rock & Roll <Watch>')));
    });
  });

  group('selectStoreProfile', () {
    final now = DateTime(2026, 7, 6);

    ProvisioningProfileInfo profile(String appId,
        {bool store = true, DateTime? expires, String name = 'p'}) {
      return ProvisioningProfileInfo(
        path: '/profiles/$name.mobileprovision',
        name: name,
        appId: appId,
        isAppStore: store,
        expiresAt: expires,
      );
    }

    test('picks the matching store profile', () {
      final ProvisioningProfileInfo? chosen = selectStoreProfile(<ProvisioningProfileInfo>[
        profile('com.acme.other', name: 'other'),
        profile('com.acme.app', name: 'match', expires: DateTime(2027)),
      ], 'com.acme.app', now: now);
      expect(chosen?.name, 'match');
    });

    test('ignores development and expired profiles', () {
      final ProvisioningProfileInfo? chosen = selectStoreProfile(<ProvisioningProfileInfo>[
        profile('com.acme.app', store: false, name: 'dev'),
        profile('com.acme.app', expires: DateTime(2020), name: 'expired'),
      ], 'com.acme.app', now: now);
      expect(chosen, isNull);
    });

    test('prefers the latest expiry when several match', () {
      final ProvisioningProfileInfo? chosen = selectStoreProfile(<ProvisioningProfileInfo>[
        profile('com.acme.app', expires: DateTime(2026, 12), name: 'sooner'),
        profile('com.acme.app', expires: DateTime(2028), name: 'later'),
      ], 'com.acme.app', now: now);
      expect(chosen?.name, 'later');
    });
  });

  group('WatchosUploadCommand.altoolArgs', () {
    test('validate and upload argv target the ios delivery platform', () {
      final List<String> validate = WatchosUploadCommand.altoolArgs(
        upload: false,
        ipaPath: '/x/app.ipa',
        apiKeyId: 'KEY',
        apiIssuer: 'ISSUER',
      );
      expect(validate, contains('--validate-app'));
      // Watch-only containers upload as iOS packages; altool 26 has no
      // watchos platform at all.
      expect(validate, containsAllInOrder(<String>['--platform', 'ios']));
      expect(validate, containsAllInOrder(<String>['--apiKey', 'KEY']));

      final List<String> upload = WatchosUploadCommand.altoolArgs(
        upload: true,
        ipaPath: '/x/app.ipa',
        apiKeyId: 'KEY',
        apiIssuer: 'ISSUER',
      );
      expect(upload, contains('--upload-app'));
      expect(upload, isNot(contains('--validate-app')));
    });
  });
}
