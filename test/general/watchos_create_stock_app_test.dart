// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// A watch-only `create` writes the app stock `flutter create` writes: the
// counter app, unmodified, from the pinned SDK's own template. Both commands
// run here on a memory file system that holds the real templates, and their
// shared files are compared.

import 'dart:io' as io;

import 'package:args/command_runner.dart';
import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/commands/create.dart';
import 'package:flutter_tools/src/features.dart';
import 'package:flutter_tools/src/runner/flutter_command.dart';
import 'package:flutter_tools/src/template.dart';
import 'package:flutter_watchos/commands/create.dart';

import '../../flutter/packages/flutter_tools/test/src/fakes.dart' show TestFeatureFlags;
import '../src/context.dart';
import '../src/host_sources.dart';
import '../src/test_flutter_command_runner.dart';

/// The project files stock `create` writes for every platform.
const _sharedFiles = <String>[
  'lib/main.dart',
  'test/widget_test.dart',
  'pubspec.yaml',
  'README.md',
  '.gitignore',
  'hello_watch.iml',
];

void main() {
  late MemoryFileSystem fileSystem;
  String? savedFlutterRoot;

  setUpAll(() {
    Cache.disableLocking();
  });

  setUp(() {
    savedFlutterRoot = Cache.flutterRoot;
    fileSystem = MemoryFileSystem.test();
    // The pinned SDK's templates and its pubspec.lock, which stock create
    // reads, and this CLI's own templates for watchos/, at the same paths.
    final String flutterRoot = cliRootPath('flutter');
    _copyIn(fileSystem, '$flutterRoot/packages/flutter_tools/templates');
    _copyIn(fileSystem, '$flutterRoot/pubspec.lock');
    _copyIn(fileSystem, '$flutterRoot/bin/cache/dart-sdk/version');
    _copyIn(fileSystem, cliRootPath('templates'));
    Cache.flutterRoot = flutterRoot;
  });

  tearDown(() {
    Cache.flutterRoot = savedFlutterRoot;
  });

  Future<void> create(FlutterCommand command, List<String> args) async {
    final CommandRunner<void> runner = createTestCommandRunner(command);
    await runner.run(<String>['create', '--no-pub', '--project-name', 'hello_watch', ...args]);
  }

  String read(String project, String path) =>
      fileSystem.directory('/projects/$project').childFile(path).readAsStringSync();

  final overrides = <Type, Generator>{
    FileSystem: () => fileSystem,
    ProcessManager: () => FakeProcessManager.any(),
    // Stock create on Linux needs no template images; the shared files are the
    // same for every platform.
    FeatureFlags: () => TestFeatureFlags(isLinuxEnabled: true),
    TemplatePathProvider: () => _NoImagesTemplatePathProvider(),
  };

  testUsingContext(
    'a watch-only create writes the files stock create writes, unmodified',
    () async {
      await create(WatchosCreateCommand(verboseHelp: false), <String>[
        '--watchos-only',
        '/projects/watch',
      ]);
      await create(CreateCommand(), <String>['--platforms=linux', '/projects/stock']);

      for (final String path in _sharedFiles) {
        expect(read('watch', path), read('stock', path), reason: path);
      }
      // The counter, as stock writes it.
      final String mainDart = read('watch', 'lib/main.dart');
      expect(mainDart, contains('You have pushed the button this many times:'));
      expect(mainDart, contains('FloatingActionButton('));
      // The watch app is beside it, and no other platform is.
      final Directory watch = fileSystem.directory('/projects/watch');
      expect(watch.childDirectory('watchos').existsSync(), isTrue);
      for (final platform in <String>['ios', 'android', 'web', 'macos', 'linux', 'windows']) {
        expect(watch.childDirectory(platform).existsSync(), isFalse, reason: platform);
      }
      // Stock seeds pubspec.lock with the SDK's own versions; so does the
      // watch-only path.
      expect(read('watch', 'pubspec.lock'), read('stock', 'pubspec.lock'));
    },
    overrides: overrides,
  );

  testUsingContext('a watch-only create honours --empty as stock does', () async {
    await create(WatchosCreateCommand(verboseHelp: false), <String>[
      '--watchos-only',
      '--empty',
      '/projects/watch',
    ]);
    await create(CreateCommand(), <String>['--platforms=linux', '--empty', '/projects/stock']);

    expect(read('watch', 'lib/main.dart'), read('stock', 'lib/main.dart'));
    expect(
      fileSystem.directory('/projects/watch').childFile('test/widget_test.dart').existsSync(),
      isFalse,
    );
  }, overrides: overrides);
}

/// Copies the file or directory at [path] on disk to the same path in
/// [fileSystem].
void _copyIn(MemoryFileSystem fileSystem, String path) {
  if (io.FileSystemEntity.typeSync(path) == io.FileSystemEntityType.file) {
    fileSystem.file(path)
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(io.File(path).readAsBytesSync());
    return;
  }
  for (final io.FileSystemEntity entity in io.Directory(path).listSync(recursive: true)) {
    if (entity is io.File) {
      fileSystem.file(entity.path)
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(entity.readAsBytesSync());
    }
  }
}

/// The real template directories, and no template images: neither the
/// watch-only app nor stock's Linux app has an image to resolve.
class _NoImagesTemplatePathProvider extends TemplatePathProvider {
  @override
  Future<Directory> imageDirectory(String? name, FileSystem fileSystem, Logger logger) async =>
      fileSystem.directory('/no-template-images');
}
