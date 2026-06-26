// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/terminal.dart';

import 'watchos_device.dart' show WatchosDevice;

/// A [Logger] decorator that rewrites the device-list category column from
/// `(mobile)` to `(watch)` on lines describing watchOS devices.
///
/// Why this exists: Flutter's `Device.descriptions` hard-codes the line as
/// `'${device.displayName} (${device.category})'` and `Category` is a sealed
/// `enum { web, desktop, mobile }` we can't extend without forking the SDK
/// (which the project explicitly forbids — the Flutter SDK is never patched).
/// Rewriting the rendered line at the logger boundary is the least invasive
/// way to ship the cosmetic fix.
///
/// The rewrite only fires on lines that contain `• watchos •` (the third
/// column printed by `flutter-watchos devices` for our [WatchosDevice], whose
/// `targetPlatformDisplayName` returns `'watchos'`). That makes it impossible
/// to accidentally rewrite an iPhone or anything else that happens to contain
/// the substring `(mobile)`.
class WatchosCategoryRewritingLogger extends DelegatingLogger {
  WatchosCategoryRewritingLogger(super.delegate);

  // The third column is left-padded with spaces to align the table. Match
  // any whitespace around the bullet.
  static final RegExp _watchosLine = RegExp(r'•\s*watchos\s*•');

  String _rewrite(String message) {
    if (!_watchosLine.hasMatch(message)) {
      return message;
    }
    // Replace only the FIRST `(mobile)` — that's the category column. Any
    // later occurrence (e.g. inside a device name) is preserved. Pad with
    // trailing spaces so the next column stays vertically aligned with other
    // rows that still say `(mobile)`. `(mobile)` is 8 chars; `(watch)` is 7,
    // so 1 space of padding keeps the table square.
    return message.replaceFirst('(mobile)', '(watch) ');
  }

  @override
  void printStatus(
    String message, {
    bool? emphasis,
    TerminalColor? color,
    bool? newline,
    int? indent,
    int? hangingIndent,
    bool? wrap,
  }) {
    super.printStatus(
      _rewrite(message),
      emphasis: emphasis,
      color: color,
      newline: newline,
      indent: indent,
      hangingIndent: hangingIndent,
      wrap: wrap,
    );
  }
}
