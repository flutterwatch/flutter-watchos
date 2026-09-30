// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:file/memory.dart';
import 'package:flutter_tools/runner.dart' as runner;
import 'package:flutter_tools/src/base/exit.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/base/process.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_watchos/executable.dart';
import 'package:flutter_watchos/watchos_logger.dart';

import '../../src/common.dart';
import '../../src/context.dart';

/// Stock's hint after a usage error.
const String _stockHint =
    "Run 'flutter -h' (or 'flutter <command> -h') for available flutter commands and options.";

void main() {
  group('the usage hint', () {
    testWithoutContext('names flutter-watchos', () {
      final buffer = BufferLogger.test();
      final logger = WatchosCategoryRewritingLogger(buffer);

      logger.printError(_stockHint);

      expect(
        buffer.errorText.trim(),
        "Run 'flutter-watchos -h' (or 'flutter-watchos <command> -h') for available "
        'flutter-watchos commands and options.',
      );
    });

    testWithoutContext('other errors pass unchanged', () {
      final buffer = BufferLogger.test();
      final logger = WatchosCategoryRewritingLogger(buffer);

      logger.printError('Could not find a command named "x".');
      logger.printError("Run 'flutter -h' later.");

      expect(
        buffer.errorText,
        'Could not find a command named "x".\n'
        "Run 'flutter -h' later.\n",
      );
    });
  });

  group('flutter-watchos nosuchcommand', () {
    int? exitCode;

    setUp(() {
      exitCode = null;
      // Instead of ending the test process, record the code and stop the run.
      setExitFunctionForTests((int code) {
        exitCode ??= code;
        throw Exception('test exit');
      });
      Cache.disableLocking();
    });

    tearDown(() {
      restoreExitFunction();
      Cache.enableLocking();
    });

    testUsingContext(
      'exits 64 and the hint names flutter-watchos',
      () async {
        final buffer = BufferLogger.test();
        final completer = Completer<void>();
        unawaited(
          runZonedGuarded<Future<void>?>(
            () {
              unawaited(
                runner.run(
                  <String>['--suppress-analytics', '--no-version-check', 'nosuchcommand'],
                  () => generateWatchosCommands(verboseHelp: false, verbose: false),
                  reportCrashes: false,
                  shutdownHooks: ShutdownHooks(),
                  overrides: <Type, Generator>{
                    Logger: () => WatchosCategoryRewritingLogger(buffer),
                  },
                ),
              );
              return null;
            },
            (Object error, StackTrace stack) {
              if (!completer.isCompleted) {
                completer.complete();
              }
            },
          ),
        );
        await completer.future;

        expect(exitCode, 64);
        expect(buffer.errorText, contains('Could not find a command named "nosuchcommand".'));
        expect(buffer.errorText, contains(WatchosCategoryRewritingLogger.usageHint));
        expect(buffer.errorText, isNot(contains("'flutter -h'")));
      },
      overrides: <Type, Generator>{
        FileSystem: () => MemoryFileSystem.test(),
        ProcessManager: () => FakeProcessManager.any(),
        Platform: () => FakePlatform(environment: <String, String>{'FLUTTER_ROOT': '/'}),
      },
    );
  });
}
