// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_watchos/commands/test.dart';

import '../../src/common.dart';
import '../../src/context.dart';
import '../../src/test_flutter_command_runner.dart';
import 'src/watch_project.dart';

void main() {
  late MemoryFileSystem fileSystem;
  late BufferLogger logger;

  setUpAll(() {
    Cache.disableLocking();
  });

  setUp(() {
    fileSystem = MemoryFileSystem.test();
    logger = BufferLogger.test();
    writeWatchProject(fileSystem);
  });

  Map<Type, Generator> overrides() => <Type, Generator>{
    FileSystem: () => fileSystem,
    ProcessManager: () => FakeProcessManager.empty(),
    Logger: () => logger,
    Cache: () => Cache.test(processManager: FakeProcessManager.empty()),
  };

  testUsingContext("runs the watch tooling check, then stock's checks", () async {
    await expectLater(
      createTestCommandRunner(
        WatchosTestCommand(verboseHelp: false),
      ).run(<String>['test', '--no-pub', 'test/missing_test.dart']),
      throwsToolExit(message: 'cannot run without a dependency on either'),
    );

    // The tooling check wrote the watch plugin registrant before stock
    // stopped on the pubspec, which has no test dependency.
    expect(
      fileSystem.file('/project/watchos/Flutter/GeneratedPluginRegistrant.swift').existsSync(),
      isTrue,
    );
  }, overrides: overrides());
}
