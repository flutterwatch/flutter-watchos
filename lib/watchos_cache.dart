// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';

import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/os.dart' show OperatingSystemUtils;
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/base/process.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/features.dart';
import 'package:flutter_tools/src/flutter_cache.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/runner/flutter_command.dart';
import 'package:process/process.dart';

import 'watchos_auth.dart';

const String kWatchosEngineStampName = 'watchos-sdk';

/// Every engine artifact zip, in download order.
///
/// NOTE: there is deliberately no `watchos_debug_arm64` — debug (JIT) cannot
/// exist on a physical watch (the device SDK removes the Mach APIs the Dart
/// JIT VM needs). The Simulator is the debug path; devices use profile/release.
const List<String> kWatchosEngineZipNames = <String>[
  'watchos_debug_sim_arm64.zip',
  'watchos_profile_arm64.zip',
  'watchos_release_arm64.zip',
  'host_debug_unopt.zip',
  'host_release.zip',
];

/// Marker file inside the artifact directory listing the zips a previous
/// download was not entitled to (e.g. release engines during the closed
/// beta). While it is non-empty, `flutter-watchos precache` re-checks those
/// zips — so an account that gains release access picks the release engines
/// up with a plain `precache`, no cache-nuking required.
const String kWatchosPendingDownloadsFileName = '.pending_downloads';

/// The zips still owed to this artifact directory, newline-separated in the
/// marker file. Unknown names are ignored so a stale or hand-edited marker
/// can never make the tool fetch arbitrary URLs.
List<String> readPendingEngineZips(Directory artifactDir) {
  final File marker = artifactDir.childFile(kWatchosPendingDownloadsFileName);
  if (!marker.existsSync()) {
    return const <String>[];
  }
  try {
    return marker
        .readAsLinesSync()
        .map((String line) => line.trim())
        .where(kWatchosEngineZipNames.contains)
        .toList();
  } on FileSystemException {
    return const <String>[];
  }
}

/// Records [zipNames] as still-pending downloads (deletes the marker when
/// the list is empty).
void writePendingEngineZips(Directory artifactDir, Iterable<String> zipNames) {
  final File marker = artifactDir.childFile(kWatchosPendingDownloadsFileName);
  final List<String> names = zipNames.toList();
  if (names.isEmpty) {
    if (marker.existsSync()) {
      marker.deleteSync();
    }
    return;
  }
  marker.writeAsStringSync('${names.join('\n')}\n');
}

/// Extracts the machine-readable `error` code from an artifact-API gate
/// response body (e.g. `beta_access_required`, `release_not_in_beta`), or
/// null when the file is missing or not a JSON gate response.
String? apiGateErrorCode(File responseFile) {
  if (!responseFile.existsSync()) {
    return null;
  }
  try {
    final Object? data = json.decode(responseFile.readAsStringSync());
    if (data is Map<String, Object?>) {
      final Object? error = data['error'];
      if (error is String && error.isNotEmpty) {
        return error;
      }
    }
  } on FormatException {
    // Binary zip data or truncated body — not a gate response.
  } on FileSystemException {
    // Disappeared between existsSync() and read.
  }
  return null;
}

/// Fallback base URL for engine artifact zips, used only when the artifact
/// API is switched off ([kArtifactApiByDefault] false, or
/// `WATCHOS_ENGINE_BASE_URL` set to a non-http value). Tag and filename are
/// appended: {base}/{tag}/{name}.zip
///
/// Artifacts are served from flutterwatch.dev, not from GitHub — this repo
/// does not exist, so reaching this URL means the API was disabled without a
/// replacement host being supplied. Kept as the shape of a base URL rather
/// than a working endpoint.
const String kDefaultEngineBaseUrl =
    'https://github.com/flutterwatch/engine-artifacts/releases/download';

Directory watchosToolRootDirectory(FileSystem fileSystem) {
  return fileSystem.directory(Cache.flutterRoot).parent;
}

/// The directory holding the extracted watchOS engine artifacts.
///
/// Dev override: if `WATCHOS_ENGINE_ARTIFACTS` is set to an existing directory,
/// it is used directly (no download/extraction). This lets development point
/// the CLI at a locally-packaged engine workspace while the public
/// artifact-distribution story is finalized. The engine itself is never
/// committed to this repo (closed-source).
///
/// Resolution order:
/// 1. `WATCHOS_ENGINE_ARTIFACTS` env dir (if it exists).
/// 2. A pre-extracted `engine_artifacts/` at the **workspace root** (the CLI
///    checkout's parent), the layout `package_artifacts.sh` produces. This is
///    what makes a local monorepo checkout "just work" without the env var.
/// 3. `engine_artifacts/` inside the CLI checkout (the download target).
Directory watchosArtifactDirectory(FileSystem fileSystem) {
  final String? override = globals.platform.environment['WATCHOS_ENGINE_ARTIFACTS'];
  if (override != null && override.isNotEmpty) {
    final Directory dir = fileSystem.directory(override);
    if (dir.existsSync()) {
      return dir;
    }
  }

  // Workspace-root engine_artifacts/ (sibling of the CLI checkout).
  final Directory workspaceArtifacts =
      watchosToolRootDirectory(fileSystem).parent.childDirectory('engine_artifacts');
  if (workspaceArtifacts.existsSync()) {
    return workspaceArtifacts;
  }

  return watchosToolRootDirectory(fileSystem).childDirectory('engine_artifacts');
}

/// Local override: if zips are present here they are used instead of
/// downloading. Used in development within the monorepo — `artifacts/` lives
/// at the monorepo root, alongside the CLI checkout (so the CLI repo itself
/// stays CLI-only). Not relevant for public users.
Directory _localArtifactArchiveDirectory(FileSystem fileSystem) {
  return watchosToolRootDirectory(fileSystem).parent.childDirectory('artifacts');
}

mixin WatchosRequiredArtifacts on FlutterCommand {
  @override
  Future<Set<DevelopmentArtifact>> get requiredArtifacts async => <DevelopmentArtifact>{
    ...await super.requiredArtifacts,
    WatchosDevelopmentArtifact.watchos,
  };
}

/// See: [DevelopmentArtifact] in `cache.dart`
class WatchosDevelopmentArtifact implements DevelopmentArtifact {
  const WatchosDevelopmentArtifact._(this.name);

  @override
  final String name;

  // [DevelopmentArtifact] declares `feature` so we must override it. watchOS
  // isn't gated behind a Flutter feature flag, so this is intentionally null
  // and a getter (rather than a field initializer) keeps the class
  // const-friendly.
  @override
  Feature? get feature => null;

  static const DevelopmentArtifact watchos = WatchosDevelopmentArtifact._('watchos');
}

/// Extends [FlutterCache] to register [WatchosEngineArtifacts].
class WatchosFlutterCache extends FlutterCache {
  WatchosFlutterCache({
    required Logger logger,
    required super.fileSystem,
    required Platform platform,
    required super.osUtils,
    required super.projectFactory,
    required ProcessManager processManager,
  }) : super(logger: logger, platform: platform) {
    registerArtifact(
      WatchosEngineArtifacts(
        this,
        logger: logger,
        platform: platform,
        processManager: processManager,
      ),
    );
  }
}

/// Downloads and caches watchOS engine artifacts.
///
/// Artifact sources (in priority order):
/// 1. `WATCHOS_ENGINE_ARTIFACTS` env dir — dev override, used as-is
/// 2. Local zip files in `../artifacts/` — dev override
/// 3. GitHub Releases — default for all public users
///
/// The GitHub Releases base URL can be overridden with the
/// `WATCHOS_ENGINE_BASE_URL` environment variable. The release tag comes from
/// `bin/internal/engine.version` (e.g. `v0.1.0-flutter3.44.4`).
class WatchosEngineArtifacts extends EngineCachedArtifact {
  WatchosEngineArtifacts(
    Cache cache, {
    required Logger logger,
    required Platform platform,
    required ProcessManager processManager,
  }) : _logger = logger,
       _platform = platform,
       _processUtils = ProcessUtils(processManager: processManager, logger: logger),
       super(kWatchosEngineStampName, cache, WatchosDevelopmentArtifact.watchos);

  final Logger _logger;
  final Platform _platform;
  final ProcessUtils _processUtils;

  static const List<String> _artifactZipNames = kWatchosEngineZipNames;

  @override
  String get displayName => 'watchOS Engine';

  @override
  Directory get location => watchosArtifactDirectory(globals.fs);

  @override
  String? get version {
    final File versionFile = globals.fs
        .directory(Cache.flutterRoot)
        .parent
        .childDirectory('bin')
        .childDirectory('internal')
        .childFile('engine.version');
    return versionFile.existsSync() ? versionFile.readAsStringSync().trim() : null;
  }

  /// The release tag, e.g. `v0.1.0-flutter3.44.1`.
  String get releaseTag {
    if (version == null || version!.isEmpty) {
      throwToolExit(
        'Could not read engine version from bin/internal/engine.version.\n'
        'Run `flutter-watchos precache` to download the required artifacts.',
      );
    }
    return version!;
  }

  /// Base URL for GitHub Releases downloads.
  /// Override with WATCHOS_ENGINE_BASE_URL for custom artifact hosting.
  String get engineBaseUrl {
    return _platform.environment['WATCHOS_ENGINE_BASE_URL'] ?? kDefaultEngineBaseUrl;
  }

  /// Full download URL for a given zip file. When the flutterwatch.dev
  /// artifact API is active (see [watchosArtifactApiBase]) the download is
  /// authenticated and access-gated server-side; otherwise it is the legacy
  /// public GitHub Releases URL.
  String artifactDownloadUrl(String zipName) {
    final String? apiBase = watchosArtifactApiBase(_platform);
    if (apiBase != null) {
      return '$apiBase/v1/artifacts/$releaseTag/$zipName';
    }
    return '$engineBaseUrl/$releaseTag/$zipName';
  }

  @override
  List<List<String>> getBinaryDirs() => <List<String>>[
    <String>['watchos_debug_sim_arm64', ''],
    <String>['watchos_profile_arm64', ''],
    <String>['watchos_release_arm64', ''],
    <String>['host_debug_unopt', ''],
    <String>['host_release', ''],
  ];

  @override
  List<String> getLicenseDirs() => const <String>[];

  @override
  List<String> getPackageDirs() => const <String>[];

  @override
  Future<void> updateInner(
    ArtifactUpdater artifactUpdater,
    FileSystem fileSystem,
    OperatingSystemUtils operatingSystemUtils,
  ) async {
    // --- Strategy 1: WATCHOS_ENGINE_ARTIFACTS points at a ready dir ---
    final String? envDir = _platform.environment['WATCHOS_ENGINE_ARTIFACTS'];
    if (envDir != null && envDir.isNotEmpty && fileSystem.directory(envDir).existsSync()) {
      _logger.printTrace('Using watchOS engine artifacts from WATCHOS_ENGINE_ARTIFACTS=$envDir');
      return;
    }

    // --- Strategy 1b: the resolved artifact dir is already populated ---
    // `location` (watchosArtifactDirectory) may resolve to a pre-extracted
    // engine_artifacts/ at the workspace root, or a previous download. If it
    // already holds extracted engine variant dirs, use it as-is — except for
    // zips a previous download was not yet entitled to, which are retried
    // here (this is how release engines arrive after an account upgrade).
    if (location.existsSync() &&
        location
            .listSync()
            .whereType<Directory>()
            .any((Directory d) => fileSystem.path.basename(d.path).startsWith('watchos_'))) {
      final List<String> pending = readPendingEngineZips(location);
      if (pending.isNotEmpty && watchosArtifactApiBase(_platform) != null) {
        await _fetchPendingZips(pending, fileSystem, operatingSystemUtils);
        return;
      }
      _logger.printTrace('Using pre-extracted watchOS engine artifacts at ${location.path}');
      return;
    }

    // --- Strategy 2: local zips (dev override) ---
    final Directory localArchiveDir = _localArtifactArchiveDirectory(fileSystem);
    final List<File> localZips = _artifactZipNames
        .map((String name) => localArchiveDir.childFile(name))
        .where((File f) => f.existsSync())
        .toList();

    if (localZips.isNotEmpty) {
      await _extractZips(localZips, fileSystem, operatingSystemUtils);
      return;
    }

    // --- Strategy 3: download from GitHub Releases ---
    final String tag = releaseTag;

    if (location.existsSync()) {
      location.deleteSync(recursive: true);
    }
    location.createSync(recursive: true);

    final Directory tempDir = fileSystem.systemTempDirectory.createTempSync(
      'flutter_watchos_artifacts.',
    );

    final apiMode = watchosArtifactApiBase(_platform) != null;
    final String? token = apiMode ? readWatchosToken(globals.fs, _platform) : null;

    final skippedZips = <String>[];
    try {
      var index = 0;
      for (final String zipName in _artifactZipNames) {
        index++;
        final String url = artifactDownloadUrl(zipName);
        final File tempZip = tempDir.childFile(zipName);
        final Status status = _logger.startProgress(
          _treeLine(index, _artifactZipNames.length, _friendlyName(zipName)),
        );
        try {
          final RunResult curlResult = await _processUtils.run(<String>[
            'curl',
            '--location',
            if (!apiMode) '--fail',
            '--silent',
            '--show-error',
            // In API mode capture the HTTP status so gate responses (401/403)
            // can be surfaced with the server's message instead of a bare
            // curl failure.
            if (apiMode) ...<String>['--write-out', '%{http_code}'],
            if (token != null) ...<String>['--header', 'Authorization: Bearer $token'],
            '--output', tempZip.path,
            url,
          ]);

          if (apiMode) {
            final String httpCode = curlResult.stdout.trim();
            if (curlResult.exitCode != 0 || httpCode != '200') {
              // Release engines are not part of the closed beta. Skip them so
              // `precache` completes with the debug + profile artifacts a
              // beta account can actually use; anything else stays fatal.
              // The skip is recorded so a later `precache` retries it once
              // the account has release access.
              if (apiGateErrorCode(tempZip) == 'release_not_in_beta') {
                status.cancel();
                skippedZips.add(zipName);
                _logger.printStatus(
                  _treeLine(index, _artifactZipNames.length,
                      '${_friendlyName(zipName)} — not in the closed beta, skipped'),
                );
                continue;
              }
              status.cancel();
              throwToolExit(_apiGateMessage(zipName, httpCode, tempZip, curlResult));
            }
          } else if (curlResult.exitCode != 0) {
            status.cancel();
            // Only reachable when WATCHOS_ENGINE_BASE_URL points the CLI at a
            // custom host, so send the user to that host — not to the default
            // one, which is not where their artifacts live.
            throwToolExit(
              'Failed to download $zipName from $url.\n\n${curlResult.stderr}\n\n'
              'Check that "$tag/$zipName" exists under the artifact host:\n'
              '  $engineBaseUrl\n\n'
              'The tag comes from bin/internal/engine.version; the host from '
              'the WATCHOS_ENGINE_BASE_URL environment variable. Unset that '
              'variable to download from flutterwatch.dev instead.',
            );
          }

          final RunResult unzipResult = await _processUtils.run(<String>[
            'unzip',
            '-q',
            tempZip.path,
            '-d',
            location.path,
          ]);

          if (unzipResult.exitCode != 0) {
            status.cancel();
            throwToolExit('Failed to extract $zipName.\n\n${unzipResult.stderr}');
          }
        } finally {
          status.stop();
        }
      }
    } finally {
      tempDir.deleteSync(recursive: true);
    }

    writePendingEngineZips(location, skippedZips);

    final Directory macOsMetaDir = location.childDirectory('__MACOSX');
    if (macOsMetaDir.existsSync()) {
      macOsMetaDir.deleteSync(recursive: true);
    }

    _makeFilesExecutable(location, operatingSystemUtils);
  }

  /// Retries the zips a previous download was not entitled to, on top of an
  /// otherwise-populated artifact directory.
  ///
  /// Nothing here is fatal: the existing debug/profile engines keep working
  /// whatever happens, so a still-gated zip is re-skipped (and stays pending)
  /// and a transient failure is reported and retried on the next `precache`.
  Future<void> _fetchPendingZips(
    List<String> pending,
    FileSystem fileSystem,
    OperatingSystemUtils operatingSystemUtils,
  ) async {
    final String? token = readWatchosToken(globals.fs, _platform);
    final Directory tempDir = fileSystem.systemTempDirectory.createTempSync(
      'flutter_watchos_artifacts.',
    );
    final stillPending = <String>[];
    var extractedAny = false;
    try {
      var index = 0;
      for (final zipName in pending) {
        index++;
        final String url = artifactDownloadUrl(zipName);
        final File tempZip = tempDir.childFile(zipName);
        final Status status = _logger.startProgress(
          _treeLine(index, pending.length, _friendlyName(zipName)),
        );
        try {
          final RunResult curlResult = await _processUtils.run(<String>[
            'curl',
            '--location',
            '--silent',
            '--show-error',
            '--write-out', '%{http_code}',
            if (token != null) ...<String>['--header', 'Authorization: Bearer $token'],
            '--output', tempZip.path,
            url,
          ]);

          final String httpCode = curlResult.stdout.trim();
          if (curlResult.exitCode != 0 || httpCode != '200') {
            status.cancel();
            stillPending.add(zipName);
            final note = apiGateErrorCode(tempZip) == 'release_not_in_beta'
                ? 'not in the closed beta, skipped'
                : 'unavailable right now, will retry on the next precache';
            _logger.printStatus(
              _treeLine(index, pending.length, '${_friendlyName(zipName)} — $note'),
            );
            continue;
          }

          final RunResult unzipResult = await _processUtils.run(<String>[
            'unzip',
            '-q',
            '-o',
            tempZip.path,
            '-d',
            location.path,
          ]);
          if (unzipResult.exitCode != 0) {
            status.cancel();
            throwToolExit('Failed to extract $zipName.\n\n${unzipResult.stderr}');
          }
          extractedAny = true;
        } finally {
          status.stop();
        }
      }
    } finally {
      tempDir.deleteSync(recursive: true);
    }

    writePendingEngineZips(location, stillPending);

    final Directory macOsMetaDir = location.childDirectory('__MACOSX');
    if (macOsMetaDir.existsSync()) {
      macOsMetaDir.deleteSync(recursive: true);
    }
    if (extractedAny) {
      _makeFilesExecutable(location, operatingSystemUtils);
    }
  }

  /// The tool-exit message for a failed API-mode download. Gate responses
  /// (not signed in, no access) arrive as JSON with a human-readable
  /// `message` — surface that verbatim so access policy and wording stay
  /// entirely server-side.
  ///
  /// See also [apiGateErrorCode], which extracts the machine-readable
  /// `error` code used to decide whether a gate is fatal or skippable.
  String _apiGateMessage(
    String zipName,
    String httpCode,
    File responseFile,
    RunResult curlResult,
  ) {
    if (responseFile.existsSync()) {
      try {
        final Object? data = json.decode(responseFile.readAsStringSync());
        if (data is Map<String, Object?>) {
          final Object? message = data['message'];
          if (message is String && message.isNotEmpty) {
            return message;
          }
        }
      } on FormatException {
        // Not a JSON gate response — fall through to the generic message.
      }
    }
    final String detail = curlResult.stderr.trim();
    return 'Failed to download $zipName from the flutterwatch.dev artifact '
        'service (HTTP $httpCode).'
        '${detail.isEmpty ? '' : '\n\n$detail'}\n\n'
        'If you are not signed in yet, run `flutter-watchos login`.';
  }

  Future<void> _extractZips(
    List<File> zips,
    FileSystem fileSystem,
    OperatingSystemUtils operatingSystemUtils,
  ) async {
    if (location.existsSync()) {
      location.deleteSync(recursive: true);
    }
    location.createSync(recursive: true);

    var index = 0;
    for (final zip in zips) {
      index++;
      final Status status = _logger.startProgress(
        _treeLine(index, zips.length, _friendlyName(zip.basename)),
      );
      try {
        final RunResult result = await _processUtils.run(<String>[
          'unzip',
          '-q',
          zip.path,
          '-d',
          location.path,
        ]);
        if (result.exitCode != 0) {
          status.cancel();
          throwToolExit('Failed to extract ${zip.basename}.\n\n${result.stderr}');
        }
      } finally {
        status.stop();
      }
    }

    final Directory macOsMetaDir = location.childDirectory('__MACOSX');
    if (macOsMetaDir.existsSync()) {
      macOsMetaDir.deleteSync(recursive: true);
    }

    _makeFilesExecutable(location, operatingSystemUtils);
  }

  /// Formats one zip's progress line as a child of the framework-printed
  /// `[i/N] engine` header, mirroring stock Flutter's nested artifact tree.
  String _treeLine(int index, int total, String name) {
    final prefix = index == total ? '└─' : '├─';
    return '  $prefix [$index/$total] $name';
  }

  /// Converts a zip filename to the human-readable progress label.
  ///
  /// Host builds are prefixed `watchos-host-…` so they don't collide with the
  /// `host-debug` / `host-release` artifacts the parent FlutterCache fetches.
  String _friendlyName(String zipName) {
    final String stem = zipName.endsWith('.zip')
        ? zipName.substring(0, zipName.length - 4)
        : zipName;
    final String dashed = stem.replaceAll('_', '-');
    if (dashed.startsWith('host-')) {
      return 'watchos-$dashed';
    }
    return dashed;
  }

  void _makeFilesExecutable(Directory dir, OperatingSystemUtils operatingSystemUtils) {
    operatingSystemUtils.chmod(dir, 'a+r,a+x');
    for (final File file in dir.listSync(recursive: true).whereType<File>()) {
      if (file.basename == 'gen_snapshot' ||
          file.basename == 'frontend_server_aot.dart.snapshot') {
        operatingSystemUtils.chmod(file, 'a+r,a+x');
      }
    }
  }
}
