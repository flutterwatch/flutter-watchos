// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';

import 'package:file/file.dart';
import 'package:flutter_tools/src/base/common.dart';
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
