// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:io' as io;

import 'package:file/file.dart';
import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/os.dart';
import 'package:flutter_tools/src/base/platform.dart';

/// The production flutterwatch.dev API base (auth + artifact downloads).
const String kDefaultWatchosApiBase = 'https://api.flutterwatch.dev';

/// Feature flag for API-gated artifact downloads. When `true`, downloads route
/// through the authenticated flutterwatch.dev service ([kDefaultWatchosApiBase]).
/// Enabled 2026-07-03 now that the service is live at api.flutterwatch.dev with
/// the engine artifacts uploaded. `WATCHOS_ARTIFACTS_API` still overrides the
/// base URL (e.g. for a staging Worker).
const bool kArtifactApiByDefault = true;

/// The artifact API base URL, or `null` when the legacy GitHub Releases
/// download path should be used.
///
/// Set `WATCHOS_ARTIFACTS_API` to a base URL (e.g.
/// `https://api.flutterwatch.dev`) to route artifact downloads through the
/// authenticated flutterwatch.dev service.
///
/// The override must be `https://`. The account token rides every download as
/// a bearer header, so a plain-http host would send it in the clear; the one
/// exception is a local development server (`wrangler dev`), which never
/// leaves the machine. A value that is neither is an error rather than a
/// silent fall-through to production: the person who set it meant something.
String? watchosArtifactApiBase(Platform platform) {
  final String? value = platform.environment['WATCHOS_ARTIFACTS_API'];
  if (value == null || value.isEmpty) {
    return kArtifactApiByDefault ? kDefaultWatchosApiBase : null;
  }
  final Uri? uri = Uri.tryParse(value);
  final bool isSecure = uri != null && uri.scheme == 'https' && uri.host.isNotEmpty;
  final bool isLocalPlainHttp = uri != null &&
      uri.scheme == 'http' &&
      const <String>{'localhost', '127.0.0.1', '::1'}.contains(uri.host);
  if (!isSecure && !isLocalPlainHttp) {
    throwToolExit(
      'WATCHOS_ARTIFACTS_API must be an https:// URL (plain http is accepted '
      'for localhost only), but it is set to "$value". Your account token is '
      'sent with every download, so it is never sent over plain http.',
    );
  }
  return value.endsWith('/') ? value.substring(0, value.length - 1) : value;
}

/// The API base for `flutter-watchos login` — always non-null (login must
/// work even before the artifact-download flag is flipped).
String watchosApiBase(Platform platform) {
  return watchosArtifactApiBase(platform) ?? kDefaultWatchosApiBase;
}

/// `~/.flutter-watchos/credentials.json` — written by `flutter-watchos login`.
File watchosCredentialsFile(FileSystem fileSystem, Platform platform) {
  final String home =
      platform.environment['HOME'] ?? fileSystem.currentDirectory.path;
  return fileSystem
      .directory(home)
      .childDirectory('.flutter-watchos')
      .childFile('credentials.json');
}

/// The stored API token, or `null` when logged out (or the file is corrupt).
String? readWatchosToken(FileSystem fileSystem, Platform platform) {
  final File file = watchosCredentialsFile(fileSystem, platform);
  if (!file.existsSync()) {
    return null;
  }
  try {
    final Object? data = json.decode(file.readAsStringSync());
    if (data is Map<String, Object?>) {
      final Object? token = data['token'];
      if (token is String && token.isNotEmpty) {
        return token;
      }
    }
  } on FormatException {
    // Corrupt credentials file — treat as logged out.
  }
  return null;
}

/// Stores the token, readable by the owner only.
///
/// A file created with the default umask is world-readable from the moment it
/// exists, so the token is never written into one: the file is created empty,
/// narrowed to the owner, and only then filled — under a temporary name that
/// is renamed over the real one, so a reader never sees a partial file
/// either. [operatingSystemUtils] does the narrowing; without it (tests on an
/// in-memory file system) the permissions are left to the file system.
void writeWatchosCredentials(
  FileSystem fileSystem,
  Platform platform, {
  required String token,
  String? login,
  OperatingSystemUtils? operatingSystemUtils,
}) {
  final File file = watchosCredentialsFile(fileSystem, platform);
  final Directory dir = file.parent..createSync(recursive: true);
  operatingSystemUtils?.chmod(dir, '700');
  final File staged = dir.childFile('.${file.basename}.tmp');
  staged.writeAsStringSync('');
  operatingSystemUtils?.chmod(staged, '600');
  staged.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(<String, Object?>{
      'token': token,
      if (login != null) 'login': login,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    }),
  );
  staged.renameSync(file.path);
}

/// Returns `true` if credentials existed and were removed.
bool deleteWatchosCredentials(FileSystem fileSystem, Platform platform) {
  final File file = watchosCredentialsFile(fileSystem, platform);
  if (!file.existsSync()) {
    return false;
  }
  file.deleteSync();
  return true;
}

/// What became of the token `logout` asked the service to revoke.
enum TokenRevocation {
  /// The service revoked it.
  revoked,

  /// The service does not offer revocation (an older service answers 404), or
  /// already refuses the token. Nothing to tell anyone.
  notNeeded,

  /// No answer, or an error: the token may still be valid.
  unreachable,
}

/// Sends the revocation request and returns the HTTP status. Separate so
/// tests can see exactly what is sent.
typedef TokenRevokeRequest = Future<int> Function(Uri uri, String token);

const Duration _revokeTimeout = Duration(seconds: 5);

/// Asks the service to revoke [token] (`DELETE /v1/auth/token`, with the token
/// as the bearer). Best-effort: never throws, never waits longer than five
/// seconds, and a failure never stops `logout` from removing the local file.
Future<TokenRevocation> revokeWatchosToken({
  required Platform platform,
  required String token,
  Logger? logger,
  TokenRevokeRequest? request,
  io.HttpClient Function()? createHttpClient,
}) async {
  final int status;
  try {
    final Uri uri = Uri.parse('${watchosApiBase(platform)}/v1/auth/token');
    if (request != null) {
      status = await request(uri, token).timeout(_revokeTimeout);
    } else {
      final io.HttpClient client = (createHttpClient ?? io.HttpClient.new)()
        ..connectionTimeout = _revokeTimeout;
      try {
        status = await _deleteToken(client, uri, token).timeout(_revokeTimeout);
      } finally {
        client.close(force: true);
      }
    }
  } on Object catch (error) {
    // Offline, a timeout, a bad override URL: the local file goes anyway.
    logger?.printTrace('Could not revoke the token on flutterwatch.dev: $error');
    return TokenRevocation.unreachable;
  }
  logger?.printTrace('flutterwatch.dev answered the token revocation with HTTP $status.');
  if (status >= 200 && status < 300) {
    return TokenRevocation.revoked;
  }
  // 404: a service from before revocation existed. 401/403: it no longer
  // accepts this token anyway.
  if (status == 404 || status == 401 || status == 403) {
    return TokenRevocation.notNeeded;
  }
  return TokenRevocation.unreachable;
}

Future<int> _deleteToken(io.HttpClient client, Uri uri, String token) async {
  final io.HttpClientRequest request = await client.deleteUrl(uri);
  request.headers.set(io.HttpHeaders.authorizationHeader, 'Bearer $token');
  final io.HttpClientResponse response = await request.close();
  await response.drain<void>();
  return response.statusCode;
}

/// What `logout` says, given whether a credentials file was [removed] and
/// what became of its token ([revocation] is null when there was no token to
/// revoke).
String logoutMessage({required bool removed, TokenRevocation? revocation}) {
  if (!removed) {
    return 'Not logged in.';
  }
  return switch (revocation) {
    TokenRevocation.revoked =>
      'Logged out. flutterwatch.dev revoked the sign-in this machine used, and '
          'it is removed from this machine.',
    TokenRevocation.unreachable =>
      'Logged out. The sign-in is removed from this machine, but flutterwatch.dev '
          'could not be reached to revoke it: it stays valid until you revoke it '
          'in your console at $kDefaultWatchosApiBase/.',
    TokenRevocation.notNeeded || null => 'Logged out. The sign-in is removed from this machine.',
  };
}
