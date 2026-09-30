// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/base/terminal.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/device.dart';
import 'package:flutter_tools/src/runner/flutter_command.dart';
import 'package:flutter_watchos/commands/drive.dart';
import 'package:flutter_watchos/commands/launch_checks.dart';
import 'package:flutter_watchos/watchos_mode_guidance.dart';

import '../../src/common.dart';
import '../../src/context.dart';
import '../../src/test_flutter_command_runner.dart';
import 'src/watch_project.dart';
import 'src/words.dart';

/// `drive` with its checks, and a runCommand that only records that it was
/// reached: nothing is built, launched or driven.
class _CheckedDriveCommand extends WatchosDriveCommand {
  _CheckedDriveCommand({required super.fileSystem, required super.logger})
    : super(
        verboseHelp: false,
        platform: FakePlatform(),
        signals: FakeSignals(),
        terminal: Terminal.test(),
        outputPreferences: OutputPreferences.test(),
      );

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
  late _CheckedDriveCommand command;

  setUpAll(() {
    Cache.disableLocking();
  });

  setUp(() {
    fileSystem = MemoryFileSystem.test();
    logger = BufferLogger.test();
    deviceManager = FakeDeviceManager()
      ..attachedDevices = <Device>[watchSimulator(), physicalWatch()];
    command = _CheckedDriveCommand(fileSystem: fileSystem, logger: logger);
    writeWatchProject(fileSystem);
  });

  Map<Type, Generator> overrides() => <Type, Generator>{
    FileSystem: () => fileSystem,
    ProcessManager: () => FakeProcessManager.empty(),
    Logger: () => logger,
    DeviceManager: () => deviceManager,
    Cache: () => Cache.test(processManager: FakeProcessManager.empty()),
  };

  group('drive mode checks', () {
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
            ).run(<String>['drive', '--no-pub', '-d', kSimulatorId, flag]),
            throwsToolExit(
              message: watchosModeRefusal(
                command: WatchosModeCommand.drive,
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
        createTestCommandRunner(command).run(<String>['drive', '--no-pub', '-d', kWatchId]),
        throwsToolExit(
          message: watchosModeRefusal(
            command: WatchosModeCommand.drive,
            mode: BuildMode.debug,
            simulator: false,
            deviceId: kWatchId,
          ),
        ),
      );
      expect(command.reachedRunCommand, isFalse);
    }, overrides: overrides());

    testUsingContext('with two targets and no -d it stops before runCommand', () async {
      await expectLater(
        createTestCommandRunner(command).run(<String>['drive', '--no-pub']),
        throwsToolExit(),
      );
      expect(command.reachedRunCommand, isFalse);
    }, overrides: overrides());

    for (final (List<String> args, String target) in <(List<String>, String)>[
      (<String>['-d', kSimulatorId], 'debug on the Simulator'),
      (<String>['-d', kWatchId, '--profile'], 'profile on a physical watch'),
      (<String>['-d', kWatchId, '--release'], 'release on a physical watch'),
    ]) {
      testUsingContext('$target passes the checks', () async {
        await createTestCommandRunner(command).run(<String>['drive', '--no-pub', ...args]);

        expect(command.reachedRunCommand, isTrue);
      }, overrides: overrides());
    }
  });

  group('drive --flavor', () {
    testUsingContext('--flavor for the Simulator stops before the tooling check', () async {
      final List<String> before = allFiles(fileSystem);

      await expectLater(
        createTestCommandRunner(
          command,
        ).run(<String>['drive', '--no-pub', '-d', kSimulatorId, '--flavor', 'x']),
        throwsToolExit(message: kWatchosFlavorRefusal),
      );

      expect(command.reachedRunCommand, isFalse);
      expect(allFiles(fileSystem), before);
      expect(logger.warningText, isEmpty);
    }, overrides: overrides());

    testUsingContext('a pubspec default-flavor gives one warning and the drive goes on', () async {
      writeWatchProject(fileSystem, defaultFlavor: 'x');

      await createTestCommandRunner(command).run(<String>['drive', '--no-pub', '-d', kSimulatorId]);

      expect(command.reachedRunCommand, isTrue);
      expect(watchosDefaultFlavorWarning('x').allMatches(logger.warningText), hasLength(1));
      expect(forbiddenWordsIn(logger.warningText), isEmpty);
    }, overrides: overrides());
  });
}
