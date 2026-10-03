// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_watchos/commands/downgrade.dart';

import '../../src/context.dart';
import '../../src/fake_process_manager.dart';
import '../../src/test_flutter_command_runner.dart';
import 'src/words.dart';

void main() {
  late BufferLogger logger;
  late FakeProcessManager processManager;

  setUpAll(() {
    Cache.disableLocking();
  });

  setUp(() {
    logger = BufferLogger.test();
    processManager = FakeProcessManager.empty();
  });

  Map<Type, Generator> overrides() => <Type, Generator>{
    FileSystem: () => MemoryFileSystem.test(),
    ProcessManager: () => processManager,
    Logger: () => logger,
  };

  group('downgrade', () {
    for (final args in <List<String>>[
      <String>['downgrade'],
      <String>['downgrade', '--no-prompt'],
      <String>['downgrade', '--working-directory', '/elsewhere'],
      <String>['downgrade', '3.44.0'],
    ]) {
      testUsingContext('"${args.join(' ')}" exits 1 before any process call', () async {
        Object? caught;
        try {
          await createTestCommandRunner(WatchosDowngradeCommand()).run(args);
        } on ToolExit catch (error) {
          caught = error;
        }

        expect(caught, isA<ToolExit>());
        final exit = caught! as ToolExit;
        expect(exit.exitCode, anyOf(isNull, 1));
        expect(exit.message, contains('Downgrading is not supported.'));
        expect(exit.message, contains('follows no Flutter channel'));
        expect(exit.message, contains('\n  flutter-watchos upgrade'));
        expect(exit.message, isNot(contains('flutter channel')));
        expect(exit.message, isNot(contains('checkout')));
        expect(forbiddenWordsIn(exit.message!), isEmpty);
        expect(processManager, hasNoRemainingExpectations);
      }, overrides: overrides());
    }

    testUsingContext('help says it is not supported and names upgrade', () async {
      await createTestCommandRunner(WatchosDowngradeCommand()).run(<String>['downgrade', '--help']);

      expect(
        logger.statusText,
        contains('Not supported: flutter-watchos pins its Flutter version.'),
      );
      expect(logger.statusText, contains('flutter-watchos upgrade'));
      expect(logger.statusText, isNot(contains('last active version')));
      expect(forbiddenWordsIn(logger.statusText), isEmpty);
    }, overrides: overrides());
  });
}
