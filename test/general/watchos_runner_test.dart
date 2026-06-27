// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/template.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_watchos/commands/watchos_runner.dart';

import '../src/common.dart';

class _FakeTemplateRenderer implements TemplateRenderer {
  @override
  dynamic noSuchMethod(Invocation invocation) => '';
}

void main() {
  late MemoryFileSystem fileSystem;
  late BufferLogger logger;
  late _FakeTemplateRenderer renderer;

  setUp(() {
    fileSystem = MemoryFileSystem.test();
    logger = BufferLogger.test();
    renderer = _FakeTemplateRenderer();
    Cache.flutterRoot = '/x/flutter';
  });

  String templatePath() => fileSystem.path.join(
    Cache.flutterRoot!,
    '..',
    'templates',
    'app',
    'swift',
    'watchos.tmpl',
  );

  Future<void> render(String projectDirPath) => renderWatchosRunner(
    fileSystem: fileSystem,
    logger: logger,
    templateRenderer: renderer,
    projectDirPath: projectDirPath,
    name: 'demo',
    organization: 'com.example',
  );

  group('renderWatchosRunner guards', () {
    testWithoutContext('is a no-op when the template directory is missing', () async {
      fileSystem.directory('/proj').createSync(recursive: true);

      await render('/proj');

      expect(fileSystem.directory('/proj/watchos').existsSync(), isFalse);
      expect(logger.statusText, isNot(contains('Generating watchOS runner')));
    });

    testWithoutContext('is a no-op when watchos/ already exists', () async {
      // Even with a template present, an existing watchos/ must not be
      // re-rendered (the create/port flows are idempotent).
      fileSystem.directory(templatePath()).createSync(recursive: true);
      fileSystem.directory('/proj/watchos').createSync(recursive: true);

      await render('/proj');

      expect(logger.statusText, isNot(contains('Generating watchOS runner')));
    });
  });
}
