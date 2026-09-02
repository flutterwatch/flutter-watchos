// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/features.dart';
import 'package:flutter_watchos/commands/precache.dart';
import 'package:flutter_watchos/watchos_cache.dart';

import '../src/common.dart';
import '../src/fakes.dart';

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
    // Written when a download skips gated zips (release engines during the
    // beta); read by `precache` to retry them after an account upgrade.
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
    // fatal (auth problems) or skippable (release zips during the beta).
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
}
