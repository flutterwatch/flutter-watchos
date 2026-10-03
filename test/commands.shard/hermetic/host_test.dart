// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_watchos/commands/host.dart';

import '../../src/common.dart';
import '../../src/context.dart';
import '../../src/test_flutter_command_runner.dart';
import 'src/words.dart';

/// A watch-only app's `Info.plist`.
const String _watchOnlyPlist = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>WKApplication</key>
	<true/>
	<key>WKWatchOnly</key>
	<true/>
</dict>
</plist>
''';

void main() {
  late MemoryFileSystem fileSystem;
  late BufferLogger logger;
  late Directory project;

  setUpAll(() {
    Cache.disableLocking();
  });

  setUp(() {
    fileSystem = MemoryFileSystem.test();
    logger = BufferLogger.test();
    project = fileSystem.directory('/project')..createSync();
    project.childFile('pubspec.yaml').writeAsStringSync('name: my_app\n');
    fileSystem.currentDirectory = project;
  });

  void writeWatchRunner() {
    project.childDirectory('watchos').childDirectory('Runner').childFile('Info.plist')
      ..createSync(recursive: true)
      ..writeAsStringSync(_watchOnlyPlist);
  }

  Map<Type, Generator> overrides() => <Type, Generator>{
    FileSystem: () => fileSystem,
    ProcessManager: () => FakeProcessManager.empty(),
    Logger: () => logger,
  };

  testUsingContext('a watch-only project is standalone, and stays so', () async {
    writeWatchRunner();

    await createTestCommandRunner(WatchosHostCommand()).run(<String>['host']);

    expect(logger.statusText, startsWith('Host mode: standalone (no iOS app in this project).'));
    expect(
      project
          .childDirectory('watchos')
          .childDirectory('Runner')
          .childFile('Info.plist')
          .readAsStringSync(),
      contains('<key>WKWatchOnly</key>'),
    );
    expect(forbiddenWordsIn(logger.statusText), isEmpty);
  }, overrides: overrides());

  testUsingContext('outside a watch project it is a tool exit', () async {
    await expectLater(
      createTestCommandRunner(WatchosHostCommand()).run(<String>['host']),
      throwsToolExit(message: 'No watchos/ directory here.'),
    );
  }, overrides: overrides());

  testUsingContext('without the watch Info.plist it is a tool exit', () async {
    project.childDirectory('watchos').createSync();

    await expectLater(
      createTestCommandRunner(WatchosHostCommand()).run(<String>['host']),
      throwsToolExit(message: 'No watch app Info.plist at watchos/Runner/Info.plist.'),
    );
  }, overrides: overrides());

  testUsingContext('the mode is not a setting: an argument is a tool exit', () async {
    writeWatchRunner();

    await expectLater(
      createTestCommandRunner(WatchosHostCommand()).run(<String>['host', 'companion']),
      throwsToolExit(message: 'The host mode is not a setting'),
    );
  }, overrides: overrides());
}
