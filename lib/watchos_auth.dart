// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';

import 'package:file/file.dart';
import 'package:flutter_tools/src/base/platform.dart';

/// The production flutterwatch.dev API base (auth + artifact downloads).
const String kDefaultWatchosApiBase = 'https://api.flutterwatch.dev';

/// Feature flag for API-gated artifact downloads. While `false`, downloads
/// use the public GitHub Releases URL unless `WATCHOS_ARTIFACTS_API` is set.
/// Flip to `true` once the artifact service is live to make the API the
/// default for everyone.
const bool kArtifactApiByDefault = false;

/// The artifact API base URL, or `null` when the legacy GitHub Releases
/// download path should be used.
///
/// Set `WATCHOS_ARTIFACTS_API` to a base URL (e.g.
/// `https://api.flutterwatch.dev`) to route artifact downloads through the
/// authenticated flutterwatch.dev service.
String? watchosArtifactApiBase(Platform platform) {
  final String? value = platform.environment['WATCHOS_ARTIFACTS_API'];
  if (value == null || value.isEmpty) {
    return kArtifactApiByDefault ? kDefaultWatchosApiBase : null;
  }
  final String base = value.startsWith('http') ? value : kDefaultWatchosApiBase;
  return base.endsWith('/') ? base.substring(0, base.length - 1) : base;
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

void writeWatchosCredentials(
  FileSystem fileSystem,
  Platform platform, {
  required String token,
  String? login,
}) {
  final File file = watchosCredentialsFile(fileSystem, platform);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(<String, Object?>{
      'token': token,
      if (login != null) 'login': login,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    }),
  );
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
