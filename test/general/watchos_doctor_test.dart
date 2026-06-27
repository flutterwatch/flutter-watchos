// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/os.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/doctor_validator.dart';
import 'package:flutter_watchos/watchos_doctor.dart';

import '../src/common.dart';
import '../src/fake_process_manager.dart';
import '../src/fakes.dart';

// A fake platform whose script URI points to a known path so that
// _checkEngineArtifacts can resolve the CLI root without touching globals.
//   /cli/bin/cache/flutter-watchos.snapshot  ← script
//   /cli/engine_artifacts/watchos_debug_sim_arm64/
FakePlatform _makePlatform() =>
    FakePlatform(script: Uri.file('/cli/bin/cache/flutter-watchos.snapshot'));

MemoryFileSystem _makeEngineFs({bool artifactsPresent = true}) {
  final fs = MemoryFileSystem.test();
  if (artifactsPresent) {
    fs.directory('/cli/engine_artifacts/watchos_debug_sim_arm64').createSync(recursive: true);
  }
  return fs;
}

const FakeCommand _xcodeOk = FakeCommand(
  command: <String>['xcodebuild', '-version'],
  stdout: 'Xcode 16.3\nBuild version 16E140',
);
const FakeCommand _watchosSdkOk = FakeCommand(
  command: <String>['xcrun', '--sdk', 'watchos', '--show-sdk-path'],
  // ignore: lines_longer_than_80_chars
  stdout: '/Applications/Xcode.app/Contents/Developer/Platforms/WatchOS.platform/Developer/SDKs/WatchOS11.0.sdk',
);
const FakeCommand _runtimeOk = FakeCommand(
  command: <String>['xcrun', 'simctl', 'list', 'runtimes', '--json'],
  // ignore: lines_longer_than_80_chars
  stdout: '{"runtimes":[{"name":"watchOS 11.0","identifier":"com.apple.CoreSimulator.SimRuntime.watchOS-11-0"}]}',
);
const FakeCommand _podOk = FakeCommand(command: <String>['pod', '--version'], stdout: '1.15.2');

List<String> _texts(ValidationResult r) =>
    r.messages.map((ValidationMessage m) => m.message).toList();

void main() {
  late FakeProcessManager processManager;

  setUp(() {
    processManager = FakeProcessManager.empty();
  });

  group('WatchosValidator', () {
    testWithoutContext('success when all checks pass', () async {
      processManager.addCommands(<FakeCommand>[_xcodeOk, _watchosSdkOk, _runtimeOk, _podOk]);

      final validator = WatchosValidator(
        processManager: processManager,
        fileSystem: _makeEngineFs(),
        platform: _makePlatform(),
      );

      final ValidationResult result = await validator.validate();
      expect(result.type, equals(ValidationType.success));

      final List<String> messageTexts = _texts(result);
      expect(messageTexts, contains(contains('Xcode installed')));
      expect(messageTexts, contains(contains('watchOS SDK')));
      expect(messageTexts, contains(contains('watchOS Simulator runtime')));
      expect(messageTexts, contains(contains('CocoaPods')));
      expect(messageTexts, contains(contains('engine artifacts')));
      expect(processManager, hasNoRemainingExpectations);
    });

    testWithoutContext('missing when Xcode is not installed', () async {
      processManager.addCommand(
        const FakeCommand(command: <String>['xcodebuild', '-version'], exitCode: 1),
      );

      final validator = WatchosValidator(
        processManager: processManager,
        fileSystem: _makeEngineFs(),
        platform: _makePlatform(),
      );

      final ValidationResult result = await validator.validate();
      expect(result.type, equals(ValidationType.missing));
      expect(result.messages.first.message, contains('Xcode is not installed'));
    });

    testWithoutContext('partial when watchOS SDK is missing', () async {
      processManager.addCommands(<FakeCommand>[
        _xcodeOk,
        const FakeCommand(
          command: <String>['xcrun', '--sdk', 'watchos', '--show-sdk-path'],
          exitCode: 1,
        ),
        _runtimeOk,
        _podOk,
      ]);

      final validator = WatchosValidator(
        processManager: processManager,
        fileSystem: _makeEngineFs(),
        platform: _makePlatform(),
      );

      final ValidationResult result = await validator.validate();
      expect(result.type, equals(ValidationType.partial));
      expect(_texts(result), contains(contains('watchOS SDK not found')));
    });

    testWithoutContext('partial when no watchOS Simulator runtime is installed', () async {
      processManager.addCommands(<FakeCommand>[
        _xcodeOk,
        _watchosSdkOk,
        const FakeCommand(
          command: <String>['xcrun', 'simctl', 'list', 'runtimes', '--json'],
          // ignore: lines_longer_than_80_chars
          stdout: '{"runtimes":[{"name":"iOS 17.0","identifier":"com.apple.CoreSimulator.SimRuntime.iOS-17-0"}]}',
        ),
        _podOk,
      ]);

      final validator = WatchosValidator(
        processManager: processManager,
        fileSystem: _makeEngineFs(),
        platform: _makePlatform(),
      );

      final ValidationResult result = await validator.validate();
      expect(result.type, equals(ValidationType.partial));
      expect(_texts(result), contains(contains('No watchOS Simulator runtime found')));
    });

    testWithoutContext('CocoaPods missing is a hint, not a failure', () async {
      processManager.addCommands(<FakeCommand>[
        _xcodeOk,
        _watchosSdkOk,
        _runtimeOk,
        const FakeCommand(command: <String>['pod', '--version'], exitCode: 1),
      ]);

      final validator = WatchosValidator(
        processManager: processManager,
        fileSystem: _makeEngineFs(),
        platform: _makePlatform(),
      );

      final ValidationResult result = await validator.validate();
      expect(result.type, equals(ValidationType.success));
      expect(_texts(result), contains(contains('CocoaPods not installed')));
    });

    testWithoutContext('absent engine artifacts is a hint, not a failure', () async {
      processManager.addCommands(<FakeCommand>[_xcodeOk, _watchosSdkOk, _runtimeOk, _podOk]);

      final validator = WatchosValidator(
        processManager: processManager,
        fileSystem: _makeEngineFs(artifactsPresent: false),
        platform: _makePlatform(),
      );

      final ValidationResult result = await validator.validate();
      expect(result.type, equals(ValidationType.success));
      expect(_texts(result), contains(contains('engine artifacts not found')));
    });
  });

  group('WatchosWorkflow', () {
    testWithoutContext('applies to a macOS host and can list/launch devices', () {
      final workflow = WatchosWorkflow(
        operatingSystemUtils: FakeOperatingSystemUtils(hostPlatform: HostPlatform.darwin_arm64),
      );
      expect(workflow.appliesToHostPlatform, isTrue);
      expect(workflow.canLaunchDevices, isTrue);
      expect(workflow.canListDevices, isTrue);
      expect(workflow.canListEmulators, isTrue);
    });
  });
}
