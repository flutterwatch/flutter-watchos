// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/io.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/base/signals.dart';
import 'package:flutter_tools/src/base/terminal.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/device.dart';
import 'package:flutter_tools/src/runner/flutter_command.dart';
import 'package:flutter_watchos/commands/attach.dart';
import 'package:flutter_watchos/commands/launch_checks.dart';
import 'package:flutter_watchos/watchos_mode_guidance.dart';

import '../../src/common.dart';
import '../../src/context.dart';
import '../../src/fakes.dart';
import '../../src/test_flutter_command_runner.dart';
import 'src/watch_project.dart';

/// `attach` with its checks, and a runCommand that only records that it was
/// reached: no connection is attempted.
class _CheckedAttachCommand extends WatchosAttachCommand {
  _CheckedAttachCommand({required super.fileSystem, required super.logger})
    : super(
        verboseHelp: false,
        stdio: FakeStdio(),
        terminal: Terminal.test(),
        signals: Signals.test(),
        platform: FakePlatform(),
        processInfo: ProcessInfo.test(MemoryFileSystem.test()),
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
  late _CheckedAttachCommand command;

  setUpAll(() {
    Cache.disableLocking();
  });

  setUp(() {
    fileSystem = MemoryFileSystem.test();
    logger = BufferLogger.test();
    deviceManager = FakeDeviceManager()
      ..attachedDevices = <Device>[watchSimulator(), physicalWatch()];
    command = _CheckedAttachCommand(fileSystem: fileSystem, logger: logger);
    writeWatchProject(fileSystem);
  });

  Map<Type, Generator> overrides() => <Type, Generator>{
    FileSystem: () => fileSystem,
    ProcessManager: () => FakeProcessManager.empty(),
    Logger: () => logger,
    DeviceManager: () => deviceManager,
    Cache: () => Cache.test(processManager: FakeProcessManager.empty()),
  };

  group('attach mode checks', () {
    testUsingContext(
      '--profile on the Simulator stops in validateCommand with the guidance',
      () async {
        await expectLater(
          createTestCommandRunner(command).run(<String>['attach', '-d', kSimulatorId, '--profile']),
          throwsToolExit(
            message: watchosModeRefusal(
              command: WatchosModeCommand.attach,
              mode: BuildMode.profile,
              simulator: true,
              deviceId: kSimulatorId,
            ),
          ),
        );
        expect(command.reachedRunCommand, isFalse);
      },
      overrides: overrides(),
    );

    for (final (List<String> mode, String name) in <(List<String>, String)>[
      (<String>[], 'debug'),
      (<String>['--profile'], 'profile'),
    ]) {
      testUsingContext(
        '$name on a physical watch with no URL stops in validateCommand with the guidance',
        () async {
          await expectLater(
            createTestCommandRunner(command).run(<String>['attach', '-d', kWatchId, ...mode]),
            throwsToolExit(message: watchosAttachWatchRefusal(deviceId: kWatchId)),
          );
          expect(command.reachedRunCommand, isFalse);
        },
        overrides: overrides(),
      );
    }

    for (final args in <List<String>>[
      <String>['--debug-url', 'http://127.0.0.1:50001/aBcD1234=/'],
      <String>['--debug-url', 'http://127.0.0.1:50001/aBcD1234=/', '--profile'],
      <String>['--debug-port', '50001'],
    ]) {
      testUsingContext('a physical watch with ${args.join(' ')} passes the checks', () async {
        await createTestCommandRunner(command).run(<String>['attach', '-d', kWatchId, ...args]);

        expect(command.reachedRunCommand, isTrue);
      }, overrides: overrides());
    }

    testUsingContext('debug on the Simulator passes the checks', () async {
      await createTestCommandRunner(command).run(<String>['attach', '-d', kSimulatorId]);

      expect(command.reachedRunCommand, isTrue);
    }, overrides: overrides());
  });

  // A shut-down Simulator is found only by its exact UDID, so that run can
  // boot it; attach cannot find an app there, and stops before it waits for
  // a VM Service.
  for (final args in <List<String>>[
    <String>[],
    <String>['--debug-url', 'http://127.0.0.1:50001/aBcD1234=/'],
  ]) {
    testUsingContext(
      'a shut-down Simulator ${args.isEmpty ? '' : 'with --debug-url '}stops with the boot guidance',
      () async {
        deviceManager.attachedDevices.add(shutDownWatchSimulator());

        await expectLater(
          createTestCommandRunner(
            command,
          ).run(<String>['attach', '-d', kShutDownSimulatorId, ...args]),
          throwsToolExit(
            message: watchosShutDownSimulatorGuidance(
              shutDownWatchSimulator(),
              reason: 'no app is running on it to attach to',
            ),
          ),
        );
        expect(command.reachedRunCommand, isFalse);
      },
      overrides: overrides(),
    );
  }
}
