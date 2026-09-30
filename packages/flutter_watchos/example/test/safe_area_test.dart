// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_watchos/flutter_watchos.dart';

import 'package:flutter_watchos_example/main.dart';

/// A watch screen in points, with the insets watchOS reports for it while the
/// clock is shown, and the corner inset the host reports instead in the
/// default safe area (as measured on the watchOS Simulator).
class _Watch {
  const _Watch(
    this.name,
    this.size, {
    required this.top,
    required this.bottom,
    required this.corner,
  });

  final String name;
  final Size size;

  /// The top inset watchOS reports: the clock's band.
  final double top;

  /// The bottom inset watchOS reports.
  final double bottom;

  /// The inset on all four sides in the default `corners` safe area.
  final double corner;
}

/// The left and right insets watchOS reports, the same on every watch.
const double _sides = 2;

const List<_Watch> _watches = <_Watch>[
  _Watch('40mm', Size(162, 197), top: 40, bottom: 19, corner: 9),
  _Watch('42mm', Size(187, 223), top: 48, bottom: 31, corner: 13),
  _Watch('Ultra 3', Size(211, 257), top: 56.5, bottom: 40, corner: 17),
];

/// The safe area the host reports, selected by the app's
/// `FlutterWatchOSSafeArea` key, which
/// https://github.com/flutterwatch/flutter-watchos/blob/main/doc/layout.md
/// explains.
enum _Mode {
  /// The default: the corner inset on all four sides, clock left out.
  corners,

  /// `platform`: the insets watchOS reports, clock included.
  platform,

  /// `platform` under a host that does not report the clock band, as a CLI
  /// from before the band was reported builds it.
  platformUnreported,
}

/// Stands in for the clock band the watch host reports.
class _FakeBindings extends WatchOSNativeBindings {
  _FakeBindings(this.band) : super.forTesting();

  final double band;

  @override
  double get clockBandHeight => band;
}

void main() {
  tearDown(() => WatchStatusBar.bindingsOverride = null);

  for (final _Watch watch in _watches) {
    for (final _Mode mode in _Mode.values) {
      testWidgets(
          '${watch.name}, ${mode.name}: the home list fills the screen, '
          'starts below the clock and insets its rows',
          (WidgetTester tester) async {
        final double side = mode == _Mode.corners ? watch.corner : _sides;
        final double top = mode == _Mode.corners ? watch.corner : watch.top;
        final double bottom =
            mode == _Mode.corners ? watch.corner : watch.bottom;
        // The host reports the clock's band in both safe areas; a host that
        // does not report it leaves heightOf the view's top padding, which in
        // `platform` is the band too.
        if (mode != _Mode.platformUnreported) {
          WatchStatusBar.bindingsOverride = _FakeBindings(watch.top);
        }

        const double pixelRatio = 2;
        tester.view.devicePixelRatio = pixelRatio;
        tester.view.physicalSize = watch.size * pixelRatio;
        final FakeViewPadding insets = FakeViewPadding(
          left: side * pixelRatio,
          top: top * pixelRatio,
          right: side * pixelRatio,
          bottom: bottom * pixelRatio,
        );
        tester.view.padding = insets;
        tester.view.viewPadding = insets;
        // flutter_test draws every glyph as a square 1 em wide, about twice as
        // wide as SF Compact, the watch's system font: at 12 pt
        // 'Platform.isIOS' is 168 wide in the test font and 82 in SF Compact.
        // At full size that label overflows its row on the 40mm and 42mm
        // screens, where it fits in SF Compact. Half-size text brings the
        // widths close to the watch's. None of the positions checked below
        // depend on the text size.
        tester.platformDispatcher.textScaleFactorTestValue = 0.5;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

        await tester.pumpWidget(const FlutterWatchosExampleApp());

        // No SafeArea shrinks the list: it covers the whole screen, so its
        // rows can scroll under the clock and down to the bottom edge.
        expect(tester.getRect(find.byType(ListView)), Offset.zero & watch.size);

        // The first row starts 6 below the clock's band in both safe areas,
        // and 10 inside the side insets.
        final Rect title = tester.getRect(find.text('flutter_watchos'));
        expect(title.top, watch.top + 6);
        expect(title.left, side + 10);
        expect(title.right, watch.size.width - side - 10);

        // Scroll to the end. One jump is not enough: the list builds its rows
        // lazily and learns its full length only once the last ones are
        // built.
        final ScrollPosition position =
            tester.state<ScrollableState>(find.byType(Scrollable)).position;
        double extent = -1;
        for (int jumps = 0;
            jumps < 10 && position.maxScrollExtent != extent;
            jumps++) {
          extent = position.maxScrollExtent;
          position.jumpTo(extent);
          await tester.pump();
        }
        expect(position.pixels, position.maxScrollExtent);

        // The last row, a haptic button with its bottom padding, ends 6 above
        // the bottom inset.
        final String lastHaptic = 'haptic: ${WatchHapticType.values.last.name}';
        final Finder lastRow = find
            .ancestor(
              of: find.widgetWithText(ElevatedButton, lastHaptic),
              matching: find.byType(Padding),
            )
            .first;
        expect(tester.getRect(lastRow).bottom, watch.size.height - bottom - 6);
      });
    }
  }
}
