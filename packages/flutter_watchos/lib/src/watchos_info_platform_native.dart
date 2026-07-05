// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io' show Platform;

/// Whether the watchOS native FFI symbols are linked into this process.
///
/// They only exist in an actual flutter-watchos app build, which reports
/// `Platform.operatingSystem == 'watchos'` (on device and in the Simulator —
/// the engine's Dart VM patch sets it). `Platform.isIOS` is NOT the right
/// check: it is also `true` on iPhone/iPad, where the watch symbols are not
/// linked and an FFI lookup throws "symbol not found" — cross-platform apps
/// must be able to call the package APIs there and get the documented no-op.
/// The same applies to macOS/Linux unit-test hosts. When false, the package
/// falls back to safe no-op bindings.
bool get isWatch => Platform.operatingSystem == 'watchos';
