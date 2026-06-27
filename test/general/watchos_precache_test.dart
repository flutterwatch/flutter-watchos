// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/features.dart';
import 'package:flutter_watchos/commands/precache.dart';

import '../src/common.dart';

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
}
