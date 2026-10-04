// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/commands/run.dart';
import 'package:flutter_tools/src/runner/flutter_command.dart';
import 'package:flutter_watchos/commands/port_help.dart';
import 'package:flutter_watchos/executable.dart';

import '../../src/context.dart';
import '../../src/test_flutter_command_runner.dart';
import 'src/words.dart';

/// The commands whose help has stock's port options.
const List<String> _portCommands = <String>['run', 'drive', 'attach', 'debug-adapter', 'test'];

/// The commands whose only port option is `--dds-port`.
const Set<String> _ddsPortOnly = <String>{'debug-adapter', 'test'};

/// The phrases each command's help has; `debug-adapter` and `test` have only
/// `--dds-port`.
const Map<String, List<String>> _phrases = <String, List<String>>{
  'run': <String>['random unused port', 'random unused host port'],
  'drive': <String>['random unused port', 'random unused host port'],
  'attach': <String>['random unused port', 'random unused host port'],
  'debug-adapter': <String>['random unused port'],
  'test': <String>['random unused port'],
};

void main() {
  late BufferLogger logger;

  setUpAll(() {
    Cache.disableLocking();
  });

  setUp(() {
    logger = BufferLogger.test();
  });

  Map<Type, Generator> overrides() => <Type, Generator>{
    FileSystem: () => MemoryFileSystem.test(),
    ProcessManager: () => FakeProcessManager.empty(),
    Logger: () => logger,
  };

  FlutterCommand command(String name, {required bool verboseHelp}) => generateWatchosCommands(
    verboseHelp: verboseHelp,
    verbose: verboseHelp,
  ).singleWhere((FlutterCommand command) => command.name == name);

  group('rewordStockPortHelp', () {
    testUsingContext('rewords the help of each stock port option', () {
      final stock = RunCommand(verboseHelp: true);
      for (final (String option, String phrase) in <(String, String)>[
        ('dds-port', 'random unused port'),
        ('vm-service-port', 'random unused port'),
        ('host-vmservice-port', 'random unused host port'),
      ]) {
        final String help = stock.argParser.options[option]!.help!;
        expect(forbiddenWordsIn(help), isNotEmpty, reason: '$option: stock text changed');

        final String reworded = rewordStockPortHelp(help);
        expect(reworded, contains(phrase), reason: option);
        expect(forbiddenWordsIn(reworded), isEmpty, reason: option);
      }
    }, overrides: overrides());

    testUsingContext('rewords wrapped help, and leaves other text alone', () {
      final String help = RunCommand().argParser.options['dds-port']!.help!;
      final String wrapped = help.replaceAll(' ', '\n        ');

      expect(forbiddenWordsIn(rewordStockPortHelp(wrapped)), isEmpty);
      expect(rewordStockPortHelp('a random host port'), 'a random host port');
      expect(rewordStockPortHelp('a random unused port'), 'a random unused port');
      expect(rewordStockPortHelp('no port here'), 'no port here');
    }, overrides: overrides());
  });

  for (final String name in _portCommands) {
    for (final verboseHelp in <bool>[false, true]) {
      final flags = verboseHelp ? '-v --help' : '--help';

      testUsingContext('$name $flags says random unused port', () async {
        await createTestCommandRunner(
          command(name, verboseHelp: verboseHelp),
        ).run(<String>[if (verboseHelp) '-v', name, '--help']);

        for (final String phrase in _phrases[name]!) {
          expect(logger.statusText, contains(phrase));
        }
        expect(forbiddenWordsIn(logger.statusText), isEmpty);
      }, overrides: overrides());
    }

    testUsingContext('$name keeps stock port options; only the printed help changes', () {
      final FlutterCommand ours = command(name, verboseHelp: true);
      final stock = RunCommand(verboseHelp: true);

      expect(ours, isA<UnusedPortHelp>());
      for (final option in <String>[
        'dds-port',
        if (!_ddsPortOnly.contains(name)) 'host-vmservice-port',
      ]) {
        expect(
          ours.argParser.options[option]!.help,
          stock.argParser.options[option]!.help,
          reason: option,
        );
      }
    }, overrides: overrides());
  }
}
