// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Web stub — dart:ffi is not available on Web. All getters return safe
// defaults that match the non-watchOS fallback in the native implementation.

/// FFI bindings stub for Web. No native symbols are available.
class WatchOSNativeBindings {
  WatchOSNativeBindings();
  WatchOSNativeBindings.forTesting();

  bool get isWatchOS => false;
  String get systemVersion => '';
  String get deviceModel => '';
  String get machineId => '';
  bool get isSimulator => false;
  int get screenWidth => 0;
  int get screenHeight => 0;
  double get screenScale => 0.0;
  String get screenResolution => '0x0';

  void playHaptic(int type) {}

  int get crownMode => 0;
  set crownMode(int mode) {}
  double consumeCrownDelta() => 0.0;
}
