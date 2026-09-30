// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// This file starts no binding: it has no testWidgets and never calls
// ensureInitialized, as an app's main() before runApp.

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_watchos/flutter_watchos.dart';

/// Stands in for the flag the watch host reads to hide the clock.
class _FakeStatusBarBindings extends WatchOSNativeBindings {
  _FakeStatusBarBindings() : super.forTesting();

  bool clockHidden = false;

  @override
  bool get statusBarHidden => clockHidden;

  @override
  set statusBarHidden(bool hidden) => clockHidden = hidden;
}

void main() {
  tearDown(() {
    WatchStatusBar.bindingsOverride = null;
    WatchStatusBar.isWatchOverride = null;
  });

  test('WatchStatusBar.hidden can be set with no binding, and creates none',
      () {
    expect(BindingBase.debugBindingType(), isNull);
    final _FakeStatusBarBindings fake = _FakeStatusBarBindings();
    WatchStatusBar.bindingsOverride = fake;
    WatchStatusBar.isWatchOverride = true;

    // No scheduleFrameOverride: this is the real frame request.
    WatchStatusBar.hidden = true;

    expect(fake.clockHidden, isTrue);
    expect(BindingBase.debugBindingType(), isNull);
  });
}
