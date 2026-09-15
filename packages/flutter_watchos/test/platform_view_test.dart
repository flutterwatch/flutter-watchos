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

  /// Flip to true to simulate an engine that composites platform views from
  /// the layer tree (`FlutterWatchOSPlatformViewsComposited` returns true).
  bool composited = false;

  @override
  bool get supportsPlatformViews => true;

  @override
  bool get supportsPlatformViewUnderlay => underlaySupported;

  @override
  bool get supportsCompositedPlatformViews => composited;

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

    testWidgets('legacy engine: no PlatformViewLayer, no repaint boundary',
        (tester) async {
      await tester.pumpWidget(const WatchPlatformView(viewType: 'map'));
      expect(tester.layers.whereType<PlatformViewLayer>(), isEmpty);
      final RenderObject box =
          tester.renderObject(find.byType(WatchPlatformView));
      expect(box.isRepaintBoundary, isFalse);
      expect(box.needsCompositing, isFalse);
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

  group('WatchPlatformView composited (layer tree) mode', () {
    setUp(() {
      bindings.composited = true;
    });

    /// The [PlatformViewLayer]s currently in the scene.
    Iterable<PlatformViewLayer> platformViewLayers(WidgetTester tester) =>
        tester.layers.whereType<PlatformViewLayer>();

    testWidgets('paints a PlatformViewLayer with its view id at its rect',
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
      final PlatformViewLayer layer = platformViewLayers(tester).single;
      expect(layer.viewId, 1);
      // The box is a repaint boundary, so it paints at the origin of its own
      // OffsetLayer; the widget's global rect is the two combined.
      final OffsetLayer own = layer.parent! as OffsetLayer;
      expect(layer.rect.shift(own.offset),
          tester.getRect(find.byType(WatchPlatformView)));
      expect(layer.rect.size, const Size(120, 48));
    });

    testWidgets('is a repaint boundary that always needs compositing',
        (tester) async {
      await tester.pumpWidget(const WatchPlatformView(viewType: 'map'));
      final RenderObject box =
          tester.renderObject(find.byType(WatchPlatformView));
      expect(box.isRepaintBoundary, isTrue);
      expect(box.needsCompositing, isTrue);
      expect(box.debugLayer, isA<OffsetLayer>());
    });

    testWidgets('belowFlutter punches no hole: only the platform view layer',
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
      final RenderObject box =
          tester.renderObject(find.byType(WatchPlatformView));
      // No canvas drawing at all (in particular no BlendMode.clear rect)...
      expect(box, paintsNothing);
      // ...and the box's own layer holds exactly the PlatformViewLayer — a
      // cleared rect would show up as a sibling PictureLayer.
      final ContainerLayer own = box.debugLayer!;
      expect(own.firstChild, isA<PlatformViewLayer>());
      expect(own.lastChild, same(own.firstChild));
      expect(platformViewLayers(tester).single.viewId, 1);
    });

    testWidgets('one layer per view, in paint order', (tester) async {
      await tester.pumpWidget(
        const Column(
          children: <Widget>[
            Expanded(child: WatchPlatformView(viewType: 'a')),
            Expanded(
                child: WatchPlatformView(
                    viewType: 'b',
                    layer: WatchPlatformViewLayer.belowFlutter)),
          ],
        ),
      );
      expect(
        platformViewLayers(tester).map((PlatformViewLayer l) => l.viewId),
        <int>[1, 2],
      );
    });

    testWidgets('hides when not painted (scrolled out of the viewport)',
        (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ListView(
            children: const <Widget>[
              SizedBox(height: 500),
              SizedBox(height: 48, child: WatchPlatformView(viewType: 'map')),
              SizedBox(height: 2000),
            ],
          ),
        ),
      );
      expect(platformViewLayers(tester), hasLength(1));
      await tester.drag(find.byType(ListView), const Offset(0, -1000));
      await tester.pump();
      expect(platformViewLayers(tester), isEmpty);
    });

    testWidgets('registry calls are unchanged: create/dispose with the layer',
        (tester) async {
      await tester.pumpWidget(
        const WatchPlatformView(viewType: 'map', creationParams: '{"z":3}'),
      );
      expect(bindings.log, <String>['create(1, map, {"z":3}, below=false)']);
      expect(bindings.sizeLog, <String>['setSize(1, 800.0x600.0)']);

      await tester.pumpWidget(
        const WatchPlatformView(
          viewType: 'map',
          creationParams: '{"z":3}',
          layer: WatchPlatformViewLayer.belowFlutter,
        ),
      );
      await tester.pumpWidget(const SizedBox());
      expect(bindings.log, <String>[
        'create(1, map, {"z":3}, below=false)',
        'create(1, map, {"z":3}, below=true)',
        'dispose(1)',
      ]);
    });

    testWidgets('still tags its semantics node with the platform view id',
        (tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      await tester.pumpWidget(const WatchPlatformView(viewType: 'map'));
      expect(
          tester.getSemantics(find.byType(WatchPlatformView)).platformViewId,
          1);
      semantics.dispose();
    });

    testWidgets('stays touch-transparent (ownership is decided natively)',
        (tester) async {
      int taps = 0;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => taps++,
            child: const WatchPlatformView(
              viewType: 'gauge',
              layer: WatchPlatformViewLayer.belowFlutter,
            ),
          ),
        ),
      );
      await tester.tap(find.byType(GestureDetector));
      expect(taps, 1);
    });

    test('isComposited mirrors the bindings', () {
      expect(WatchPlatformView.isComposited, isTrue);
      bindings.composited = false;
      expect(WatchPlatformView.isComposited, isFalse);
      WatchPlatformView.bindingsOverride = WatchOSNativeBindings.forTesting();
      expect(WatchPlatformView.isComposited, isFalse);
    });
  });
}
