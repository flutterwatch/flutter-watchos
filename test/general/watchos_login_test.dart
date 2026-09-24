// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_watchos/commands/login.dart';

import '../src/common.dart';
import '../src/context.dart';

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
}
