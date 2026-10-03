// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/executable.dart' show LoggerFactory;
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/terminal.dart';

import 'watchos_device.dart' show WatchosDevice;

/// The logger flutter-watchos runs with: stock's, from [loggerFactory] with the
/// inputs stock's `main` gives it, wrapped for people only.
///
/// For `daemon` and for any `--machine` run (`attach --machine` too) it is
/// exactly the logger stock builds, with no wrapper: IDEs parse that output,
/// and stock code finds the logger by its type (`daemon` with
/// `asLogger<NotifyingLogger>`, `attach --machine` with a cast to
/// `MachineOutputLogger`). In every other mode it is stock's logger inside
/// [WatchosCategoryRewritingLogger]. [verbose], [prefixedErrors] and
/// [windows] reach [LoggerFactory.createLogger] as they do in stock.
Logger createWatchosLogger(
  LoggerFactory loggerFactory, {
  required bool verbose,
  required bool prefixedErrors,
  required bool machine,
  required bool daemon,
  required bool windows,
}) {
  final Logger logger = loggerFactory.createLogger(
    verbose: verbose,
    prefixedErrors: prefixedErrors,
    machine: machine,
    daemon: daemon,
    windows: windows,
    // Stock sets it for the command that shows widgets in a browser, which
    // flutter-watchos does not register.
    widgetPreviews: false,
  );
  if (daemon || machine) {
    return logger;
  }
  return WatchosCategoryRewritingLogger(logger);
}

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
///
/// It also rewrites stock's hint after a usage error, which names `flutter`,
/// to name `flutter-watchos` ([usageHint]).
class WatchosCategoryRewritingLogger extends DelegatingLogger {
  WatchosCategoryRewritingLogger(super.delegate);

  /// Stock's hint after a usage error (stock `runner.dart`), which names
  /// `flutter`.
  static const String _stockUsageHint =
      "Run 'flutter -h' (or 'flutter <command> -h') for available flutter commands and options.";

  /// The hint this logger prints after a usage error instead of stock's.
  static const String usageHint =
      "Run 'flutter-watchos -h' (or 'flutter-watchos <command> -h') for available "
      'flutter-watchos commands and options.';

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
  void printError(
    String message, {
    StackTrace? stackTrace,
    bool? emphasis,
    TerminalColor? color,
    int? indent,
    int? hangingIndent,
    bool? wrap,
  }) {
    super.printError(
      message == _stockUsageHint ? usageHint : message,
      stackTrace: stackTrace,
      emphasis: emphasis,
      color: color,
      indent: indent,
      hangingIndent: hangingIndent,
      wrap: wrap,
    );
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
