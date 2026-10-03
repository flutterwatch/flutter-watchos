// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_watchos/commands/upload.dart';

import '../../src/common.dart';
import '../../src/context.dart';
import '../../src/fake_process_manager.dart';
import '../../src/test_flutter_command_runner.dart';
import 'src/words.dart';

void main() {
  late BufferLogger logger;

  setUpAll(() {
    Cache.disableLocking();
  });

  setUp(() {
    logger = BufferLogger.test();
  });

  group('upload help', () {
    testUsingContext('--ipa says the .ipa is an Xcode export', () async {
      await createTestCommandRunner(WatchosUploadCommand()).run(<String>['upload', '--help']);

      // Usage wraps the help; compare it as one line.
      final String help = logger.statusText.replaceAll(RegExp(r'\s+'), ' ');
      expect(help, contains('an App Store export from Xcode'));
      expect(help, contains("the Organizer's Distribute App, or xcodebuild -exportArchive"));
      expect(help, contains('that folder is only where upload looks'));
      expect(forbiddenWordsIn(logger.statusText), isEmpty);
    }, overrides: <Type, Generator>{Logger: () => logger});
  });

  group('altoolArgs', () {
    test('validate', () {
      expect(
        WatchosUploadCommand.altoolArgs(
          upload: false,
          ipaPath: 'build/watchos/ipa/Runner.ipa',
          apiKeyId: 'KEY123',
          apiIssuer: 'issuer-uuid',
        ),
        <String>[
          'xcrun',
          'altool',
          '--validate-app',
          '-f',
          'build/watchos/ipa/Runner.ipa',
          '--platform',
          'ios',
          '--apiKey',
          'KEY123',
          '--apiIssuer',
          'issuer-uuid',
          '--output-format',
          'normal',
        ],
      );
    });

    test('upload', () {
      expect(
        WatchosUploadCommand.altoolArgs(
          upload: true,
          ipaPath: '/exports/App.ipa',
          apiKeyId: 'KEY123',
          apiIssuer: 'issuer-uuid',
        ),
        <String>[
          'xcrun',
          'altool',
          '--upload-app',
          '-f',
          '/exports/App.ipa',
          '--platform',
          'ios',
          '--apiKey',
          'KEY123',
          '--apiIssuer',
          'issuer-uuid',
          '--output-format',
          'normal',
        ],
      );
    });
  });

  group('upload', () {
    late MemoryFileSystem fileSystem;
    late FakeProcessManager processManager;

    const credentials = <String>['--api-key-id', 'KEY123', '--api-issuer', 'issuer-uuid'];

    FakeCommand altool({required bool upload, required String ipaPath, int exitCode = 0}) {
      return FakeCommand(
        command: WatchosUploadCommand.altoolArgs(
          upload: upload,
          ipaPath: ipaPath,
          apiKeyId: 'KEY123',
          apiIssuer: 'issuer-uuid',
        ),
        exitCode: exitCode,
        stdout: upload && exitCode == 0 ? 'Delivery UUID: 0f0e-d0c0\n' : '',
        stderr: exitCode == 0 ? '' : 'ERROR ITMS-90000: rejected',
      );
    }

    /// Writes an empty `.ipa` at [path], last changed at [modified].
    void ipaAt(String path, DateTime modified) {
      fileSystem.file(path)
        ..createSync(recursive: true)
        ..setLastModifiedSync(modified);
    }

    setUp(() {
      fileSystem = MemoryFileSystem.test();
      fileSystem.directory('/project').createSync();
      fileSystem.currentDirectory = '/project';
      processManager = FakeProcessManager.empty();
    });

    Map<Type, Generator> overrides() => <Type, Generator>{
      FileSystem: () => fileSystem,
      ProcessManager: () => processManager,
      Platform: () => FakePlatform(operatingSystem: 'macos'),
      Logger: () => logger,
    };

    testUsingContext('a missing --ipa path is a tool exit, and altool never runs', () async {
      await expectLater(
        createTestCommandRunner(
          WatchosUploadCommand(),
        ).run(<String>['upload', '--ipa', '/exports/missing.ipa', ...credentials]),
        throwsToolExit(message: 'No ipa at /exports/missing.ipa.'),
      );
      expect(processManager, hasNoRemainingExpectations);
    }, overrides: overrides());

    testUsingContext('no .ipa under build/watchos/ipa/ is a tool exit', () async {
      fileSystem.file('build/watchos/ipa/notes.txt').createSync(recursive: true);

      await expectLater(
        createTestCommandRunner(WatchosUploadCommand()).run(<String>['upload', ...credentials]),
        throwsToolExit(message: 'No .ipa found under build/watchos/ipa/.'),
      );
    }, overrides: overrides());

    testUsingContext('without --ipa the newest .ipa under build/watchos/ipa/ wins', () async {
      ipaAt('build/watchos/ipa/old.ipa', DateTime(2026, 9, 2));
      ipaAt('build/watchos/ipa/new.ipa', DateTime(2026, 9, 30));
      ipaAt('build/watchos/ipa/middle.ipa', DateTime(2026, 9, 15));
      processManager.addCommand(altool(upload: false, ipaPath: 'build/watchos/ipa/new.ipa'));

      await createTestCommandRunner(
        WatchosUploadCommand(),
      ).run(<String>['upload', '--validate-only', ...credentials]);

      expect(processManager, hasNoRemainingExpectations);
      expect(logger.statusText, contains('Validation passed'));
    }, overrides: overrides());

    testUsingContext('validates, then uploads the given .ipa', () async {
      ipaAt('/exports/App.ipa', DateTime(2026, 9, 30));
      processManager
        ..addCommand(altool(upload: false, ipaPath: '/exports/App.ipa'))
        ..addCommand(altool(upload: true, ipaPath: '/exports/App.ipa'));

      await createTestCommandRunner(
        WatchosUploadCommand(),
      ).run(<String>['upload', '--ipa', '/exports/App.ipa', ...credentials]);

      expect(processManager, hasNoRemainingExpectations);
      expect(logger.statusText, contains('Delivery UUID: 0f0e-d0c0'));
    }, overrides: overrides());

    testUsingContext('a failed validation is a tool exit, and nothing is uploaded', () async {
      ipaAt('/exports/App.ipa', DateTime(2026, 9, 30));
      processManager.addCommand(altool(upload: false, ipaPath: '/exports/App.ipa', exitCode: 1));

      await expectLater(
        createTestCommandRunner(
          WatchosUploadCommand(),
        ).run(<String>['upload', '--ipa', '/exports/App.ipa', ...credentials]),
        throwsToolExit(message: 'ERROR ITMS-90000: rejected'),
      );
      expect(processManager, hasNoRemainingExpectations);
    }, overrides: overrides());
  });
}
