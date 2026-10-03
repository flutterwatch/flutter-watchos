// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_watchos_runtime/watchos_crown_runtime.dart';

/// Records what the runtime tells the host.
class FakeHost implements CrownHost {
  final List<CrownDescription?> configured = <CrownDescription?>[];
  final List<(double, bool)> synced = <(double, bool)>[];
  void Function(double pixels, int phase)? listener;

  @override
  void configure(CrownDescription? description) => configured.add(description);

  @override
  void sync(double pixels, {bool stop = false}) => synced.add((pixels, stop));

  @override
  void setListener(void Function(double pixels, int phase)? listener) =>
      this.listener = listener;
}

/// What `WatchCrownScroll` (package:flutter_watchos) puts above its child.
Widget mark(Widget child, {bool enabled = true, bool indicator = true}) {
  return MetaData(
    metaData: <String, Object>{
      crownScrollMarker: true,
      'enabled': enabled,
      'scrollIndicator': indicator,
    },
    child: child,
  );
}

// The 46 mm screen: 208 x 248 points at 2x.
const Size kScreen = Size(208, 248);

Widget rows({
  ScrollController? controller,
  ScrollPhysics? physics,
  int count = 40,
  NotificationListenerCallback<ScrollNotification>? onScroll,
}) {
  return MaterialApp(
    home: NotificationListener<ScrollNotification>(
      onNotification: onScroll ?? (_) => false,
      child: ListView.builder(
        controller: controller,
        physics: physics,
        itemExtent: 44,
        itemCount: count,
        itemBuilder: (BuildContext context, int index) => Text('Row $index'),
      ),
    ),
  );
}

void main() {
  late FakeHost host;
  late CrownRuntime runtime;

  Future<void> start(WidgetTester tester, Widget app) async {
    tester.view.physicalSize = kScreen * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    host = FakeHost();
    runtime = CrownRuntime(host, scanInterval: 1);
    runtime.attach(tester.binding);
    addTearDown(runtime.detach);
    await tester.pumpWidget(app);
    await tester.pump();
  }

  ScrollPosition positionOf(WidgetTester tester, [Finder? finder]) => tester
      .state<ScrollableState>(finder ?? find.byType(Scrollable).first)
      .position;

  testWidgets('describes the main list and registers for the crown', (
    WidgetTester tester,
  ) async {
    await start(tester, rows());
    expect(host.listener, isNotNull);
    expect(
      host.configured.last,
      const CrownDescription(
        viewport: 248,
        minExtent: 0,
        maxExtent: 40 * 44 - 248,
        rowExtent: 44,
      ),
    );
    // Selecting a scrollable stops whatever the native view was doing.
    expect(host.synced.last, (0.0, true));
  });

  testWidgets('an app that drew and went idle is found without a touch', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = kScreen * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(rows());
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);

    host = FakeHost();
    runtime = CrownRuntime(host, scanInterval: 1);
    runtime.attach(tester.binding);
    addTearDown(runtime.detach);
    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.pump();
    expect(host.configured.last?.maxExtent, 40 * 44 - 248);
  });

  testWidgets('the crown moves the content exactly, overscroll included', (
    WidgetTester tester,
  ) async {
    final List<ScrollNotification> seen = <ScrollNotification>[];
    await start(
      tester,
      rows(
        onScroll: (ScrollNotification n) {
          seen.add(n);
          return false;
        },
      ),
    );
    final ScrollPosition position = positionOf(tester);

    runtime.onNativePosition(100, 1);
    await tester.pump();
    expect(position.pixels, 100);
    expect(seen.whereType<ScrollStartNotification>(), hasLength(1));

    // The native view's edge spring, past the end.
    runtime.onNativePosition(1512 + 60, 1);
    await tester.pump();
    expect(position.pixels, 1572);
    // The crown's own moves are never synced back.
    expect(host.synced.where(((double, bool) s) => s.$1 > 0), isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('a rest ends the drive in place, without a ballistic', (
    WidgetTester tester,
  ) async {
    final List<ScrollNotification> seen = <ScrollNotification>[];
    await start(
      tester,
      rows(
        onScroll: (ScrollNotification n) {
          seen.add(n);
          return false;
        },
      ),
    );
    final ScrollPosition position = positionOf(tester);

    runtime.onNativePosition(100, 1);
    runtime.onNativePosition(120, 0);
    await tester.pump();
    // As after a drag: the scroll ends, then the user direction goes idle.
    expect(seen[seen.length - 2], isA<ScrollEndNotification>());
    expect(
      seen.last,
      isA<UserScrollNotification>().having(
        (UserScrollNotification n) => n.direction,
        'direction',
        ScrollDirection.idle,
      ),
    );
    expect(position.isScrollingNotifier.value, isFalse);
    await tester.pump(const Duration(seconds: 1));
    expect(position.pixels, 120);
  });

  testWidgets('a finger during a drive stops the native view and wins', (
    WidgetTester tester,
  ) async {
    await start(tester, rows());
    final ScrollPosition position = positionOf(tester);

    runtime.onNativePosition(100, 1);
    await tester.pump();
    final TestGesture finger = await tester.startGesture(
      tester.getCenter(find.byType(ListView)),
    );
    await tester.pump();
    expect(host.synced.last, (100.0, true));

    // The native view's glide runs on; the content stays with the finger.
    runtime.onNativePosition(130, 1);
    await tester.pump();
    expect(position.pixels, 100);
    await finger.moveBy(const Offset(0, -60));
    await tester.pump();
    final double dragged = position.pixels;
    expect(dragged, greaterThan(100));
    await finger.up();
    await tester.pumpAndSettle();

    // At rest the native view is brought to where the content is.
    runtime.onNativePosition(170, 0);
    expect(host.synced.last, (position.pixels, false));
    // And the crown drives again.
    runtime.onNativePosition(position.pixels + 10, 1);
    await tester.pump();
    expect(host.synced.last.$2, isFalse);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('a turn while a finger holds the content is ignored', (
    WidgetTester tester,
  ) async {
    await start(tester, rows());
    final ScrollPosition position = positionOf(tester);
    final TestGesture finger = await tester.startGesture(
      tester.getCenter(find.byType(ListView)),
    );
    await tester.pump();
    runtime.onNativePosition(0, 2);
    runtime.onNativePosition(40, 1);
    await tester.pump();
    expect(position.pixels, 0);
    await finger.up();
    await tester.pumpAndSettle();
    // Once the finger is off, the next turn drives.
    runtime.onNativePosition(0, 2);
    runtime.onNativePosition(20, 1);
    await tester.pump();
    expect(position.pixels, 20);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('a new turn after a finger took over drives at once', (
    WidgetTester tester,
  ) async {
    await start(tester, rows());
    final ScrollPosition position = positionOf(tester);
    runtime.onNativePosition(0, 2);
    runtime.onNativePosition(100, 1);
    await tester.pump();
    final TestGesture finger = await tester.startGesture(
      tester.getCenter(find.byType(ListView)),
    );
    await tester.pump();
    expect(host.synced.last, (100.0, true));
    await finger.moveBy(const Offset(0, -40));
    await finger.up();
    await tester.pumpAndSettle();
    final double after = position.pixels;
    // No rest came for the stopped glide; a new turn still drives.
    runtime.onNativePosition(after, 2);
    runtime.onNativePosition(after + 30, 1);
    await tester.pump();
    expect(position.pixels, after + 30);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('a crown turn during a fling takes over without a jump', (
    WidgetTester tester,
  ) async {
    await start(tester, rows(count: 200));
    final ScrollPosition position = positionOf(tester);

    await tester.fling(find.byType(ListView), const Offset(0, -200), 1500);
    await tester.pump(const Duration(milliseconds: 50));
    final double flung = position.pixels;
    // The native view followed the fling 35 behind; the crown's first step
    // moves it 5.
    runtime.onNativePosition(flung - 35, 2);
    runtime.onNativePosition(flung - 30, 1);
    await tester.pump();
    expect(position.pixels, flung + 5);
    // The 35 behind is blended out at 0.8 per report.
    runtime.onNativePosition(flung - 25, 1);
    await tester.pump();
    expect(position.pixels, moreOrLessEquals(flung - 25 + 35 * 0.8));
    for (int i = 0; i < 30; i++) {
      runtime.onNativePosition(flung - 25 + i, 1);
    }
    await tester.pump();
    expect(position.pixels, moreOrLessEquals(flung - 25 + 29, epsilon: 0.3));
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('content moved by the app is synced to the native view', (
    WidgetTester tester,
  ) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    await start(tester, rows(controller: controller));
    controller.jumpTo(300);
    await tester.pump();
    expect(host.synced.last, (300.0, false));
  });

  testWidgets('a covered route gives the crown back when the top one pops', (
    WidgetTester tester,
  ) async {
    final GlobalKey<NavigatorState> navigator = GlobalKey<NavigatorState>();
    await start(
      tester,
      MaterialApp(
        navigatorKey: navigator,
        home: ListView.builder(
          itemExtent: 44,
          itemCount: 40,
          itemBuilder: (BuildContext context, int index) => Text('A $index'),
        ),
      ),
    );
    expect(host.configured.last?.maxExtent, 40 * 44 - 248);

    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => ListView.builder(
          itemExtent: 44,
          itemCount: 20,
          itemBuilder: (BuildContext context, int index) => Text('B $index'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(host.configured.last?.maxExtent, 20 * 44 - 248);

    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(host.configured.last?.maxExtent, 40 * 44 - 248);
  });

  testWidgets('a WatchCrownScroll mark wins over a larger list', (
    WidgetTester tester,
  ) async {
    Widget list(String name, int count) => ListView.builder(
      itemExtent: 44,
      itemCount: count,
      itemBuilder: (BuildContext context, int index) => Text('$name $index'),
    );
    await start(
      tester,
      MaterialApp(
        home: Column(
          children: <Widget>[
            SizedBox(height: 80, child: mark(list('M', 30))),
            Expanded(child: list('L', 50)),
          ],
        ),
      ),
    );
    expect(host.configured.last?.viewport, 80);
  });

  testWidgets('an app-wide mark still picks the main list', (
    WidgetTester tester,
  ) async {
    // Wonderous wraps the whole app in WatchCrownScroll: every page's
    // outermost list is marked, and a small one later in paint order must
    // not win over the list that fills the screen.
    Widget list(String name, int count) => ListView.builder(
      itemExtent: 44,
      itemCount: count,
      itemBuilder: (BuildContext context, int index) => Text('$name $index'),
    );
    await start(
      tester,
      MaterialApp(
        home: mark(
          Column(
            children: <Widget>[
              Expanded(child: list('Main', 50)),
              SizedBox(height: 40, child: list('Ticker', 10)),
            ],
          ),
        ),
      ),
    );
    expect(host.configured.last?.viewport, 248 - 40);
  });

  testWidgets("an IndexedStack's hidden tab never takes the crown", (
    WidgetTester tester,
  ) async {
    // Wonderous keeps visited tabs in an IndexedStack: laid out, not drawn.
    Widget list(String name, int count) => ListView.builder(
      itemExtent: 44,
      itemCount: count,
      itemBuilder: (BuildContext context, int index) => Text('$name $index'),
    );
    int index = 0;
    late StateSetter setIndex;
    await start(
      tester,
      MaterialApp(
        home: StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            setIndex = setState;
            return IndexedStack(
              index: index,
              children: <Widget>[list('Article', 40), const Text('Photos')],
            );
          },
        ),
      ),
    );
    expect(host.configured.last?.maxExtent, 40 * 44 - 248);
    setIndex(() => index = 1);
    await tester.pump();
    await tester.pump();
    expect(host.configured.last, isNull);
  });

  testWidgets('switching tabs mid-turn lets go of the hidden list at once', (
    WidgetTester tester,
  ) async {
    // Wonderous: turn the crown on the article, switch to the photos while
    // the turn goes on, come back: the article must not have moved.
    Widget list(String name, int count) => ListView.builder(
      itemExtent: 44,
      itemCount: count,
      itemBuilder: (BuildContext context, int index) => Text('$name $index'),
    );
    int index = 0;
    late StateSetter setIndex;
    await start(
      tester,
      MaterialApp(
        home: StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            setIndex = setState;
            return IndexedStack(
              index: index,
              children: <Widget>[list('Article', 40), const Text('Photos')],
            );
          },
        ),
      ),
    );
    final ScrollPosition article = positionOf(tester);
    runtime.onNativePosition(0, 2);
    runtime.onNativePosition(100, 1);
    await tester.pump();
    expect(article.pixels, 100);
    setIndex(() => index = 1);
    await tester.pump();
    expect(host.configured.last, isNull);
    expect(article.isScrollingNotifier.value, isFalse);
    // The rest of the turn reaches nothing.
    runtime.onNativePosition(150, 1);
    runtime.onNativePosition(200, 1);
    await tester.pump();
    expect(article.pixels, 100);
  });

  testWidgets('a mark with enabled: false keeps the crown off its lists', (
    WidgetTester tester,
  ) async {
    Widget list(String name, int count) => ListView.builder(
      itemExtent: 44,
      itemCount: count,
      itemBuilder: (BuildContext context, int index) => Text('$name $index'),
    );
    await start(
      tester,
      MaterialApp(
        home: Column(
          children: <Widget>[
            Expanded(flex: 3, child: mark(list('Big', 50), enabled: false)),
            Expanded(child: list('Small', 50)),
          ],
        ),
      ),
    );
    // Only the small list is left to take the crown.
    expect(host.configured.last?.viewport, 62);
  });

  testWidgets('a mark can hide the scroll indicator', (
    WidgetTester tester,
  ) async {
    await start(tester, MaterialApp(home: mark(rows(), indicator: false)));
    expect(host.configured.last?.indicator, isFalse);
  });

  testWidgets('with nothing to scroll the description is withdrawn', (
    WidgetTester tester,
  ) async {
    await start(tester, rows());
    expect(host.configured.last, isNotNull);
    await tester.pumpWidget(const MaterialApp(home: Text('No list')));
    await tester.pump();
    expect(host.configured.last, isNull);
  });

  testWidgets('a released stretch springs back as the native view does', (
    WidgetTester tester,
  ) async {
    await start(tester, rows());
    final ScrollPosition position = positionOf(tester);

    final TestGesture finger = await tester.startGesture(
      tester.getCenter(find.byType(ListView)),
    );
    for (int i = 0; i < 12; i++) {
      await finger.moveBy(const Offset(0, 10));
      await tester.pump(const Duration(milliseconds: 100));
    }
    // The finger rests on the stretch, then lets go: no release velocity.
    await tester.pump(const Duration(milliseconds: 200));
    await finger.up();
    await tester.pump(); // the platform's release is replaced
    final double x0 = position.pixels;
    expect(x0, lessThan(-20));
    await tester.pump(); // the native release's first tick (t = 0)
    expect(position.pixels, moreOrLessEquals(x0, epsilon: 0.01));
    await tester.pump(const Duration(milliseconds: 100));
    // Straight back, e^(-11t)·x0: the native view, not the platform's
    // slower-starting spring.
    expect(
      position.pixels,
      moreOrLessEquals(math.exp(-11 * 0.1) * x0, epsilon: 1.0),
    );
    await tester.pumpAndSettle();
    expect(position.pixels, moreOrLessEquals(0, epsilon: 0.01));
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets("an app's own physics keep their own release", (
    WidgetTester tester,
  ) async {
    await start(tester, rows(physics: const ClampingScrollPhysics()));
    final ScrollPosition position = positionOf(tester);
    await tester.fling(find.byType(ListView), const Offset(0, -100), 1000);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    // Clamping never leaves the range, native or not.
    expect(position.pixels, inInclusiveRange(0, 1512));
    expect(CrownRuntime.isPlatformBounce(position.physics), isFalse);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('an endless list is mirrored through a window around it', (
    WidgetTester tester,
  ) async {
    await start(
      tester,
      MaterialApp(
        home: ListView.builder(
          itemExtent: 44,
          itemBuilder: (BuildContext context, int index) => Text('Row $index'),
        ),
      ),
    );
    final CrownDescription? described = host.configured.last;
    expect(described, isNotNull);
    expect(described!.maxExtent.isFinite, isTrue);
    expect(described.maxExtent, greaterThan(10000));
    expect(described.minExtent, 0);
    runtime.onNativePosition(0, 2);
    runtime.onNativePosition(5000, 1);
    await tester.pump();
    expect(positionOf(tester).pixels, 5000);
  });

  testWidgets('a reversed list is mirrored so the crown turns the right way', (
    WidgetTester tester,
  ) async {
    await start(
      tester,
      MaterialApp(
        home: ListView.builder(
          reverse: true,
          itemExtent: 44,
          itemCount: 40,
          itemBuilder: (BuildContext context, int index) => Text('Row $index'),
        ),
      ),
    );
    const double max = 40 * 44 - 248;
    // At rest at its start (the bottom), the native view is at its end.
    expect(host.synced.last.$1, max);
    // The crown turning down (native origin up) moves a reversed list
    // towards its start, as it moves the content on screen.
    runtime.onNativePosition(max, 2);
    runtime.onNativePosition(max - 100, 1);
    await tester.pump();
    expect(positionOf(tester).pixels, 100);
  });

  testWidgets('a dialog over a list takes the crown away from it', (
    WidgetTester tester,
  ) async {
    final GlobalKey<NavigatorState> navigator = GlobalKey<NavigatorState>();
    await start(
      tester,
      MaterialApp(
        navigatorKey: navigator,
        home: ListView.builder(
          itemExtent: 44,
          itemCount: 40,
          itemBuilder: (BuildContext context, int index) => Text('A $index'),
        ),
      ),
    );
    expect(host.configured.last, isNotNull);
    showDialog<void>(
      context: navigator.currentContext!,
      builder: (BuildContext context) => const AlertDialog(content: Text('Hi')),
    );
    await tester.pumpAndSettle();
    expect(host.configured.last, isNull);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(host.configured.last?.maxExtent, 40 * 44 - 248);
  });

  testWidgets('a rest past an edge ends the drive and springs back', (
    WidgetTester tester,
  ) async {
    await start(tester, rows(count: 200));
    final ScrollPosition position = positionOf(tester);
    await tester.fling(find.byType(ListView), const Offset(0, -200), 1500);
    await tester.pump(const Duration(milliseconds: 50));
    final double flung = position.pixels;
    // A turn that starts 40 behind the content and rests at once, short of
    // the top: the leftover offset is folded into the rest.
    runtime.onNativePosition(flung - 40, 2);
    runtime.onNativePosition(flung - 41, 1);
    runtime.onNativePosition(flung - 41, 0);
    await tester.pumpAndSettle();
    expect(position.isScrollingNotifier.value, isFalse);
    expect(position.outOfRange, isFalse);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('a turn that rests past the end with an offset springs back', (
    WidgetTester tester,
  ) async {
    await start(tester, rows());
    final ScrollPosition position = positionOf(tester);
    position.jumpTo(1500);
    await tester.pump();
    // The native view trailed by 40 and rests at once: content would be
    // left 8 past the end (max 1512) with the drive still holding it.
    runtime.onNativePosition(1460, 2);
    runtime.onNativePosition(1480, 1);
    await tester.pump();
    expect(position.pixels, 1520);
    runtime.onNativePosition(1480, 0);
    await tester.pumpAndSettle();
    expect(position.isScrollingNotifier.value, isFalse);
    expect(position.pixels, moreOrLessEquals(1512, epsilon: 0.01));
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  group('isPlatformBounce', () {
    test('the platform default, as the framework composes it', () {
      expect(
        CrownRuntime.isPlatformBounce(
          const BouncingScrollPhysics(parent: RangeMaintainingScrollPhysics()),
        ),
        isTrue,
      );
      expect(
        CrownRuntime.isPlatformBounce(
          const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(
              parent: RangeMaintainingScrollPhysics(),
            ),
          ),
        ),
        isTrue,
      );
    });

    test('anything an app chose', () {
      expect(
        CrownRuntime.isPlatformBounce(const ClampingScrollPhysics()),
        isFalse,
      );
      expect(
        CrownRuntime.isPlatformBounce(
          const BouncingScrollPhysics(
            decelerationRate: ScrollDecelerationRate.fast,
          ),
        ),
        isFalse,
      );
      expect(
        CrownRuntime.isPlatformBounce(
          const PageScrollPhysics(parent: BouncingScrollPhysics()),
        ),
        isFalse,
      );
    });
  });

  group('nativeBallisticSimulation', () {
    FixedScrollMetrics at(double pixels) => FixedScrollMetrics(
      minScrollExtent: 0,
      maxScrollExtent: 1000,
      pixels: pixels,
      viewportDimension: 248,
      axisDirection: AxisDirection.down,
      devicePixelRatio: 2,
    );
    const Tolerance tolerance = Tolerance(distance: 0.01, velocity: 0.03);

    const double lead = 1 / 60;

    test('leaves any other ballistic that stays in range to the platform', () {
      expect(
        nativeBallisticSimulation(
          at(500),
          300,
          tolerance,
          fingerRelease: false,
        ),
        isNull,
      );
    });

    test(
      'a flick runs one frame ahead, as the native release moves at once',
      () {
        final Simulation sim = nativeBallisticSimulation(
          at(500),
          300,
          tolerance,
        )!;
        final Simulation friction = FrictionSimulation(0.135, 500, 300);
        expect(sim.x(0), moreOrLessEquals(friction.x(lead)));
      },
    );

    test('a released stretch runs e^(-11t)·(x0 + v·t)', () {
      final Simulation sim = nativeBallisticSimulation(
        at(-61.5),
        -180,
        tolerance,
      )!;
      for (final double t in <double>[0.05, 0.1, 0.2]) {
        final double u = t + lead;
        expect(
          sim.x(t),
          moreOrLessEquals(
            math.exp(-11 * u) * (-61.5 - 180 * u),
            epsilon: 0.05,
          ),
        );
      }
    });

    test('a still finger lets go of a stretch with no lead', () {
      final Simulation sim = nativeBallisticSimulation(at(-40), 0, tolerance)!;
      expect(sim.x(0), moreOrLessEquals(-40));
      expect(sim.x(0.1), moreOrLessEquals(math.exp(-1.1) * -40, epsilon: 0.05));
    });

    test('a ballistic restarted mid-spring gets no second release kick', () {
      // The spring's own state at -30 moving in at 200 pt/s carries on.
      final Simulation sim = nativeBallisticSimulation(
        at(-30),
        200,
        tolerance,
        fingerRelease: false,
      )!;
      expect(sim.dx(0), moreOrLessEquals(200));
    });

    test('a fling into the edge peaks at v/(e·ω), 1/ω after it', () {
      final Simulation sim = nativeBallisticSimulation(
        at(1000),
        1900,
        tolerance,
      )!;
      expect(
        sim.x(1 / 11 - lead) - 1000,
        moreOrLessEquals(1900 / (math.e * 11), epsilon: 0.5),
      );
    });
  });
}
