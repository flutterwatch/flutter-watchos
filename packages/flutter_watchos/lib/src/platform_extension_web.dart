// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Web stub — dart:io (and therefore `Platform`) is not available on Web.
//
// A Web build is never watchOS and never an iOS-family OS in the `Platform`
// sense (Mobile Safari on an iPhone is still the Web platform, not iOS), so
// every getter is a compile-time-constant `false`. This lets a cross-platform
// app write `FlutterWatchosPlatform.isWatch` — the guard this package's docs
// recommend over `Platform.isIOS` — without breaking its Web build.
//
// The native branch also declares `extension FlutterWatchosPlatformExt on
// Platform`; it has no Web counterpart because the type it extends does not
// exist here.

/// Cheap, synchronous watchOS detection that mirrors the style of
/// `Platform.isIOS`, `Platform.isAndroid`, etc.
///
/// On Web every getter is `false`: there is no dart:io `Platform` to consult,
/// and a Web build is by definition not running on watchOS or on an
/// iOS-family OS. See the native implementation for the full documentation.
abstract final class FlutterWatchosPlatform {
  /// Whether the current operating system is watchOS. Always `false` on Web.
  static bool get isWatch => false;

  /// Whether the current OS is iPhone/iPad and **not** watchOS. Always
  /// `false` on Web.
  static bool get isIos => false;

  /// Whether the current OS is any iOS-family platform (iPhone, iPad, or
  /// Apple Watch). Always `false` on Web.
  static bool get isAppleMobile => false;
}
