// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io' show HttpRequest, HttpServer, InternetAddress, SocketException;

import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_watchos/watchos_auth.dart';

import '../src/common.dart';
import '../src/fakes.dart';

FakePlatform _withApi(String? value) => FakePlatform(
  environment: <String, String>{
    if (value != null) 'WATCHOS_ARTIFACTS_API': value,
  },
);

void main() {
  group('watchosArtifactApiBase', () {
    testWithoutContext('defaults to the production service', () {
      expect(watchosArtifactApiBase(_withApi(null)), kDefaultWatchosApiBase);
      expect(watchosArtifactApiBase(_withApi('')), kDefaultWatchosApiBase);
    });

    testWithoutContext('accepts an https override and drops a trailing slash', () {
      expect(
        watchosArtifactApiBase(_withApi('https://staging.flutterwatch.dev/')),
        'https://staging.flutterwatch.dev',
      );
    });

    testWithoutContext('accepts plain http for a local development server only', () {
      expect(
        watchosArtifactApiBase(_withApi('http://localhost:8787')),
        'http://localhost:8787',
      );
      expect(
        watchosArtifactApiBase(_withApi('http://127.0.0.1:8787/')),
        'http://127.0.0.1:8787',
      );
    });

    // The token is sent as a bearer header on every download. Over plain
    // http to a remote host that is a credential leak, and the old behaviour
    // of silently substituting the production URL for anything unrecognised
    // was a different surprise: a typo pointed a staging test at production.
    testWithoutContext('refuses a plain-http remote host', () {
      expect(
        () => watchosArtifactApiBase(_withApi('http://staging.flutterwatch.dev')),
        throwsToolExit(message: 'https://'),
      );
    });

    testWithoutContext('refuses a value that is not a URL', () {
      expect(
        () => watchosArtifactApiBase(_withApi('api.flutterwatch.dev')),
        throwsToolExit(),
      );
    });
  });

  group('writeWatchosCredentials', () {
    late MemoryFileSystem fs;
    late FakePlatform platform;

    setUp(() {
      fs = MemoryFileSystem.test();
      platform = FakePlatform(environment: <String, String>{'HOME': '/home/u'});
    });

    testWithoutContext('round-trips the token', () {
      writeWatchosCredentials(fs, platform, token: 'fw_secret', login: 'someone');
      expect(readWatchosToken(fs, platform), 'fw_secret');
    });

    // A file created with the default umask is world-readable from the moment
    // it exists. The token must therefore land in a file that has ALREADY
    // been narrowed to the owner, which is what the temp-then-rename dance
    // guarantees: the chmod targets an empty file, and the token is written
    // only after it.
    testWithoutContext('narrows the directory and the file before the token is written', () {
      final os = FakeOperatingSystemUtils();
      writeWatchosCredentials(
        fs,
        platform,
        token: 'fw_secret',
        operatingSystemUtils: os,
      );
      expect(os.chmods, <List<String>>[
        <String>['/home/u/.flutter-watchos', '700'],
        <String>['/home/u/.flutter-watchos/.credentials.json.tmp', '600'],
      ]);
      expect(readWatchosToken(fs, platform), 'fw_secret');
      expect(
        fs.file('/home/u/.flutter-watchos/.credentials.json.tmp').existsSync(),
        isFalse,
      );
    });

    testWithoutContext('replaces an existing credentials file', () {
      writeWatchosCredentials(fs, platform, token: 'fw_old');
      writeWatchosCredentials(fs, platform, token: 'fw_new');
      final File file = watchosCredentialsFile(fs, platform);
      expect(readWatchosToken(fs, platform), 'fw_new');
      expect(file.readAsStringSync(), isNot(contains('fw_old')));
    });
  });

  // `logout` used to delete only the local file: the token stayed valid on the
  // service, and every login added one more.
  group('revokeWatchosToken', () {
    testWithoutContext('sends a DELETE for the token, with it as the bearer', () async {
      final sent = <(Uri, String)>[];
      final TokenRevocation result = await revokeWatchosToken(
        platform: _withApi(null),
        token: 'fw_secret',
        request: (Uri uri, String token) async {
          sent.add((uri, token));
          return 204;
        },
      );
      expect(result, TokenRevocation.revoked);
      expect(sent, <(Uri, String)>[(Uri.parse('$kDefaultWatchosApiBase/v1/auth/token'), 'fw_secret')]);
    });

    testWithoutContext('over the wire: a DELETE with the token as the bearer', () async {
      final HttpServer server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final seen = <String>[];
      server.listen((HttpRequest request) {
        seen.add('${request.method} ${request.uri.path} ${request.headers.value('authorization')}');
        request.response
          ..statusCode = 204
          ..close();
      });

      final TokenRevocation result = await revokeWatchosToken(
        platform: _withApi('http://127.0.0.1:${server.port}'),
        token: 'fw_secret',
      );

      expect(result, TokenRevocation.revoked);
      expect(seen, <String>['DELETE /v1/auth/token Bearer fw_secret']);
    });

    testWithoutContext('an older service without the endpoint is not a problem', () async {
      final TokenRevocation result = await revokeWatchosToken(
        platform: _withApi(null),
        token: 'fw_secret',
        request: (Uri uri, String token) async => 404,
      );
      expect(result, TokenRevocation.notNeeded);
      expect(logoutMessage(removed: true, revocation: result), 'Logged out. The sign-in is removed from this machine.');
    });

    testWithoutContext('a token the service already refuses needs nothing more', () async {
      expect(
        await revokeWatchosToken(
          platform: _withApi(null),
          token: 'fw_secret',
          request: (Uri uri, String token) async => 401,
        ),
        TokenRevocation.notNeeded,
      );
    });

    testWithoutContext('no answer never throws, and says the token may still be valid', () async {
      final TokenRevocation result = await revokeWatchosToken(
        platform: _withApi(null),
        token: 'fw_secret',
        request: (Uri uri, String token) async => throw const SocketException('offline'),
      );
      expect(result, TokenRevocation.unreachable);
      expect(logoutMessage(removed: true, revocation: result), contains('stays valid until you revoke it'));
      expect(
        await revokeWatchosToken(
          platform: _withApi(null),
          token: 'fw_secret',
          request: (Uri uri, String token) async => 503,
        ),
        TokenRevocation.unreachable,
      );
    });

    testWithoutContext('an override that is not a usable URL does not stop the logout', () async {
      expect(
        await revokeWatchosToken(
          platform: _withApi('http://staging.flutterwatch.dev'),
          token: 'fw_secret',
          request: (Uri uri, String token) async => fail('nothing is sent over plain http'),
        ),
        TokenRevocation.unreachable,
      );
    });
  });

  group('logoutMessage', () {
    testWithoutContext('says what happened to the sign-in', () {
      expect(logoutMessage(removed: false), 'Not logged in.');
      expect(logoutMessage(removed: true, revocation: TokenRevocation.revoked), contains('revoked'));
      expect(logoutMessage(removed: true), 'Logged out. The sign-in is removed from this machine.');
    });
  });
}
