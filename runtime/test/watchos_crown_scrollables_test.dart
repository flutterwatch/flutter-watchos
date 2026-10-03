// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// The crown with every common kind of Flutter scrollable: which one the
// runtime picks, how a turn moves it, where its rest leaves it, what the host
// is told, and what a change of extent in the middle of a turn does.
//
// A case that works with a caveat says so where it asserts today's
// behaviour (CAVEAT). A case that is broken today asserts what it should do,
// in a skipped group whose reason starts with BROKEN.

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_watchos_runtime/watchos_crown_runtime.dart';

/// The host's hidden native ScrollView, as far as the runtime can tell: it
/// records what the runtime tells it, follows its syncs, keeps its offset
/// from the top of its content when it gets a new description (as a SwiftUI
/// ScrollView keeps its content offset when the content changes height), and
/// comes to rest inside its range (the native edge spring).
class NativeView implements CrownHost {
  final List<CrownDescription?> configured = <CrownDescription?>[];
  final List<(double, bool)> synced = <(double, bool)>[];
  void Function(double pixels, int phase)? listener;

  /// The last description, or null when there is none.
  CrownDescription? get description =>
      configured.isEmpty ? null : configured.last;

  /// The view's offset from the top of its content.
  double _origin = 0;

  /// Where the view is, in the host's pixels (WatchCrownProxy.swift:
  /// `pixels(atOrigin:)`).
  double get pixels => (description?.minExtent ?? 0) + _origin;

  @override
  void configure(CrownDescription? description) => configured.add(description);

  @override
  void sync(double pixels, {bool stop = false}) {
    synced.add((pixels, stop));
    _origin = pixels - (description?.minExtent ?? 0);
  }

  @override
  void setListener(void Function(double pixels, int phase)? listener) =>
      this.listener = listener;

  /// Reports where the view is, in [phase].
  void report(int phase) => listener?.call(pixels, phase);

  /// The crown moves the view by [delta].
  void moveBy(double delta) => _origin += delta;

  /// The native edge spring brings the view back into its range.
  void spring() {
    final CrownDescription? d = description;
    if (d != null) {
      _origin = _origin.clamp(0, d.maxExtent - d.minExtent).toDouble();
    }
  }
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
const double kWidth = 208;
const double kHeight = 248;

/// One display refresh.
const Duration kFrame = Duration(milliseconds: 16);

/// [count] rows of [height].
List<Widget> rows(int count, {double height = 44, String name = 'Row'}) {
  return List<Widget>.generate(
    count,
    (int i) => SizedBox(height: height, child: Text('$name $i')),
  );
}

/// A description of exactly this shape.
Matcher describes({
  required double viewport,
  required double max,
  double min = 0,
  double? row,
  bool? indicator,
}) {
  TypeMatcher<CrownDescription> matcher = isA<CrownDescription>()
      .having(
        (CrownDescription d) => d.viewport,
        'viewport',
        moreOrLessEquals(viewport, epsilon: 0.01),
      )
      .having(
        (CrownDescription d) => d.minExtent,
        'minExtent',
        moreOrLessEquals(min, epsilon: 0.01),
      )
      .having(
        (CrownDescription d) => d.maxExtent,
        'maxExtent',
        moreOrLessEquals(max, epsilon: 0.01),
      );
  if (row != null) {
    matcher = matcher.having(
      (CrownDescription d) => d.rowExtent,
      'rowExtent',
      moreOrLessEquals(row, epsilon: 0.01),
    );
  }
  if (indicator != null) {
    matcher = matcher.having(
      (CrownDescription d) => d.indicator,
      'indicator',
      indicator,
    );
  }
  return matcher;
}

/// A fixed header of [extent] that scrolls away.
class _Header extends SliverPersistentHeaderDelegate {
  const _Header(this.extent);

  final double extent;

  @override
  double get minExtent => extent;

  @override
  double get maxExtent => extent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => const ColoredBox(color: Color(0xFF336699), child: Text('Header'));

  @override
  bool shouldRebuild(_Header oldDelegate) => oldDelegate.extent != extent;
}

void main() {
  late NativeView host;
  late CrownRuntime runtime;

  // A watch app runs as iOS (doc/architecture.md).
  final TargetPlatformVariant ios = TargetPlatformVariant.only(
    TargetPlatform.iOS,
  );

  Future<void> start(WidgetTester tester, Widget app) async {
    tester.view.physicalSize = kScreen * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    host = NativeView();
    runtime = CrownRuntime(host, scanInterval: 1);
    runtime.attach(tester.binding);
    addTearDown(runtime.detach);
    await tester.pumpWidget(app);
    await tester.pump();
  }

  /// The outermost scrollable under the widget with [key].
  ScrollableState scrollableIn(WidgetTester tester, Key key) {
    // Any Scrollable, a ListWheelScrollView's subclass included.
    return tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byKey(key),
            matching: find.byWidgetPredicate((Widget w) => w is Scrollable),
          )
          .first,
    );
  }

  ScrollPosition positionIn(WidgetTester tester, Key key) =>
      scrollableIn(tester, key).position;

  void expectPicked(WidgetTester tester, Key key) {
    expect(
      runtime.scrollable,
      same(scrollableIn(tester, key)),
      reason: 'the crown should drive $key',
    );
  }

  void expectNothingPicked() {
    expect(runtime.scrollable, isNull);
    expect(host.description, isNull);
  }

  /// More of the turn in progress: one move per display refresh (phase 1).
  Future<void> more(WidgetTester tester, List<double> moves) async {
    for (final double delta in moves) {
      host.moveBy(delta);
      host.report(1);
      await tester.pump(kFrame);
    }
  }

  /// A crown turn's start (phase 2) and its moves, without its rest.
  Future<void> turn(WidgetTester tester, List<double> moves) async {
    host.report(2);
    await more(tester, moves);
  }

  /// The turn's rest (phase 0), inside the native view's range, and
  /// whatever the scrollable does then (a snap).
  Future<void> rest(WidgetTester tester) async {
    host.spring();
    host.report(0);
    await tester.pumpAndSettle();
  }

  /// A turn by [moves] that [position] must follow one to one: the same
  /// way in the host's pixels, or the other way for a reversed list.
  Future<void> turnFollowed(
    WidgetTester tester,
    ScrollPosition position,
    List<double> moves, {
    bool reversed = false,
  }) async {
    final double from = position.pixels;
    double moved = 0;
    host.report(2);
    for (final double delta in moves) {
      host.moveBy(delta);
      host.report(1);
      await tester.pump(kFrame);
      moved += delta;
      expect(
        position.pixels,
        moreOrLessEquals(from + (reversed ? -moved : moved), epsilon: 0.01),
        reason: 'after a turn of $moved',
      );
    }
  }

  void expectAtRest(ScrollPosition position) {
    expect(position.isScrollingNotifier.value, isFalse);
    expect(
      position.pixels,
      inInclusiveRange(position.minScrollExtent, position.maxScrollExtent),
    );
  }

  // ---------------------------------------------------------------------
  group('1. ListView', () {
    testWidgets('baseline: picked, described, followed, rests in place', (
      WidgetTester tester,
    ) async {
      const Key list = Key('list');
      await start(
        tester,
        MaterialApp(
          home: ListView(key: list, children: rows(40)),
        ),
      );
      expectPicked(tester, list);
      expect(
        host.description,
        describes(viewport: kHeight, max: 40 * 44 - kHeight, row: 44),
      );
      final ScrollPosition position = positionIn(tester, list);
      await turnFollowed(tester, position, <double>[50, 50, 50]);
      await rest(tester);
      expect(position.pixels, 150);
      expectAtRest(position);
      // Past the end the content follows the native spring; it rests at
      // the end.
      await turnFollowed(tester, position, <double>[1400, 60]);
      expect(position.pixels, 1610);
      await rest(tester);
      expect(position.pixels, 40 * 44 - kHeight);
      expectAtRest(position);
    }, variant: ios);

    testWidgets('the list shrinking under a turn ends inside the new range', (
      WidgetTester tester,
    ) async {
      const Key list = Key('list');
      int count = 40;
      late StateSetter setCount;
      await start(
        tester,
        MaterialApp(
          home: StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) {
              setCount = setState;
              return ListView(key: list, children: rows(count));
            },
          ),
        ),
      );
      final ScrollPosition position = positionIn(tester, list);
      await turnFollowed(tester, position, <double>[500, 500]);
      setCount(() => count = 20);
      await tester.pump(kFrame);
      expect(
        host.description,
        describes(viewport: kHeight, max: 20 * 44 - kHeight),
      );
      // The native view is past its new end; the content stays with it.
      await more(tester, <double>[10]);
      expect(position.pixels, 1010);
      await rest(tester);
      expect(position.pixels, 20 * 44 - kHeight);
      expectAtRest(position);
    }, variant: ios);

    testWidgets(
      'builder, 1000 rows, no itemExtent: the estimate grows under a turn',
      (WidgetTester tester) async {
        const Key list = Key('list');
        // Rows of 30 first, then 60: the first estimate is 1000 rows of 30.
        await start(
          tester,
          MaterialApp(
            home: ListView.builder(
              key: list,
              itemCount: 1000,
              itemBuilder: (BuildContext context, int i) =>
                  SizedBox(height: i < 100 ? 30 : 60, child: Text('Row $i')),
            ),
          ),
        );
        expectPicked(tester, list);
        const double exact = 100 * 30 + 900 * 60 - kHeight;
        expect(
          host.description,
          describes(viewport: kHeight, max: 1000 * 30 - kHeight, row: 30),
        );
        final ScrollPosition position = positionIn(tester, list);
        final int before = host.configured.length;
        await turnFollowed(tester, position, <double>[1000, 1000, 1000, 1000]);
        // Described again mid-turn as the estimate grew, without a sync
        // (the native view keeps the turn), and exact once the 60 rows
        // are laid out.
        expect(host.configured.length, greaterThan(before));
        expect(
          host.description,
          describes(viewport: kHeight, max: exact, row: 60),
        );
        expect(host.synced.where(((double, bool) s) => s.$1 > 0), isEmpty);
        await rest(tester);
        expect(position.pixels, 4000);
        expectAtRest(position);
      },
      variant: ios,
    );
  });

  // ---------------------------------------------------------------------
  group('2. ListView.builder without itemCount (endless)', () {
    testWidgets('a window around the content, moved only at rest', (
      WidgetTester tester,
    ) async {
      const Key list = Key('list');
      await start(
        tester,
        MaterialApp(
          home: ListView.builder(
            key: list,
            itemBuilder: (BuildContext context, int i) =>
                SizedBox(height: 44, child: Text('Row $i')),
          ),
        ),
      );
      expectPicked(tester, list);
      expect(
        host.description,
        describes(viewport: kHeight, max: 100000, row: 44),
      );
      final ScrollPosition position = positionIn(tester, list);
      expect(position.maxScrollExtent, double.infinity);
      await turnFollowed(tester, position, <double>[2000, 2000, 2000]);
      await rest(tester);
      expect(position.pixels, 6000);
      // Far into the window: it stays put while the crown turns, and is
      // centred on the content once it rests.
      await turnFollowed(tester, position, <double>[27000, 27000]);
      expect(host.description!.maxExtent, 100000);
      await rest(tester);
      expect(position.pixels, 60000);
      expect(
        host.description,
        describes(viewport: kHeight, max: 160000, row: 44),
      );
      await turnFollowed(tester, position, <double>[100]);
      await rest(tester);
      expect(position.pixels, 60100);
    }, variant: ios);
  });

  // ---------------------------------------------------------------------
  group('3. SingleChildScrollView + Column', () {
    testWidgets('short (fits): nothing to scroll, the crown drives nothing', (
      WidgetTester tester,
    ) async {
      const Key page = Key('page');
      await start(
        tester,
        MaterialApp(
          home: SingleChildScrollView(
            key: page,
            child: Column(children: rows(3)),
          ),
        ),
      );
      expectNothingPicked();
      await turn(tester, <double>[40, 40]);
      await rest(tester);
      expect(positionIn(tester, page).pixels, 0);
    }, variant: ios);

    testWidgets('long: picked, followed, and grows under a turn', (
      WidgetTester tester,
    ) async {
      const Key page = Key('page');
      int count = 30;
      late StateSetter setCount;
      await start(
        tester,
        MaterialApp(
          home: StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) {
              setCount = setState;
              return SingleChildScrollView(
                key: page,
                child: Column(children: rows(count, height: 60)),
              );
            },
          ),
        ),
      );
      expectPicked(tester, page);
      // CAVEAT: a SingleChildScrollView has no rows the runtime can measure;
      // the native view gets 44 for its rows of 60 (detents only).
      expect(
        host.description,
        describes(viewport: kHeight, max: 30 * 60 - kHeight, row: 44),
      );
      final ScrollPosition position = positionIn(tester, page);
      await turnFollowed(tester, position, <double>[100, 100, 100]);
      setCount(() => count = 40);
      await tester.pump(kFrame);
      expect(
        host.description,
        describes(viewport: kHeight, max: 40 * 60 - kHeight),
      );
      // Beyond the old end, the turn goes on one to one.
      await more(tester, <double>[1300, 100]);
      expect(position.pixels, 1700);
      await rest(tester);
      expect(position.pixels, 1700);
      expectAtRest(position);
    }, variant: ios);

    testWidgets('short with AlwaysScrollableScrollPhysics: an empty range', (
      WidgetTester tester,
    ) async {
      const Key page = Key('page');
      await start(
        tester,
        MaterialApp(
          home: SingleChildScrollView(
            key: page,
            physics: const AlwaysScrollableScrollPhysics(),
            child: Column(children: rows(3)),
          ),
        ),
      );
      // Picked like a short ListView: the crown stretches it and the
      // native spring brings it back.
      expectPicked(tester, page);
      expect(host.description, describes(viewport: kHeight, max: 0, row: 44));
      final ScrollPosition position = positionIn(tester, page);
      await turnFollowed(tester, position, <double>[20, 20]);
      await rest(tester);
      expect(position.pixels, 0);
    }, variant: ios);

    testWidgets('reverse: true: mirrored like a chat', (
      WidgetTester tester,
    ) async {
      const Key page = Key('page');
      await start(
        tester,
        MaterialApp(
          home: SingleChildScrollView(
            key: page,
            reverse: true,
            child: Column(children: rows(30)),
          ),
        ),
      );
      expectPicked(tester, page);
      const double max = 30 * 44 - kHeight;
      expect(host.description, describes(viewport: kHeight, max: max));
      expect(host.pixels, max);
      final ScrollPosition position = positionIn(tester, page);
      await turnFollowed(tester, position, <double>[-100, -20], reversed: true);
      await rest(tester);
      expect(position.pixels, 120);
    }, variant: ios);

    testWidgets('fill-or-scroll (ConstrainedBox to the viewport, short)', (
      WidgetTester tester,
    ) async {
      const Key page = Key('page');
      await start(
        tester,
        MaterialApp(
          home: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) =>
                SingleChildScrollView(
                  key: page,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: rows(3),
                    ),
                  ),
                ),
          ),
        ),
      );
      // Exactly one screen: nothing to scroll.
      expectNothingPicked();
    }, variant: ios);
  });

  // ---------------------------------------------------------------------
  group('4. CustomScrollView with slivers', () {
    testWidgets(
      'pinned app bar, header, list, grid: picked, described, followed',
      (WidgetTester tester) async {
        const Key view = Key('view');
        await start(
          tester,
          MaterialApp(
            home: CustomScrollView(
              key: view,
              slivers: <Widget>[
                const SliverAppBar(
                  pinned: true,
                  expandedHeight: 100,
                  title: Text('Pinned'),
                ),
                const SliverPersistentHeader(delegate: _Header(40)),
                SliverList.list(children: rows(20)),
                SliverGrid.count(
                  crossAxisCount: 2,
                  children: rows(10, name: 'Tile'),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 60)),
              ],
            ),
          ),
        );
        expectPicked(tester, view);
        // 100 (app bar) + 40 (header) + 20 x 44 + 5 x 104 (grid) + 60.
        const double max = 100 + 40 + 20 * 44 + 5 * 104 + 60 - kHeight;
        expect(
          host.description,
          describes(viewport: kHeight, max: max, row: 44),
        );
        final ScrollPosition position = positionIn(tester, view);
        await turnFollowed(tester, position, <double>[100, 100, 100]);
        // The pinned bar stays, collapsed.
        expect(
          tester.getRect(find.byType(AppBar)),
          const Rect.fromLTWH(0, 0, kWidth, kToolbarHeight),
        );
        // Into the grid and to the end.
        await more(tester, <double>[900, max - 1200]);
        expect(position.pixels, max);
        await rest(tester);
        expect(position.pixels, max);
        expectAtRest(position);
      },
      variant: ios,
    );

    testWidgets('a floating, snapping app bar comes back with the crown', (
      WidgetTester tester,
    ) async {
      const Key view = Key('view');
      await start(
        tester,
        MaterialApp(
          home: CustomScrollView(
            key: view,
            slivers: <Widget>[
              const SliverAppBar(
                floating: true,
                snap: true,
                title: Text('Float'),
              ),
              SliverList.list(children: rows(30)),
            ],
          ),
        ),
      );
      expectPicked(tester, view);
      expect(
        host.description,
        describes(viewport: kHeight, max: kToolbarHeight + 30 * 44 - kHeight),
      );
      final ScrollPosition position = positionIn(tester, view);
      await turnFollowed(tester, position, <double>[100, 100, 100]);
      await rest(tester);
      final Finder bar = find.byType(AppBar, skipOffstage: false);
      expect(tester.getRect(bar).bottom, lessThanOrEqualTo(0));
      // Turning back up floats it in as far as the content moved...
      await turnFollowed(tester, position, <double>[-20]);
      expect(tester.getRect(bar).bottom, moreOrLessEquals(20));
      // ...and the rest snaps it open, as after a drag.
      await rest(tester);
      expect(tester.getRect(bar).bottom, moreOrLessEquals(kToolbarHeight));
      expect(position.pixels, 280);
    }, variant: ios);

    testWidgets('a group with a pinned header, fixed rows, fill remaining', (
      WidgetTester tester,
    ) async {
      const Key view = Key('view');
      await start(
        tester,
        MaterialApp(
          home: CustomScrollView(
            key: view,
            slivers: <Widget>[
              SliverMainAxisGroup(
                slivers: <Widget>[
                  const PinnedHeaderSliver(
                    child: SizedBox(height: 30, child: Text('Group')),
                  ),
                  SliverFixedExtentList.list(
                    itemExtent: 50,
                    children: rows(10, height: 50),
                  ),
                ],
              ),
              const SliverFillRemaining(
                hasScrollBody: false,
                child: SizedBox(height: 40, child: Text('End')),
              ),
            ],
          ),
        ),
      );
      expectPicked(tester, view);
      // 30 + 10 x 50 + 40; rows exactly the fixed extent.
      const double max = 30 + 10 * 50 + 40 - kHeight;
      expect(host.description, describes(viewport: kHeight, max: max, row: 50));
      final ScrollPosition position = positionIn(tester, view);
      await turnFollowed(tester, position, <double>[100, 100]);
      // The group's header stays pinned.
      expect(tester.getTopLeft(find.text('Group')).dy, 0);
      await more(tester, <double>[max - 200]);
      await rest(tester);
      expect(position.pixels, max);
      expectAtRest(position);
    }, variant: ios);
  });

  // ---------------------------------------------------------------------
  group('5. GridView', () {
    testWidgets('picked, followed; row pitch from the tiles', (
      WidgetTester tester,
    ) async {
      const Key grid = Key('grid');
      await start(
        tester,
        MaterialApp(
          home: GridView.count(
            key: grid,
            crossAxisCount: 2,
            mainAxisSpacing: 8,
            children: rows(30, name: 'Tile'),
          ),
        ),
      );
      expectPicked(tester, grid);
      // 15 rows of 104 with 14 gaps of 8. CAVEAT: the row pitch is the
      // tile's height (104), not tile plus spacing (112).
      const double max = 15 * 104 + 14 * 8 - kHeight;
      expect(
        host.description,
        describes(viewport: kHeight, max: max, row: 104),
      );
      final ScrollPosition position = positionIn(tester, grid);
      await turnFollowed(tester, position, <double>[112, 112, 112]);
      await rest(tester);
      expect(position.pixels, 336);
      expectAtRest(position);
    }, variant: ios);
  });

  // ---------------------------------------------------------------------
  Widget nestedScrollView() {
    return MaterialApp(
      home: NestedScrollView(
        key: const Key('nested'),
        headerSliverBuilder: (BuildContext context, bool innerScrolled) =>
            const <Widget>[
              SliverAppBar(
                pinned: true,
                expandedHeight: 100,
                title: Text('Nested'),
              ),
            ],
        body: ListView.builder(
          key: const Key('body'),
          itemExtent: 44,
          itemCount: 40,
          itemBuilder: (BuildContext context, int i) => Text('Row $i'),
        ),
      ),
    );
  }

  group('6. NestedScrollView', () {
    testWidgets('today: the runtime keeps out of it, nothing is held', (
      WidgetTester tester,
    ) async {
      await start(tester, nestedScrollView());
      // Its positions are not ScrollPositionWithSingleContext.
      expectNothingPicked();
      await turn(tester, <double>[50, 50]);
      await rest(tester);
      expect(positionIn(tester, const Key('nested')).pixels, 0);
      expect(positionIn(tester, const Key('body')).pixels, 0);
    }, variant: ios);
  });

  group(
    '6. NestedScrollView',
    () {
      testWidgets('the crown collapses the header, then scrolls the body', (
        WidgetTester tester,
      ) async {
        await start(tester, nestedScrollView());
        expect(runtime.scrollable, isNotNull);
        expect(host.description, isNotNull);
        final ScrollPosition outer = positionIn(tester, const Key('nested'));
        final ScrollPosition inner = positionIn(tester, const Key('body'));
        host.report(2);
        await more(tester, <double>[50, 50]);
        await rest(tester);
        // The header collapses by 44 (100 to the toolbar's 56); the body
        // takes the rest of the turn.
        expect(outer.pixels, 100 - kToolbarHeight);
        expect(inner.pixels, 100 - (100 - kToolbarHeight));
      }, variant: ios);
    },
    skip:
        'BROKEN: _visibleArea rejects every position that is not a '
        'ScrollPositionWithSingleContext, and both of a NestedScrollView\'s '
        'positions are _NestedScrollPosition: the crown drives nothing',
  );

  // ---------------------------------------------------------------------
  group('7. ListWheelScrollView', () {
    testWidgets('default physics: followed, rests where the turn ends', (
      WidgetTester tester,
    ) async {
      const Key wheel = Key('wheel');
      await start(
        tester,
        MaterialApp(
          home: ListWheelScrollView(
            key: wheel,
            itemExtent: 40,
            children: rows(20, height: 40),
          ),
        ),
      );
      expectPicked(tester, wheel);
      expect(
        host.description,
        describes(viewport: kHeight, max: 19 * 40, row: 40),
      );
      final ScrollPosition position = positionIn(tester, wheel);
      await turnFollowed(tester, position, <double>[30, 40]);
      await rest(tester);
      // Without FixedExtentScrollPhysics a wheel does not snap, under a
      // finger either.
      expect(position.pixels, 70);
      expectAtRest(position);
    }, variant: ios);

    testWidgets('FixedExtentScrollPhysics: the rest snaps to an item', (
      WidgetTester tester,
    ) async {
      const Key wheel = Key('wheel');
      await start(
        tester,
        MaterialApp(
          home: ListWheelScrollView(
            key: wheel,
            itemExtent: 40,
            physics: const FixedExtentScrollPhysics(),
            children: rows(20, height: 40),
          ),
        ),
      );
      expectPicked(tester, wheel);
      final ScrollPosition position = positionIn(tester, wheel);
      await turnFollowed(tester, position, <double>[30, 40]);
      await rest(tester);
      // Within the physics' tolerance (half a pixel at 2x), as after a
      // finger.
      expect(position.pixels, moreOrLessEquals(80, epsilon: 0.5));
      expect((position as FixedExtentMetrics).itemIndex, 2);
      // The native view is brought to the item.
      expect(host.synced.last.$1, position.pixels);
      expect(host.synced.last.$2, isFalse);
      expectAtRest(position);
    }, variant: ios);

    testWidgets('.useDelegate, looping: a window both ways, snaps', (
      WidgetTester tester,
    ) async {
      const Key wheel = Key('wheel');
      await start(
        tester,
        MaterialApp(
          home: ListWheelScrollView.useDelegate(
            key: wheel,
            itemExtent: 40,
            physics: const FixedExtentScrollPhysics(),
            childDelegate: ListWheelChildLoopingListDelegate(
              children: rows(10, height: 40),
            ),
          ),
        ),
      );
      expectPicked(tester, wheel);
      expect(
        host.description,
        describes(viewport: kHeight, min: -100000, max: 100000, row: 40),
      );
      final ScrollPosition position = positionIn(tester, wheel);
      // Up past the first item, which loops.
      await turnFollowed(tester, position, <double>[-60, -50]);
      await rest(tester);
      expect(position.pixels, moreOrLessEquals(-120, epsilon: 0.5));
      expect(host.synced.last.$1, position.pixels);
    }, variant: ios);
  });

  // ---------------------------------------------------------------------
  group('8. vertical PageView', () {
    testWidgets('followed, and the rest snaps to a page', (
      WidgetTester tester,
    ) async {
      const Key pages = Key('pages');
      await start(
        tester,
        MaterialApp(
          home: PageView(
            key: pages,
            scrollDirection: Axis.vertical,
            children: List<Widget>.generate(
              5,
              (int i) => Center(child: Text('Page $i')),
            ),
          ),
        ),
      );
      expectPicked(tester, pages);
      expect(
        host.description,
        describes(viewport: kHeight, max: 4 * kHeight, row: kHeight),
      );
      final ScrollPosition position = positionIn(tester, pages);
      await turnFollowed(tester, position, <double>[100, 30]);
      await rest(tester);
      expect(position.pixels, moreOrLessEquals(kHeight, epsilon: 0.01));
      expect(host.synced.last.$1, moreOrLessEquals(kHeight, epsilon: 0.01));
      // Less than half a page back: it snaps back.
      await turnFollowed(tester, position, <double>[-60]);
      await rest(tester);
      expect(position.pixels, moreOrLessEquals(kHeight, epsilon: 0.01));
    }, variant: ios);
  });

  // ---------------------------------------------------------------------
  group('9. two ListViews side by side', () {
    Widget sideBySide({int left = 1, int right = 1, bool markLeft = false}) {
      final Widget leftList = ListView(
        key: const Key('left'),
        children: rows(40, name: 'L'),
      );
      return MaterialApp(
        home: Row(
          children: <Widget>[
            Expanded(flex: left, child: markLeft ? mark(leftList) : leftList),
            Expanded(
              flex: right,
              child: ListView(
                key: const Key('right'),
                children: rows(20, name: 'R'),
              ),
            ),
          ],
        ),
      );
    }

    testWidgets('50/50: the frontmost (the right one) takes the crown', (
      WidgetTester tester,
    ) async {
      await start(tester, sideBySide());
      // CAVEAT: both cover 50%; the later one in paint order wins.
      expectPicked(tester, const Key('right'));
      expect(
        host.description,
        describes(viewport: kHeight, max: 20 * 44 - kHeight, row: 44),
      );
      final ScrollPosition right = positionIn(tester, const Key('right'));
      await turnFollowed(tester, right, <double>[50, 50]);
      await rest(tester);
      expect(right.pixels, 100);
      expect(positionIn(tester, const Key('left')).pixels, 0);
    }, variant: ios);

    testWidgets('50/50 with WatchCrownScroll on the left one', (
      WidgetTester tester,
    ) async {
      await start(tester, sideBySide(markLeft: true));
      expectPicked(tester, const Key('left'));
      final ScrollPosition left = positionIn(tester, const Key('left'));
      await turnFollowed(tester, left, <double>[50, 50]);
      await rest(tester);
      expect(left.pixels, 100);
      expect(positionIn(tester, const Key('right')).pixels, 0);
    }, variant: ios);

    testWidgets('70/30: the larger one takes the crown', (
      WidgetTester tester,
    ) async {
      await start(tester, sideBySide(left: 7, right: 3));
      expectPicked(tester, const Key('left'));
      expect(
        host.description,
        describes(viewport: kHeight, max: 40 * 44 - kHeight, row: 44),
      );
      final ScrollPosition left = positionIn(tester, const Key('left'));
      await turnFollowed(tester, left, <double>[50, 50]);
      await rest(tester);
      expect(left.pixels, 100);
      expect(positionIn(tester, const Key('right')).pixels, 0);
    }, variant: ios);
  });

  // ---------------------------------------------------------------------
  Widget carousel() => SizedBox(
    height: 100,
    child: ListView(
      key: const Key('carousel'),
      scrollDirection: Axis.horizontal,
      children: List<Widget>.generate(
        10,
        (int i) => SizedBox(width: 80, child: Text('C $i')),
      ),
    ),
  );

  group('10. a horizontal ListView inside a vertical ListView', () {
    testWidgets('the vertical list takes the crown, the carousel stays', (
      WidgetTester tester,
    ) async {
      const Key outer = Key('outer');
      await start(
        tester,
        MaterialApp(
          home: ListView(
            key: outer,
            children: <Widget>[carousel(), ...rows(30)],
          ),
        ),
      );
      expectPicked(tester, outer);
      final ScrollPosition position = positionIn(tester, outer);
      // Rows of two heights: the extent is the list's estimate until the
      // end is laid out.
      expect(
        host.description,
        describes(viewport: kHeight, max: position.maxScrollExtent, row: 44),
      );
      final ScrollPosition carouselPosition = positionIn(
        tester,
        const Key('carousel'),
      );
      await turnFollowed(tester, position, <double>[60, 60]);
      await rest(tester);
      expect(position.pixels, 120);
      expect(carouselPosition.pixels, 0);
      // To the end, where the extent is exact.
      await turnFollowed(tester, position, <double>[1052]);
      expect(
        host.description,
        describes(viewport: kHeight, max: 100 + 30 * 44 - kHeight, row: 44),
      );
      await rest(tester);
      expect(position.pixels, 100 + 30 * 44 - kHeight);
    }, variant: ios);
  });

  group(
    '10. a horizontal ListView inside a vertical ListView',
    () {
      testWidgets('a carousel first in a CustomScrollView: rows of the list', (
        WidgetTester tester,
      ) async {
        const Key outer = Key('outer');
        await start(
          tester,
          MaterialApp(
            home: CustomScrollView(
              key: outer,
              slivers: <Widget>[
                SliverToBoxAdapter(child: carousel()),
                SliverList.list(children: rows(30)),
              ],
            ),
          ),
        );
        expectPicked(tester, outer);
        expect(
          host.description,
          describes(viewport: kHeight, max: 100 + 30 * 44 - kHeight, row: 44),
        );
      }, variant: ios);
    },
    skip:
        'BROKEN: _rowExtent takes the first RenderSliverMultiBoxAdaptor '
        'anywhere under the scrollable, here the horizontal carousel inside '
        'a SliverToBoxAdapter: the row pitch is its tiles\' height (100), '
        'not the vertical list\'s 44 (detent haptics only)',
  );

  // ---------------------------------------------------------------------
  /// A chat: a reversed list of [count] messages, the newest at the bottom.
  Widget chat(int Function() count, void Function(StateSetter) onSetState) {
    return MaterialApp(
      home: StatefulBuilder(
        builder: (BuildContext context, StateSetter setState) {
          onSetState(setState);
          return ListView.builder(
            key: const Key('chat'),
            reverse: true,
            itemCount: count(),
            itemBuilder: (BuildContext context, int i) =>
                SizedBox(height: 44, child: Text('Message $i')),
          );
        },
      ),
    );
  }

  group('11. reverse: true ListView (chat)', () {
    testWidgets('mirrored, followed the right way, rests in place', (
      WidgetTester tester,
    ) async {
      int count = 40;
      late StateSetter setCount;
      await start(tester, chat(() => count, (StateSetter s) => setCount = s));
      expectPicked(tester, const Key('chat'));
      const double max = 40 * 44 - kHeight;
      expect(host.description, describes(viewport: kHeight, max: max, row: 44));
      // The native view starts at its end, where the newest message is.
      expect(host.pixels, max);
      final ScrollPosition position = positionIn(tester, const Key('chat'));
      await turnFollowed(tester, position, <double>[-100, -50], reversed: true);
      await rest(tester);
      expect(position.pixels, 150);
      expectAtRest(position);
      // Up to the oldest message, where older ones are loaded at rest: the
      // native view is moved so it still mirrors the content.
      await turnFollowed(tester, position, <double>[
        -(max - 150),
      ], reversed: true);
      await rest(tester);
      expect(position.pixels, max);
      expect(host.pixels, 0);
      setCount(() => count = 50);
      await tester.pump(kFrame);
      expect(
        host.description,
        describes(viewport: kHeight, max: 50 * 44 - kHeight),
      );
      expect(host.pixels, 50 * 44 - kHeight - max);
      expect(position.pixels, max);
      await turnFollowed(tester, position, <double>[-10, -10], reversed: true);
      expect(position.pixels, max + 20);
    }, variant: ios);
  });

  group(
    '11. reverse: true ListView (chat)',
    () {
      testWidgets('older messages arriving under a turn do not jump', (
        WidgetTester tester,
      ) async {
        int count = 40;
        late StateSetter setCount;
        await start(tester, chat(() => count, (StateSetter s) => setCount = s));
        final ScrollPosition position = positionIn(tester, const Key('chat'));
        await turnFollowed(tester, position, <double>[
          -100,
          -50,
        ], reversed: true);
        setCount(() => count = 50);
        await tester.pump(kFrame);
        // The turn goes on from where the content is.
        await more(tester, <double>[-10]);
        expect(position.pixels, 160);
        await rest(tester);
        expect(position.pixels, 160);
      }, variant: ios);

      testWidgets('older messages loaded at rest mid-list do not jump at '
          'the next turn', (WidgetTester tester) async {
        int count = 40;
        late StateSetter setCount;
        await start(tester, chat(() => count, (StateSetter s) => setCount = s));
        final ScrollPosition position = positionIn(tester, const Key('chat'));
        await turnFollowed(tester, position, <double>[
          -100,
          -50,
        ], reversed: true);
        await rest(tester);
        // Nothing laid out changes, so Flutter does not lay the list out
        // for the new count: its extent, and the native view, stay as they
        // were until something scrolls it.
        setCount(() => count = 50);
        await tester.pump(kFrame);
        expect(position.maxScrollExtent, 40 * 44 - kHeight);
        // The next turn's first move lays it out, so max grows mid-turn.
        await turnFollowed(tester, position, <double>[
          -10,
          -10,
        ], reversed: true);
        expect(position.pixels, 170);
      }, variant: ios);
    },
    skip:
        'BROKEN: a reversed list is mirrored through min + max of the '
        'current description; when max grows mid-turn (older messages '
        'loaded, or laid out for the first time by the turn) the native '
        'view keeps its offset, so the content jumps by the growth (to 600, '
        'not 160)',
  );

  // ---------------------------------------------------------------------
  Widget nestedShrinkWrap({required bool neverScrollable}) {
    return MaterialApp(
      home: SingleChildScrollView(
        key: const Key('outer'),
        child: Column(
          children: <Widget>[
            const SizedBox(height: 60, child: Text('Header')),
            ListView(
              key: const Key('inner'),
              shrinkWrap: true,
              physics: neverScrollable
                  ? const NeverScrollableScrollPhysics()
                  : null,
              children: rows(30),
            ),
          ],
        ),
      ),
    );
  }

  group('12. a shrinkWrap ListView inside a SingleChildScrollView', () {
    testWidgets('inner NeverScrollableScrollPhysics: the outer is driven', (
      WidgetTester tester,
    ) async {
      await start(tester, nestedShrinkWrap(neverScrollable: true));
      expectPicked(tester, const Key('outer'));
      expect(
        host.description,
        describes(viewport: kHeight, max: 60 + 30 * 44 - kHeight, row: 44),
      );
      final ScrollPosition outer = positionIn(tester, const Key('outer'));
      await turnFollowed(tester, outer, <double>[100, 100]);
      await rest(tester);
      expect(outer.pixels, 200);
      expectAtRest(outer);
    }, variant: ios);
  });

  group(
    '12. a shrinkWrap ListView inside a SingleChildScrollView',
    () {
      testWidgets('inner default physics: the outer is still driven', (
        WidgetTester tester,
      ) async {
        await start(tester, nestedShrinkWrap(neverScrollable: false));
        expectPicked(tester, const Key('outer'));
        final ScrollPosition outer = positionIn(tester, const Key('outer'));
        await turnFollowed(tester, outer, <double>[100, 100]);
        await rest(tester);
        expect(outer.pixels, 200);
      }, variant: ios);
    },
    skip:
        'BROKEN: the inner list (AlwaysScrollableScrollPhysics, range 0) '
        'is the frontmost scrollable covering 40%, so it takes the crown: a '
        'turn only stretches it and the page never moves (a finger has the '
        'same Flutter gotcha)',
  );

  // ---------------------------------------------------------------------
  group('13. RefreshIndicator over a ListView', () {
    testWidgets('the list is driven; the crown never pulls to refresh', (
      WidgetTester tester,
    ) async {
      const Key list = Key('list');
      int refreshed = 0;
      await start(
        tester,
        MaterialApp(
          home: RefreshIndicator(
            onRefresh: () async => refreshed++,
            child: ListView(key: list, children: rows(40)),
          ),
        ),
      );
      expectPicked(tester, list);
      expect(
        host.description,
        describes(viewport: kHeight, max: 40 * 44 - kHeight, row: 44),
      );
      final ScrollPosition position = positionIn(tester, list);
      // Up past the top, into the native spring.
      await turnFollowed(tester, position, <double>[-40, -40]);
      expect(position.pixels, -80);
      await rest(tester);
      expect(position.pixels, 0);
      expect(refreshed, 0);
      expect(find.byType(RefreshProgressIndicator), findsNothing);
      await turnFollowed(tester, position, <double>[100]);
      await rest(tester);
      expect(position.pixels, 100);
    }, variant: ios);
  });

  // ---------------------------------------------------------------------
  group('14. DraggableScrollableSheet', () {
    testWidgets('the sheet\'s list is driven; the sheet keeps its size', (
      WidgetTester tester,
    ) async {
      const Key list = Key('list');
      final DraggableScrollableController sheet =
          DraggableScrollableController();
      addTearDown(sheet.dispose);
      await start(
        tester,
        MaterialApp(
          home: Stack(
            children: <Widget>[
              const Positioned.fill(child: ColoredBox(color: Colors.black)),
              DraggableScrollableSheet(
                controller: sheet,
                minChildSize: 0.25,
                builder: (BuildContext context, ScrollController controller) =>
                    ColoredBox(
                      color: Colors.white,
                      child: ListView.builder(
                        key: list,
                        controller: controller,
                        itemExtent: 44,
                        itemCount: 30,
                        itemBuilder: (BuildContext context, int i) =>
                            Text('Row $i'),
                      ),
                    ),
              ),
            ],
          ),
        ),
      );
      expectPicked(tester, list);
      const double half = kHeight / 2;
      expect(
        host.description,
        describes(viewport: half, max: 30 * 44 - half, row: 44),
      );
      final ScrollPosition position = positionIn(tester, list);
      await turnFollowed(tester, position, <double>[50, 50]);
      await rest(tester);
      expect(position.pixels, 100);
      // CAVEAT: a finger dragging up grows the sheet before it scrolls the
      // list; the crown scrolls the list inside the half-open sheet.
      expect(sheet.size, moreOrLessEquals(0.5));
      // The app opens the sheet: the native view takes its new shape.
      sheet.jumpTo(1);
      await tester.pumpAndSettle();
      expect(
        host.description,
        describes(viewport: kHeight, max: 30 * 44 - kHeight, row: 44),
      );
      await turnFollowed(tester, position, <double>[50]);
      await rest(tester);
      expect(position.pixels, 150);
    }, variant: ios);
  });

  // ---------------------------------------------------------------------
  group('15. Scrollbar and CupertinoScrollbar around a ListView', () {
    for (final bool cupertino in <bool>[false, true]) {
      testWidgets(
        '${cupertino ? 'CupertinoScrollbar' : 'Scrollbar'}: the list is '
        'driven and the Flutter thumb shows too',
        (WidgetTester tester) async {
          const Key list = Key('list');
          final Widget child = ListView(key: list, children: rows(40));
          await start(
            tester,
            MaterialApp(
              home: cupertino
                  ? CupertinoScrollbar(child: child)
                  : Scrollbar(child: child),
            ),
          );
          expectPicked(tester, list);
          // The native indicator stays on.
          expect(
            host.description,
            describes(
              viewport: kHeight,
              max: 40 * 44 - kHeight,
              row: 44,
              indicator: true,
            ),
          );
          final Finder scrollbar = find.byType(CupertinoScrollbar);
          expect(scrollbar, isNot(paints..rrect()));
          final ScrollPosition position = positionIn(tester, list);
          await turnFollowed(tester, position, <double>[50, 50]);
          await tester.pump(const Duration(milliseconds: 300));
          // CAVEAT: two scroll indicators while the crown turns, watchOS's
          // and Flutter's.
          expect(scrollbar, paints..rrect());
          await rest(tester);
          expect(position.pixels, 100);
        },
        variant: ios,
      );
    }
  });

  // ---------------------------------------------------------------------
  Widget tabs() {
    return MaterialApp(
      home: DefaultTabController(
        length: 2,
        child: Material(
          child: Column(
            children: <Widget>[
              const TabBar(
                tabs: <Widget>[
                  Tab(text: 'A'),
                  Tab(text: 'B'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: <Widget>[
                    ListView(key: const Key('a'), children: rows(40)),
                    ListView(key: const Key('b'), children: rows(20)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void showTab(WidgetTester tester, int index) {
    DefaultTabController.of(
      tester.element(find.byType(TabBarView)),
    ).animateTo(index);
  }

  group('16. TabBarView with a ListView per tab', () {
    testWidgets('the shown tab\'s list is driven, and the next one\'s', (
      WidgetTester tester,
    ) async {
      await start(tester, tabs());
      expectPicked(tester, const Key('a'));
      final ScrollPosition a = positionIn(tester, const Key('a'));
      final double viewport = a.viewportDimension;
      expect(viewport, lessThan(kHeight));
      expect(
        host.description,
        describes(viewport: viewport, max: 40 * 44 - viewport, row: 44),
      );
      await turnFollowed(tester, a, <double>[50, 50]);
      await rest(tester);
      expect(a.pixels, 100);

      showTab(tester, 1);
      await tester.pumpAndSettle();
      expectPicked(tester, const Key('b'));
      expect(
        host.description,
        describes(viewport: viewport, max: 20 * 44 - viewport, row: 44),
      );
      final ScrollPosition b = positionIn(tester, const Key('b'));
      await turnFollowed(tester, b, <double>[30]);
      await rest(tester);
      expect(b.pixels, 30);
    }, variant: ios);

    testWidgets('a tab switch mid-turn hands the crown to the new tab', (
      WidgetTester tester,
    ) async {
      await start(tester, tabs());
      final ScrollPosition a = positionIn(tester, const Key('a'));
      await turnFollowed(tester, a, <double>[50, 50]);
      showTab(tester, 1);
      // The old tab slides out with the turn still on it; once it is gone
      // the new tab's list is described and the native view stopped on it.
      await tester.pumpAndSettle();
      expectPicked(tester, const Key('b'));
      final ScrollPosition b = positionIn(tester, const Key('b'));
      expect(host.synced.last, (0.0, true));
      expect(b.pixels, 0);
      // The host ends the stopped turn; the next one drives the new tab.
      await rest(tester);
      expect(b.pixels, 0);
      await turnFollowed(tester, b, <double>[30]);
      await rest(tester);
      expect(b.pixels, 30);
    }, variant: ios);
  });

  // ---------------------------------------------------------------------
  group('17. content that grows while scrolling', () {
    testWidgets('load more at the end: the turn runs on into the new rows', (
      WidgetTester tester,
    ) async {
      const Key list = Key('list');
      int count = 20;
      await start(
        tester,
        MaterialApp(
          home: StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) {
              return NotificationListener<ScrollUpdateNotification>(
                onNotification: (ScrollUpdateNotification n) {
                  if (n.metrics.extentAfter < 100 && count < 100) {
                    setState(() => count += 20);
                  }
                  return false;
                },
                child: ListView.builder(
                  key: list,
                  itemExtent: 44,
                  itemCount: count,
                  itemBuilder: (BuildContext context, int i) => Text('Row $i'),
                ),
              );
            },
          ),
        ),
      );
      expectPicked(tester, list);
      expect(
        host.description,
        describes(viewport: kHeight, max: 20 * 44 - kHeight, row: 44),
      );
      final ScrollPosition position = positionIn(tester, list);
      await turnFollowed(tester, position, <double>[300, 250]);
      // Loaded under the turn: the native view grows with it.
      expect(
        host.description,
        describes(viewport: kHeight, max: 40 * 44 - kHeight, row: 44),
      );
      // Past the old end, one to one.
      await more(tester, <double>[300, 300]);
      expect(position.pixels, 1150);
      await rest(tester);
      expect(position.pixels, 1150);
      expectAtRest(position);
    }, variant: ios);

    Widget earlier(int Function() before, VoidCallback loadEarlier) {
      const Key center = Key('center');
      return MaterialApp(
        home: NotificationListener<ScrollUpdateNotification>(
          onNotification: (ScrollUpdateNotification n) {
            if (n.metrics.extentBefore < 100) {
              loadEarlier();
            }
            return false;
          },
          child: CustomScrollView(
            key: const Key('view'),
            center: center,
            slivers: <Widget>[
              SliverList.list(children: rows(before(), name: 'Earlier')),
              SliverList.list(key: center, children: rows(30)),
            ],
          ),
        ),
      );
    }

    testWidgets('load earlier above, at rest: the native view keeps up', (
      WidgetTester tester,
    ) async {
      int before = 10;
      late StateSetter setBefore;
      await start(
        tester,
        StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            setBefore = setState;
            return earlier(() => before, () {});
          },
        ),
      );
      expectPicked(tester, const Key('view'));
      expect(
        host.description,
        describes(viewport: kHeight, min: -440, max: 30 * 44 - kHeight),
      );
      final ScrollPosition position = positionIn(tester, const Key('view'));
      await turnFollowed(tester, position, <double>[-200]);
      await rest(tester);
      expect(position.pixels, -200);
      setBefore(() => before = 20);
      await tester.pump(kFrame);
      expect(host.description!.minExtent, -880);
      expect(host.pixels, -200);
      await turnFollowed(tester, position, <double>[-10]);
      expect(position.pixels, -210);
    }, variant: ios);

    group(
      'under a turn',
      () {
        testWidgets('load earlier above: the turn goes on without a jump', (
          WidgetTester tester,
        ) async {
          int before = 10;
          await start(
            tester,
            StatefulBuilder(
              builder: (BuildContext context, StateSetter setState) {
                return earlier(() => before, () {
                  if (before < 20) {
                    setState(() => before = 20);
                  }
                });
              },
            ),
          );
          final ScrollPosition position = positionIn(tester, const Key('view'));
          await turnFollowed(tester, position, <double>[-200, -150]);
          expect(host.description!.minExtent, -880);
          await more(tester, <double>[-10]);
          expect(position.pixels, -360);
          await rest(tester);
          expect(position.pixels, -360);
        }, variant: ios);
      },
      skip:
          'BROKEN: when minScrollExtent moves under a turn, the native view '
          'keeps its offset from its top, so its reports (min + offset) '
          'jump by the change and the content with them; the runtime '
          'resyncs only at rest',
    );
  });

  // ---------------------------------------------------------------------
  group('18. ReorderableListView', () {
    testWidgets('picked, described, followed', (WidgetTester tester) async {
      const Key list = Key('list');
      await start(
        tester,
        MaterialApp(
          home: Material(
            child: ReorderableListView(
              key: list,
              onReorderItem: (int from, int to) {},
              children: <Widget>[
                for (int i = 0; i < 30; i++)
                  SizedBox(
                    key: ValueKey<int>(i),
                    height: 44,
                    child: Text('Row $i'),
                  ),
              ],
            ),
          ),
        ),
      );
      expectPicked(tester, list);
      expect(
        host.description,
        describes(viewport: kHeight, max: 30 * 44 - kHeight, row: 44),
      );
      final ScrollPosition position = positionIn(tester, list);
      await turnFollowed(tester, position, <double>[100, 100]);
      await rest(tester);
      expect(position.pixels, 200);
      expectAtRest(position);
    }, variant: ios);
  });

  // ---------------------------------------------------------------------
  group('19. explicit physics', () {
    testWidgets('ClampingScrollPhysics: followed, held at the edges', (
      WidgetTester tester,
    ) async {
      const Key list = Key('list');
      await start(
        tester,
        MaterialApp(
          home: ListView(
            key: list,
            physics: const ClampingScrollPhysics(),
            children: rows(40),
          ),
        ),
      );
      expectPicked(tester, list);
      const double max = 40 * 44 - kHeight;
      expect(host.description, describes(viewport: kHeight, max: max, row: 44));
      final ScrollPosition position = positionIn(tester, list);
      await turnFollowed(tester, position, <double>[100]);
      // The native view springs past the end; the content stops at it.
      await more(tester, <double>[1500]);
      expect(position.pixels, max);
      await rest(tester);
      expect(position.pixels, max);
      expectAtRest(position);
    }, variant: ios);

    testWidgets('NeverScrollableScrollPhysics: never driven', (
      WidgetTester tester,
    ) async {
      await start(
        tester,
        MaterialApp(
          home: Column(
            children: <Widget>[
              Expanded(
                flex: 3,
                child: ListView(
                  key: const Key('fixed'),
                  physics: const NeverScrollableScrollPhysics(),
                  children: rows(40),
                ),
              ),
              Expanded(
                child: ListView(key: const Key('free'), children: rows(40)),
              ),
            ],
          ),
        ),
      );
      // The smaller list is the only one the crown may drive.
      expectPicked(tester, const Key('free'));
      await turn(tester, <double>[50]);
      await rest(tester);
      expect(positionIn(tester, const Key('fixed')).pixels, 0);
      expect(positionIn(tester, const Key('free')).pixels, 50);
    }, variant: ios);

    testWidgets('NeverScrollableScrollPhysics alone: nothing is driven', (
      WidgetTester tester,
    ) async {
      await start(
        tester,
        MaterialApp(
          home: ListView(
            key: const Key('fixed'),
            physics: const NeverScrollableScrollPhysics(),
            children: rows(40),
          ),
        ),
      );
      expectNothingPicked();
      await turn(tester, <double>[50]);
      await rest(tester);
      expect(positionIn(tester, const Key('fixed')).pixels, 0);
    }, variant: ios);

    testWidgets('PageScrollPhysics on a ListView: the rest snaps a screen', (
      WidgetTester tester,
    ) async {
      const Key list = Key('list');
      await start(
        tester,
        MaterialApp(
          home: ListView(
            key: list,
            physics: const PageScrollPhysics(),
            children: rows(10, height: kHeight),
          ),
        ),
      );
      expectPicked(tester, list);
      expect(
        host.description,
        describes(viewport: kHeight, max: 9 * kHeight, row: kHeight),
      );
      final ScrollPosition position = positionIn(tester, list);
      await turnFollowed(tester, position, <double>[100, 30]);
      await rest(tester);
      expect(position.pixels, moreOrLessEquals(kHeight, epsilon: 0.01));
      expect(host.synced.last.$1, moreOrLessEquals(kHeight, epsilon: 0.01));
    }, variant: ios);
  });

  // ---------------------------------------------------------------------
  group('20. a list in a modal bottom sheet and in a dialog', () {
    Widget page(GlobalKey<NavigatorState> navigator) => MaterialApp(
      navigatorKey: navigator,
      home: ListView(key: const Key('page'), children: rows(40)),
    );

    testWidgets('showModalBottomSheet: the sheet\'s list takes the crown', (
      WidgetTester tester,
    ) async {
      final GlobalKey<NavigatorState> navigator = GlobalKey<NavigatorState>();
      await start(tester, page(navigator));
      expectPicked(tester, const Key('page'));
      showModalBottomSheet<void>(
        context: navigator.currentContext!,
        builder: (BuildContext context) => ListView(
          key: const Key('sheet'),
          children: rows(20, name: 'S'),
        ),
      );
      await tester.pumpAndSettle();
      expectPicked(tester, const Key('sheet'));
      final ScrollPosition sheet = positionIn(tester, const Key('sheet'));
      final double viewport = sheet.viewportDimension;
      expect(viewport, moreOrLessEquals(kHeight * 9 / 16));
      expect(
        host.description,
        describes(viewport: viewport, max: 20 * 44 - viewport, row: 44),
      );
      await turnFollowed(tester, sheet, <double>[50, 50]);
      await rest(tester);
      expect(sheet.pixels, 100);
      expect(positionIn(tester, const Key('page')).pixels, 0);

      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expectPicked(tester, const Key('page'));
      expect(
        host.description,
        describes(viewport: kHeight, max: 40 * 44 - kHeight, row: 44),
      );
    }, variant: ios);

    testWidgets('showDialog: the dialog\'s list takes the crown', (
      WidgetTester tester,
    ) async {
      final GlobalKey<NavigatorState> navigator = GlobalKey<NavigatorState>();
      await start(tester, page(navigator));
      showDialog<void>(
        context: navigator.currentContext!,
        builder: (BuildContext context) => Dialog(
          child: SizedBox(
            height: 180,
            child: ListView(
              key: const Key('dialog'),
              children: rows(20, name: 'D'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expectPicked(tester, const Key('dialog'));
      expect(
        host.description,
        describes(viewport: 180, max: 20 * 44 - 180, row: 44),
      );
      final ScrollPosition dialog = positionIn(tester, const Key('dialog'));
      await turnFollowed(tester, dialog, <double>[50, 50]);
      await rest(tester);
      expect(dialog.pixels, 100);
      expect(positionIn(tester, const Key('page')).pixels, 0);

      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expectPicked(tester, const Key('page'));
    }, variant: ios);
  });

  // ---------------------------------------------------------------------
  group('21. a SingleChildScrollView with a TextField', () {
    const String longText =
        'one two three four five six seven eight nine ten eleven twelve '
        'thirteen fourteen fifteen sixteen seventeen eighteen nineteen '
        'twenty twenty-one twenty-two twenty-three twenty-four twenty-five';

    Widget form({required int maxLines, required bool fieldFirst}) {
      final TextEditingController text = TextEditingController(text: longText);
      addTearDown(text.dispose);
      final Widget field = TextField(
        key: const Key('field'),
        maxLines: maxLines,
        controller: text,
      );
      return MaterialApp(
        home: Material(
          child: SingleChildScrollView(
            key: const Key('page'),
            child: Column(
              children: <Widget>[
                if (fieldFirst) field,
                ...rows(10),
                if (!fieldFirst) field,
                ...rows(10, name: 'After'),
              ],
            ),
          ),
        ),
      );
    }

    testWidgets('the page is driven, not the field\'s own scroll', (
      WidgetTester tester,
    ) async {
      await start(tester, form(maxLines: 2, fieldFirst: false));
      // The field's text overflows two lines: it scrolls on its own.
      final ScrollPosition field = positionIn(tester, const Key('field'));
      expect(field.maxScrollExtent, greaterThan(0));
      expectPicked(tester, const Key('page'));
      final ScrollPosition page = positionIn(tester, const Key('page'));
      expect(
        host.description,
        describes(viewport: kHeight, max: page.maxScrollExtent, row: 44),
      );
      await turnFollowed(tester, page, <double>[100, 100]);
      await rest(tester);
      expect(page.pixels, 200);
      expect(field.pixels, 0);
    }, variant: ios);

    testWidgets('focusing a field below scrolls the page; the crown follows', (
      WidgetTester tester,
    ) async {
      await start(tester, form(maxLines: 2, fieldFirst: false));
      final ScrollPosition page = positionIn(tester, const Key('page'));
      expect(page.pixels, 0);
      await tester.showKeyboard(find.byKey(const Key('field')));
      // The caret is brought on screen after a frame, in an animation.
      for (int i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(page.pixels, greaterThan(0));
      // The native view was told where the field brought the page.
      expect(host.synced.last, (page.pixels, false));
      final double from = page.pixels;
      await turn(tester, <double>[20]);
      expect(page.pixels, from + 20);
      host.report(0);
      await tester.pump(const Duration(seconds: 1));
      expect(page.pixels, from + 20);
    }, variant: ios);

    testWidgets('a tall multi-line field takes the crown from the page', (
      WidgetTester tester,
    ) async {
      await start(tester, form(maxLines: 7, fieldFirst: true));
      final ScrollPosition field = positionIn(tester, const Key('field'));
      expect(field.maxScrollExtent, greaterThan(0));
      // CAVEAT: the field covers 40% of the screen and comes after the
      // page: it is the frontmost candidate, so the crown scrolls the text
      // and the page cannot move until a finger moves it.
      expectPicked(tester, const Key('field'));
      final ScrollPosition page = positionIn(tester, const Key('page'));
      await turn(tester, <double>[30, 300]);
      await rest(tester);
      expect(page.pixels, 0);
      expect(field.pixels, field.maxScrollExtent);
    }, variant: ios);
  });
}
