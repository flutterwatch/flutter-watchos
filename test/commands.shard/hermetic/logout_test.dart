// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_watchos/commands/login.dart';

import '../../src/context.dart';
import '../../src/test_flutter_command_runner.dart';
import 'src/words.dart';

const String _home = '/home/user';

void main() {
  late MemoryFileSystem fileSystem;
  late BufferLogger logger;

  setUpAll(() {
    Cache.disableLocking();
  });

  setUp(() {
    fileSystem = MemoryFileSystem.test();
    logger = BufferLogger.test();
  });

  File credentials() => fileSystem.file('$_home/.flutter-watchos/credentials.json');

  Map<Type, Generator> overrides({Map<String, String> environment = const <String, String>{}}) =>
      <Type, Generator>{
        FileSystem: () => fileSystem,
        ProcessManager: () => FakeProcessManager.empty(),
        Logger: () => logger,
        Platform: () => FakePlatform(
          operatingSystem: 'macos',
          environment: <String, String>{'HOME': _home, ...environment},
        ),
      };

  testUsingContext('signed out, it says so and succeeds', () async {
    await createTestCommandRunner(WatchosLogoutCommand()).run(<String>['logout']);

    expect(logger.statusText.trim(), 'Not logged in.');
  }, overrides: overrides());

  testUsingContext(
    'signed in, it removes the sign-in even when the service cannot be asked',
    () async {
      credentials()
        ..createSync(recursive: true)
        ..writeAsStringSync('{"token": "t0k3n", "login": "someone"}');

      // An API base the tool refuses, so no request is ever sent.
      await createTestCommandRunner(WatchosLogoutCommand()).run(<String>['logout']);

      expect(credentials().existsSync(), isFalse);
      expect(logger.statusText, contains('Logged out. The sign-in is removed from this machine'));
      expect(logger.statusText, contains('could not be reached to revoke it'));
      expect(forbiddenWordsIn(logger.statusText), isEmpty);
    },
    overrides: overrides(environment: <String, String>{'WATCHOS_ARTIFACTS_API': 'ftp://nowhere'}),
  );
}
