// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:io' show ContentType, HttpRequest, HttpServer, InternetAddress;

import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_watchos/commands/login.dart';

import '../src/common.dart';
import '../src/context.dart';
import '../src/test_flutter_command_runner.dart';

void main() {
  // `--help` is the first thing a new user reads. It used to say an account
  // was "required to download engine artifacts", which is not true of the
  // Simulator engine.
  testUsingContext('login says what an account is for, and that the Simulator needs none', () {
    final String description = WatchosLoginCommand().description;
    expect(description, contains('physical watch'));
    expect(description, contains('the Simulator needs none'));
    expect(description, isNot(contains('required')));
  });

  group('loginFailureMessage', () {
    // A service without migration 0009 answered the first request with
    // HTTP 500 and {"error":"internal"}, and `login` printed "internal".
    testWithoutContext('a server error says it failed, and with what status', () {
      final String message = loginFailureMessage(500, <String, Object?>{'error': 'internal'});
      expect(message, startsWith('Login failed (HTTP 500: internal).'));
      expect(message, contains('try again'));
      expect(loginFailureMessage(502, <String, Object?>{}), startsWith('Login failed (HTTP 502).'));
    });

    testWithoutContext("the service's own message is passed on as it is", () {
      const tooMany = 'Too many sign-in attempts right now. '
          'Wait a few minutes, then run `flutter-watchos login` again.';
      expect(
        loginFailureMessage(429, <String, Object?>{'error': 'slow_down', 'message': tooMany}),
        tooMany,
      );
    });

    testWithoutContext('a bare error code is shown with the status', () {
      expect(
        loginFailureMessage(400, <String, Object?>{'error': 'invalid_grant'}),
        'Login failed (HTTP 400: invalid_grant).',
      );
      expect(loginFailureMessage(404, <String, Object?>{}), 'Login failed (HTTP 404).');
      expect(
        loginFailureMessage(400, <String, Object?>{'error': 'expired_token'}),
        contains('`flutter-watchos login` again'),
      );
    });
  });

  // What the person does in the browser is confirm the code `login` printed.
  // The command used to say it was "waiting for approval", and that the code
  // "expired before it was approved", as if someone else had to say yes.
  group('login, against a local service whose code expires', () {
    late HttpServer server;
    late List<String> requests;

    // The command runner locks the SDK's cache before any command; there is
    // no SDK in the memory file system.
    setUpAll(Cache.disableLocking);
    tearDownAll(Cache.enableLocking);

    setUp(() async {
      requests = <String>[];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest request) async {
        requests.add('${request.method} ${request.uri.path}');
        await request.drain<void>();
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path == '/v1/auth/device') {
          request.response.write(
            jsonEncode(<String, Object?>{
              'device_code': 'device-code',
              'user_code': 'ABCD-2345',
              'verification_uri': 'http://127.0.0.1:${server.port}/activate',
              'interval': 0,
              'expires_in': 60,
            }),
          );
        } else {
          request.response
            ..statusCode = 400
            ..write(jsonEncode(<String, Object?>{'error': 'expired_token'}));
        }
        await request.response.close();
      });
    });

    tearDown(() => server.close(force: true));

    testUsingContext(
      'asks the person to confirm the code, and says it expired before they did',
      () async {
        await expectLater(
          createTestCommandRunner(WatchosLoginCommand()).run(<String>['login']),
          throwsToolExit(message: 'The sign-in code expired before it was confirmed.'),
        );

        expect(requests, <String>['POST /v1/auth/device', 'POST /v1/auth/device/token']);
        expect(testLogger.statusText, contains('and confirm the code: ABCD-2345'));
        expect(
          testLogger.statusText,
          contains('Waiting for you to confirm the code in the browser (Ctrl-C to cancel)...'),
        );
        expect(kLoginWaitingNote, isNot(contains('approv')));
        expect(testLogger.statusText.toLowerCase(), isNot(contains('approv')));
      },
      overrides: <Type, Generator>{
        FileSystem: () => MemoryFileSystem.test(),
        ProcessManager: () => FakeProcessManager.any(),
        Platform: () => FakePlatform(
          environment: <String, String>{
            'HOME': '/home/u',
            'WATCHOS_ARTIFACTS_API': 'http://127.0.0.1:${server.port}',
          },
        ),
      },
    );
  });
}
