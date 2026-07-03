// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

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

/// Fake bindings for [WatchCrownScrolling]: records the scroll options.
class _FakeScrollOptionBindings extends WatchOSNativeBindings {
  _FakeScrollOptionBindings() : super.forTesting();

  double multiplier = 1.0;
  bool detents = true;

  @override
  double get crownScrollMultiplier => multiplier;
  @override
  set crownScrollMultiplier(double value) => multiplier = value;

  @override
  bool get crownDetentHaptics => detents;
  @override
  set crownDetentHaptics(bool value) => detents = value;
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
  });

  group('WatchCrownScroll', () {
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

    FixedScrollMetrics overscrolled(double past) => FixedScrollMetrics(
          minScrollExtent: 0,
          maxScrollExtent: 1000,
          pixels: 1000 + past,
          viewportDimension: 248,
          axisDirection: AxisDirection.down,
          devicePixelRatio: 2.0,
        );

    test('resistance rises steeply and hits a hard cap', () {
      // In range: same friction as iOS at rest…
      expect(physics.frictionFactor(0), moreOrLessEquals(0.52));
      // …but zero at (and past) the stretch cap — a hard native-style limit.
      expect(physics.frictionFactor(0.12), 0);
      expect(physics.frictionFactor(0.5), 0);
      // Monotonically decreasing in between.
      expect(physics.frictionFactor(0.03), greaterThan(physics.frictionFactor(0.06)));
      expect(physics.frictionFactor(0.06), greaterThan(physics.frictionFactor(0.09)));
    });

    test('content cannot be dragged past the stretch cap', () {
      // Negative user offset past the END = tensioning further out. At the
      // cap (12% of a 248-pt viewport ≈ 29.8), it moves the content nowhere.
      final double atCap =
          physics.applyPhysicsToUserOffset(overscrolled(248 * 0.12), -50);
      expect(atCap.abs(), lessThan(0.001));
      // Well inside the cap, input still moves it (with resistance).
      final double inside =
          physics.applyPhysicsToUserOffset(overscrolled(5), -10);
      expect(inside.abs(), greaterThan(0));
      expect(inside.abs(), lessThan(10)); // resisted, not free
    });

    test('spring is much stiffer than the phone default (shallow bounce)', () {
      expect(physics.spring.stiffness, greaterThanOrEqualTo(500));
      // Default scroll spring is stiffness 100 — the watch settle must be
      // several times firmer or flings visibly overshoot the list end.
      expect(const BouncingScrollPhysics().spring.stiffness, lessThan(200));
    });

    test('one huge crown sample crossing the edge is still capped', () {
      // The engine delivers up to ~120 logical px per crown sample. Stock
      // bouncing physics applies NO friction to an event that starts in
      // range, so a single sample crossing the edge would plant content most
      // of a screen deep. Split + integrated friction must bound it.
      final FixedScrollMetrics nearEnd = FixedScrollMetrics(
        minScrollExtent: 0,
        maxScrollExtent: 1000,
        pixels: 990, // 10 px of free travel left
        viewportDimension: 248,
        axisDirection: AxisDirection.down,
        devicePixelRatio: 2.0,
      );
      final double moved =
          physics.applyPhysicsToUserOffset(nearEnd, -120).abs();
      // Free travel (10) + at most the stretch cap (~29.8), never the
      // unfrictioned 120.
      expect(moved, lessThan(10 + 248 * 0.12 + 0.001));
      expect(moved, greaterThan(10)); // still crosses the edge with a stretch
      // Fully in-range movement stays untouched.
      final FixedScrollMetrics middle = FixedScrollMetrics(
        minScrollExtent: 0,
        maxScrollExtent: 1000,
        pixels: 500,
        viewportDimension: 248,
        axisDirection: AxisDirection.down,
        devicePixelRatio: 2.0,
      );
      expect(physics.applyPhysicsToUserOffset(middle, -120), -120);
    });

    test('ballistic entry velocity is clamped (bounded bounce depth)', () {
      // Stacked crown/wheel momentum can hand goBallistic tens of thousands
      // of px/s; the simulation must start no faster than maxFlingVelocity or
      // the edge bounce goes phone-deep.
      final FixedScrollMetrics inRange = FixedScrollMetrics(
        minScrollExtent: 0,
        maxScrollExtent: 1000,
        pixels: 500,
        viewportDimension: 248,
        axisDirection: AxisDirection.down,
        devicePixelRatio: 2.0,
      );
      final Simulation sim =
          physics.createBallisticSimulation(inRange, 30000)!;
      expect(sim.dx(0).abs(),
          lessThanOrEqualTo(physics.maxFlingVelocity * 1.01));
    });

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
      expect(ScrollConfiguration.of(context), isNot(isA<WatchScrollBehavior>()));
    });
  });

  group('WatchCrownScrolling', () {
    late _FakeScrollOptionBindings fake;

    setUp(() {
      fake = _FakeScrollOptionBindings();
      WatchCrownScrolling.bindingsOverride = fake;
    });
    tearDown(() => WatchCrownScrolling.bindingsOverride = null);

    test('defaults match native: high sensitivity, detents on', () {
      expect(WatchCrownScrolling.sensitivity, WatchCrownSensitivity.high);
      expect(WatchCrownScrolling.detentHaptics, isTrue);
    });

    test('sensitivity writes the native multiplier', () {
      WatchCrownScrolling.sensitivity = WatchCrownSensitivity.low;
      expect(fake.multiplier, 0.25);
      expect(WatchCrownScrolling.sensitivity, WatchCrownSensitivity.low);
      WatchCrownScrolling.sensitivity = WatchCrownSensitivity.medium;
      expect(fake.multiplier, 0.5);
      WatchCrownScrolling.sensitivity = WatchCrownSensitivity.high;
      expect(fake.multiplier, 1.0);
    });

    test('detentHaptics writes the native flag', () {
      WatchCrownScrolling.detentHaptics = false;
      expect(fake.detents, isFalse);
      expect(WatchCrownScrolling.detentHaptics, isFalse);
      WatchCrownScrolling.detentHaptics = true;
      expect(fake.detents, isTrue);
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
