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
import 'package:flutter_tools/src/base/utils.dart' show getElapsedAsMilliseconds, getElapsedAsSeconds;
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/features.dart';
import 'package:flutter_tools/src/flutter_cache.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/runner/flutter_command.dart';
import 'package:process/process.dart';

import 'watchos_auth.dart';

const String kWatchosEngineStampName = 'watchos-sdk';

/// The public engine: the one a machine that is not signed in gets, and the
/// only one a debug (Simulator) build needs. It is never left owed.
const String kWatchosSimulatorEngineZipName = 'watchos_debug_sim_arm64.zip';

/// Every engine artifact zip, in download order.
///
/// NOTE: there is deliberately no `watchos_debug_arm64` — debug (JIT) cannot
/// exist on a physical watch (the device SDK removes the Mach APIs the Dart
/// JIT VM needs). The Simulator is the debug path; devices use profile/release.
const List<String> kWatchosEngineZipNames = <String>[
  kWatchosSimulatorEngineZipName,
  'watchos_profile_arm64.zip',
  'watchos_release_arm64.zip',
  'host_debug_unopt.zip',
  'host_release.zip',
];

/// Marker file inside the artifact directory listing the zips a previous
/// download could not have yet — the device and release engines of a machine
/// that was not signed in, or engines the service does not give that account.
/// While it is non-empty, `flutter-watchos precache` re-checks those zips, and
/// so does the first build after `flutter-watchos login` — so signing in, or
/// gaining access, picks the missing engines up without any cache-nuking.
/// Other commands leave them alone: nothing about them can change between
/// one build and the next.
const String kWatchosPendingDownloadsFileName = '.pending_downloads';

/// Marker file recording the engine tag a *downloaded* artifact directory was
/// extracted from.
///
/// Without it an upgrade is silent: the download target is reused whenever it
/// merely contains `watchos_*` directories, so a user who already had the
/// previous engine kept it after bumping `bin/internal/engine.version`, and
/// the "run `precache` after upgrading" instruction did nothing.
///
/// Only written by the downloader. A hand-built engine — `WATCHOS_ENGINE_ARTIFACTS`
/// or a workspace-root `engine_artifacts/` — has no stamp and must never be
/// treated as stale, because there is no tag it could be compared against.
const String kWatchosEngineVersionFileName = '.engine_version';

/// Curl arguments that send the bearer token, WITHOUT putting it in argv.
///
/// `--header 'Authorization: Bearer …'` leaks the token twice over: argv is
/// world-readable, so any user on the machine sees it in `ps` for as long as
/// the download runs, and `precache -v` prints the command it is about to run —
/// which is exactly the output people paste into bug reports. curl reads the
/// same header from a `--config` file, whose contents it never echoes.
///
/// The file is written inside [tempDir] (already 0700 from `createTempSync`),
/// narrowed to owner-only, and goes when the caller deletes that directory.
/// Returns no arguments at all when there is no token — the anonymous case.
List<String> curlAuthArgs(
  String? token,
  Directory tempDir,
  OperatingSystemUtils operatingSystemUtils,
) {
  if (token == null || token.isEmpty) {
    return const <String>[];
  }
  final File config = tempDir.childFile('auth.curl');
  config.writeAsStringSync('header = "Authorization: Bearer $token"\n');
  operatingSystemUtils.chmod(config, 'go-rwx');
  return <String>['--config', config.path];
}

/// The engine tag [artifactDir] was downloaded from, or null when unstamped.
String? readEngineVersionStamp(Directory artifactDir) {
  final File stamp = artifactDir.childFile(kWatchosEngineVersionFileName);
  if (!stamp.existsSync()) {
    return null;
  }
  try {
    final String tag = stamp.readAsStringSync().trim();
    return tag.isEmpty ? null : tag;
  } on FileSystemException {
    return null;
  }
}

/// Records that [artifactDir] holds the artifacts for [tag].
void writeEngineVersionStamp(Directory artifactDir, String tag) {
  artifactDir.childFile(kWatchosEngineVersionFileName).writeAsStringSync('$tag\n');
}

/// How an extracted engine directory relates to the tag being asked for — the
/// three cases are not the same, and collapsing them to a bool is what let a
/// stale engine pass for a fresh one.
enum EngineArtifactsMatch {
  /// Stamped with this exact tag. Reuse it.
  stamped,

  /// Stamped with something else: an engine bump that has not arrived yet.
  /// Re-fetch.
  mismatched,

  /// No stamp at all. Reusable, but only because refusing would break a
  /// hand-assembled local engine — NOT because it was checked. See
  /// [engineArtifactsMatchTag].
  unverifiable,
}

/// Whether [artifactDir] can be reused for [tag], and on what grounds.
///
/// A stamped directory is reusable only when it matches, which is what makes an
/// engine bump reach an existing install.
///
/// An unstamped one is reusable too, and that is the dangerous case. It is
/// meant for a local engine somebody built and dropped in, which has no id to
/// declare — but nothing distinguishes it from a download whose stamp went
/// missing, or a tree that has simply gone stale. On 2026-08-25 exactly that
/// happened: a four-day-old engine_artifacts/ answered for a freshly built id,
/// `precache` reported success, and the CLI ran the old binary. Everything this
/// project's tooling produces is stamped now (package_artifacts.sh writes it),
/// so an unstamped tree really is hand-assembled — and the caller says so out
/// loud rather than reusing it in silence.
EngineArtifactsMatch engineArtifactsMatch(Directory artifactDir, String tag) {
  final String? stamped = readEngineVersionStamp(artifactDir);
  if (stamped == null) {
    return EngineArtifactsMatch.unverifiable;
  }
  return stamped == tag
      ? EngineArtifactsMatch.stamped
      : EngineArtifactsMatch.mismatched;
}

/// Whether [artifactDir] can be reused for [tag] at all.
bool engineArtifactsMatchTag(Directory artifactDir, String tag) =>
    engineArtifactsMatch(artifactDir, tag) != EngineArtifactsMatch.mismatched;

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

/// Makes the next command that needs the engine retry the zips [artifactDir]
/// still owes, by invalidating the engine's cache stamp; returns whether any
/// are owed.
///
/// Owed engines do not make the cache stale by themselves (see
/// [WatchosEngineArtifacts.isUpToDateInner]), so something has to say when a
/// retry could turn out differently: `precache`, and signing in.
bool retryOwedEnginesNextTime(Directory artifactDir, Cache cache) {
  if (readPendingEngineZips(artifactDir).isEmpty) {
    return false;
  }
  cache.setStampFor(kWatchosEngineStampName, 'pending-downloads');
  return true;
}

/// Said by `login` when the machine owes engines from a signed-out download.
const String kOwedEnginesAfterSignInNote =
    'The engines for a physical watch and for release builds download with '
    'your next build, or run `flutter-watchos precache` to fetch them now.';

/// A gate response that leaves one zip out instead of ending the download.
enum SkippedGate {
  /// The service does not give this account that engine.
  notForThisAccount('not available to this account, skipped'),

  /// Nobody is signed in, and that engine needs an account.
  needsAccount('needs an account, skipped'),

  /// The service refused the engine to the account signed in here (it has
  /// switched the account off). Its own words follow the download, once.
  refused('refused, see below');

  const SkippedGate(this.note);

  /// What the progress line says after the engine's name.
  final String note;
}

/// Whether the gate response [errorCode] may be skipped, and why; null when it
/// must end the download.
///
/// Which engines an account gets is the service's decision, and it changes
/// without a CLI release, so this reads the machine-readable code and nothing
/// else:
///
///   * `release_not_in_beta` — the account is fine, that engine is not part
///     of what it has. The rest of the download is still exactly what the
///     account can use.
///   * `auth_required` with nobody signed in, once an engine is already in
///     hand ([haveAnEngine]): the Simulator engine is public, so a machine
///     that never signed in still gets a working Simulator setup. Refused on
///     the very first zip it stays fatal — there would be nothing to install —
///     and so does a token the service no longer accepts, because that person
///     meant to be signed in and needs to hear that they are not.
///   * `access_inactive`, once an engine is in hand: the service has switched
///     the account off, but it still serves the public Simulator engine to it,
///     so the download keeps that engine rather than throwing it away. What the
///     service says about the account is shown once, after the download.
SkippedGate? skippableGate(
  String? errorCode, {
  required bool signedIn,
  required bool haveAnEngine,
}) {
  return switch (errorCode) {
    'release_not_in_beta' => SkippedGate.notForThisAccount,
    'auth_required' when !signedIn && haveAnEngine => SkippedGate.needsAccount,
    'access_inactive' when haveAnEngine => SkippedGate.refused,
    _ => null,
  };
}

/// Said once after a download that left engines out for want of an account.
const String kSignInForMoreEnginesHint =
    'Not signed in: the Simulator engine is ready. Engines for a watch and for '
    'release builds need a flutterwatch.dev account — run `flutter-watchos '
    'login`, then `flutter-watchos precache`.';

/// Said after the service's own message when it refused the token this
/// machine sent: the person meant to be signed in, and is not any more.
const String kSignInNotAcceptedNote =
    'The sign-in stored on this machine was not accepted; run '
    '`flutter-watchos login` again.';

/// Said after the service's message when it switched the account off: the
/// Simulator engine stays usable.
const String kSimulatorStillReadyNote = 'The Simulator engine is ready; it needs no account.';

/// Why a precompiled build cannot go ahead, when the engine it needs is one a
/// download left out; null when nothing it needs is known to be owed.
///
/// Without this the build fails further in with "libflutter_engine.dylib not
/// found — run precache", and for a machine that is not signed in `precache`
/// alone changes nothing. [release] picks the release engines over the profile
/// ones; the Simulator engine is never owed, so debug builds do not ask.
String? owedEngineAdvice(
  Directory artifactDir, {
  required bool release,
  required bool signedIn,
}) {
  final needed = release
      ? const <String>['watchos_release_arm64.zip', 'host_release.zip']
      : const <String>['watchos_profile_arm64.zip', 'host_debug_unopt.zip'];
  final List<String> owed = readPendingEngineZips(artifactDir);
  if (!needed.any(owed.contains)) {
    return null;
  }
  final mode = release ? 'release' : 'profile';
  if (!signedIn) {
    return 'The $mode engine is not installed: it needs a flutterwatch.dev '
        'account, and this machine is not signed in.\n'
        'Run `flutter-watchos login`, then `flutter-watchos precache`, and '
        'build again.\n'
        'The Simulator needs no account:\n'
        '  flutter-watchos build watchos --simulator';
  }
  // Signed in, an engine is owed after a download that was refused it or
  // could not reach the service; which of the two, `precache` says.
  return 'The $mode engine is not installed yet: the last download did not '
      'get it.\n'
      'Run `flutter-watchos precache` to fetch it; it says why if it cannot.';
}

/// The build modes an engine directory can serve, each with the engine
/// directories it needs: debug runs on the Simulator; profile and release
/// run on a watch and also need their host SDK to compile against.
const Map<String, List<String>> kWatchosEngineModes = <String, List<String>>{
  'Simulator (debug)': <String>['watchos_debug_sim_arm64'],
  'profile': <String>['watchos_profile_arm64', 'host_debug_unopt'],
  'release': <String>['watchos_release_arm64', 'host_release'],
};

/// The modes of [kWatchosEngineModes] whose engine directories are all in
/// [artifactDir].
List<String> installedEngineModes(Directory artifactDir) => <String>[
  for (final MapEntry<String, List<String>> mode in kWatchosEngineModes.entries)
    if (mode.value.every((String dir) => artifactDir.childDirectory(dir).existsSync())) mode.key,
];

/// The modes of [kWatchosEngineModes] that need an engine [artifactDir] still
/// owes (see [readPendingEngineZips]).
List<String> owedEngineModes(Directory artifactDir) {
  final Set<String> owed = readPendingEngineZips(
    artifactDir,
  ).map((String zip) => zip.substring(0, zip.length - '.zip'.length)).toSet();
  return <String>[
    for (final MapEntry<String, List<String>> mode in kWatchosEngineModes.entries)
      if (mode.value.any(owed.contains)) mode.key,
  ];
}

/// Extracts the machine-readable `error` code from an artifact-API gate
/// response body (e.g. `auth_required`, `release_not_in_beta`), or null when
/// the file is missing or not a JSON gate response.
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
///
/// [platform] defaults to the context's; tests without a context pass one.
Directory watchosArtifactDirectory(FileSystem fileSystem, {Platform? platform}) {
  final String? override =
      (platform ?? globals.platform).environment['WATCHOS_ENGINE_ARTIFACTS'];
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

/// The `engine_artifacts/` inside the CLI checkout: the one directory this
/// tool downloads into, and so the only one it may delete. A
/// `WATCHOS_ENGINE_ARTIFACTS` directory or a workspace-root `engine_artifacts/`
/// is somebody's hand-built engine.
Directory watchosDownloadedArtifactDirectory(FileSystem fileSystem) =>
    watchosToolRootDirectory(fileSystem).childDirectory('engine_artifacts');

/// Whether [artifactDir] is this tool's own download target
/// ([watchosDownloadedArtifactDirectory]).
bool isDownloadedArtifactDirectory(FileSystem fileSystem, Directory artifactDir) =>
    fileSystem.path.equals(artifactDir.path, watchosDownloadedArtifactDirectory(fileSystem).path);

/// Where [redownloadEngine] keeps the engine it is replacing.
Directory _previousEngineDirectory(Directory artifactDir) =>
    artifactDir.parent.childDirectory('${artifactDir.basename}.previous');

/// Puts back the engine a `precache --force` killed mid-download left aside
/// (see [redownloadEngine]), when nothing has taken its place; returns
/// whether it did. `precache` calls it first, with or without --force.
///
/// That copy is the only working engine on the machine. `precache` ignored
/// it and downloaded every engine again, and `precache --force` deleted it
/// before its own download, so if that one failed too there was no engine
/// left at all.
///
/// Not called from the engine update itself: inside [redownloadEngine] the
/// engine is aside on purpose, and putting it back there would stop the
/// download --force asked for. A build after a killed run still downloads
/// the engine again.
bool restoreInterruptedRedownload(Directory artifactDir) {
  final Directory previous = _previousEngineDirectory(artifactDir);
  if (artifactDir.existsSync() || !previous.existsSync()) {
    return false;
  }
  previous.renameSync(artifactDir.path);
  return true;
}

/// Runs [download] — the engine update of `precache --force` — with the
/// engine in [artifactDir] moved aside rather than deleted: if the download
/// fails (no network, a refusal), the previous engine is put back instead of
/// being lost with it. The copy goes once the download has succeeded.
///
/// The copy sits beside [artifactDir] as `engine_artifacts.previous`, a name
/// .gitignore covers, so a run killed halfway leaves nothing that would make
/// the checkout look modified to `upgrade`; the next `precache` puts it back
/// ([restoreInterruptedRedownload]).
Future<void> redownloadEngine(Directory artifactDir, Future<void> Function() download) async {
  restoreInterruptedRedownload(artifactDir);
  final Directory previous = _previousEngineDirectory(artifactDir);
  if (previous.existsSync()) {
    // Left beside an engine that is in place: by a run killed after its new
    // engine went in, or before a build downloaded one. The engine in place
    // is the newer one.
    previous.deleteSync(recursive: true);
  }
  final bool hadEngine = artifactDir.existsSync();
  if (hadEngine) {
    artifactDir.renameSync(previous.path);
  }
  try {
    await download();
  } on Object {
    if (hadEngine) {
      if (artifactDir.existsSync()) {
        artifactDir.deleteSync(recursive: true);
      }
      previous.renameSync(artifactDir.path);
    }
    rethrow;
  }
  if (previous.existsSync()) {
    previous.deleteSync(recursive: true);
  }
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

/// The engine id this CLI is pinned to (`bin/internal/engine.version`, e.g.
/// `engine-ddc777be435e`), or null when the file is missing.
String? pinnedWatchosEngineVersion() {
  final File versionFile = globals.fs
      .directory(Cache.flutterRoot)
      .parent
      .childDirectory('bin')
      .childDirectory('internal')
      .childFile('engine.version');
  return versionFile.existsSync() ? versionFile.readAsStringSync().trim() : null;
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
/// `bin/internal/engine.version` (e.g. `engine-ddc777be435e`).
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

  /// How long curl may take to connect to the artifact service. The download
  /// itself has no limit; a service that cannot be reached at all should not
  /// hold a build up for the system's TCP timeout.
  static const int _connectTimeoutSeconds = 15;

  @override
  String get displayName => 'watchOS Engine';

  @override
  Directory get location => watchosArtifactDirectory(globals.fs);

  @override
  String? get version => pinnedWatchosEngineVersion();

  /// The engine id the artifacts are stored under, e.g.
  /// `engine-ddc777be435e`, from `bin/internal/engine.version`.
  ///
  /// It names WHAT WAS BUILT rather than the Flutter version it happened to be
  /// built for, which is the same choice flutter-tvos makes and for the same
  /// reason: a version-shaped tag ("v0.1.8-flutter3.47.1") goes stale the
  /// moment one engine is reused across two Flutter releases, and forces a
  /// rebuild and a 75 MB re-upload of bytes that are already there. The id
  /// comes from engine_build/scripts/engine_id.sh, which hashes what actually
  /// determines the binary, so a framework-only release simply leaves this pin
  /// alone.
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

  /// Up to date when every engine directory is there, or is one a previous
  /// download left owed.
  ///
  /// The inherited check wants all five directories, so a machine that never
  /// signed in — which has only the Simulator engine — was never up to date:
  /// every `run`, `build` and `drive` went back to the service for the four
  /// engines it had just been told need an account, printed four "skipped"
  /// lines and the sign-in hint again, and offline it waited on the network
  /// first. Nothing about an owed engine changes from one build to the next;
  /// `precache` and `login` invalidate the stamp when a retry could succeed
  /// (see [retryOwedEnginesNextTime]).
  ///
  /// The Simulator engine never counts as owed, so a hand-edited marker cannot
  /// hide a missing one.
  @override
  bool isUpToDateInner(FileSystem fileSystem) {
    final owed = <String>{
      for (final String zip in readPendingEngineZips(location))
        if (zip != kWatchosSimulatorEngineZipName) zip.substring(0, zip.length - '.zip'.length),
    };
    return getBinaryDirs().every(
      (List<String> dir) => owed.contains(dir[0]) || location.childDirectory(dir[0]).existsSync(),
    );
  }

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
    // zips a previous download left owed, which are retried here (this is how
    // the device and release engines arrive after `login`).
    if (location.existsSync() &&
        location
            .listSync()
            .whereType<Directory>()
            .any((Directory d) => fileSystem.path.basename(d.path).startsWith('watchos_')) &&
        engineArtifactsMatchTag(location, releaseTag)) {
      final List<String> pending = readPendingEngineZips(location);
      if (pending.isNotEmpty && watchosArtifactApiBase(_platform) != null) {
        await _fetchPendingZips(pending, fileSystem, operatingSystemUtils);
        return;
      }
      if (engineArtifactsMatch(location, releaseTag) ==
          EngineArtifactsMatch.unverifiable) {
        // Reused, but nobody checked it. Said at warning level because the
        // failure it precedes is silent: the wrong engine runs, everything
        // reports success, and the symptom shows up somewhere else entirely.
        _logger.printWarning(
          'Using an unstamped watchOS engine at ${location.path}.\n'
          'It carries no $kWatchosEngineVersionFileName file, so there is no '
          'way to tell whether it is $releaseTag. If you built it yourself, '
          'write that file with the engine id it was built from. To fetch '
          '$releaseTag instead, delete the directory and re-run '
          '`flutter-watchos precache`.',
        );
      } else {
        _logger.printTrace('Using pre-extracted watchOS engine artifacts at ${location.path}');
      }
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

    // --- Strategy 3: download from the artifact service ---
    final String tag = releaseTag;

    // Every zip is extracted into a staging directory beside `location`, and
    // the tree moves into place in one rename after the last zip is in and
    // the stamp is written. Until then whatever engine `location` already
    // holds keeps working, and a run that dies halfway — Ctrl-C, a dropped
    // connection, a full disk — leaves nothing the next run could mistake for
    // an engine. Extracting straight into `location` did exactly that: the
    // stamp is written last, so an interrupted download left an unstamped
    // tree that Strategy 1b then reused as though it were hand-built.
    final Directory staging = _createStagingDirectory();

    final Directory tempDir = fileSystem.systemTempDirectory.createTempSync(
      'flutter_watchos_artifacts.',
    );

    final apiMode = watchosArtifactApiBase(_platform) != null;
    final String? token = apiMode ? readWatchosToken(globals.fs, _platform) : null;

    final skippedZips = <String>[];
    final refusals = _Refusals();
    var extractedAny = false;
    var needsAccount = false;
    var installed = false;
    try {
      var index = 0;
      for (final String zipName in _artifactZipNames) {
        index++;
        final String url = artifactDownloadUrl(zipName);
        final File tempZip = tempDir.childFile(zipName);
        final line = _TreeLine(
          _logger,
          _treeLine(index, _artifactZipNames.length, _friendlyName(zipName)),
        );
        try {
          final RunResult curlResult = await _processUtils.run(<String>[
            'curl',
            '--location',
            if (!apiMode) '--fail',
            '--silent',
            '--show-error',
            // An unreachable host fails fast instead of holding up the build.
            '--connect-timeout', '$_connectTimeoutSeconds',
            // In API mode capture the HTTP status so gate responses (401/403)
            // can be surfaced with the server's message instead of a bare
            // curl failure.
            if (apiMode) ...<String>['--write-out', '%{http_code}'],
            ...curlAuthArgs(token, tempDir, operatingSystemUtils),
            '--output', tempZip.path,
            url,
          ]);

          if (apiMode) {
            final String httpCode = curlResult.stdout.trim();
            if (curlResult.exitCode != 0 || httpCode != '200') {
              // Some refusals leave one engine out rather than ending the
              // download (see [skippableGate]); anything else stays fatal.
              // The skip is recorded so a later `precache` retries it once
              // the machine is signed in or the account has that engine.
              final String? errorCode = apiGateErrorCode(tempZip);
              final SkippedGate? skipped = skippableGate(
                errorCode,
                signedIn: token != null,
                haveAnEngine: extractedAny,
              );
              if (skipped != null) {
                skippedZips.add(zipName);
                needsAccount |= skipped == SkippedGate.needsAccount;
                if (skipped == SkippedGate.refused) {
                  refusals.add(errorCode, _serverMessage(tempZip), signedIn: token != null);
                }
                line.note(skipped.note);
                continue;
              }
              throwToolExit(
                _apiGateMessage(zipName, httpCode, tempZip, curlResult, signedIn: token != null),
              );
            }
          } else if (curlResult.exitCode != 0) {
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
            staging.path,
          ]);

          if (unzipResult.exitCode != 0) {
            throwToolExit('Failed to extract $zipName.\n\n${unzipResult.stderr}');
          }
          extractedAny = true;
          line.done();
        } finally {
          // Ends the line before a failure is reported under it.
          line.end();
        }
      }

      writePendingEngineZips(staging, skippedZips);
      // Stamp last: only a download that got this far is the tag it claims.
      writeEngineVersionStamp(staging, tag);
      _finalizeExtractedTree(staging, operatingSystemUtils);
      _installStagedTree(staging);
      installed = true;
      if (needsAccount) {
        _logger.printStatus(kSignInForMoreEnginesHint);
      }
      refusals.report(_logger, simulatorReady: _hasSimulatorEngine);
    } finally {
      tempDir.deleteSync(recursive: true);
      if (!installed && staging.existsSync()) {
        staging.deleteSync(recursive: true);
      }
    }
  }

  /// Whether the public Simulator engine is installed at [location].
  bool get _hasSimulatorEngine => location
      .childDirectory(kWatchosSimulatorEngineZipName.substring(
        0,
        kWatchosSimulatorEngineZipName.length - '.zip'.length,
      ))
      .existsSync();

  /// A fresh, empty staging directory beside [location] — on the same file
  /// system, so moving it into place is a rename rather than a copy.
  Directory _createStagingDirectory() {
    final Directory staging =
        location.parent.childDirectory('.${location.basename}.staging');
    if (staging.existsSync()) {
      // Left by a run that was killed before (or during) its cleanup.
      staging.deleteSync(recursive: true);
    }
    staging.createSync(recursive: true);
    return staging;
  }

  /// Drops the Finder metadata a zip made on macOS carries and marks the
  /// host tools executable, on a fully extracted tree.
  void _finalizeExtractedTree(
    Directory tree,
    OperatingSystemUtils operatingSystemUtils,
  ) {
    final Directory macOsMetaDir = tree.childDirectory('__MACOSX');
    if (macOsMetaDir.existsSync()) {
      macOsMetaDir.deleteSync(recursive: true);
    }
    _makeFilesExecutable(tree, operatingSystemUtils);
  }

  /// Replaces whatever [location] holds with the finished [staging] tree.
  /// The previous engine is gone only once its replacement is complete.
  void _installStagedTree(Directory staging) {
    if (location.existsSync()) {
      location.deleteSync(recursive: true);
    }
    staging.renameSync(location.path);
  }

  /// Retries the zips a previous download left owed, on top of an
  /// otherwise-populated artifact directory.
  ///
  /// Nothing here is fatal: the engines already installed keep working
  /// whatever happens, so a still-refused zip is re-skipped (and stays owed)
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
    final refusals = _Refusals();
    var extractedAny = false;
    var needsAccount = false;
    try {
      var index = 0;
      for (final zipName in pending) {
        index++;
        final String url = artifactDownloadUrl(zipName);
        final File tempZip = tempDir.childFile(zipName);
        final line = _TreeLine(_logger, _treeLine(index, pending.length, _friendlyName(zipName)));
        try {
          final RunResult curlResult = await _processUtils.run(<String>[
            'curl',
            '--location',
            '--silent',
            '--show-error',
            '--connect-timeout', '$_connectTimeoutSeconds',
            '--write-out', '%{http_code}',
            ...curlAuthArgs(token, tempDir, operatingSystemUtils),
            '--output', tempZip.path,
            url,
          ]);

          final String httpCode = curlResult.stdout.trim();
          if (curlResult.exitCode != 0 || httpCode != '200') {
            stillPending.add(zipName);
            // An engine is already installed here, so every refusal is
            // survivable; only what is said about it differs.
            final String? errorCode = apiGateErrorCode(tempZip);
            final SkippedGate? skipped = skippableGate(
              errorCode,
              signedIn: token != null,
              haveAnEngine: true,
            );
            needsAccount |= skipped == SkippedGate.needsAccount;
            // A refusal the service explained does not go away by retrying;
            // only a failure with no answer at all (the network, a 5xx) is
            // worth calling temporary.
            final String note = skipped?.note ??
                (errorCode != null
                    ? SkippedGate.refused.note
                    : 'unavailable right now, will retry on the next precache');
            line.note(note);
            // Anything else the service had to say (a sign-in it no longer
            // accepts, an account it has switched off) is its wording to give.
            if (skipped == null || skipped == SkippedGate.refused) {
              refusals.add(errorCode, _serverMessage(tempZip), signedIn: token != null);
            }
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
            throwToolExit('Failed to extract $zipName.\n\n${unzipResult.stderr}');
          }
          extractedAny = true;
          line.done();
        } finally {
          // Ends the line before a failure is reported under it.
          line.end();
        }
      }
    } finally {
      tempDir.deleteSync(recursive: true);
    }

    writePendingEngineZips(location, stillPending);
    if (needsAccount) {
      _logger.printStatus(kSignInForMoreEnginesHint);
    }
    refusals.report(_logger, simulatorReady: _hasSimulatorEngine);

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
    RunResult curlResult, {
    required bool signedIn,
  }) {
    final String? message = _serverMessage(responseFile);
    if (message != null) {
      // The service writes its `auth_required` text for a machine that never
      // signed in; this one did, and needs to hear that it no longer counts.
      if (signedIn && apiGateErrorCode(responseFile) == 'auth_required') {
        return '$message\n$kSignInNotAcceptedNote';
      }
      return message;
    }
    final String detail = curlResult.stderr.trim();
    final curlSaid = detail.isEmpty ? '' : '\n\n$detail';
    // No HTTP status at all: the service was never reached. Signing in
    // would not help (and `login` needs the same network).
    if (httpCode.isEmpty || httpCode == '000') {
      return 'Could not reach the flutterwatch.dev artifact service to download '
          '$zipName.$curlSaid\n\n'
          'Check your network connection, then run `flutter-watchos precache` '
          'again.';
    }
    final String next = switch (httpCode) {
      '401' when signedIn => kSignInNotAcceptedNote,
      '401' => 'If you are not signed in yet, run `flutter-watchos login`.',
      _ => 'Run `flutter-watchos precache` again in a few minutes.',
    };
    return 'Failed to download $zipName from the flutterwatch.dev artifact '
        'service (HTTP $httpCode).$curlSaid\n\n$next';
  }

  /// The human-readable `message` of a JSON gate response, or null when
  /// [responseFile] is not one.
  String? _serverMessage(File responseFile) {
    if (!responseFile.existsSync()) {
      return null;
    }
    try {
      final Object? data = json.decode(responseFile.readAsStringSync());
      if (data is Map<String, Object?>) {
        final Object? message = data['message'];
        if (message is String && message.isNotEmpty) {
          return message;
        }
      }
    } on FormatException {
      // Binary zip data or a truncated body — not a gate response.
    } on FileSystemException {
      // Disappeared between existsSync() and the read.
    }
    return null;
  }

  Future<void> _extractZips(
    List<File> zips,
    FileSystem fileSystem,
    OperatingSystemUtils operatingSystemUtils,
  ) async {
    // Staged and renamed into place for the same reason the download is (see
    // updateInner): a failed extraction must not leave a half-populated tree
    // where an engine is expected.
    final Directory staging = _createStagingDirectory();
    var installed = false;
    try {
      var index = 0;
      for (final zip in zips) {
        index++;
        final line = _TreeLine(_logger, _treeLine(index, zips.length, _friendlyName(zip.basename)));
        try {
          final RunResult result = await _processUtils.run(<String>[
            'unzip',
            '-q',
            zip.path,
            '-d',
            staging.path,
          ]);
          if (result.exitCode != 0) {
            throwToolExit('Failed to extract ${zip.basename}.\n\n${result.stderr}');
          }
          line.done();
        } finally {
          line.end();
        }
      }
      _finalizeExtractedTree(staging, operatingSystemUtils);
      _installStagedTree(staging);
      installed = true;
    } finally {
      if (!installed && staging.existsSync()) {
        staging.deleteSync(recursive: true);
      }
    }
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

/// One engine's line in the download tree: its name, a spinner while it
/// downloads, and then — on the same line — how long it took, or what
/// happened to it instead.
///
/// [Logger.startProgress] cannot end a line with a note: its status always
/// finishes the line itself. A skipped engine therefore came out as three
/// lines — the progress line, the line again with the note, and the elapsed
/// time on a line of its own, because the status was both cancelled and
/// stopped.
class _TreeLine {
  _TreeLine(this._logger, this._text) {
    // The verbose logger puts every message on a line of its own, so there
    // the whole line is printed once, at the end.
    if (!_logger.isVerbose) {
      _logger.printStatus(_text, newline: false, wrap: false);
    }
    _spinner = _logger.startSpinner();
    _stopwatch.start();
  }

  final Logger _logger;
  final String _text;
  final _stopwatch = Stopwatch();
  late final Status _spinner;
  var _ended = false;

  /// Ends the line with how long the engine took, aligned the way
  /// [Logger.startProgress] aligns it.
  void done() {
    final Duration elapsed = _stopwatch.elapsed;
    final String time = elapsed.inSeconds > 2
        ? getElapsedAsSeconds(elapsed)
        : getElapsedAsMilliseconds(elapsed);
    final int gap = (kDefaultStatusPadding - _text.length).clamp(0, kDefaultStatusPadding) + 5;
    _end('${' ' * gap}${time.padLeft(8)}');
  }

  /// Ends the line with [note] in place of the time.
  void note(String note) => _end(' — $note');

  /// Ends the line as it stands; does nothing once the line has ended.
  void end() => _end('');

  void _end(String suffix) {
    if (_ended) {
      return;
    }
    _ended = true;
    _spinner.stop();
    _logger.printStatus(_logger.isVerbose ? '$_text$suffix' : suffix, wrap: false);
  }
}

/// What the service said while refusing engines during one download — told
/// once, when the download is over, rather than under every engine it
/// refused.
class _Refusals {
  final _messages = <String>{};
  var _signInRejected = false;
  var _accountSwitchedOff = false;

  void add(String? errorCode, String? message, {required bool signedIn}) {
    if (message != null) {
      _messages.add(message);
    }
    _signInRejected |= signedIn && errorCode == 'auth_required';
    _accountSwitchedOff |= errorCode == 'access_inactive';
  }

  void report(Logger logger, {required bool simulatorReady}) {
    _messages.forEach(logger.printStatus);
    if (_signInRejected) {
      logger.printStatus(kSignInNotAcceptedNote);
    }
    if (_accountSwitchedOff && simulatorReady) {
      logger.printStatus(kSimulatorStillReadyNote);
    }
  }
}
