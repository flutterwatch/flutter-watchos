// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:file/memory.dart';
import 'package:flutter_tools/src/application_package.dart';
import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/io.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/device.dart';
import 'package:flutter_tools/src/runner/flutter_command.dart';
import 'package:flutter_watchos/commands/logs.dart';
import 'package:flutter_watchos/executable.dart';
import 'package:flutter_watchos/watchos_device.dart';
import 'package:test/fake.dart';

import '../src/common.dart';
import '../src/context.dart';
import '../src/fake_process_manager.dart';
import '../src/test_flutter_command_runner.dart';

// `logs` on a watch: a Simulator streams through stock's command, and a
// physical watch is refused with guidance before anything runs (spec 0005
// criteria 18-19).

class _FakeProcessSignal extends Fake implements ProcessSignal {
  final _controller = StreamController<ProcessSignal>();

  @override
  Stream<ProcessSignal> watch() => _controller.stream;

  @override
  bool send(int pid) {
    _controller.add(this);
    return true;
  }
}

class _NoPackages extends Fake implements ApplicationPackageFactory {
  @override
  Future<ApplicationPackage?> getPackageForPlatform(
    TargetPlatform platform, {
    BuildInfo? buildInfo,
    File? applicationBinary,
  }) async => null;
}

void main() {
  late FakeDeviceManager deviceManager;
  late FakeProcessManager processManager;
  late BufferLogger logger;

  setUp(() {
    Cache.disableLocking();
    deviceManager = FakeDeviceManager();
    processManager = FakeProcessManager.empty();
    logger = BufferLogger.test();
  });

  tearDown(Cache.enableLocking);

  testUsingContext(
    'logs is the watch command, with stock name and options',
    () {
      final FlutterCommand logs = generateWatchosCommands(
        verboseHelp: false,
        verbose: false,
      ).singleWhere((FlutterCommand command) => command.name == 'logs');

      expect(logs, isA<WatchosLogsCommand>());
      expect(logs.argParser.options.keys, contains('clear'));
    },
    overrides: <Type, Generator>{
      FileSystem: () => MemoryFileSystem.test(),
      DeviceManager: () => deviceManager,
      ProcessManager: () => processManager,
      Cache: () => Cache.test(processManager: FakeProcessManager.empty()),
    },
  );

  testWithoutContext('the watch guidance offers bare commands, each alone on its line', () {
    final String guidance = WatchosLogsCommand.physicalWatchGuidance('watch-1');

    // The docs URL names a heading; nothing else may hold a `#`.
    expect(
      guidance.replaceAll(WatchosLogsCommand.physicalWatchLogsDocUrl, ''),
      isNot(contains('#')),
    );
    expect(guidance.split('\n').where((String line) => line.startsWith('  ')), <String>[
      '  flutter-watchos run -d watch-1 --profile',
    ]);
    expect(guidance, contains(WatchosLogsCommand.physicalWatchLogsDocUrl));
  });

  testUsingContext(
    'logs -d <watch> exits non-zero with the guidance, and runs nothing',
    () async {
      deviceManager.attachedDevices.add(
        WatchosDevice('watch-1', name: 'My Watch', logger: logger, isSimulator: false),
      );
      final command = WatchosLogsCommand(
        sigint: _FakeProcessSignal(),
        sigterm: _FakeProcessSignal(),
      );

      await expectLater(
        createTestCommandRunner(command).run(<String>['logs', '-d', 'watch-1']),
        throwsA(
          isA<ToolExit>()
              .having((ToolExit e) => e.exitCode, 'exitCode', anyOf(isNull, 1))
              .having(
                (ToolExit e) => e.message,
                'message',
                allOf(
                  contains('logs cannot read a physical Apple Watch'),
                  contains('flutter-watchos run -d watch-1 --profile'),
                  contains('--watchos-log-to-file'),
                ),
              ),
        ),
      );
      expect(processManager, hasNoRemainingExpectations);
    },
    overrides: <Type, Generator>{
      DeviceManager: () => deviceManager,
      ProcessManager: () => processManager,
      ApplicationPackageFactory: () => _NoPackages(),
      Platform: () => FakePlatform(),
    },
  );

  testUsingContext(
    'logs -d <simulator> names the device and starts the log stream',
    () async {
      processManager.addCommand(
        const FakeCommand(
          command: <String>[
            'xcrun',
            'simctl',
            'spawn',
            'sim-1',
            'log',
            'stream',
            '--style',
            'json',
            '--predicate',
            WatchosSimulatorLogReader.predicate,
          ],
          stdout:
              'Filtering the log data using "eventType = logEvent"\n'
              '  "eventMessage" : "[flutter:flutter] SUITE_MARK_PRINT",\n',
        ),
      );
      deviceManager.attachedDevices.add(
        WatchosDevice(
          'sim-1',
          name: 'Apple Watch Series 11 (46mm)',
          logger: logger,
          isSimulator: true,
        ),
      );
      final sigint = _FakeProcessSignal();
      final command = WatchosLogsCommand(sigint: sigint, sigterm: _FakeProcessSignal());

      final Future<void> run = createTestCommandRunner(
        command,
      ).run(<String>['logs', '-d', 'sim-1']);
      await pumpEventQueue(times: 10);
      sigint.send(1);
      await run;

      expect(testLogger.statusText, contains('Showing Apple Watch Series 11 (46mm) logs:'));
      expect(testLogger.statusText, contains('flutter: SUITE_MARK_PRINT'));
      expect(processManager, hasNoRemainingExpectations);
    },
    overrides: <Type, Generator>{
      DeviceManager: () => deviceManager,
      ProcessManager: () => processManager,
      ApplicationPackageFactory: () => _NoPackages(),
      Platform: () => FakePlatform(),
    },
  );

  testUsingContext(
    'logs -d <UDID> of a shut-down Simulator exits at once, and says run boots it',
    () async {
      deviceManager.attachedDevices.add(
        WatchosDevice(
          'AAAA-BBBB-CCCC',
          name: 'Apple Watch Ultra 3',
          logger: logger,
          isSimulator: true,
          isShutDown: true,
        ),
      );
      final command = WatchosLogsCommand(
        sigint: _FakeProcessSignal(),
        sigterm: _FakeProcessSignal(),
      );

      await expectLater(
        createTestCommandRunner(command).run(<String>['logs', '-d', 'AAAA-BBBB-CCCC']),
        throwsA(
          isA<ToolExit>().having(
            (ToolExit e) => e.message,
            'message',
            allOf(
              contains('Apple Watch Ultra 3 (AAAA-BBBB-CCCC) is shut down'),
              contains('flutter-watchos run -d AAAA-BBBB-CCCC'),
            ),
          ),
        ),
      );
      expect(processManager, hasNoRemainingExpectations);
    },
    overrides: <Type, Generator>{
      DeviceManager: () => deviceManager,
      ProcessManager: () => processManager,
      ApplicationPackageFactory: () => _NoPackages(),
      Platform: () => FakePlatform(),
    },
  );
}
