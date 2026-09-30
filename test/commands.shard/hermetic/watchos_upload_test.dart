// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_watchos/commands/upload.dart';

import '../../src/context.dart';
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
}
