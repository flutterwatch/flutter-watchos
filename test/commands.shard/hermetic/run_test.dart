// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/device.dart';
import 'package:flutter_tools/src/runner/flutter_command.dart';
import 'package:flutter_watchos/commands/launch_checks.dart';
import 'package:flutter_watchos/commands/run.dart';
import 'package:flutter_watchos/watchos_mode_guidance.dart';

import '../../src/common.dart';
import '../../src/context.dart';
import '../../src/fake_devices.dart';
import '../../src/test_flutter_command_runner.dart';
import 'src/watch_project.dart';
import 'src/words.dart';

/// `run` with its checks, and a runCommand that only records that it was
/// reached: nothing is built or launched.
class _CheckedRunCommand extends WatchosRunCommand {
  _CheckedRunCommand() : super(verboseHelp: false);

  bool reachedRunCommand = false;

  @override
  Future<FlutterCommandResult> runCommand() async {
    reachedRunCommand = true;
    return FlutterCommandResult.success();
  }
}

void main() {
  late MemoryFileSystem fileSystem;
  late BufferLogger logger;
  late FakeDeviceManager deviceManager;
  late _CheckedRunCommand command;

  setUpAll(() {
    Cache.disableLocking();
  });

  setUp(() {
    fileSystem = MemoryFileSystem.test();
    logger = BufferLogger.test();
    deviceManager = FakeDeviceManager()
      ..attachedDevices = <Device>[watchSimulator(), physicalWatch()];
    command = _CheckedRunCommand();
    writeWatchProject(fileSystem);
  });

  Map<Type, Generator> overrides() => <Type, Generator>{
    FileSystem: () => fileSystem,
    ProcessManager: () => FakeProcessManager.empty(),
    Logger: () => logger,
    DeviceManager: () => deviceManager,
    Cache: () => Cache.test(processManager: FakeProcessManager.empty()),
  };

  group('run mode checks', () {
    for (final (String flag, BuildMode mode) in <(String, BuildMode)>[
      ('--profile', BuildMode.profile),
      ('--release', BuildMode.release),
    ]) {
      testUsingContext(
        '$flag on the Simulator stops in validateCommand with the guidance',
        () async {
          await expectLater(
            createTestCommandRunner(
              command,
            ).run(<String>['run', '--no-pub', '-d', kSimulatorId, flag]),
            throwsToolExit(
              message: watchosModeRefusal(
                command: WatchosModeCommand.run,
                mode: mode,
                simulator: true,
                deviceId: kSimulatorId,
              ),
            ),
          );
          expect(command.reachedRunCommand, isFalse);
        },
        overrides: overrides(),
      );
    }

    testUsingContext('debug on a physical watch stops in validateCommand', () async {
      await expectLater(
        createTestCommandRunner(command).run(<String>['run', '--no-pub', '-d', kWatchId]),
        throwsToolExit(
          message: watchosModeRefusal(
            command: WatchosModeCommand.run,
            mode: BuildMode.debug,
            simulator: false,
            deviceId: kWatchId,
          ),
        ),
      );
      expect(command.reachedRunCommand, isFalse);
    }, overrides: overrides());

    testUsingContext('the refusal is a tool exit, which prints no stack trace', () async {
      Object? caught;
      try {
        await createTestCommandRunner(
          command,
        ).run(<String>['run', '--no-pub', '-d', kSimulatorId, '--release']);
      } on Object catch (error) {
        caught = error;
      }

      expect(caught, isA<ToolExit>());
      expect((caught! as ToolExit).exitCode, anyOf(isNull, isNonZero));
    }, overrides: overrides());

    for (final (List<String> args, String target) in <(List<String>, String)>[
      (<String>['-d', kSimulatorId], 'debug on the Simulator'),
      (<String>['-d', kWatchId, '--profile'], 'profile on a physical watch'),
      (<String>['-d', kWatchId, '--release'], 'release on a physical watch'),
    ]) {
      testUsingContext('$target passes the checks', () async {
        await createTestCommandRunner(command).run(<String>['run', '--no-pub', ...args]);

        expect(command.reachedRunCommand, isTrue);
      }, overrides: overrides());
    }

    testUsingContext('a device that is not a watch is left to stock', () async {
      deviceManager.attachedDevices = <Device>[
        FakeDevice('iPhone', 'iphone-id', type: PlatformType.ios),
      ];

      await createTestCommandRunner(
        command,
      ).run(<String>['run', '--no-pub', '-d', 'iphone-id', '--release']);

      expect(command.reachedRunCommand, isTrue);
    }, overrides: overrides());
  });

  group('run --flavor', () {
    testUsingContext(
      'the tooling check writes into the project, so the checks below can see it',
      () async {
        final List<String> before = allFiles(fileSystem);

        await createTestCommandRunner(command).run(<String>['run', '--no-pub', '-d', kSimulatorId]);

        expect(allFiles(fileSystem), isNot(before));
        expect(
          allFiles(fileSystem),
          anyElement(endsWith('/watchos/Flutter/GeneratedPluginRegistrant.swift')),
        );
      },
      overrides: overrides(),
    );

    for (final (List<String> args, String target) in <(List<String>, String)>[
      (<String>['-d', kSimulatorId], 'the Simulator'),
      (<String>['-d', kWatchId, '--release'], 'a physical watch'),
    ]) {
      testUsingContext(
        '--flavor for $target stops before the tooling check, with no stock warning',
        () async {
          final List<String> before = allFiles(fileSystem);

          await expectLater(
            createTestCommandRunner(
              command,
            ).run(<String>['run', '--no-pub', ...args, '--flavor', 'x']),
            throwsToolExit(message: kWatchosFlavorRefusal),
          );

          expect(command.reachedRunCommand, isFalse);
          expect(allFiles(fileSystem), before);
          expect(logger.warningText, isEmpty);
        },
        overrides: overrides(),
      );
    }

    testUsingContext('--flavor for an iPhone keeps stock behaviour', () async {
      deviceManager.attachedDevices = <Device>[
        FakeDevice('iPhone', 'iphone-id', type: PlatformType.ios),
      ];

      await createTestCommandRunner(
        command,
      ).run(<String>['run', '--no-pub', '-d', 'iphone-id', '--flavor', 'x']);

      expect(command.reachedRunCommand, isTrue);
      expect(logger.warningText, contains('Flavor-related features may not function properly'));
    }, overrides: overrides());

    testUsingContext('a pubspec default-flavor gives one warning and the run goes on', () async {
      writeWatchProject(fileSystem, defaultFlavor: 'x');

      await createTestCommandRunner(command).run(<String>['run', '--no-pub', '-d', kSimulatorId]);

      expect(command.reachedRunCommand, isTrue);
      expect(watchosDefaultFlavorWarning('x').allMatches(logger.warningText), hasLength(1));
      expect(forbiddenWordsIn(logger.warningText), isEmpty);
    }, overrides: overrides());

    testUsingContext('a pubspec default-flavor with an iPhone target gives no warning', () async {
      writeWatchProject(fileSystem, defaultFlavor: 'x');
      deviceManager.attachedDevices = <Device>[
        FakeDevice('iPhone', 'iphone-id', type: PlatformType.ios),
      ];

      await createTestCommandRunner(command).run(<String>['run', '--no-pub', '-d', 'iphone-id']);

      expect(command.reachedRunCommand, isTrue);
      expect(logger.warningText, isEmpty);
    }, overrides: overrides());
  });

  group('run --route', () {
    for (final (List<String> args, String target) in <(List<String>, String)>[
      (<String>['-d', kSimulatorId], 'the Simulator'),
      (<String>['-d', kWatchId, '--profile'], 'a physical watch'),
    ]) {
      testUsingContext('--route for $target gives one warning and the run goes on', () async {
        await createTestCommandRunner(
          command,
        ).run(<String>['run', '--no-pub', ...args, '--route', '/details']);

        expect(command.reachedRunCommand, isTrue);
        expect(kWatchosRouteWarning.allMatches(logger.warningText), hasLength(1));
        expect(forbiddenWordsIn(logger.warningText), isEmpty);
      }, overrides: overrides());
    }

    testUsingContext('a watch run without --route gives no warning', () async {
      await createTestCommandRunner(command).run(<String>['run', '--no-pub', '-d', kSimulatorId]);

      expect(command.reachedRunCommand, isTrue);
      expect(logger.warningText, isEmpty);
    }, overrides: overrides());

    testUsingContext('--route for an iPhone keeps stock behaviour', () async {
      deviceManager.attachedDevices = <Device>[
        FakeDevice('iPhone', 'iphone-id', type: PlatformType.ios),
      ];

      await createTestCommandRunner(
        command,
      ).run(<String>['run', '--no-pub', '-d', 'iphone-id', '--route', '/details']);

      expect(command.reachedRunCommand, isTrue);
      expect(logger.warningText, isEmpty);
    }, overrides: overrides());
  });
}
