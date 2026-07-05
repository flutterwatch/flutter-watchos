// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/src/interface/directory.dart';
import 'package:flutter_tools/src/commands/precache.dart';
import 'package:flutter_tools/src/features.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/runner/flutter_command.dart';
import 'package:meta/meta.dart';

import '../watchos_cache.dart';

class WatchosPrecacheCommand extends PrecacheCommand {
  WatchosPrecacheCommand({
    required super.verboseHelp,
    required super.cache,
    required super.logger,
    required super.platform,
    required super.featureFlags,
  }) {
    argParser.addFlag(
      'watchos',
      defaultsTo: true,
      help: 'Precache artifacts for watchOS development.',
    );
  }

  // The `--android` umbrella flag stands in for its three child artifacts.
  static const Map<String, String> _umbrellaForArtifact = <String, String>{
    'android_gen_snapshot': 'android',
    'android_maven': 'android',
    'android_internal_build': 'android',
  };

  // Non-platform artifacts a watchOS build always needs (fonts, sky_engine,
  // flutter_patched_sdk, font-subset, host USB-deploy tools, engine stamp).
  static const Set<String> _alwaysOn = <String>{'universal', 'informative'};

  /// The non-watchOS artifacts to fetch for the given flags. With no platform
  /// flags this is only [_alwaysOn]; `--all-platforms` and explicit
  /// per-platform flags add their artifacts. Pure (no I/O) so it is unit-tested
  /// directly.
  @visibleForTesting
  static Set<DevelopmentArtifact> selectRequiredArtifacts({
    required FeatureFlags featureFlags,
    required bool allPlatforms,
    required bool Function(String flagName) isFlagOn,
  }) {
    final requiredArtifacts = <DevelopmentArtifact>{};
    for (final DevelopmentArtifact artifact in DevelopmentArtifact.values) {
      if (artifact.feature != null && !featureFlags.isEnabled(artifact.feature!)) {
        continue;
      }
      final String? umbrella = _umbrellaForArtifact[artifact.name];
      final bool explicitlyRequested =
          isFlagOn(artifact.name) || (umbrella != null && isFlagOn(umbrella));
      if (allPlatforms || _alwaysOn.contains(artifact.name) || explicitlyRequested) {
        requiredArtifacts.add(artifact);
      }
    }
    return requiredArtifacts;
  }

  @override
  Future<FlutterCommandResult> runCommand() async {
    if (boolArg('watchos')) {
      final Directory artifactDir = watchosArtifactDirectory(globals.fs);
      if (boolArg('force')) {
        if (artifactDir.existsSync()) {
          artifactDir.deleteSync(recursive: true);
        }
      } else if (readPendingEngineZips(artifactDir).isNotEmpty) {
        // Zips a previous download was not entitled to (release engines
        // during the beta). Invalidate the stamp so the cache re-enters the
        // artifact update, which retries exactly those zips — this is how an
        // account that gained release access picks up the release engines.
        globals.cache.setStampFor(kWatchosEngineStampName, 'pending-downloads');
      }
      await globals.cache.updateAll(<DevelopmentArtifact>{WatchosDevelopmentArtifact.watchos});
    }

    // Stock `flutter precache` with no platform flags downloads *every* enabled
    // platform's artifacts. A watchOS embedder needs none of those — only the
    // universal artifacts and the engine stamp, on top of the watchOS engine
    // set fetched above. So drive the cache ourselves instead of delegating to
    // `super.runCommand()`, while still honouring the stock per-platform flags.
    if (globals.platform.environment['FLUTTER_ALREADY_LOCKED'] != 'true') {
      await globals.cache.lock();
    }
    if (boolArg('force')) {
      globals.cache.clearStampFiles();
    }
    final bool allPlatforms = boolArg('all-platforms');
    if (allPlatforms) {
      globals.cache.includeAllPlatforms = true;
    }
    if (boolArg('use-unsigned-mac-binaries')) {
      globals.cache.useUnsignedMacBinaries = true;
    }

    final Set<DevelopmentArtifact> requiredArtifacts = selectRequiredArtifacts(
      featureFlags: featureFlags,
      allPlatforms: allPlatforms,
      isFlagOn: (String name) =>
          argParser.options.containsKey(name) && argResults!.wasParsed(name) && boolArg(name),
    );

    await globals.cache.updateAll(requiredArtifacts);
    return FlutterCommandResult.success();
  }
}
