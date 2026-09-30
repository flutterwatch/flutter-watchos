// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_watchos_example/main.dart';

void main() {
  testWidgets('home screen shows the title and the crown demo button',
      (WidgetTester tester) async {
    await tester.pumpWidget(const FlutterWatchosExampleApp());

    expect(find.text('flutter_watchos'), findsOneWidget);
    expect(find.text('crown demo →'), findsOneWidget);
  });
}
