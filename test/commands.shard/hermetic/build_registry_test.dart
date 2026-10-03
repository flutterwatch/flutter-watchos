// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';

import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_watchos/commands/build_registry.dart';

import '../../src/context.dart';
import '../../src/test_flutter_command_runner.dart';
import 'src/words.dart';

const String _home = '/home/user';

/// The command lines `build-registry` offers to paste, in order.
const List<String> _commandLines = <String>[
  '  flutter-watchos build-registry --disable',
  '  export FLUTTER_WATCHOS_BUILD_REGISTRY=0',
  '  flutter-watchos build watchos --release --no-register-build',
];

void main() {
  late MemoryFileSystem fileSystem;
  late BufferLogger logger;

  setUpAll(() {
    Cache.disableLocking();
  });

  setUp(() {
    fileSystem = MemoryFileSystem.test();
    logger = BufferLogger.test();
  });

  File settings() => fileSystem.file('$_home/.flutter-watchos/settings.json');

  Object? savedSetting() {
    if (!settings().existsSync()) {
      return null;
    }
    return (json.decode(settings().readAsStringSync()) as Map<String, Object?>)['build_registry'];
  }

  /// Runs `build-registry` with [args] and returns what it printed.
  Future<String> run(List<String> args) async {
    await createTestCommandRunner(
      WatchosBuildRegistryCommand(),
    ).run(<String>['build-registry', ...args]);
    return logger.statusText;
  }

  /// Every printed line that offers a command, in order.
  List<String> offeredCommands(String output) => output
      .split('\n')
      .where((String line) => line.startsWith('  flutter-watchos ') || line.startsWith('  export '))
      .toList();

  Map<Type, Generator> overrides({Map<String, String> environment = const <String, String>{}}) =>
      <Type, Generator>{
        FileSystem: () => fileSystem,
        ProcessManager: () => FakeProcessManager.empty(),
        Platform: () => FakePlatform(environment: <String, String>{'HOME': _home, ...environment}),
        Logger: () => logger,
      };

  group('build-registry', () {
    testUsingContext('with no flag shows the state and the three ways to turn it off', () async {
      final String output = await run(<String>[]);

      expect(output, startsWith('Build registry: on.\n'));
      expect(offeredCommands(output), _commandLines);
      expect(
        output,
        contains(
          'To turn it off on this machine:\n'
          '${_commandLines[0]}\n'
          "For this shell only (on CI, set the variable in the job's environment):\n"
          '${_commandLines[1]}\n'
          'For one build:\n'
          '${_commandLines[2]}\n',
        ),
      );
      expect(savedSetting(), isNull);
    }, overrides: overrides());

    testUsingContext('no line starts with the bare variable assignment', () async {
      final String output = await run(<String>[]);

      for (final String line in output.split('\n')) {
        expect(line.trimLeft(), isNot(startsWith('FLUTTER_WATCHOS_BUILD_REGISTRY=')), reason: line);
      }
      expect(forbiddenWordsIn(output), isEmpty);
    }, overrides: overrides());

    testUsingContext('--disable saves the setting and says it is off', () async {
      final String output = await run(<String>['--disable']);

      expect(output, startsWith('Build registry: off.\n'));
      expect(savedSetting(), isFalse);
      expect(offeredCommands(output), _commandLines);
    }, overrides: overrides());

    testUsingContext('--enable saves the setting and says it is on', () async {
      settings()
        ..createSync(recursive: true)
        ..writeAsStringSync('{"build_registry": false}');

      final String output = await run(<String>['--enable']);

      expect(output, startsWith('Build registry: on.\n'));
      expect(savedSetting(), isTrue);
      expect(offeredCommands(output), _commandLines);
    }, overrides: overrides());

    testUsingContext('the environment variable wins over --enable', () async {
      final String output = await run(<String>['--enable']);

      expect(
        output,
        startsWith(
          'Build registry: off for this shell (FLUTTER_WATCHOS_BUILD_REGISTRY is set)'
          ' — the saved setting is now on, but the environment variable wins.\n',
        ),
      );
      expect(savedSetting(), isTrue);
      expect(offeredCommands(output), _commandLines);
    }, overrides: overrides(environment: <String, String>{'FLUTTER_WATCHOS_BUILD_REGISTRY': '0'}));

    testUsingContext('--enable with --disable fails and changes nothing', () async {
      await run(<String>['--enable', '--disable']);

      expect(logger.errorText, contains('Pass either --enable or --disable, not both.'));
      expect(logger.statusText, isEmpty);
      expect(savedSetting(), isNull);
    }, overrides: overrides());
  });
}
