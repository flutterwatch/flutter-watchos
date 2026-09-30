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
import 'package:flutter_watchos/commands/run.dart';
import 'package:flutter_watchos/watchos_mode_guidance.dart';

import '../../src/common.dart';
import '../../src/context.dart';
import '../../src/fake_devices.dart';
import '../../src/test_flutter_command_runner.dart';
import 'src/watch_project.dart';

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
}
