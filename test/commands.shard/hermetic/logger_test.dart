// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/executable.dart' show LoggerFactory;
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/terminal.dart';
import 'package:flutter_tools/src/commands/daemon.dart';
import 'package:flutter_watchos/watchos_logger.dart';

import '../../src/common.dart';
import '../../src/fakes.dart';

/// A `devices` line for a watch, as stock prints it.
const String _watchLine =
    'Apple Watch Series 11 (46mm) (mobile) • 4F1C2B7E • watchos • com.apple.CoreSimulator';

void main() {
  late FakeStdio stdio;

  setUp(() {
    stdio = FakeStdio();
  });

  /// The logger `main` would build for these inputs.
  Logger create({
    bool verbose = false,
    bool prefixedErrors = false,
    bool machine = false,
    bool daemon = false,
  }) {
    return createWatchosLogger(
      LoggerFactory(
        terminal: Terminal.test(),
        stdio: stdio,
        outputPreferences: OutputPreferences.test(),
      ),
      verbose: verbose,
      prefixedErrors: prefixedErrors,
      machine: machine,
      daemon: daemon,
      windows: false,
    );
  }

  group('daemon', () {
    testWithoutContext('is stock NotifyingLogger itself, with no wrapper', () {
      final Logger logger = create(daemon: true);

      expect(logger, isA<NotifyingLogger>());
      expect(asLogger<NotifyingLogger>(logger), same(logger));
    });

    testWithoutContext('with -v too', () {
      expect(create(daemon: true, verbose: true), isA<NotifyingLogger>());
    });
  });

  group('--machine', () {
    testWithoutContext('is stock MachineOutputLogger itself, so attach --machine can cast it', () {
      final Logger logger = create(machine: true);

      expect(logger, isA<MachineOutputLogger>());
      expect(() => logger as MachineOutputLogger, returnsNormally);
      expect(asLogger<MachineOutputLogger>(logger), same(logger));
    });

    testWithoutContext('prints a watch line unchanged', () {
      create(machine: true).printStatus(_watchLine);

      expect(stdio.writtenToStdout.join(), isNot(contains('(watch)')));
    });
  });

  group('people', () {
    testWithoutContext('get stock StdoutLogger inside the watch wrapper', () {
      final Logger logger = create();

      expect(logger, isA<WatchosCategoryRewritingLogger>());
      expect(asLogger<StdoutLogger>(logger), isA<StdoutLogger>());
    });

    testWithoutContext('see (watch) in the device list', () {
      create().printStatus(_watchLine);

      expect(stdio.writtenToStdout.join(), contains('Apple Watch Series 11 (46mm) (watch)  •'));
    });

    testWithoutContext('with -v get stock VerboseLogger inside the wrapper', () {
      final Logger logger = create(verbose: true);

      expect(logger, isA<WatchosCategoryRewritingLogger>());
      expect(asLogger<VerboseLogger>(logger), isA<VerboseLogger>());
    });

    testWithoutContext('with --prefixed-errors get stock prefixes on error lines', () {
      final Logger logger = create(prefixedErrors: true);

      expect(asLogger<PrefixedErrorLogger>(logger), isA<PrefixedErrorLogger>());
      logger.printError('something failed');
      expect(stdio.writtenToStderr.join(), contains('ERROR: something failed'));
    });

    testWithoutContext('without --prefixed-errors get none', () {
      create().printError('something failed');

      expect(stdio.writtenToStderr.join(), isNot(contains('ERROR:')));
    });
  });
}
