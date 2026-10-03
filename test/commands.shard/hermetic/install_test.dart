// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/device.dart';
import 'package:flutter_tools/src/runner/flutter_command.dart';
import 'package:flutter_watchos/commands/install.dart';
import 'package:flutter_watchos/commands/launch_checks.dart';
import 'package:flutter_watchos/executable.dart';

import '../../src/common.dart';
import '../../src/context.dart';
import '../../src/fake_devices.dart';
import '../../src/test_flutter_command_runner.dart';
import 'src/watch_project.dart';

/// `install` with its checks, and a runCommand that only records that it was
/// reached: nothing is installed.
class _CheckedInstallCommand extends WatchosInstallCommand {
  _CheckedInstallCommand() : super(verboseHelp: false);

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
  late _CheckedInstallCommand command;

  setUpAll(() {
    Cache.disableLocking();
  });

  setUp(() {
    fileSystem = MemoryFileSystem.test();
    logger = BufferLogger.test();
    deviceManager = FakeDeviceManager()
      ..attachedDevices = <Device>[watchSimulator(), physicalWatch()];
    command = _CheckedInstallCommand();
    writeWatchProject(fileSystem);
  });

  Map<Type, Generator> overrides() => <Type, Generator>{
    FileSystem: () => fileSystem,
    ProcessManager: () => FakeProcessManager.empty(),
    Logger: () => logger,
    DeviceManager: () => deviceManager,
    Cache: () => Cache.test(processManager: FakeProcessManager.empty()),
  };

  testUsingContext('install is the watch command, with stock name and options', () {
    final FlutterCommand install = generateWatchosCommands(
      verboseHelp: false,
      verbose: false,
    ).singleWhere((FlutterCommand command) => command.name == 'install');

    expect(install, isA<WatchosInstallCommand>());
    expect(install.argParser.options.keys, containsAll(<String>['flavor', 'uninstall-only']));
  }, overrides: overrides());

  for (final device in <String>[kSimulatorId, kWatchId]) {
    testUsingContext('--flavor for a watch ($device) stops before any install step', () async {
      final List<String> before = allFiles(fileSystem);

      await expectLater(
        createTestCommandRunner(command).run(<String>['install', '-d', device, '--flavor', 'x']),
        throwsToolExit(message: kWatchosFlavorRefusal),
      );

      expect(command.reachedRunCommand, isFalse);
      expect(allFiles(fileSystem), before);
    }, overrides: overrides());
  }

  testUsingContext('without --flavor a watch passes the checks', () async {
    await createTestCommandRunner(command).run(<String>['install', '-d', kSimulatorId]);

    expect(command.reachedRunCommand, isTrue);
  }, overrides: overrides());

  testUsingContext('--flavor for an iPhone keeps stock behaviour', () async {
    deviceManager.attachedDevices = <Device>[
      FakeDevice('iPhone', 'iphone-id', type: PlatformType.ios),
    ];

    await createTestCommandRunner(
      command,
    ).run(<String>['install', '-d', 'iphone-id', '--flavor', 'x']);

    expect(command.reachedRunCommand, isTrue);
  }, overrides: overrides());

  testUsingContext('--flavor with no device stops as stock does', () async {
    deviceManager.attachedDevices = <Device>[];

    await expectLater(
      createTestCommandRunner(command).run(<String>['install', '--flavor', 'x']),
      throwsToolExit(message: 'No target device found'),
    );
    expect(command.reachedRunCommand, isFalse);
  }, overrides: overrides());
}
