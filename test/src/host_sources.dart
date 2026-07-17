// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io' as io;

/// Locates a file by walking up from the current directory (tests may run
/// from the package root or a workspace root) and appending [relativePath].
String _readFromCliRoot(String relativePath) {
  io.Directory dir = io.Directory.current.absolute;
  while (true) {
    final candidate = io.File('${dir.path}/$relativePath');
    if (candidate.existsSync()) {
      return candidate.readAsStringSync();
    }
    final io.Directory parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('Could not find: $relativePath');
    }
    dir = parent;
  }
}

/// Reads a source of the FlutterWatchOS host module (the CLI-compiled runner
/// glue) from the CLI's `host/` directory — e.g. `FlutterRunner.swift`,
/// `FlutterHostView.swift`, `flutter_watchos_host.h`.
String readHostSource(String fileName) => _readFromCliRoot('host/$fileName');

/// Reads a file from the watchOS Runner app template.
String readRunnerTemplate(String fileName) =>
    _readFromCliRoot('templates/app/swift/watchos.tmpl/Runner/$fileName');
