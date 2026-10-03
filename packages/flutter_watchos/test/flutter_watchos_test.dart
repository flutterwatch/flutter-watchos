// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_watchos/flutter_watchos.dart';

/// Fake bindings so we can exercise [WatchOSInfo] without a real device.
class _FakeBindings extends WatchOSNativeBindings {
  _FakeBindings() : super.forTesting();

  int hapticCalls = 0;
  int? lastHaptic;

  @override
  bool get isWatchOS => true;
  @override
  String get systemVersion => '11.0';
  @override
  String get deviceModel => 'Apple Watch';
  @override
  String get machineId => 'Watch7,1';
  @override
  bool get isSimulator => true;
  @override
  int get screenWidth => 396;
  @override
  int get screenHeight => 484;
  @override
  double get screenScale => 2.0;

  @override
  void playHaptic(int type) {
    hapticCalls++;
    lastHaptic = type;
  }
}

/// Fake bindings for [WatchCrown]: records the routing mode and hands out a
/// queued rotation delta.
class _FakeCrownBindings extends WatchOSNativeBindings {
  _FakeCrownBindings() : super.forTesting();

  int mode = 0;
  double pending = 0.0;

  @override
  int get crownMode => mode;
  @override
  set crownMode(int value) => mode = value;

  @override
  double consumeCrownDelta() {
    final double v = pending;
    pending = 0.0;
    return v;
  }
}

void main() {
  group('WatchOSInfo', () {
    setUp(() => WatchOSInfo.bindingsOverride = _FakeBindings());
    tearDown(() => WatchOSInfo.bindingsOverride = null);

    test('reports device info from native bindings', () {
      expect(WatchOSInfo.isWatchOS, isTrue);
      expect(WatchOSInfo.watchOSVersion, '11.0');
      expect(WatchOSInfo.deviceModel, 'Apple Watch');
      expect(WatchOSInfo.machineId, 'Watch7,1');
      expect(WatchOSInfo.isSimulator, isTrue);
      expect(WatchOSInfo.screenWidth, 396);
      expect(WatchOSInfo.screenHeight, 484);
      expect(WatchOSInfo.screenScale, 2.0);
      expect(WatchOSInfo.screenResolution, '396x484');
    });
  });

  group('WatchHapticType', () {
    test('raw values match WKHapticType ordering', () {
      expect(WatchHapticType.notification.rawValue, 0);
      expect(WatchHapticType.click.rawValue, 8);
      // Stable mapping across the whole enum.
      expect(
        WatchHapticType.values.map((t) => t.rawValue).toList(),
        <int>[0, 1, 2, 3, 4, 5, 6, 7, 8],
      );
    });
  });

  group('FlutterWatchosPlatform', () {
    test('isWatch is false on the test host (not watchOS)', () {
      expect(FlutterWatchosPlatform.isWatch, isFalse);
    });

    test('isIos and isAppleMobile agree with the host OS', () {
      // The suite runs on the desktop VM (macOS/Linux), never on an
      // iOS-family OS — so both are false, and isIos in particular must not
      // fall back to "not watchOS means iOS".
      expect(FlutterWatchosPlatform.isIos, isFalse);
      expect(FlutterWatchosPlatform.isAppleMobile, isFalse);
    });

    test('isIos implies neither watchOS nor a non-Apple host', () {
      // Invariant that holds on every platform, including the Web stub where
      // all three are constant false: isIos is the strict iPhone/iPad case.
      expect(
        FlutterWatchosPlatform.isIos,
        FlutterWatchosPlatform.isAppleMobile && !FlutterWatchosPlatform.isWatch,
      );
    });
  });

  group('WatchCrownScroll', () {
    testWidgets('marks its scrollable for the crown runtime', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: WatchCrownScroll(
            scrollIndicator: false,
            child: ListView(children: const <Widget>[]),
          ),
        ),
      );
      // The runtime the CLI compiles into every app looks for this map
      // above a scrollable (runtime/lib/watchos_crown_runtime.dart).
      final MetaData mark = tester.widget<MetaData>(
        find.ancestor(
            of: find.byType(ListView), matching: find.byType(MetaData)),
      );
      expect(mark.metaData, <String, Object>{
        'flutter_watchos.crownScroll': true,
        'enabled': true,
        'scrollIndicator': false,
      });
    });

    testWidgets('can keep the crown off its scrollables', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: WatchCrownScroll(
            enabled: false,
            child: ListView(children: const <Widget>[]),
          ),
        ),
      );
      final MetaData mark = tester.widget<MetaData>(
        find.ancestor(
            of: find.byType(ListView), matching: find.byType(MetaData)),
      );
      expect((mark.metaData as Map<String, Object>)['enabled'], isFalse);
    });

    testWidgets('renders its child', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: WatchCrownScroll(child: Center(child: Text('content'))),
        ),
      );
      expect(find.text('content'), findsOneWidget);
    });

    testWidgets('does not consume scroll notifications', (
      WidgetTester tester,
    ) async {
      var sawScroll = false;
      await tester.pumpWidget(
        MaterialApp(
          home: NotificationListener<ScrollNotification>(
            onNotification: (ScrollNotification n) {
              sawScroll = true;
              return false;
            },
            child: WatchCrownScroll(
              child: ListView(
                physics: const BouncingScrollPhysics(),
                children: <Widget>[
                  for (int i = 0; i < 30; i++)
                    SizedBox(height: 40, child: Text('row $i')),
                ],
              ),
            ),
          ),
        ),
      );

      // Any scroll must bubble through WatchCrownScroll to app listeners.
      await tester.drag(find.byType(ListView), const Offset(0, -120));
      await tester.pumpAndSettle();

      expect(
        sawScroll,
        isTrue,
        reason:
            'WatchCrownScroll must let notifications bubble to app listeners',
      );
    });
  });

  group('WatchScrollPhysics', () {
    const WatchScrollPhysics physics = WatchScrollPhysics();

    FixedScrollMetrics at(double pixels) => FixedScrollMetrics(
          minScrollExtent: 0,
          maxScrollExtent: 1000,
          pixels: pixels,
          viewportDimension: 248,
          axisDirection: AxisDirection.down,
          devicePixelRatio: 2.0,
        );

    // UIKit's rubber band for a finger x past the edge of a 248-pt viewport.
    double stretchFor(double x) => 0.55 * x * 248 / (248 + 0.55 * x);

    test('a finger past the edge stretches the content on the UIKit curve', () {
      // Dragging up at the end: negative offsets push pixels past max.
      double pixels = 1000;
      for (int i = 0; i < 20; i++) {
        pixels -= physics.applyPhysicsToUserOffset(at(pixels), -5);
      }
      // 100 pt of finger past the edge: 45 pt of stretch, whatever the
      // event sizes.
      expect(pixels - 1000, moreOrLessEquals(stretchFor(100), epsilon: 1e-6));
      final double oneEvent = -physics.applyPhysicsToUserOffset(at(1000), -100);
      expect(oneEvent, moreOrLessEquals(stretchFor(100), epsilon: 1e-6));
      // Measured on a Series 10: 47.5 pt of stretch for ~106 pt of finger.
      expect(stretchFor(106), moreOrLessEquals(47.5, epsilon: 1.0));
    });

    test('the finger can hold a stretch and ease it back on the same curve',
        () {
      double pixels = 1000;
      pixels -= physics.applyPhysicsToUserOffset(at(pixels), -100);
      final double held = pixels;
      // Easing back the same 100 pt returns exactly to the edge…
      expect(
        held - physics.applyPhysicsToUserOffset(at(held), 100),
        moreOrLessEquals(1000, epsilon: 1e-6),
      );
      // …and 50 pt more carries on into the content one to one.
      expect(
        held - physics.applyPhysicsToUserOffset(at(held), 150),
        moreOrLessEquals(950, epsilon: 1e-6),
      );
    });

    test('an event crossing the edge moves one to one up to it, stretched beyond', () {
      // 10 pt of travel left, a 120-pt event.
      final double moved = -physics.applyPhysicsToUserOffset(at(990), -120);
      expect(moved, moreOrLessEquals(10 + stretchFor(110), epsilon: 1e-6));
      // In range it is untouched.
      expect(physics.applyPhysicsToUserOffset(at(500), -120), -120);
      // The top edge mirrors the bottom one.
      final double down = physics.applyPhysicsToUserOffset(at(0), 100);
      expect(down, moreOrLessEquals(stretchFor(100), epsilon: 1e-6));
    });

    test('the edge spring is critically damped at 11 rad/s', () {
      final SpringDescription spring = physics.spring;
      expect(spring.mass, 1);
      expect(spring.stiffness, 121);
      expect(spring.damping, 22);
    });

    // A flick's release runs one display frame ahead (see the physics).
    const double lead = 1 / 60;

    test('a released stretch falls back as e^(-11t)·(x0 + v·t)', () {
      // Measured: let go 61.5 pt past the top with the finger still moving
      // out at ~180 pt/s.
      final Simulation sim =
          physics.createBallisticSimulation(at(-61.5), -180)!;
      double model(double t) => math.exp(-11 * t) * (-61.5 - 180 * t);
      for (final double t in <double>[0.05, 0.1, 0.2, 0.3]) {
        expect(sim.x(t), moreOrLessEquals(model(t + lead), epsilon: 0.05));
      }
      // It heads straight back: no outward drift with a slow finger.
      expect(sim.dx(0), greaterThan(0));
      // Native, 200 ms after the lift: 9.5 pt left.
      expect(sim.x(0.2), moreOrLessEquals(-9.5, epsilon: 1.5));
      expect(sim.isDone(1.0), isTrue);
    });

    test('a still finger lets go of a stretch with no lead', () {
      final Simulation sim = physics.createBallisticSimulation(at(-40), 0)!;
      expect(sim.x(0), moreOrLessEquals(-40));
      expect(sim.x(0.1), moreOrLessEquals(math.exp(-1.1) * -40, epsilon: 0.05));
    });

    test('a fling into the edge overshoots and returns like the native list',
        () {
      // Measured: crossing the end at ~1900 pt/s peaked 63.5 pt out ~90 ms
      // later.
      final Simulation sim = physics.createBallisticSimulation(at(1000), 1900)!;
      expect(sim.x(1 / 11 - lead) - 1000,
          moreOrLessEquals(1900 / (math.e * 11), epsilon: 0.5));
      expect(sim.x(1 / 11 - lead) - 1000, moreOrLessEquals(63.5, epsilon: 1.0));
      expect(sim.isDone(1.5), isTrue);
      expect(sim.x(1.5), moreOrLessEquals(1000, epsilon: 0.5));
    });

    test('a fling decelerates at UIKit\'s normal rate', () {
      final Simulation sim = physics.createBallisticSimulation(at(100), 2400)!;
      // 0.998 per millisecond, a frame ahead.
      expect(
        sim.dx(0.1),
        moreOrLessEquals(
          2400 * math.pow(0.998, 100 + 1000 * lead).toDouble(),
          epsilon: 5,
        ),
      );
    });

    test('a flick during a fling carries no momentum over', () {
      expect(physics.carriedMomentum(1590), 0);
      expect(
        const WatchScrollPhysics(parent: AlwaysScrollableScrollPhysics())
            .carriedMomentum(1590),
        0,
      );
    });

    testWidgets('a spring restarted midway gets no second release kick', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ListView.builder(
            physics: const WatchScrollPhysics(),
            itemExtent: 44,
            itemCount: 30,
            itemBuilder: (BuildContext context, int index) =>
                Text('row $index'),
          ),
        ),
      );
      final ScrollPosition position =
          tester.state<ScrollableState>(find.byType(Scrollable)).position;
      final TestGesture finger = await tester.startGesture(
        tester.getCenter(find.byType(ListView)),
      );
      for (int i = 0; i < 10; i++) {
        await finger.moveBy(const Offset(0, 10));
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pump(const Duration(milliseconds: 200));
      await finger.up();
      await tester.pump();
      final double x0 = position.pixels;
      expect(x0, lessThan(-20));
      await tester.pump(const Duration(milliseconds: 50));
      // New content mid-spring restarts the ballistic.
      // The ballistic restarts mid-spring, as new content dimensions do.
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      position.activity!.applyNewDimensions();
      await tester.pump(); // the restarted ballistic's first tick (t = 0)
      await tester.pump(const Duration(milliseconds: 50));
      // Still the one spring from the lift: e^(-11t)·x0 at ~100 ms, not a
      // second kick toward the edge.
      expect(
        position.pixels,
        moreOrLessEquals(math.exp(-11 * 0.1) * x0, epsilon: 2.0),
      );
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('WatchCrownScroll installs the native behavior by default',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: WatchCrownScroll(
            child: ListView(children: const <Widget>[Text('row')]),
          ),
        ),
      );
      final BuildContext context = tester.element(find.text('row'));
      expect(ScrollConfiguration.of(context), isA<WatchScrollBehavior>());
      expect(ScrollConfiguration.of(context).getScrollPhysics(context),
          isA<WatchScrollPhysics>());
    });

    testWidgets('nativePhysics: false keeps the ambient behavior',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: WatchCrownScroll(
            nativePhysics: false,
            child: ListView(children: const <Widget>[Text('row')]),
          ),
        ),
      );
      final BuildContext context = tester.element(find.text('row'));
      expect(
          ScrollConfiguration.of(context), isNot(isA<WatchScrollBehavior>()));
    });
  });

  group('WatchCrown', () {
    late _FakeCrownBindings fake;

    setUp(() {
      fake = _FakeCrownBindings();
      WatchCrown.instance.bindingsOverride = fake;
      WatchCrown.instance.debugAutoTick = false; // drive polling manually
    });
    tearDown(() {
      WatchCrown.instance.bindingsOverride = null;
      WatchCrown.instance.debugAutoTick = true;
    });

    test('enable/disable toggles raw mode, reference-counted', () {
      final WatchCrown crown = WatchCrown.instance;
      expect(crown.isEnabled, isFalse);

      crown.enable();
      expect(fake.mode, 1);
      expect(crown.isEnabled, isTrue);

      crown.enable(); // nested
      crown.disable();
      expect(fake.mode, 1, reason: 'one enable still outstanding');

      crown.disable();
      expect(fake.mode, 0);
      expect(crown.isEnabled, isFalse);
    });

    test('drain returns accumulated rotation, then zero', () {
      final WatchCrown crown = WatchCrown.instance;
      fake.pending = 3.5;
      expect(crown.drain(), 3.5);
      expect(crown.drain(), 0.0);
    });

    test('rotations stream emits on poll and toggles mode', () async {
      final WatchCrown crown = WatchCrown.instance;
      final List<CrownRotationEvent> events = <CrownRotationEvent>[];
      final sub = crown.rotations.listen(events.add);

      // First listener switches the crown into raw mode.
      expect(fake.mode, 1);

      fake.pending = 2.0;
      crown.debugPoll(const Duration(milliseconds: 16));
      await Future<void>.delayed(Duration.zero); // let the broadcast deliver

      expect(events.single.delta, 2.0);

      // An idle poll (no rotation) emits nothing.
      crown.debugPoll(const Duration(milliseconds: 32));
      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(1));

      await sub.cancel();
      expect(
        fake.mode,
        0,
        reason: 'cancelling the last listener returns the crown to scroll',
      );
    });
  });
}
