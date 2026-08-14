// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/template.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/isolated/mustache_template.dart';
import 'package:flutter_watchos/commands/watchos_runner.dart';

import '../src/common.dart';
import '../src/host_sources.dart';

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

  /// Renders the real `Runner/App.swift.tmpl` into [projectDirPath] with the
  /// real mustache renderer, so the assertions below are about the Swift that
  /// actually ships rather than about the template context.
  Future<String> renderAppSwift({required String projectDirPath, required String name}) async {
    fileSystem
        .file(fileSystem.path.join(templatePath(), 'Runner', 'App.swift.tmpl'))
        .createSync(recursive: true);
    fileSystem
        .file(fileSystem.path.join(templatePath(), 'Runner', 'App.swift.tmpl'))
        .writeAsStringSync(readRunnerTemplate('App.swift.tmpl'));

    await renderWatchosRunner(
      fileSystem: fileSystem,
      logger: logger,
      templateRenderer: const MustacheTemplateRenderer(),
      projectDirPath: projectDirPath,
      name: name,
      organization: 'com.example',
    );

    return fileSystem
        .file(fileSystem.path.join(projectDirPath, 'watchos', 'Runner', 'App.swift'))
        .readAsStringSync();
  }

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

  group('watchosRunnerProjectName', () {
    testWithoutContext('keeps a real project name', () {
      expect(
        watchosRunnerProjectName(name: 'tandem', directoryName: 'checkout'),
        'tandem',
      );
    });

    testWithoutContext('falls back to the directory for a `create .` name', () {
      // `create .` used to reach the template with the argument as written.
      expect(watchosRunnerProjectName(name: '.', directoryName: 'my_app'), 'my_app');
      expect(watchosRunnerProjectName(name: '..', directoryName: 'my_app'), 'my_app');
      expect(watchosRunnerProjectName(name: '', directoryName: 'my_app'), 'my_app');
    });

    testWithoutContext('falls back to "runner" when the directory is degenerate too', () {
      expect(watchosRunnerProjectName(name: '.', directoryName: '.'), 'runner');
      expect(watchosRunnerProjectName(name: '.', directoryName: '/'), 'runner');
    });
  });

  group('watchosSwiftTypeName', () {
    testWithoutContext('upper-camel-cases a package name', () {
      // The names the shipped example runners were generated with.
      expect(watchosSwiftTypeName('tandem'), 'Tandem');
      expect(watchosSwiftTypeName('sensors_plus_example'), 'SensorsPlusExample');
    });

    testWithoutContext('drops characters Swift identifiers cannot hold', () {
      expect(watchosSwiftTypeName('my-app'), 'MyApp');
      expect(watchosSwiftTypeName('foo.bar'), 'FooBar');
      expect(watchosSwiftTypeName('my app 2'), 'MyApp2');
    });

    testWithoutContext('never starts with a digit', () {
      expect(watchosSwiftTypeName('3d_demo'), '_3dDemo');
      expect(watchosSwiftTypeName('2048'), '_2048');
    });

    testWithoutContext('falls back to Runner when nothing is left', () {
      expect(watchosSwiftTypeName('.'), 'Runner');
      expect(watchosSwiftTypeName(''), 'Runner');
    });
  });

  group('generated App.swift', () {
    testWithoutContext('declares a valid Swift struct for `create .`', () async {
      // Regression: `create .` named the project "." and emitted
      // `struct .App: App`, which does not parse ("Expected identifier in
      // struct declaration"), so the build failed.
      final String appSwift = await renderAppSwift(projectDirPath: '/work/my_app', name: '.');

      expect(appSwift, contains('struct MyAppApp: App {'));
      expect(appSwift, isNot(contains('struct .App')));
      // The unsupported-device screen is the other place the name is spelled.
      expect(appSwift, contains('Text("My App")'));
    });

    testWithoutContext('declares a valid Swift struct for any project name', () async {
      final swiftStruct = RegExp(r'^struct ([A-Za-z_][A-Za-z0-9_]*)App: App \{$', multiLine: true);
      for (final name in <String>['tandem', 'my-app', '3d_demo', '.', '..']) {
        fileSystem = MemoryFileSystem.test();
        final String appSwift = await renderAppSwift(projectDirPath: '/work/proj', name: name);

        expect(
          swiftStruct.hasMatch(appSwift),
          isTrue,
          reason: 'name "$name" produced Swift that does not declare a valid '
              'struct identifier:\n$appSwift',
        );
      }
    });
  });
}
