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
}
