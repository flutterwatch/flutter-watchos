// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Contract tests for FlutterWatchOSContentScale: an Info.plist knob that
// lays the app out in a proportionally larger logical space rendered
// smaller (same ratio, smaller components), so phone-designed UIs — e.g. a
// plugin's upstream example, shipped verbatim — fit the watch screen. The
// runner owns the whole conversion: the engine just receives a bigger
// logical size with a smaller pixel ratio (same physical pixel count), and
// every coordinate crossing the host boundary is converted in the host
// module.

import '../src/common.dart';
import '../src/host_sources.dart';

void main() {
  final String runner = readHostSource('FlutterRunner.swift');

  group('watchOS content scale — FlutterWatchOSContentScale', () {
    test('reads the Info.plist key, clamped, defaulting to 1.0', () {
      expect(runner, contains('enum WatchContentScale'));
      expect(runner, contains('"FlutterWatchOSContentScale"'));
      expect(runner, contains('min(max(number.doubleValue, 0.3), 1.0)'));
      expect(runner, contains('return 1.0'));
    });

    test('engine runs at scaled logical size with compensated pixel ratio', () {
      // logical × ratio must stay the physical pixel count: the logical
      // space grows by 1/scale while the ratio shrinks by scale.
      expect(runner, contains('screenScale * WatchContentScale.value'));
      expect(
        runner,
        contains('sizePoints.width / WatchContentScale.value'),
      );
      // HostRun receives the SCALED size, not the raw display points.
      final int hostRun = runner.indexOf('FlutterWatchOSHostRun(');
      expect(hostRun, greaterThanOrEqualTo(0));
      final String args =
          runner.substring(hostRun, runner.indexOf('ctx)', hostRun));
      expect(args, contains('flutterSize.width'));
      expect(args, isNot(contains('sizePoints.width')));
    });

    test('touches and crown deltas are converted into logical points', () {
      expect(
        runner,
        contains('location.x / WatchContentScale.value'),
      );
      expect(
        runner,
        contains('FlutterWatchOSCrownDelta(delta / WatchContentScale.value)'),
      );
    });

    test('has its own doc comment, apart from WatchDisplayCorner', () {
      // Each enum's comment is the block between the blank line above it and
      // its declaration; the two blocks once ran together, which left
      // WatchContentScale with none.
      String docAbove(String declaration) {
        final int at = runner.indexOf('\n$declaration');
        expect(at, greaterThan(-1));
        return runner.substring(runner.lastIndexOf('\n\n', at), at).trimLeft();
      }

      final String scaleDoc = docAbove('enum WatchContentScale');
      expect(scaleDoc, startsWith('/// Content scale:'));
      expect(scaleDoc, contains('<key>FlutterWatchOSContentScale</key>'));
      final String cornerDoc = docAbove('enum WatchDisplayCorner');
      expect(cornerDoc, startsWith("/// The display's rounded-corner radius"));
      expect(cornerDoc, isNot(contains('FlutterWatchOSContentScale')));
    });

    test('both overlay mirrors convert engine rects to display points', () {
      // Text-input proxies AND platform-view slots place in SwiftUI points;
      // the single conversion point is each mirror's reload().
      expect(
        RegExp('WatchContentScale.toDisplay').allMatches(runner).length,
        greaterThanOrEqualTo(2),
      );
    });
  });
}
