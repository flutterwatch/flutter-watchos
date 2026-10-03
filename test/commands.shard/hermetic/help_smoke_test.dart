// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/memory.dart';
import 'package:flutter_tools/executable.dart' as stock;
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/runner/flutter_command.dart';
import 'package:flutter_tools/src/runner/flutter_command_runner.dart';
import 'package:flutter_watchos/executable.dart';

import '../../src/common.dart';
import '../../src/context.dart';
import '../../src/test_flutter_command_runner.dart';
import 'src/words.dart';

/// Every name flutter-watchos registers, `-h` or not. A command added or
/// dropped changes this list on purpose.
const List<String> _registered = <String>[
  'analyze',
  'assemble',
  'attach',
  'bash-completion',
  'build',
  'build-registry',
  'channel',
  'clean',
  'config',
  'create',
  'daemon',
  'debug-adapter',
  'devices',
  'doctor',
  'downgrade',
  'drive',
  'emulators',
  'gen-l10n',
  'generate',
  'host',
  'install',
  'login',
  'logout',
  'logs',
  'plugin',
  'precache',
  'pub',
  'run',
  'screenshot',
  'symbolize',
  'test',
  'upgrade',
  'upload',
];

/// The commands whose `-v --help` shows more options, which is checked too.
const List<String> _verboseHelpCommands = <String>['run', 'drive', 'attach', 'test'];

Set<String> _names(Iterable<FlutterCommand> commands) =>
    commands.map((FlutterCommand command) => command.name).toSet();

FlutterCommandRunner _runner({required bool verboseHelp}) {
  final runner = FlutterCommandRunner(verboseHelp: verboseHelp);
  generateWatchosCommands(
    verboseHelp: verboseHelp,
    verbose: verboseHelp,
  ).forEach(runner.addCommand);
  return runner;
}

void main() {
  setUpAll(() {
    Cache.disableLocking();
  });

  Map<Type, Generator> overrides() => <Type, Generator>{
    FileSystem: () => MemoryFileSystem.test(),
    ProcessManager: () => FakeProcessManager.empty(),
  };

  group('the command list', () {
    testUsingContext('is pinned', () {
      final List<String> names = _names(
        generateWatchosCommands(verboseHelp: false, verbose: false),
      ).toList()..sort();

      expect(names, _registered);
    }, overrides: overrides());

    testUsingContext('-h lists analyze', () {
      expect(_runner(verboseHelp: false).usage, contains('\n  analyze '));
    }, overrides: overrides());

    testUsingContext('-h -v lists neither update-packages nor upgrade-packages', () {
      final String usage = _runner(verboseHelp: true).usage;

      expect(usage, contains('\n  analyze '));
      expect(usage, isNot(contains('update-packages')));
      expect(usage, isNot(contains('upgrade-packages')));
    }, overrides: overrides());

    testUsingContext('leaves out exactly the four stock commands with no use here', () {
      final List<FlutterCommand> stockCommands = stock.generateCommands(
        verboseHelp: true,
        verbose: false,
      );
      final Set<String> left = _names(
        stockCommands,
      ).difference(_names(generateWatchosCommands(verboseHelp: true, verbose: false)));

      // The fourth shows widgets in a browser; the list names it only by
      // leaving it out.
      expect(left, containsAll(<String>['custom-devices', 'ide-config', 'update-packages']));
      expect(left, hasLength(4));
    }, overrides: overrides());

    testUsingContext('typing a command that is left out, or its alias, is a usage error', () async {
      final List<FlutterCommand> stockCommands = stock.generateCommands(
        verboseHelp: true,
        verbose: false,
      );
      final Set<String> ours = _names(generateWatchosCommands(verboseHelp: true, verbose: false));
      final typed = <String>[
        for (final FlutterCommand command in stockCommands)
          if (!ours.contains(command.name)) ...<String>[command.name, ...command.aliases],
      ];
      expect(typed, contains('upgrade-packages'));

      for (final name in typed) {
        final FlutterCommandRunner runner = _runner(verboseHelp: false);
        await expectLater(
          runner.run(<String>[name]),
          throwsUsageException(message: 'Could not find a command named "$name".'),
          reason: name,
        );
      }
    }, overrides: overrides());
  });

  group('help', () {
    late BufferLogger logger;

    setUp(() {
      logger = BufferLogger.test();
    });

    Map<Type, Generator> helpOverrides() => <Type, Generator>{
      FileSystem: () => MemoryFileSystem.test(),
      ProcessManager: () => FakeProcessManager.empty(),
      Logger: () => logger,
    };

    /// Runs `<name> --help`, with `-v` when [verboseHelp], through the
    /// command runner, and returns what it printed.
    Future<String> help(String name, {required bool verboseHelp}) async {
      final FlutterCommand command = generateWatchosCommands(
        verboseHelp: verboseHelp,
        verbose: verboseHelp,
      ).singleWhere((FlutterCommand command) => command.name == name);
      await createTestCommandRunner(command).run(<String>[if (verboseHelp) '-v', name, '--help']);
      return logger.statusText;
    }

    for (final String name in _registered) {
      for (final verboseHelp in <bool>[false, if (_verboseHelpCommands.contains(name)) true]) {
        final flags = verboseHelp ? '-v --help' : '--help';

        testUsingContext('$name $flags exits 0 and prints its usage', () async {
          final String output = await help(name, verboseHelp: verboseHelp);

          expect(output, contains('Usage: '));
          expect(logger.errorText, isEmpty);
        }, overrides: helpOverrides());

        testUsingContext('$name $flags has no forbidden word', () async {
          expect(forbiddenWordsIn(await help(name, verboseHelp: verboseHelp)), isEmpty);
        }, overrides: helpOverrides());
      }
    }
  });
}
