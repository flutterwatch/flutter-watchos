// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_watchos/watchos_mode_guidance.dart';

import '../commands.shard/hermetic/src/words.dart';
import '../src/common.dart';

const String _udid = '4F1C2B7E-0000-4000-8000-00000000A11E';

/// Options that take a value, which is then the next word.
const Set<String> _optionsWithValue = <String>{'-d', '--debug-url'};

/// Why [line], an offered command line, is not a bare command, or null when
/// it is: `flutter-watchos`, a command (and `watchos` after `build`), then
/// options, each option in [_optionsWithValue] followed by one value. A
/// value may be a placeholder such as `<watch>`. No `#`, no parentheses, no
/// doubled space, and no word after the last argument.
String? _notBare(String line) {
  if (!line.startsWith('  flutter-watchos ')) {
    return 'does not start with the command';
  }
  final String command = line.substring(2);
  if (command.contains('#') || command.contains('(') || command.contains(')')) {
    return 'has a comment or parentheses';
  }
  if (command.contains('  ') || command != command.trim()) {
    return 'has extra spaces';
  }
  final List<String> words = command.split(' ');
  var i = 1;
  if (!const <String>{'build', 'run', 'drive', 'attach'}.contains(words[i])) {
    return 'names no command';
  }
  if (words[i++] == 'build' && (i >= words.length || words[i++] != 'watchos')) {
    return 'builds something other than watchos';
  }
  while (i < words.length) {
    final String word = words[i++];
    if (!RegExp(r'^--?[a-z][a-z-]*$').hasMatch(word)) {
      return 'has "$word" after its arguments';
    }
    if (_optionsWithValue.contains(word)) {
      if (i >= words.length || words[i].startsWith('-')) {
        return '$word has no value';
      }
      i++;
    }
  }
  return null;
}

void main() {
  group('watchosTargetRunsMode', () {
    test('the Simulator runs debug only', () {
      expect(watchosTargetRunsMode(BuildMode.debug, simulator: true), isTrue);
      for (final mode in <BuildMode>[BuildMode.profile, BuildMode.release, BuildMode.jitRelease]) {
        expect(watchosTargetRunsMode(mode, simulator: true), isFalse, reason: mode.cliName);
      }
    });

    test('a physical watch runs profile and release only', () {
      expect(watchosTargetRunsMode(BuildMode.profile, simulator: false), isTrue);
      expect(watchosTargetRunsMode(BuildMode.release, simulator: false), isTrue);
      expect(watchosTargetRunsMode(BuildMode.debug, simulator: false), isFalse);
      expect(watchosTargetRunsMode(BuildMode.jitRelease, simulator: false), isFalse);
    });
  });

  group('watchosModeRefusal', () {
    test('is null for every mode the target runs', () {
      for (final WatchosModeCommand command in WatchosModeCommand.values) {
        expect(
          watchosModeRefusal(command: command, mode: BuildMode.debug, simulator: true),
          isNull,
        );
        for (final mode in <BuildMode>[BuildMode.profile, BuildMode.release]) {
          expect(watchosModeRefusal(command: command, mode: mode, simulator: false), isNull);
        }
      }
    });

    for (final WatchosModeCommand command in WatchosModeCommand.values) {
      for (final simulator in <bool>[true, false]) {
        for (final BuildMode mode in BuildMode.values) {
          if (watchosTargetRunsMode(mode, simulator: simulator)) {
            continue;
          }
          final target = simulator ? 'the Simulator' : 'a physical watch';
          test('${command.name}, ${mode.cliName} on $target: bare command lines', () {
            final String? refusal = watchosModeRefusal(
              command: command,
              mode: mode,
              simulator: simulator,
              deviceId: _udid,
            );

            expect(refusal, isNotNull);
            final List<String> lines = refusal!.split('\n');
            final List<String> commandLines = lines
                .where((String line) => line.startsWith('  '))
                .toList();
            expect(commandLines, isNotEmpty);
            for (final line in commandLines) {
              expect(_notBare(line), isNull, reason: line);
            }
            // Each command has what it is for on the line above.
            for (var i = 0; i < lines.length; i++) {
              if (lines[i].startsWith('  ')) {
                expect(i, greaterThan(0));
                expect(lines[i - 1], anyOf(endsWith(':'), startsWith('  ')), reason: lines[i]);
              }
            }
            expect(forbiddenWordsIn(refusal), isEmpty);
          });
        }
      }
    }

    test('build on the Simulator names the mode and the three builds', () {
      expect(
        watchosModeRefusal(
          command: WatchosModeCommand.build,
          mode: BuildMode.release,
          simulator: true,
        ),
        '--release is not supported with --simulator: the watchOS Simulator engine '
        'is JIT-only, so Simulator builds are always debug. AOT (profile and release) '
        'builds target a physical watch.\n'
        'To build for the Simulator, in debug:\n'
        '  flutter-watchos build watchos --simulator\n'
        'To build for a physical watch, with logging and DevTools:\n'
        '  flutter-watchos build watchos --profile\n'
        'To build for a physical watch, for the App Store:\n'
        '  flutter-watchos build watchos --release',
      );
    });

    test('build in debug for a physical watch says why', () {
      expect(
        watchosModeRefusal(
          command: WatchosModeCommand.build,
          mode: BuildMode.debug,
          simulator: false,
        ),
        startsWith(
          'Debug mode is not supported on a physical Apple Watch: it needs a JIT '
          'engine, which cannot be built for watchOS',
        ),
      );
    });

    test('run and drive name the device they were given', () {
      for (final command in <WatchosModeCommand>[
        WatchosModeCommand.run,
        WatchosModeCommand.drive,
      ]) {
        final String verb = command.name;
        expect(
          watchosModeRefusal(
            command: command,
            mode: BuildMode.profile,
            simulator: true,
            deviceId: _udid,
          ),
          endsWith(
            'To $verb in debug on this Simulator:\n'
            '  flutter-watchos $verb -d $_udid\n'
            'To $verb with --profile on a physical watch:\n'
            '  flutter-watchos $verb -d <watch> --profile',
          ),
        );
        expect(
          watchosModeRefusal(
            command: command,
            mode: BuildMode.debug,
            simulator: false,
            deviceId: _udid,
          ),
          contains(
            'To $verb on this watch with logging and DevTools:\n'
            '  flutter-watchos $verb -d $_udid --profile\n',
          ),
        );
      }
    });

    test('--jit-release on the Simulator points to --release on a watch', () {
      final String? refusal = watchosModeRefusal(
        command: WatchosModeCommand.run,
        mode: BuildMode.jitRelease,
        simulator: true,
        deviceId: _udid,
      );

      expect(refusal, startsWith('--jit-release is not supported on the watchOS Simulator'));
      expect(refusal, endsWith('  flutter-watchos run -d <watch> --release'));
    });

    test('attach on a physical watch points to run --profile', () {
      expect(
        watchosModeRefusal(
          command: WatchosModeCommand.attach,
          mode: BuildMode.debug,
          simulator: false,
          deviceId: _udid,
        ),
        endsWith(
          'To start the app on this watch and get a DevTools link to open:\n'
          '  flutter-watchos run -d $_udid --profile\n'
          'For hot reload, attach on the watchOS Simulator, where debug works:\n'
          '  flutter-watchos attach -d <simulator>',
        ),
      );
    });

    test('attach on a physical watch with no URL: bare lines, same choices', () {
      final String refusal = watchosAttachWatchRefusal(deviceId: _udid);

      expect(
        refusal,
        'attach cannot find an app on a physical Apple Watch by itself.\n'
        'To start the app on this watch and get a DevTools link to open:\n'
        '  flutter-watchos run -d $_udid --profile\n'
        'For hot reload, attach on the watchOS Simulator, where debug works:\n'
        '  flutter-watchos attach -d <simulator>',
      );
      for (final String line in refusal.split('\n').where((String l) => l.startsWith('  '))) {
        expect(_notBare(line), isNull, reason: line);
      }
      expect(forbiddenWordsIn(refusal), isEmpty);
      expect(watchosAttachWatchRefusal(), contains('  flutter-watchos run -d <watch> --profile\n'));
    });

    test('the bare-command check catches what it must', () {
      expect(_notBare('  flutter-watchos run -d X --profile   # AOT'), isNotNull);
      expect(_notBare('  flutter-watchos run -d X --profile fastest'), isNotNull);
      expect(_notBare('  flutter-watchos build watchos --simulator (debug)'), isNotNull);
      expect(_notBare('  flutter-watchos run -d'), isNotNull);
      expect(_notBare('  flutter-watchos run -d <watch> --release'), isNull);
    });
  });
}
