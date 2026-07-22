// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io' show Platform;

/// Cheap, synchronous watchOS detection that mirrors the style of
/// `Platform.isIOS`, `Platform.isAndroid`, etc.
///
/// On a flutter-watchos build:
/// - `Platform.operatingSystem == "watchos"`
/// - `Platform.isIOS == true` (watchOS is an iOS-family OS)
/// - `Platform.isWatchOS == true` (new Dart VM getter)
///
/// Since `Platform.isIOS` is `true` on both real iOS and watchOS, app code
/// that wants to branch "iPhone/iPad only" vs "Apple Watch only" needs a way
/// to disambiguate. This class provides the idiomatic helpers. It is a
/// zero-FFI string/flag check suitable for hot paths.
///
/// Unlike [WatchOSInfo.isWatchOS] (which goes through dart:ffi into native
/// code to read `TARGET_OS_WATCH` at runtime), these helpers are pure Dart and
/// trivially inlinable.
///
/// ```dart
/// import 'package:flutter_watchos/flutter_watchos.dart';
///
/// // 1. Static helper (mirrors `Platform.isIOS` call shape)
/// if (FlutterWatchosPlatform.isWatch) { /* ... */ }
///
/// // 2. Extension on a Platform instance, for code that already holds one:
/// void run(Platform p) {
///   if (p.isWatch) { /* ... */ }
/// }
/// ```
///
/// Note on naming: our Dart VM patch does add a real `Platform.isWatchOS`, but
/// prefer these helpers in app code. The analyzer resolves `dart:io` from the
/// stock Dart SDK, which has no such getter, so naming it directly turns every
/// IDE and `dart analyze` run red even though the code compiles and runs. We
/// cannot paper over that with a static `Platform.isWatch` — Dart does not
/// (yet) support static extensions on external classes — so this class mirrors
/// the `isIOS` / `isAndroid` convention under its own name instead.
abstract final class FlutterWatchosPlatform {
  /// Whether the current operating system is watchOS.
  ///
  /// Equivalent to `Platform.operatingSystem == 'watchos'` (the string emitted
  /// by our Dart VM patch on Apple Watch). The engine also exposes a native
  /// `Platform.isWatchOS` getter at runtime, but we use the string check here
  /// so code analyzes cleanly against an unpatched Dart SDK in IDE tooling.
  static bool get isWatch => Platform.operatingSystem == 'watchos';

  /// Whether the current operating system is iOS in the strict sense —
  /// iPhone or iPad — and **not** watchOS.
  ///
  /// `Platform.isIOS` alone is `true` on both iPhone/iPad and Apple Watch, so
  /// this helper excludes watchOS. Use this when your code only makes sense on
  /// a handheld (large screen, status bar, etc.).
  ///
  /// ```dart
  /// // Wrong — also runs on Apple Watch
  /// if (Platform.isIOS) { showFullScreenLayout(); }
  ///
  /// // Right — iPhone / iPad only
  /// if (FlutterWatchosPlatform.isIos) { showFullScreenLayout(); }
  /// ```
  static bool get isIos => Platform.isIOS && !isWatch;

  /// Whether the current OS is any iOS-family platform: iPhone, iPad, or
  /// Apple Watch. Equivalent to the raw `Platform.isIOS` check.
  static bool get isAppleMobile => Platform.isIOS;
}

/// Extension on a [Platform] instance that adds watchOS-aware getters.
///
/// Dart can't extend `Platform`'s static members, but projects that already
/// hold a `Platform` instance (for mocking in tests, or to pass around) can
/// still use the ergonomic form:
///
/// ```dart
/// import 'dart:io';
/// import 'package:flutter_watchos/flutter_watchos.dart';
///
/// void log(Platform p) {
///   if (p.isWatch) print('on watchOS');
///   if (p.isIos) print('on iPhone/iPad (not Watch)');
/// }
/// ```
extension FlutterWatchosPlatformExt on Platform {
  /// Whether this [Platform] reports watchOS as its operating system.
  bool get isWatch => Platform.operatingSystem == 'watchos';

  /// Whether this [Platform] is strict iOS (iPhone/iPad) — **not** watchOS.
  bool get isIos => Platform.isIOS && Platform.operatingSystem != 'watchos';
}
