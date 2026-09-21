// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:file/file.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/platform.dart';

import 'watchos_auth.dart';

/// The release-build registry: after a successful `build watchos --release`,
/// tell flutterwatch.dev which app was built, so the account's console can list
/// the apps it ships and the project can see which apps use the engine.
///
/// What is sent, and nothing else: the bundle id, the app version, the engine
/// id and the build mode, under the account's own token. It happens at build
/// time on the developer's machine; nothing is added to the app, and the app
/// never contacts anyone. See doc/build-registry.md.
///
/// Rules this file keeps:
///   * a build never fails, and is never noticeably slowed, because of it —
///     every error is swallowed and the request is bounded by [_timeout];
///   * it is never silent when it sends: a registered build prints a line;
///   * it is on by default and one command, one flag or one environment
///     variable away from off.

/// `FLUTTER_WATCHOS_BUILD_REGISTRY=0` (or `false` / `off` / `no`) turns the
/// registry off for the process — the switch for CI, where there is no one to
/// run a command. It wins over the saved setting.
const String kBuildRegistryEnv = 'FLUTTER_WATCHOS_BUILD_REGISTRY';

const Duration _timeout = Duration(seconds: 5);

/// `~/.flutter-watchos/settings.json` — next to the credentials, but not in
/// them: signing out must not flip a privacy choice back to its default.
File watchosSettingsFile(FileSystem fileSystem, Platform platform) {
  return watchosCredentialsFile(fileSystem, platform).parent.childFile('settings.json');
}

Map<String, Object?> _readSettings(FileSystem fileSystem, Platform platform) {
  final File file = watchosSettingsFile(fileSystem, platform);
  if (!file.existsSync()) {
    return <String, Object?>{};
  }
  try {
    final Object? data = json.decode(file.readAsStringSync());
    if (data is Map<String, Object?>) {
      return data;
    }
  } on FormatException {
    // A corrupt settings file is treated as no settings, not as a crash.
  }
  return <String, Object?>{};
}

void _writeSetting(FileSystem fileSystem, Platform platform, String key, Object value) {
  final File file = watchosSettingsFile(fileSystem, platform);
  final Map<String, Object?> settings = _readSettings(fileSystem, platform)..[key] = value;
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(settings));
}

/// Why the registry is off, or that it is on.
enum BuildRegistryState { enabled, disabledBySetting, disabledByEnvironment }

BuildRegistryState buildRegistryState(FileSystem fileSystem, Platform platform) {
  final String? env = platform.environment[kBuildRegistryEnv]?.trim().toLowerCase();
  if (env != null && const <String>{'0', 'false', 'off', 'no'}.contains(env)) {
    return BuildRegistryState.disabledByEnvironment;
  }
  return _readSettings(fileSystem, platform)['build_registry'] == false
      ? BuildRegistryState.disabledBySetting
      : BuildRegistryState.enabled;
}

void setBuildRegistryEnabled(FileSystem fileSystem, Platform platform, {required bool enabled}) {
  _writeSetting(fileSystem, platform, 'build_registry', enabled);
}

/// What one registration sends. Exactly these four fields leave the machine.
class ReleaseBuild {
  const ReleaseBuild({
    required this.bundleId,
    required this.appVersion,
    required this.engineVersion,
    this.buildMode = 'release',
  });

  final String bundleId;
  final String? appVersion;
  final String? engineVersion;
  final String buildMode;

  Map<String, Object?> toJson() => <String, Object?>{
    'bundle_id': bundleId,
    'app_version': appVersion,
    'engine_version': engineVersion,
    'build_mode': buildMode,
  };
}

/// Reads the built app's identity from `Runner.app/Info.plist`, where Xcode has
/// already resolved `$(PRODUCT_BUNDLE_IDENTIFIER)` and the version variables —
/// the project files only hold the unexpanded names. [readPlistValue] is
/// `PlistParser.getValueFromFile`, passed in so tests need no `plutil`.
ReleaseBuild? describeBuiltApp({
  required Directory appDir,
  required String? engineVersion,
  required String? Function(String plistPath, String key) readPlistValue,
}) {
  final File infoPlist = appDir.childFile('Info.plist');
  if (!infoPlist.existsSync()) {
    return null;
  }
  final String? bundleId = readPlistValue(infoPlist.path, 'CFBundleIdentifier');
  if (bundleId == null || bundleId.isEmpty) {
    return null;
  }
  final String? version = readPlistValue(infoPlist.path, 'CFBundleShortVersionString');
  final String? build = readPlistValue(infoPlist.path, 'CFBundleVersion');
  // "1.4.0+27", the same shape as pubspec.yaml's version.
  final String? appVersion = (version == null || version.isEmpty)
      ? null
      : (build == null || build.isEmpty || build == version ? version : '$version+$build');
  return ReleaseBuild(bundleId: bundleId, appVersion: appVersion, engineVersion: engineVersion);
}

/// Sends [body] with a bearer [token]; returns the HTTP status. Separate from
/// the policy above so tests can observe exactly what would be sent.
typedef BuildRegistryPost = Future<int> Function(Uri uri, String token, Map<String, Object?> body);

Future<int> _post(Uri uri, String token, Map<String, Object?> body, io.HttpClient client) async {
  client.connectionTimeout = _timeout;
  final io.HttpClientRequest request = await client.postUrl(uri);
  request.headers.contentType = io.ContentType.json;
  request.headers.set(io.HttpHeaders.authorizationHeader, 'Bearer $token');
  request.write(json.encode(body));
  final io.HttpClientResponse response = await request.close();
  await response.drain<void>();
  return response.statusCode;
}

enum BuildRegistration {
  registered,
  disabled,
  notSignedIn,
  /// The service said no (in the closed beta, release builds are not
  /// registered) or could not be reached. Neither is the build's problem.
  notAccepted,
}

/// Registers [build], if the registry is on and this machine is signed in.
/// Never throws and never takes longer than [_timeout].
Future<BuildRegistration> registerReleaseBuild({
  required FileSystem fileSystem,
  required Platform platform,
  required Logger logger,
  required ReleaseBuild build,
  BuildRegistryPost? post,
  io.HttpClient Function()? createHttpClient,
}) async {
  final BuildRegistryState state = buildRegistryState(fileSystem, platform);
  if (state != BuildRegistryState.enabled) {
    logger.printTrace('Build registry is off (${state.name}); not registering this build.');
    return BuildRegistration.disabled;
  }
  final String? token = readWatchosToken(fileSystem, platform);
  if (token == null) {
    logger.printTrace('Not signed in to flutterwatch.dev; not registering this build.');
    return BuildRegistration.notSignedIn;
  }

  final int status;
  try {
    final Uri uri = Uri.parse('${watchosApiBase(platform)}/v1/builds');
    if (post != null) {
      status = await post(uri, token, build.toJson()).timeout(_timeout);
    } else {
      final io.HttpClient client = (createHttpClient ?? io.HttpClient.new)();
      try {
        status = await _post(uri, token, build.toJson(), client).timeout(_timeout);
      } finally {
        client.close(force: true);
      }
    }
  } on Object catch (error) {
    // Offline, a timeout, a captive portal, a bad override URL: all the same
    // to a build that has already succeeded.
    logger.printTrace('Could not register this build with flutterwatch.dev: $error');
    return BuildRegistration.notAccepted;
  }
  if (status != 200) {
    logger.printTrace('flutterwatch.dev did not register this build (HTTP $status).');
    return BuildRegistration.notAccepted;
  }

  final version = build.appVersion == null ? '' : ' ${build.appVersion}';
  logger.printStatus('Registered this release build of ${build.bundleId}$version with flutterwatch.dev.');

  // Say once, in full, what that line means and how to stop it. After that the
  // one line above is reminder enough.
  if (_readSettings(fileSystem, platform)['build_registry_notice_shown'] != true) {
    logger.printStatus(
      '  That sent the bundle id, app version, engine id and build mode to your\n'
      '  flutterwatch.dev account — nothing else, and nothing is added to your app.\n'
      '  It lists the app under "My apps" in your console. To turn it off:\n'
      '    flutter-watchos build-registry --disable      (or $kBuildRegistryEnv=0 on CI)\n'
      '  Details: doc/build-registry.md',
    );
    try {
      _writeSetting(fileSystem, platform, 'build_registry_notice_shown', true);
    } on FileSystemException {
      // A read-only home directory means the notice shows again; that is fine.
    }
  }
  return BuildRegistration.registered;
}
