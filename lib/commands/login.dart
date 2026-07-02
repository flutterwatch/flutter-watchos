// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/runner/flutter_command.dart';

import '../watchos_auth.dart';

/// Connects the CLI to a flutterwatch.dev account via an OAuth-style
/// device-code flow: prints a URL + short code, the user approves in a
/// browser, and the CLI polls until it receives an API token. The token is
/// stored in `~/.flutter-watchos/credentials.json` and sent as a Bearer
/// header on engine-artifact downloads.
class WatchosLoginCommand extends FlutterCommand {
  @override
  final String name = 'login';

  @override
  final String description =
      'Connect this machine to your flutterwatch.dev account '
      '(required to download engine artifacts).';

  @override
  String get category => FlutterCommandCategory.tools;

  @override
  Future<FlutterCommandResult> runCommand() async {
    final String api = watchosApiBase(globals.platform);
    final HttpClient client = HttpClient();
    try {
      final (int startStatus, Map<String, Object?> start) =
          await _postJson(client, Uri.parse('$api/v1/auth/device'), <String, Object?>{});
      if (startStatus != 200) {
        throwToolExit(_serverMessage(start) ??
            'Could not reach the flutterwatch.dev service (HTTP $startStatus).');
      }

      final String deviceCode = start['device_code']! as String;
      final String userCode = start['user_code']! as String;
      final String url =
          (start['verification_uri_complete'] ?? start['verification_uri'])! as String;
      final int interval = (start['interval'] as num?)?.toInt() ?? 5;
      final int expiresIn = (start['expires_in'] as num?)?.toInt() ?? 900;

      globals.printStatus('\nTo sign in, open this URL in a browser:\n');
      globals.printStatus('  $url\n');
      globals.printStatus('and confirm the code: $userCode\n');
      globals.printStatus('Waiting for approval (Ctrl-C to cancel)...');

      final Stopwatch elapsed = Stopwatch()..start();
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
          final String token = body['token']! as String;
          final String? login = body['login'] as String?;
          writeWatchosCredentials(globals.fs, globals.platform, token: token, login: login);
          globals.os.chmod(watchosCredentialsFile(globals.fs, globals.platform), '600');
          globals.printStatus(
            '\nLogged in${login != null ? ' as $login' : ''}. '
            'Credentials stored in ${watchosCredentialsFile(globals.fs, globals.platform).path}.',
          );
          return FlutterCommandResult.success();
        }
        throwToolExit(_serverMessage(body) ?? 'Login failed (HTTP $status).');
      }
      throwToolExit('Login timed out. Run `flutter-watchos login` again.');
    } on SocketException catch (e) {
      throwToolExit('Could not reach $api: ${e.message}');
    } finally {
      client.close(force: true);
    }
  }
}

class WatchosLogoutCommand extends FlutterCommand {
  @override
  final String name = 'logout';

  @override
  final String description = 'Remove the stored flutterwatch.dev credentials.';

  @override
  String get category => FlutterCommandCategory.tools;

  @override
  Future<FlutterCommandResult> runCommand() async {
    final bool removed = deleteWatchosCredentials(globals.fs, globals.platform);
    globals.printStatus(removed ? 'Logged out.' : 'Not logged in.');
    return FlutterCommandResult.success();
  }
}

String? _serverMessage(Map<String, Object?> body) {
  final Object? message = body['message'] ?? body['error'];
  return message is String && message.isNotEmpty ? message : null;
}

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
