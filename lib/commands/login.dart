// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/runner/flutter_command.dart';
import 'package:meta/meta.dart';

import '../watchos_auth.dart';
import '../watchos_cache.dart';

/// Connects the CLI to a flutterwatch.dev account via an OAuth-style
/// device-code flow: prints a URL + short code, the user confirms the code in
/// a browser (signing in with GitHub there, which is also what creates the
/// account), and the CLI polls until it receives an API token. The token is
/// stored in `~/.flutter-watchos/credentials.json` and sent as a Bearer
/// header on engine-artifact downloads. The Simulator engine downloads
/// without it; the device and release engines need it.
class WatchosLoginCommand extends FlutterCommand {
  @override
  final String name = 'login';

  @override
  final String description =
      'Connect this machine to your flutterwatch.dev account (needed for a '
      'physical watch and release builds; the Simulator needs none).';

  @override
  String get category => FlutterCommandCategory.tools;

  @override
  Future<FlutterCommandResult> runCommand() async {
    final String api = watchosApiBase(globals.platform);
    final client = HttpClient();
    try {
      final (int startStatus, Map<String, Object?> start) =
          await _postJson(client, Uri.parse('$api/v1/auth/device'), <String, Object?>{});
      if (startStatus != 200) {
        throwToolExit(loginFailureMessage(startStatus, start));
      }

      final String deviceCode = _requireString(start, 'device_code');
      final String userCode = _requireString(start, 'user_code');
      final String url = start['verification_uri_complete'] is String
          ? start['verification_uri_complete']! as String
          : _requireString(start, 'verification_uri');
      final int interval = (start['interval'] as num?)?.toInt() ?? 5;
      final int expiresIn = (start['expires_in'] as num?)?.toInt() ?? 900;

      globals.printStatus('\nTo sign in, open this URL in a browser:\n');
      globals.printStatus('  $url\n');
      globals.printStatus('and confirm the code: $userCode\n');
      globals.printStatus(kLoginWaitingNote);

      final elapsed = Stopwatch()..start();
      while (elapsed.elapsed.inSeconds < expiresIn) {
        await Future<void>.delayed(Duration(seconds: interval));
        final int status;
        final Map<String, Object?> body;
        try {
          (status, body) = await _postJson(
            client,
            Uri.parse('$api/v1/auth/device/token'),
            <String, Object?>{'device_code': deviceCode},
          );
        } on IOException {
          // Transient network hiccup (e.g. the server closed the keep-alive
          // connection between polls) — retry on the next tick.
          continue;
        }
        if (status == 428) {
          continue; // authorization_pending
        }
        if (status == 200) {
          final String token = _requireString(body, 'token');
          final login = body['login'] as String?;
          writeWatchosCredentials(
            globals.fs,
            globals.platform,
            token: token,
            login: login,
            operatingSystemUtils: globals.os,
          );
          // Engines a signed-out download left owed can arrive now: have the
          // next build fetch them, once, instead of waiting for `precache`.
          final bool owedEngines =
              retryOwedEnginesNextTime(watchosArtifactDirectory(globals.fs), globals.cache);
          globals.printStatus(
            '\nLogged in${login != null ? ' as $login' : ''}. '
            'Credentials stored in ${watchosCredentialsFile(globals.fs, globals.platform).path}.',
          );
          if (owedEngines) {
            globals.printStatus(kOwedEnginesAfterSignInNote);
          }
          return FlutterCommandResult.success();
        }
        throwToolExit(loginFailureMessage(status, body));
      }
      throwToolExit('Login timed out. Run `flutter-watchos login` again.');
    } on IOException catch (e) {
      // SocketException, HandshakeException and HttpException alike: none of
      // them is a bug in this tool, so none deserves a crash report.
      throwToolExit('Could not reach $api: $e');
    } finally {
      client.close(force: true);
    }
  }
}

/// Said while `login` waits for the browser, where the person confirms the
/// code the command printed.
@visibleForTesting
const String kLoginWaitingNote =
    'Waiting for you to confirm the code in the browser (Ctrl-C to cancel)...';

class WatchosLogoutCommand extends FlutterCommand {
  @override
  final String name = 'logout';

  @override
  final String description =
      "Revoke this machine's flutterwatch.dev sign-in and remove the stored credentials.";

  @override
  String get category => FlutterCommandCategory.tools;

  @override
  Future<FlutterCommandResult> runCommand() async {
    // Revoke first, while the token is still at hand. Deleting only the file
    // left the token valid on the service, and every login added one more.
    final String? token = readWatchosToken(globals.fs, globals.platform);
    final TokenRevocation? revocation = token == null
        ? null
        : await revokeWatchosToken(platform: globals.platform, token: token, logger: globals.logger);
    final bool removed = deleteWatchosCredentials(globals.fs, globals.platform);
    globals.printStatus(logoutMessage(removed: removed, revocation: revocation));
    return FlutterCommandResult.success();
  }
}

/// A non-empty string field of a service reply, or a tool exit that names the
/// missing field — a service that changes shape must not read as a crash in
/// this tool.
String _requireString(Map<String, Object?> body, String key) {
  final Object? value = body[key];
  if (value is String && value.isNotEmpty) {
    return value;
  }
  throwToolExit(
    'The flutterwatch.dev service sent an unexpected reply (no "$key"). '
    'Try again in a moment; if it keeps happening, report it with the output '
    'of `flutter-watchos login -v`.',
  );
}

/// What `login` says when the service answers [status] instead of success,
/// with [body] its JSON reply (empty when it sent none).
///
/// A message the service wrote for people, such as the one for too many
/// sign-in attempts, is passed on as it is. A server error sends only a
/// code, and printed alone that read as the whole explanation: an HTTP 500
/// ended `login` with the single word "internal".
@visibleForTesting
String loginFailureMessage(int status, Map<String, Object?> body) {
  final String? message = _nonEmptyString(body['message']);
  final String? code = _nonEmptyString(body['error']);
  if (status >= 500) {
    final String? detail = message ?? code;
    return 'Login failed (HTTP $status${detail == null ? '' : ': $detail'}). '
        'The flutterwatch.dev service had a problem on its side; try again in '
        'a few minutes.';
  }
  if (message != null) {
    return message;
  }
  if (code == 'expired_token') {
    return 'The sign-in code expired before it was confirmed. Run '
        '`flutter-watchos login` again.';
  }
  return 'Login failed (HTTP $status${code == null ? '' : ': $code'}).';
}

String? _nonEmptyString(Object? value) => value is String && value.isNotEmpty ? value : null;

Future<(int, Map<String, Object?>)> _postJson(
  HttpClient client,
  Uri uri,
  Map<String, Object?> body,
) async {
  final HttpClientRequest request = await client.postUrl(uri);
  request.headers.contentType = ContentType.json;
  request.write(json.encode(body));
  final HttpClientResponse response = await request.close();
  final String text = await utf8.decoder.bind(response).join();
  Object? decoded;
  try {
    decoded = json.decode(text);
  } on FormatException {
    decoded = null;
  }
  return (
    response.statusCode,
    decoded is Map<String, Object?> ? decoded : <String, Object?>{},
  );
}
