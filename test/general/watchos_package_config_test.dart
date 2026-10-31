// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_watchos/watchos_package_config.dart';

import '../src/common.dart';

void main() {
  late MemoryFileSystem fileSystem;

  setUp(() {
    fileSystem = MemoryFileSystem.test();
  });

  void writeWorkspaceRef(String memberPath, String contents) {
    fileSystem.file('$memberPath/.dart_tool/pub/workspace_ref.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(contents);
  }

  testWithoutContext('a standalone app reads its own package config', () {
    final Directory app = fileSystem.directory('/app')..createSync();
    fileSystem.file('/app/.dart_tool/package_config.json').createSync(recursive: true);

    expect(watchosPackageConfigFile(app).path, '/app/.dart_tool/package_config.json');
  });

  testWithoutContext(
    'a standalone app keeps its own path before pub get, even under another package',
    () {
      fileSystem.file('/outer/.dart_tool/package_config.json').createSync(recursive: true);
      final Directory app = fileSystem.directory('/outer/app')..createSync(recursive: true);

      expect(
        watchosPackageConfigFile(app).path,
        '/outer/app/.dart_tool/package_config.json',
      );
    },
  );

  testWithoutContext("a workspace member reads the workspace root's package config", () {
    final Directory app = fileSystem.directory('/ws/apps/watch')..createSync(recursive: true);
    writeWorkspaceRef('/ws/apps/watch', '{\n  "workspaceRoot": "../../../.."\n}\n');
    fileSystem.file('/ws/.dart_tool/package_config.json').createSync(recursive: true);

    expect(watchosPackageConfigFile(app).path, '/ws/.dart_tool/package_config.json');
  });

  testWithoutContext("a malformed workspace_ref.json falls back to the app's own path", () {
    final Directory app = fileSystem.directory('/ws/app')..createSync(recursive: true);
    writeWorkspaceRef('/ws/app', '{"root": "../../.."}');

    expect(watchosPackageConfigFile(app).path, '/ws/app/.dart_tool/package_config.json');
  });

  testWithoutContext("an unreadable workspace_ref.json falls back to the app's own path", () {
    final Directory app = fileSystem.directory('/ws/app')..createSync(recursive: true);
    writeWorkspaceRef('/ws/app', 'not json');

    expect(watchosPackageConfigFile(app).path, '/ws/app/.dart_tool/package_config.json');
  });
}
