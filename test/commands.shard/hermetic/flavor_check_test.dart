// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_watchos/commands/launch_checks.dart';

import '../../src/common.dart';
import 'src/words.dart';

void main() {
  group('watchosFlavorCheck', () {
    test('an explicit --flavor for a watch is refused, with or without a default', () {
      for (final defaultFlavor in <String?>[null, 'y']) {
        expect(
          watchosFlavorCheck(cliFlavor: 'x', defaultFlavor: defaultFlavor, watchTarget: true),
          WatchosFlavorCheck.refuse,
        );
      }
    });

    test('a default-flavor alone for a watch warns', () {
      expect(
        watchosFlavorCheck(cliFlavor: null, defaultFlavor: 'y', watchTarget: true),
        WatchosFlavorCheck.warn,
      );
    });

    test('no flavor for a watch is nothing', () {
      expect(
        watchosFlavorCheck(cliFlavor: null, defaultFlavor: null, watchTarget: true),
        WatchosFlavorCheck.none,
      );
    });

    test('a target that is not a watch is left to stock', () {
      for (final cliFlavor in <String?>[null, 'x']) {
        for (final defaultFlavor in <String?>[null, 'y']) {
          expect(
            watchosFlavorCheck(
              cliFlavor: cliFlavor,
              defaultFlavor: defaultFlavor,
              watchTarget: false,
            ),
            WatchosFlavorCheck.none,
          );
        }
      }
    });
  });

  test('the texts say what happens and name no forbidden word', () {
    expect(kWatchosFlavorRefusal, contains('without flavors'));
    expect(kWatchosFlavorRefusal, contains('without --flavor'));
    expect(watchosDefaultFlavorWarning('staging'), contains('default-flavor "staging"'));
    expect(forbiddenWordsIn(kWatchosFlavorRefusal), isEmpty);
    expect(forbiddenWordsIn(watchosDefaultFlavorWarning('staging')), isEmpty);
  });
}
