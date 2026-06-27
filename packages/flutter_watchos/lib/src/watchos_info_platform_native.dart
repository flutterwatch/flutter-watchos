// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io' show Platform;

/// Whether the watchOS native FFI symbols are linked into this process.
///
/// They only exist in an actual watch app build, which reports
/// `Platform.isIOS == true` (watchOS is an iOS-family OS, on device and in the
/// Simulator). This must be `false` on a macOS/Linux unit-test host — those
/// don't link the plugin, so an FFI lookup there throws "symbol not found".
/// When false, the package falls back to safe no-op bindings.
bool get isApple => Platform.isIOS;
