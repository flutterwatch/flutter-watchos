// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// The log entrypoint that tool/safe_area/run_matrix.sh adds to a created app.
//
// A created app's lib/, test/ and pubspec.yaml stay exactly as
// `flutter-watchos create --platforms=watchos` wrote them. This file, copied to
// `safe_area_log/main.dart` in the app, runs the app's own main() and prints
// a SAFEAREA| line in the probe's format on the first frame and on every
// metrics change, so tool/safe_area/check_insets.sh can check the app's insets.
// It draws nothing, so a screenshot shows the app as `create` made it.
//
// The harness creates the app as `safe_area_app`, the package imported below,
// and builds it with:
//
//   flutter-watchos build watchos --simulator -t safe_area_log/main.dart \
//       --dart-define=MODE=<platform|corners>
//
// The values come from MediaQueryData.fromView on the app's view: the data
// the root MediaQuery holds. The line has no band=, because a created app does
// not depend on package:flutter_watchos.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:safe_area_app/main.dart' as app;

const String _mode = String.fromEnvironment('MODE');

void main() {
  app.main();
  final WidgetsBinding binding = WidgetsBinding.instance;
  final logger = _SafeAreaLogger(binding);
  binding.addObserver(logger);
  binding.addPostFrameCallback((Duration _) => logger.log());
}

/// Prints one SAFEAREA| line whenever the view's metrics change.
class _SafeAreaLogger with WidgetsBindingObserver {
  _SafeAreaLogger(this.binding);

  final WidgetsBinding binding;
  String? _last;

  @override
  void didChangeMetrics() => log();

  void log() {
    final ui.FlutterView view =
        binding.platformDispatcher.implicitView ?? binding.platformDispatcher.views.first;
    final mq = MediaQueryData.fromView(view);
    final line =
        'SAFEAREA|dev=${_dev()}|mode=$_mode|page=app'
        '|size=${mq.size.width.toStringAsFixed(2)}x${mq.size.height.toStringAsFixed(2)}'
        '|dpr=${mq.devicePixelRatio}'
        '|physical=${view.physicalSize.width}x${view.physicalSize.height}'
        '|padding=${_ei(mq.padding)}'
        '|viewPadding=${_ei(mq.viewPadding)}'
        '|viewInsets=${_ei(mq.viewInsets)}'
        '|systemGestureInsets=${_ei(mq.systemGestureInsets)}'
        '|displayFeatures=${mq.displayFeatures}'
        '|textScale=${mq.textScaler.scale(10) / 10}'
        '|display=${view.display.size.width}x${view.display.size.height}'
        '@${view.display.devicePixelRatio}';
    if (line != _last) {
      _last = line;
      // ignore: avoid_print
      print(line);
    }
  }
}

String _ei(EdgeInsets e) =>
    'L${e.left.toStringAsFixed(2)},T${e.top.toStringAsFixed(2)},'
    'R${e.right.toStringAsFixed(2)},B${e.bottom.toStringAsFixed(2)}';

/// The simulator's label, from the file the harness writes into the app's
/// data container (Dart's Platform.environment is empty under this embedder).
String _dev() {
  try {
    final f = File('${Directory.systemTemp.parent.path}/Documents/saprobe_DEV.txt');
    if (f.existsSync()) {
      return f.readAsStringSync().trim();
    }
  } on FileSystemException {
    // No file: unnamed.
  }
  return '?';
}
