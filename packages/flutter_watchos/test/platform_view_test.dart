// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_watchos/flutter_watchos.dart';

/// Records every platform-view registry call the widget makes.
class _FakePlatformViewBindings extends WatchOSNativeBindings {
  _FakePlatformViewBindings() : super.forTesting();

  final List<String> log = <String>[];

  /// Flip to false to simulate an engine with platform views but no
  /// underlay layer (no Create2 symbol).
  bool underlaySupported = true;

  @override
  bool get supportsPlatformViews => true;

  @override
  bool get supportsPlatformViewUnderlay => underlaySupported;

  @override
  void platformViewCreate(int viewId, String viewType, String params,
      {bool belowFrame = false}) {
    log.add('create($viewId, $viewType, $params, below=$belowFrame)');
  }

  @override
  void platformViewDispose(int viewId) {
    log.add('dispose($viewId)');
  }

  /// Layout-size reports, kept separate from [log]: they arrive on every
  /// layout and would otherwise noise up the lifecycle expectations.
  final List<String> sizeLog = <String>[];

  @override
  void platformViewSetSize(int viewId, double width, double height) {
    sizeLog.add('setSize($viewId, ${width}x$height)');
  }
}

void main() {
  late _FakePlatformViewBindings bindings;

  setUp(() {
    bindings = _FakePlatformViewBindings();
    WatchPlatformView.bindingsOverride = bindings;
  });

  tearDown(() {
    WatchPlatformView.bindingsOverride = null;
  });

  group('WatchPlatformView', () {
    testWidgets('registers on mount and disposes on unmount', (tester) async {
      await tester.pumpWidget(
        const WatchPlatformView(viewType: 'map', creationParams: '{"z":3}'),
      );
      expect(bindings.log, <String>['create(1, map, {"z":3}, below=false)']);

      await tester.pumpWidget(const SizedBox());
      expect(bindings.log, <String>[
        'create(1, map, {"z":3}, below=false)',
        'dispose(1)',
      ]);
    });

    testWidgets('re-creates in place when params change, not on rebuild',
        (tester) async {
      await tester.pumpWidget(
        const WatchPlatformView(viewType: 'map', creationParams: 'a'),
      );
      // Identical rebuild: no FFI churn.
      await tester.pumpWidget(
        const WatchPlatformView(viewType: 'map', creationParams: 'a'),
      );
      expect(bindings.log, <String>['create(1, map, a, below=false)']);

      await tester.pumpWidget(
        const WatchPlatformView(viewType: 'map', creationParams: 'b'),
      );
      expect(bindings.log, <String>[
        'create(1, map, a, below=false)',
        'create(1, map, b, below=false)',
      ]);
    });

    testWidgets('each view gets its own id', (tester) async {
      await tester.pumpWidget(
        const Column(
          children: <Widget>[
            Expanded(child: WatchPlatformView(viewType: 'a')),
            Expanded(child: WatchPlatformView(viewType: 'b')),
          ],
        ),
      );
      expect(bindings.log, <String>[
        'create(1, a, , below=false)',
        'create(2, b, , below=false)',
      ]);
    });

    testWidgets('tags its semantics node with the platform view id',
        (tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        const Center(
          child: SizedBox(
            width: 100,
            height: 40,
            child: WatchPlatformView(viewType: 'map'),
          ),
        ),
      );
      final SemanticsNode node =
          tester.getSemantics(find.byType(WatchPlatformView));
      expect(node.platformViewId, 1);
      semantics.dispose();
    });

    testWidgets('fills its parent constraints and paints nothing',
        (tester) async {
      await tester.pumpWidget(
        const Center(
          child: SizedBox(
            width: 120,
            height: 48,
            child: WatchPlatformView(viewType: 'map'),
          ),
        ),
      );
      expect(tester.getSize(find.byType(WatchPlatformView)),
          const Size(120, 48));
      expect(
          tester.renderObject(find.byType(WatchPlatformView)), paintsNothing);
    });

    testWidgets('is touch-transparent (native overlay owns the rect)',
        (tester) async {
      int taps = 0;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => taps++,
            child: const WatchPlatformView(viewType: 'map'),
          ),
        ),
      );
      await tester.tap(find.byType(GestureDetector));
      expect(taps, 1); // the tap fell through the platform view slot
    });

    testWidgets('reports its layout size once, not per relayout',
        (tester) async {
      await tester.pumpWidget(
        const Center(
          child: SizedBox(
            width: 120,
            height: 48,
            child: WatchPlatformView(viewType: 'map'),
          ),
        ),
      );
      expect(bindings.sizeLog, <String>['setSize(1, 120.0x48.0)']);

      // Same size again: no FFI churn.
      await tester.pumpWidget(
        const Center(
          child: SizedBox(
            width: 120,
            height: 48,
            child: WatchPlatformView(viewType: 'map'),
          ),
        ),
      );
      expect(bindings.sizeLog, hasLength(1));

      // A real size change re-reports.
      await tester.pumpWidget(
        const Center(
          child: SizedBox(
            width: 120,
            height: 64,
            child: WatchPlatformView(viewType: 'map'),
          ),
        ),
      );
      expect(bindings.sizeLog, <String>[
        'setSize(1, 120.0x48.0)',
        'setSize(1, 120.0x64.0)',
      ]);
    });

    test('isSupported mirrors the bindings', () {
      expect(WatchPlatformView.isSupported, isTrue);
      WatchPlatformView.bindingsOverride = WatchOSNativeBindings.forTesting();
      expect(WatchPlatformView.isSupported, isFalse);
    });
  });

  group('WatchPlatformView underlay layer', () {
    testWidgets('registers with belowFrame and punches the hole',
        (tester) async {
      await tester.pumpWidget(
        const Center(
          child: SizedBox(
            width: 120,
            height: 48,
            child: WatchPlatformView(
              viewType: 'gauge',
              layer: WatchPlatformViewLayer.belowFlutter,
            ),
          ),
        ),
      );
      expect(bindings.log, <String>['create(1, gauge, , below=true)']);
      // The hole: one full-slot rect cleared to transparent.
      expect(
        tester.renderObject(find.byType(WatchPlatformView)),
        paints..rect(rect: const Rect.fromLTWH(0, 0, 120, 48)),
      );
    });

    testWidgets('layer change re-creates in place', (tester) async {
      await tester.pumpWidget(
        const WatchPlatformView(viewType: 'gauge'),
      );
      await tester.pumpWidget(
        const WatchPlatformView(
          viewType: 'gauge',
          layer: WatchPlatformViewLayer.belowFlutter,
        ),
      );
      expect(bindings.log, <String>[
        'create(1, gauge, , below=false)',
        'create(1, gauge, , below=true)',
      ]);
    });

    testWidgets('no hole when the engine lacks the underlay layer',
        (tester) async {
      bindings.underlaySupported = false;
      await tester.pumpWidget(
        const WatchPlatformView(
          viewType: 'gauge',
          layer: WatchPlatformViewLayer.belowFlutter,
        ),
      );
      // The view degrades to overlay; clearing the rect would only expose
      // the window background beneath the frame.
      expect(
          tester.renderObject(find.byType(WatchPlatformView)), paintsNothing);
    });

    test('isUnderlaySupported mirrors the bindings', () {
      expect(WatchPlatformView.isUnderlaySupported, isTrue);
      bindings.underlaySupported = false;
      expect(WatchPlatformView.isUnderlaySupported, isFalse);
      WatchPlatformView.bindingsOverride = WatchOSNativeBindings.forTesting();
      expect(WatchPlatformView.isUnderlaySupported, isFalse);
    });
  });
}
