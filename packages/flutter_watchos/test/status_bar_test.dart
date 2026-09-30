// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_watchos/flutter_watchos.dart';
import 'package:flutter_watchos/src/watchos_ffi_bindings_web.dart' as web;

/// Fake bindings for [WatchStatusBar]: stands in for the clock band the watch
/// host reports.
class _FakeStatusBarBindings extends WatchOSNativeBindings {
  _FakeStatusBarBindings({this.band = -1}) : super.forTesting();

  /// What the host reported, or -1 when nothing has.
  double band;

  @override
  double get clockBandHeight => band;
}

/// What one build of [_Probe] saw.
typedef _Build = ({double height, double ambientTop});

/// Records what [WatchStatusBar.heightOf] and the ambient padding give at its
/// place in the tree, on every build.
class _Probe extends StatelessWidget {
  const _Probe(this.builds);

  final List<_Build> builds;

  @override
  Widget build(BuildContext context) {
    builds.add((
      height: WatchStatusBar.heightOf(context),
      ambientTop: MediaQuery.paddingOf(context).top,
    ));
    return const SizedBox.expand();
  }
}

/// Records what [WatchStatusBar.heightOf] gives on every build, and reads
/// nothing else, so any dependency it has comes from `heightOf`.
class _HeightOnlyProbe extends StatelessWidget {
  const _HeightOnlyProbe(this.heights);

  final List<double> heights;

  @override
  Widget build(BuildContext context) {
    heights.add(WatchStatusBar.heightOf(context));
    return const SizedBox.expand();
  }
}

void main() {
  group('WatchStatusBar.heightOf', () {
    const double pixelRatio = 2;

    /// Gives the test view a 42mm watch screen whose insets have [top] at the
    /// top, in logical pixels.
    void setView(WidgetTester tester, {required double top}) {
      tester.view.devicePixelRatio = pixelRatio;
      tester.view.physicalSize = const Size(187, 223) * pixelRatio;
      final FakeViewPadding insets = FakeViewPadding(
        left: 2 * pixelRatio,
        top: top * pixelRatio,
        right: 2 * pixelRatio,
        bottom: 31 * pixelRatio,
      );
      tester.view.padding = insets;
      tester.view.viewPadding = insets;
    }

    setUp(() => WatchStatusBar.bindingsOverride = null);
    tearDown(() => WatchStatusBar.bindingsOverride = null);

    testWidgets('off the watch it is the view\'s top padding', (
      WidgetTester tester,
    ) async {
      setView(tester, top: 17);
      addTearDown(tester.view.reset);
      final List<_Build> builds = <_Build>[];

      await tester.pumpWidget(_Probe(builds));

      expect(builds.last.height, 17);
    });

    testWidgets('below a SafeArea it is still the view\'s top padding', (
      WidgetTester tester,
    ) async {
      setView(tester, top: 17);
      addTearDown(tester.view.reset);
      final List<_Build> builds = <_Build>[];

      await tester.pumpWidget(SafeArea(child: _Probe(builds)));

      expect(builds.last.ambientTop, 0);
      expect(builds.last.height, 17);
    });

    testWidgets(
        'in a Scaffold body below an AppBar it is still the view\'s '
        'top padding', (WidgetTester tester) async {
      setView(tester, top: 17);
      addTearDown(tester.view.reset);
      final List<_Build> builds = <_Build>[];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(appBar: AppBar(), body: _Probe(builds)),
        ),
      );

      expect(builds.last.ambientTop, 0);
      expect(builds.last.height, 17);
    });

    testWidgets('the caller rebuilds when the view padding changes', (
      WidgetTester tester,
    ) async {
      setView(tester, top: 17);
      addTearDown(tester.view.reset);
      final List<double> heights = <double>[];
      await tester.pumpWidget(_HeightOnlyProbe(heights));
      expect(heights, <double>[17]);

      setView(tester, top: 20);
      await tester.pump();

      expect(heights, <double>[17, 20]);
    });

    testWidgets('a band the host reports wins over the padding', (
      WidgetTester tester,
    ) async {
      WatchStatusBar.bindingsOverride = _FakeStatusBarBindings(band: 56.5);
      setView(tester, top: 17);
      addTearDown(tester.view.reset);
      final List<_Build> atTop = <_Build>[];
      final List<_Build> belowSafeArea = <_Build>[];

      await tester.pumpWidget(
        Column(
          children: <Widget>[
            Expanded(child: _Probe(atTop)),
            Expanded(child: SafeArea(child: _Probe(belowSafeArea))),
          ],
        ),
      );

      expect(atTop.last.height, 56.5);
      expect(belowSafeArea.last.height, 56.5);
    });

    testWidgets('a host that has not reported gives the view\'s top padding', (
      WidgetTester tester,
    ) async {
      WatchStatusBar.bindingsOverride = _FakeStatusBarBindings(band: -1);
      setView(tester, top: 17);
      addTearDown(tester.view.reset);
      final List<_Build> builds = <_Build>[];

      await tester.pumpWidget(_Probe(builds));

      expect(builds.last.height, 17);
    });
  });

  group('clockBandHeight', () {
    test('is negative on forTesting bindings', () {
      expect(WatchOSNativeBindings.forTesting().clockBandHeight, isNegative);
    });

    test('is -1 on the Web', () {
      expect(web.WatchOSNativeBindings().clockBandHeight, -1);
      expect(web.WatchOSNativeBindings.forTesting().clockBandHeight, -1);
    });
  });
}
