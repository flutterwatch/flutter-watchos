// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/version.dart';
import 'package:flutter_watchos/commands/channel.dart';

import '../../src/context.dart';
import '../../src/fake_process_manager.dart';
import '../../src/fakes.dart';
import '../../src/test_flutter_command_runner.dart';
import 'src/words.dart';

const String _revision = '6a19cca56475dbfba1478ee68d7bd0c2ef891da1';

void main() {
  late MemoryFileSystem fileSystem;
  late BufferLogger logger;
  late FakeProcessManager processManager;

  setUpAll(() {
    Cache.disableLocking();
  });

  setUp(() {
    fileSystem = MemoryFileSystem.test();
    logger = BufferLogger.test();
    processManager = FakeProcessManager.empty();
    Cache.flutterRoot = '/flutter-watchos/flutter';
    // The tool version is injected: a unit test never reads the real
    // pubspec, whose version depends on the commit being tested.
    fileSystem.file('/flutter-watchos/pubspec.yaml')
      ..createSync(recursive: true)
      ..writeAsStringSync('name: flutter_watchos\nversion: 9.8.7\n');
  });

  Map<Type, Generator> overrides() => <Type, Generator>{
    FileSystem: () => fileSystem,
    ProcessManager: () => processManager,
    Logger: () => logger,
    FlutterVersion: () =>
        FakeFlutterVersion(frameworkVersion: '3.47.5', frameworkRevision: _revision),
  };

  group('channel', () {
    for (final args in <List<String>>[
      <String>['channel'],
      <String>['channel', '--all'],
      <String>['channel', '-a'],
      <String>['channel', '--no-cache-artifacts'],
      <String>['channel', '--cache-artifacts'],
    ]) {
      testUsingContext('"${args.join(' ')}" prints the pin and starts no process', () async {
        await createTestCommandRunner(WatchosChannelCommand()).run(args);

        expect(
          logger.statusText,
          'flutter-watchos 9.8.7\n'
          'Flutter 3.47.5, framework revision $_revision\n'
          '\n'
          'flutter-watchos pins one Flutter commit and follows no Flutter channel.\n'
          'To move to a newer flutter-watchos release, and the Flutter it pins, run:\n'
          '  flutter-watchos upgrade\n',
        );
        expect(logger.errorText, isEmpty);
        expect(processManager, hasNoRemainingExpectations);
        expect(forbiddenWordsIn(logger.statusText), isEmpty);
      }, overrides: overrides());
    }

    testUsingContext('without a readable pubspec it still answers', () async {
      fileSystem.file('/flutter-watchos/pubspec.yaml').deleteSync();

      await createTestCommandRunner(WatchosChannelCommand()).run(<String>['channel']);

      expect(logger.statusText, startsWith('flutter-watchos (version unknown)\n'));
      expect(logger.statusText, contains('  flutter-watchos upgrade'));
    }, overrides: overrides());

    for (final args in <List<String>>[
      <String>['channel', 'stable'],
      <String>['channel', 'master'],
      <String>['channel', 'main'],
      <String>['channel', 'dev'],
      <String>['channel', '--cache-artifacts', 'stable'],
      <String>['channel', 'stable', 'main'],
    ]) {
      testUsingContext('"${args.join(' ')}" exits 1 before any process call', () async {
        Object? caught;
        try {
          await createTestCommandRunner(WatchosChannelCommand()).run(args);
        } on ToolExit catch (error) {
          caught = error;
        }

        expect(caught, isA<ToolExit>());
        final exit = caught! as ToolExit;
        expect(exit.exitCode, anyOf(isNull, 1));
        expect(exit.message, contains('Switching channels is not supported.'));
        expect(exit.message, contains('\n  flutter-watchos upgrade'));
        expect(forbiddenWordsIn(exit.message!), isEmpty);
        expect(forbiddenWordsIn(logger.statusText + logger.errorText), isEmpty);
        expect(processManager, hasNoRemainingExpectations);
      }, overrides: overrides());
    }

    testUsingContext('help describes the pin, not switching channels', () async {
      await createTestCommandRunner(WatchosChannelCommand()).run(<String>['channel', '--help']);

      expect(logger.statusText, contains('Show the Flutter version flutter-watchos pins.'));
      expect(logger.statusText, contains('flutter-watchos upgrade'));
      expect(logger.statusText, isNot(contains('switch Flutter channels')));
      expect(logger.statusText, isNot(contains('--all')));
      expect(forbiddenWordsIn(logger.statusText), isEmpty);
    }, overrides: overrides());
  });
}
