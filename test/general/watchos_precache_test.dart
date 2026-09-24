// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/features.dart';
import 'package:flutter_watchos/commands/precache.dart';
import 'package:flutter_watchos/watchos_cache.dart';
import 'package:test/fake.dart';

import '../src/common.dart';
import '../src/context.dart';
import '../src/fakes.dart';
import '../src/test_flutter_command_runner.dart';

/// All features either enabled or disabled, depending on [enabled]; every other
/// FeatureFlags member returns false.
class _FakeFeatureFlags implements FeatureFlags {
  _FakeFeatureFlags({this.enabled = true});
  final bool enabled;

  @override
  bool isEnabled(Feature feature) => enabled;

  @override
  dynamic noSuchMethod(Invocation invocation) => false;
}

Set<String> _names(Set<DevelopmentArtifact> a) =>
    a.map((DevelopmentArtifact d) => d.name).toSet();

/// A cache that only records, in order, what `precache` asks of it.
class _RecordingCache extends Fake implements Cache {
  final List<String> calls = <String>[];

  @override
  Future<void> lock() async {}

  @override
  void releaseLock() {}

  @override
  void clearStampFiles() => calls.add('clear stamps');

  @override
  void setStampFor(String artifactName, String version) =>
      calls.add('stamp $artifactName');

  /// Runs after each update is recorded; a test uses it to act as the real
  /// engine update would.
  Future<void> Function(Set<DevelopmentArtifact> requiredArtifacts)? onUpdate;

  @override
  Future<void> updateAll(Set<DevelopmentArtifact> requiredArtifacts, {bool offline = false}) async {
    calls.add('update ${(_names(requiredArtifacts).toList()..sort()).join(', ')}');
    await onUpdate?.call(requiredArtifacts);
  }

  @override
  bool includeAllPlatforms = false;

  @override
  bool useUnsignedMacBinaries = false;
}

void main() {
  group('WatchosPrecacheCommand.selectRequiredArtifacts', () {
    testWithoutContext('with --all-platforms, selects every feature-enabled artifact', () {
      final Set<DevelopmentArtifact> selected = WatchosPrecacheCommand.selectRequiredArtifacts(
        featureFlags: _FakeFeatureFlags(),
        allPlatforms: true,
        isFlagOn: (String _) => false,
      );
      expect(selected.length, equals(DevelopmentArtifact.values.length));
      expect(_names(selected), contains('universal'));
      expect(_names(selected), contains('web'));
    });

    testWithoutContext('with no flags, selects ONLY the always-on artifacts', () {
      // A watchOS embedder needs none of the per-platform artifacts on a bare
      // `precache` — only the universal/informative set.
      final Set<DevelopmentArtifact> selected = WatchosPrecacheCommand.selectRequiredArtifacts(
        featureFlags: _FakeFeatureFlags(),
        allPlatforms: false,
        isFlagOn: (String _) => false,
      );
      expect(_names(selected), equals(<String>{'universal', 'informative'}));
    });

    testWithoutContext('an explicitly requested artifact is included', () {
      final Set<DevelopmentArtifact> selected = WatchosPrecacheCommand.selectRequiredArtifacts(
        featureFlags: _FakeFeatureFlags(),
        allPlatforms: false,
        isFlagOn: (String name) => name == 'web',
      );
      expect(_names(selected), contains('web'));
      expect(_names(selected), contains('universal'));
    });

    testWithoutContext('a feature-gated artifact is skipped when its feature is disabled', () {
      final Set<DevelopmentArtifact> selected = WatchosPrecacheCommand.selectRequiredArtifacts(
        featureFlags: _FakeFeatureFlags(enabled: false),
        allPlatforms: true,
        isFlagOn: (String _) => false,
      );
      // `web` is gated by flutterWebFeature; disabled → excluded even with
      // --all-platforms. The featureless `universal` stays.
      expect(_names(selected), isNot(contains('web')));
      expect(_names(selected), contains('universal'));
    });
  });

  group('pending engine zips marker', () {
    // Written when a download leaves zips out (signed out, or not given to
    // that account); read by `precache` to retry them once that changes.
    late MemoryFileSystem fs;
    late Directory artifactDir;

    setUp(() {
      fs = MemoryFileSystem.test();
      artifactDir = fs.directory('engine_artifacts')..createSync();
    });

    testWithoutContext('round-trips zip names through the marker file', () {
      writePendingEngineZips(artifactDir,
          <String>['watchos_release_arm64.zip', 'host_release.zip']);
      expect(readPendingEngineZips(artifactDir),
          <String>['watchos_release_arm64.zip', 'host_release.zip']);
    });

    testWithoutContext('reads empty when the marker is absent', () {
      expect(readPendingEngineZips(artifactDir), isEmpty);
    });

    testWithoutContext('an empty write deletes the marker', () {
      writePendingEngineZips(artifactDir, <String>['host_release.zip']);
      writePendingEngineZips(artifactDir, const <String>[]);
      expect(artifactDir.childFile(kWatchosPendingDownloadsFileName).existsSync(),
          isFalse);
      expect(readPendingEngineZips(artifactDir), isEmpty);
    });

    testWithoutContext('unknown names in the marker are ignored', () {
      artifactDir.childFile(kWatchosPendingDownloadsFileName).writeAsStringSync(
          'watchos_release_arm64.zip\n../../etc/passwd\ntotally_made_up.zip\n');
      expect(readPendingEngineZips(artifactDir),
          <String>['watchos_release_arm64.zip']);
    });
  });

  group('engine version stamp', () {
    // Without this an engine bump never reached an existing install: the
    // download target is reused whenever it holds `watchos_*` directories, so
    // `precache` after an upgrade was a no-op and the user silently kept the
    // previous engine.
    late MemoryFileSystem fs;
    late Directory artifactDir;

    setUp(() {
      fs = MemoryFileSystem.test();
      artifactDir = fs.directory('engine_artifacts')..createSync();
    });

    testWithoutContext('round-trips the tag', () {
      writeEngineVersionStamp(artifactDir, 'v0.1.3-flutter3.44.4');
      expect(readEngineVersionStamp(artifactDir), 'v0.1.3-flutter3.44.4');
    });

    testWithoutContext('reads null when unstamped', () {
      expect(readEngineVersionStamp(artifactDir), isNull);
    });

    testWithoutContext('reads null when the stamp is blank', () {
      artifactDir.childFile(kWatchosEngineVersionFileName).writeAsStringSync('  \n');
      expect(readEngineVersionStamp(artifactDir), isNull);
    });

    testWithoutContext('a matching stamp is reusable', () {
      writeEngineVersionStamp(artifactDir, 'v0.1.3-flutter3.44.4');
      expect(engineArtifactsMatchTag(artifactDir, 'v0.1.3-flutter3.44.4'), isTrue);
    });

    testWithoutContext('a stale stamp is NOT reusable — this is the upgrade path', () {
      writeEngineVersionStamp(artifactDir, 'v0.1.2-flutter3.44.4');
      expect(engineArtifactsMatchTag(artifactDir, 'v0.1.3-flutter3.44.4'), isFalse);
    });

    testWithoutContext('an unstamped directory stays reusable', () {
      // A hand-built engine (WATCHOS_ENGINE_ARTIFACTS, or a workspace-root
      // engine_artifacts/) carries no tag to compare against. Treating it as
      // stale would delete a local engine build and re-download over it.
      expect(engineArtifactsMatchTag(artifactDir, 'v0.1.3-flutter3.44.4'), isTrue);
    });

    // Reusable and verified are not the same thing, and the bool cannot tell
    // them apart. On 2026-08-25 an unstamped four-day-old engine_artifacts/
    // answered for a freshly built id: precache reported success and the CLI
    // ran the old binary. The caller warns on this case, which it can only do
    // if the case is distinguishable.
    testWithoutContext('a matching stamp reports as verified', () {
      writeEngineVersionStamp(artifactDir, 'engine-ddc777be435e');
      expect(engineArtifactsMatch(artifactDir, 'engine-ddc777be435e'),
          EngineArtifactsMatch.stamped);
    });

    testWithoutContext('a stale stamp reports as mismatched', () {
      writeEngineVersionStamp(artifactDir, 'engine-cf45e013db7c');
      expect(engineArtifactsMatch(artifactDir, 'engine-ddc777be435e'),
          EngineArtifactsMatch.mismatched);
    });

    testWithoutContext('an unstamped directory reports as unverifiable, not matched', () {
      expect(engineArtifactsMatch(artifactDir, 'engine-ddc777be435e'),
          EngineArtifactsMatch.unverifiable);
      // Still reusable — refusing would break a local engine build.
      expect(engineArtifactsMatchTag(artifactDir, 'engine-ddc777be435e'), isTrue);
    });

    testWithoutContext('a blank stamp is unverifiable rather than a mismatch', () {
      artifactDir.childFile(kWatchosEngineVersionFileName).writeAsStringSync('  \n');
      expect(engineArtifactsMatch(artifactDir, 'engine-ddc777be435e'),
          EngineArtifactsMatch.unverifiable);
    });
  });

  group('curlAuthArgs', () {
    // The token must never reach argv. argv is world-readable — any user on
    // the machine can read it out of `ps` while a download runs — and
    // `precache -v` prints the command it is about to run, which is exactly
    // the output that gets pasted into bug reports.
    late MemoryFileSystem fs;
    late Directory tempDir;

    setUp(() {
      fs = MemoryFileSystem.test();
      tempDir = fs.directory('/tmp/dl')..createSync(recursive: true);
    });

    testWithoutContext('never returns the token as an argument', () {
      const token = 'fw_secret_value_that_must_not_leak';
      final List<String> args =
          curlAuthArgs(token, tempDir, FakeOperatingSystemUtils());
      expect(args.join(' '), isNot(contains(token)));
      expect(args.join(' '), isNot(contains('Bearer')));
      expect(args.first, '--config');
    });

    testWithoutContext('puts the header in a config file curl can read', () {
      const token = 'fw_abc123';
      final List<String> args =
          curlAuthArgs(token, tempDir, FakeOperatingSystemUtils());
      final File config = fs.file(args[1]);
      expect(config.existsSync(), isTrue);
      // curl's own config syntax: `header = "..."`.
      expect(config.readAsStringSync().trim(),
          'header = "Authorization: Bearer $token"');
    });

    testWithoutContext("writes the file inside the caller's temp dir", () {
      // That directory is created 0700 and deleted when the download ends, so
      // the token neither outlives the run nor is readable by anyone else.
      final List<String> args =
          curlAuthArgs('fw_x', tempDir, FakeOperatingSystemUtils());
      expect(args[1], startsWith(tempDir.path));
    });

    testWithoutContext('narrows the file to the owner', () {
      final os = FakeOperatingSystemUtils();
      final List<String> args = curlAuthArgs('fw_x', tempDir, os);
      expect(os.chmods, <List<String>>[
        <String>[args[1], 'go-rwx'],
      ]);
    });

    testWithoutContext('sends nothing at all when there is no token', () {
      expect(curlAuthArgs(null, tempDir, FakeOperatingSystemUtils()), isEmpty);
      expect(curlAuthArgs('', tempDir, FakeOperatingSystemUtils()), isEmpty);
      expect(tempDir.childFile('auth.curl').existsSync(), isFalse);
    });
  });

  group('apiGateErrorCode', () {
    // The download loop uses this to decide whether an artifact-API gate is
    // fatal (auth problems) or skippable (see skippableGate).
    late MemoryFileSystem fs;

    setUp(() {
      fs = MemoryFileSystem.test();
    });

    testWithoutContext('extracts the error code from a JSON gate response', () {
      final File file = fs.file('resp.json')
        ..writeAsStringSync(
            '{"error":"release_not_in_beta","message":"Release engine '
            'artifacts are not part of the closed beta."}');
      expect(apiGateErrorCode(file), 'release_not_in_beta');
    });

    testWithoutContext('returns null for binary zip payloads', () {
      final File file = fs.file('artifact.zip')
        ..writeAsBytesSync(<int>[0x50, 0x4B, 0x03, 0x04, 0xFF, 0xFE]);
      expect(apiGateErrorCode(file), isNull);
    });

    testWithoutContext('returns null when the file is missing or shapeless', () {
      expect(apiGateErrorCode(fs.file('nope.json')), isNull);
      final File list = fs.file('list.json')..writeAsStringSync('[1,2,3]');
      expect(apiGateErrorCode(list), isNull);
      final File noError = fs.file('ok.json')..writeAsStringSync('{"ok":true}');
      expect(apiGateErrorCode(noError), isNull);
    });
  });

  group('skippableGate', () {
    test('an engine the account does not have is always skippable', () {
      for (final signedIn in <bool>[true, false]) {
        for (final haveAnEngine in <bool>[true, false]) {
          expect(
            skippableGate('release_not_in_beta', signedIn: signedIn, haveAnEngine: haveAnEngine),
            SkippedGate.notForThisAccount,
          );
        }
      }
    });

    test('a missing account is skippable only signed out, with an engine in hand', () {
      expect(
        skippableGate('auth_required', signedIn: false, haveAnEngine: true),
        SkippedGate.needsAccount,
      );
      // Nothing to install: say so.
      expect(skippableGate('auth_required', signedIn: false, haveAnEngine: false), isNull);
      // A token the service no longer accepts: that person meant to be signed in.
      expect(skippableGate('auth_required', signedIn: true, haveAnEngine: true), isNull);
    });

    // The service still serves the public Simulator engine to an account it
    // has switched off; throwing that engine away helped nobody.
    test('an account switched off keeps the engine already in hand', () {
      for (final signedIn in <bool>[true, false]) {
        expect(
          skippableGate('access_inactive', signedIn: signedIn, haveAnEngine: true),
          SkippedGate.refused,
        );
        // Nothing to install: say so.
        expect(skippableGate('access_inactive', signedIn: signedIn, haveAnEngine: false), isNull);
      }
    });

    test('every other refusal, and no refusal at all, is fatal', () {
      for (final code in <String?>[
        'beta_access_required', 'license_required', 'not_found', null,
      ]) {
        expect(skippableGate(code, signedIn: false, haveAnEngine: true), isNull, reason: '$code');
        expect(skippableGate(code, signedIn: true, haveAnEngine: true), isNull, reason: '$code');
      }
    });
  });

  group('owedEngineAdvice', () {
    late MemoryFileSystem fs;
    late Directory artifactDir;

    setUp(() {
      fs = MemoryFileSystem.test();
      artifactDir = fs.directory('/cli/engine_artifacts')..createSync(recursive: true);
    });

    test('is silent when nothing the build needs is owed', () {
      expect(owedEngineAdvice(artifactDir, release: true, signedIn: false), isNull);
      // Release engines owed; a profile build does not care.
      writePendingEngineZips(artifactDir, const <String>['watchos_release_arm64.zip', 'host_release.zip']);
      expect(owedEngineAdvice(artifactDir, release: false, signedIn: true), isNull);
    });

    test('signed out, it sends the developer to login, and names the Simulator', () {
      writePendingEngineZips(artifactDir, kWatchosEngineZipNames.skip(1));
      for (final release in <bool>[true, false]) {
        final String advice = owedEngineAdvice(artifactDir, release: release, signedIn: false)!;
        expect(advice, contains(release ? 'release engine' : 'profile engine'));
        expect(advice, contains('flutter-watchos login'));
        expect(advice, contains('--simulator'));
      }
    });

    test('signed in, it does not send a signed-in developer to login', () {
      writePendingEngineZips(artifactDir, const <String>['host_release.zip']);
      final String advice = owedEngineAdvice(artifactDir, release: true, signedIn: true)!;
      expect(advice, contains('flutter-watchos precache'));
      expect(advice, isNot(contains('flutter-watchos login')));
      // It does not know why the engine is missing (a refusal, or no network),
      // so it does not guess; `precache` prints the reason.
      expect(advice, isNot(contains('for this account')));
    });
  });

  // `precache --force` deleted whatever directory the engine resolved to,
  // before downloading: a hand-built WATCHOS_ENGINE_ARTIFACTS or workspace
  // engine went with it, and a failed download left no engine at all.
  group('precache --force', () {
    late MemoryFileSystem fs;

    setUp(() {
      fs = MemoryFileSystem.test();
      Cache.flutterRoot = '/cli/flutter';
    });

    testWithoutContext('only the engine this tool downloads is its to delete', () {
      expect(
        isDownloadedArtifactDirectory(fs, fs.directory('/cli/engine_artifacts')),
        isTrue,
      );
      expect(isDownloadedArtifactDirectory(fs, fs.directory('/engine_artifacts')), isFalse);
      expect(isDownloadedArtifactDirectory(fs, fs.directory('/somewhere/engines')), isFalse);
    });

    testWithoutContext('a download that succeeds replaces the engine', () async {
      final Directory engine = fs.directory('/cli/engine_artifacts');
      engine.childFile('old').createSync(recursive: true);

      await redownloadEngine(engine, () async {
        expect(engine.existsSync(), isFalse, reason: 'the old engine is out of the way');
        engine.childFile('new').createSync(recursive: true);
      });

      expect(engine.childFile('new').existsSync(), isTrue);
      expect(engine.childFile('old').existsSync(), isFalse);
      expect(fs.directory('/cli/engine_artifacts.previous').existsSync(), isFalse);
    });

    testWithoutContext('a download that fails puts the previous engine back', () async {
      final Directory engine = fs.directory('/cli/engine_artifacts');
      engine.childFile('old').createSync(recursive: true);

      await expectLater(
        redownloadEngine(engine, () async {
          engine.childDirectory('half').createSync(recursive: true);
          throw Exception('offline');
        }),
        throwsException,
      );

      expect(engine.childFile('old').existsSync(), isTrue);
      expect(engine.childDirectory('half').existsSync(), isFalse);
      expect(fs.directory('/cli/engine_artifacts.previous').existsSync(), isFalse);
    });

    // What a download leaves in place: a stamped engine, as one rename.
    void seedEngine(String path, String marker) {
      final Directory dir = fs.directory(path);
      dir.childDirectory('watchos_debug_sim_arm64').childFile(marker).createSync(recursive: true);
      writeEngineVersionStamp(dir, 'engine-0123456789ab');
    }

    // Killed after the move aside and before the new engine went in, a run
    // left the only working engine in engine_artifacts.previous, and in its
    // place the empty engine_artifacts/ flutter_tools creates before any
    // engine update. The next --force took that empty directory for the
    // engine, deleted the copy and moved the empty directory aside, so a
    // second failure left no engine at all.
    testWithoutContext('a run killed mid-download: the next one starts from the engine it left aside', () async {
      final Directory engine = fs.directory('/cli/engine_artifacts')..createSync(recursive: true);
      seedEngine('/cli/engine_artifacts.previous', 'old');

      await expectLater(
        redownloadEngine(engine, () async {
          expect(
            fs.file('/cli/engine_artifacts.previous/watchos_debug_sim_arm64/old').existsSync(),
            isTrue,
            reason: 'moved aside again, not deleted',
          );
          // What CachedArtifact.update does before it downloads.
          engine.createSync(recursive: true);
          throw Exception('offline');
        }),
        throwsException,
      );

      expect(engine.childDirectory('watchos_debug_sim_arm64').childFile('old').existsSync(), isTrue);
      expect(readEngineVersionStamp(engine), 'engine-0123456789ab');
      expect(fs.directory('/cli/engine_artifacts.previous').existsSync(), isFalse);
    });

    testWithoutContext('a leftover beside an engine in place is dropped, the engine kept', () async {
      final Directory engine = fs.directory('/cli/engine_artifacts');
      seedEngine(engine.path, 'newer');
      seedEngine('/cli/engine_artifacts.previous', 'older');

      await redownloadEngine(engine, () async {
        expect(
          fs.file('/cli/engine_artifacts.previous/watchos_debug_sim_arm64/newer').existsSync(),
          isTrue,
        );
        engine.childFile('new').createSync(recursive: true);
      });

      expect(engine.childFile('new').existsSync(), isTrue);
      expect(fs.directory('/cli/engine_artifacts.previous').existsSync(), isFalse);
    });

    group('an engine left aside', () {
      late Directory engine;
      late Directory previous;

      setUp(() {
        engine = fs.directory('/cli/engine_artifacts');
        previous = fs.directory('/cli/engine_artifacts.previous');
      });

      testWithoutContext('is nothing to do when there is none', () {
        expect(restoreInterruptedRedownload(engine), isFalse);
        expect(engine.existsSync(), isFalse);
      });

      testWithoutContext('is put back when engine_artifacts/ is missing', () {
        seedEngine(previous.path, 'old');

        expect(restoreInterruptedRedownload(engine), isTrue);
        expect(engine.childDirectory('watchos_debug_sim_arm64').childFile('old').existsSync(), isTrue);
        expect(previous.existsSync(), isFalse);
      });

      // The state a real kill leaves: flutter_tools makes the directory
      // before the download starts. Finder may have added a .DS_Store.
      testWithoutContext('is put back when engine_artifacts/ is only the empty directory a killed download leaves', () {
        seedEngine(previous.path, 'old');
        engine.childFile('.DS_Store').createSync(recursive: true);

        expect(restoreInterruptedRedownload(engine), isTrue);
        expect(engine.childDirectory('watchos_debug_sim_arm64').childFile('old').existsSync(), isTrue);
        expect(engine.childFile('.DS_Store').existsSync(), isFalse);
        expect(previous.existsSync(), isFalse);
      });

      testWithoutContext('is dropped beside a downloaded engine, which is the newer one', () {
        seedEngine(previous.path, 'older');
        seedEngine(engine.path, 'newer');

        expect(restoreInterruptedRedownload(engine), isFalse);
        expect(engine.childDirectory('watchos_debug_sim_arm64').childFile('newer').existsSync(), isTrue);
        expect(engine.childDirectory('watchos_debug_sim_arm64').childFile('older').existsSync(), isFalse);
        expect(previous.existsSync(), isFalse);
      });

      // Local zips install without a stamp; that is an engine all the same.
      testWithoutContext('is dropped beside an unstamped engine', () {
        seedEngine(previous.path, 'older');
        engine.childDirectory('watchos_debug_sim_arm64').childFile('newer').createSync(recursive: true);

        expect(restoreInterruptedRedownload(engine), isFalse);
        expect(engine.childDirectory('watchos_debug_sim_arm64').childFile('newer').existsSync(), isTrue);
        expect(previous.existsSync(), isFalse);
      });
    });
  });

  // `precache --force` cleared every cache stamp after the engine update, the
  // engine's own included. A machine that owes engines (signed out, or
  // refused them) then asked the service for them all again on its next
  // build, and printed the refusals again.
  group('precache command', () {
    late MemoryFileSystem fs;
    late _RecordingCache cache;
    final Platform platform = FakePlatform(
      operatingSystem: 'macos',
      environment: <String, String>{'HOME': '/home/u'},
    );

    setUp(() {
      fs = MemoryFileSystem.test();
      cache = _RecordingCache();
      Cache.flutterRoot = '/cli/flutter';
      fs.directory('/cli/engine_artifacts/watchos_debug_sim_arm64').createSync(recursive: true);
    });

    Future<void> runPrecache(List<String> args) => createTestCommandRunner(
      WatchosPrecacheCommand(
        verboseHelp: false,
        cache: cache,
        logger: BufferLogger.test(),
        platform: platform,
        featureFlags: TestFeatureFlags(),
      ),
    ).run(<String>['precache', ...args]);

    testUsingContext(
      '--force clears the stamps before the engine update, not after it',
      () async {
        await runPrecache(const <String>['--force']);

        expect(cache.calls, <String>[
          'update informative', // the command runner's, before any command
          'clear stamps',
          'update watchos',
          'update informative, universal',
        ]);
      },
      overrides: <Type, Generator>{
        FileSystem: () => fs,
        ProcessManager: () => FakeProcessManager.any(),
        Platform: () => platform,
        Cache: () => cache,
      },
    );

    /// What a `precache --force` killed mid-download leaves: the engine
    /// aside, and in its place the empty directory flutter_tools creates
    /// before the engine update starts.
    void killedForceRun() {
      fs.directory('/cli/engine_artifacts').renameSync('/cli/engine_artifacts.previous');
      fs.directory('/cli/engine_artifacts').createSync();
    }

    // `upgrade` runs a plain precache: after a killed --force it downloaded
    // every engine again while the old one sat beside engine_artifacts/.
    testUsingContext(
      'precache puts back the engine a killed --force left aside',
      () async {
        killedForceRun();

        await runPrecache(const <String>[]);

        expect(fs.directory('/cli/engine_artifacts/watchos_debug_sim_arm64').existsSync(), isTrue);
        expect(fs.directory('/cli/engine_artifacts.previous').existsSync(), isFalse);
      },
      overrides: <Type, Generator>{
        FileSystem: () => fs,
        ProcessManager: () => FakeProcessManager.any(),
        Platform: () => platform,
        Cache: () => cache,
      },
    );

    // The next --force deleted the copy, took the empty directory for the
    // engine, and put that back when its own download failed: no engine.
    testUsingContext(
      'a --force after a killed one keeps the engine when its download fails too',
      () async {
        killedForceRun();
        cache.onUpdate = (Set<DevelopmentArtifact> artifacts) async {
          if (artifacts.contains(WatchosDevelopmentArtifact.watchos)) {
            fs.directory('/cli/engine_artifacts').createSync();
            throwToolExit('offline');
          }
        };

        await expectLater(runPrecache(const <String>['--force']), throwsToolExit(message: 'offline'));

        expect(fs.directory('/cli/engine_artifacts/watchos_debug_sim_arm64').existsSync(), isTrue);
        expect(fs.directory('/cli/engine_artifacts.previous').existsSync(), isFalse);
      },
      overrides: <Type, Generator>{
        FileSystem: () => fs,
        ProcessManager: () => FakeProcessManager.any(),
        Platform: () => platform,
        Cache: () => cache,
      },
    );

    testUsingContext(
      'a plain precache clears no stamps',
      () async {
        await runPrecache(const <String>[]);

        expect(cache.calls, <String>[
          'update informative',
          'update watchos',
          'update informative, universal',
        ]);
      },
      overrides: <Type, Generator>{
        FileSystem: () => fs,
        ProcessManager: () => FakeProcessManager.any(),
        Platform: () => platform,
        Cache: () => cache,
      },
    );
  });
}
