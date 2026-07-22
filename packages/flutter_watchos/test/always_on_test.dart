// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_watchos/flutter_watchos.dart';

/// Fake bindings for [WatchAlwaysOn]: stands in for the flag the watch host
/// writes when SwiftUI's `\.isLuminanceReduced` changes.
class _FakeAlwaysOnBindings extends WatchOSNativeBindings {
  _FakeAlwaysOnBindings() : super.forTesting();

  bool active = false;
  bool supported = true;

  @override
  bool get alwaysOnActive => active;
  @override
  bool get alwaysOnSupported => supported;
}

/// Stands in for an app's own lifecycle observer, to prove the package's
/// observer coexists with it.
class _RecordingObserver with WidgetsBindingObserver {
  _RecordingObserver({this.onState});

  final void Function(AppLifecycleState state)? onState;
  final List<AppLifecycleState> states = <AppLifecycleState>[];

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    states.add(state);
    onState?.call(state);
  }
}

void main() {
  group('WatchAlwaysOn', () {
    late _FakeAlwaysOnBindings fake;

    setUp(() {
      fake = _FakeAlwaysOnBindings();
      WatchAlwaysOn.bindingsOverride = fake;
    });

    // Also disposes the shared notifier, so no sampling outlives a test.
    tearDown(() => WatchAlwaysOn.bindingsOverride = null);

    /// Returns the app to the lit, resumed, settled state and lets the burst
    /// that follows a lifecycle change expire — otherwise the still-armed
    /// timer trips the "timer pending after the widget tree was disposed"
    /// check, which is the framework noticing exactly what this class does on
    /// purpose for three seconds.
    Future<void> settle(WidgetTester tester) async {
      fake.active = false;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
    }

    Widget stateText() => WatchAlwaysOnBuilder(
          builder: (BuildContext context, bool alwaysOn, Widget? child) =>
              Text('$alwaysOn', textDirection: TextDirection.ltr),
        );

    test('isActive mirrors the host-reported flag', () {
      expect(WatchAlwaysOn.isActive, isFalse);
      fake.active = true;
      expect(WatchAlwaysOn.isActive, isTrue);
    });

    test('isSupported is false when the host never reports', () {
      expect(WatchAlwaysOn.isSupported, isTrue);
      fake.supported = false;
      expect(WatchAlwaysOn.isSupported, isFalse);
    });

    test('state seeds from the flag at first listen', () {
      fake.active = true;
      expect(WatchAlwaysOn.state.value, isTrue);
    });

    testWidgets('builder rebuilds when the watch dims and lights back up',
        (tester) async {
      final List<bool> seen = <bool>[];
      await tester.pumpWidget(WatchAlwaysOnBuilder(
        builder: (BuildContext context, bool alwaysOn, Widget? child) {
          seen.add(alwaysOn);
          return const SizedBox();
        },
      ));
      expect(seen, <bool>[false]);

      // Wrist down: watchOS resigns active and the host reports the dimming.
      fake.active = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(seen, <bool>[false, true]);

      // Wrist up again.
      fake.active = false;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(seen, <bool>[false, true, false]);

      await settle(tester);
    });

    testWidgets('burst catches a report that lands after the lifecycle event',
        (tester) async {
      // Resign-active and the SwiftUI environment update are not ordered, so
      // the flag can still be stale when Dart hears about the lifecycle
      // change. The burst is what closes that gap.
      await tester.pumpWidget(stateText());

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(find.text('false'), findsOneWidget,
          reason: 'host has not reported yet');

      fake.active = true; // the host reports a moment later
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('true'), findsOneWidget);

      await settle(tester);
    });

    testWidgets('keeps sampling slowly once the burst is over', (tester) async {
      // Backstop for a watchOS that dims noticeably later than it resigns
      // active — by then the burst has expired.
      await tester.pumpWidget(stateText());

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      await tester.pump(const Duration(seconds: 4)); // burst expires
      expect(find.text('false'), findsOneWidget);

      fake.active = true;
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('true'), findsOneWidget);

      await settle(tester);
    });

    testWidgets('returns to lit when the host reports late on wrist-up',
        (tester) async {
      // Regression: raising the wrist pairs become-active with the
      // brightening, in no guaranteed order — the same race as going in.
      // Reading once on `resumed` and then standing down latched "dimmed"
      // forever, with nothing left running to correct it.
      await tester.pumpWidget(stateText());

      fake.active = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(find.text('true'), findsOneWidget);

      // Wrist up: become-active arrives while the flag still reads dimmed.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(find.text('true'), findsOneWidget, reason: 'flag is still stale');

      fake.active = false; // the host brightens a moment later
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('false'), findsOneWidget);

      await settle(tester);
    });

    testWidgets('self-heals if the wrist-up lifecycle event never arrives',
        (tester) async {
      // A stuck "dimmed" is the costly failure — the app would show its
      // Always-On layout on a lit screen — so the trickle keeps running while
      // the state reads dimmed, even with no lifecycle change to prompt it.
      await tester.pumpWidget(stateText());

      fake.active = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      await tester.pump(const Duration(seconds: 4)); // burst expires
      expect(find.text('true'), findsOneWidget);

      fake.active = false; // brightened, with no lifecycle event at all
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('false'), findsOneWidget);

      await settle(tester);
    });

    testWidgets('tracks the state across the full lifecycle sweep',
        (tester) async {
      // watchOS backgrounds a frontmost app after about two minutes of
      // Always-On, so dimmed → hidden → paused → resumed is a route real apps
      // take, not a synthetic one.
      await tester.pumpWidget(stateText());

      fake.active = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(find.text('true'), findsOneWidget);

      for (final AppLifecycleState state in <AppLifecycleState>[
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
        await tester.pump();
        expect(find.text('true'), findsOneWidget,
            reason: 'still dimmed in $state');
      }

      // Coming back: the host brightens, and the state follows.
      fake.active = false;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(find.text('false'), findsOneWidget);

      await settle(tester);
    });

    testWidgets("does not disturb the app's own lifecycle observer",
        (tester) async {
      final _RecordingObserver appObserver = _RecordingObserver();
      tester.binding.addObserver(appObserver);
      addTearDown(() => tester.binding.removeObserver(appObserver));

      await tester.pumpWidget(stateText());
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      expect(appObserver.states,
          <AppLifecycleState>[AppLifecycleState.inactive, AppLifecycleState.resumed]);

      await settle(tester);
    });

    testWidgets('isActive can be stale inside a lifecycle callback; state is not',
        (tester) async {
      // The documented gotcha: an app reading isActive from its OWN
      // didChangeAppLifecycleState is reading during the race, before the host
      // has necessarily reported. Listening to `state` is what settles.
      final List<bool> readsFromCallback = <bool>[];
      final _RecordingObserver appObserver = _RecordingObserver(
        onState: (_) => readsFromCallback.add(WatchAlwaysOn.isActive),
      );
      tester.binding.addObserver(appObserver);
      addTearDown(() => tester.binding.removeObserver(appObserver));

      await tester.pumpWidget(stateText());
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(readsFromCallback, <bool>[false], reason: 'host has not reported');

      fake.active = true;
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('true'), findsOneWidget, reason: 'the listenable settles');

      await settle(tester);
    });

    testWidgets('stops sampling once lit, resumed, and settled',
        (tester) async {
      await tester.pumpWidget(stateText());
      await settle(tester);

      // A flag flip with the wrist up can't happen on device; if it did, no
      // timer is running to notice it — that is the point (zero cost while
      // lit, which is the whole state an app spends most of its life in).
      fake.active = true;
      await tester.pump(const Duration(seconds: 5));
      expect(find.text('false'), findsOneWidget);
    });
  });
}
