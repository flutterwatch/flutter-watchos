// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// A watch-only `create` writes the app stock `flutter create` writes: the
// counter app, unmodified, from the pinned SDK's own template. Both commands
// run here on a memory file system that holds the real templates, and their
// files are compared.

import 'dart:convert';
import 'dart:io' as io;

import 'package:args/command_runner.dart';
import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/commands/create.dart';
import 'package:flutter_tools/src/dart/pub.dart';
import 'package:flutter_tools/src/features.dart';
import 'package:flutter_tools/src/project.dart';
import 'package:flutter_tools/src/runner/flutter_command.dart';
import 'package:flutter_tools/src/template.dart';
import 'package:flutter_watchos/commands/create.dart';
import 'package:test/fake.dart';

import '../../flutter/packages/flutter_tools/test/src/fakes.dart' show TestFeatureFlags;
import '../src/common.dart';
import '../src/context.dart';
import '../src/host_sources.dart';
import '../src/test_flutter_command_runner.dart';

// The parts of an iOS Runner project the host-mode wiring reads and edits, as
// in watchos_host_mode_test.dart.
const _iosPbxproj = '''
		97C146ED1CF9000F007C117D /* Runner */ = {
			isa = PBXNativeTarget;
			buildPhases = (
				97C146EA1CF9000F007C117D /* Sources */,
				3B06AD1E1E4923F5004D2608 /* Thin Binary */,
			);
		};
/* Begin PBXShellScriptBuildPhase section */
		3B06AD1E1E4923F5004D2608 /* Thin Binary */ = {
			isa = PBXShellScriptBuildPhase;
			shellScript = "/bin/sh xcode_backend.sh embed_and_thin";
		};
/* End PBXShellScriptBuildPhase section */
		97C147061CF9000F007C117D /* Debug */ = {
			buildSettings = {
				PRODUCT_BUNDLE_IDENTIFIER = "com.example.helloWatch";
			};
		};
''';

void main() {
  late MemoryFileSystem fileSystem;
  String? savedFlutterRoot;

  setUpAll(() {
    Cache.disableLocking();
  });

  setUp(() {
    savedFlutterRoot = Cache.flutterRoot;
    fileSystem = MemoryFileSystem.test();
    // The pinned SDK's templates, its pubspec.lock and the flutter package's
    // pubspec, which stock create reads, and this CLI's own templates for
    // watchos/, at the same paths as on disk.
    final String flutterRoot = cliRootPath('flutter');
    _copyIn(fileSystem, '$flutterRoot/packages/flutter_tools/templates');
    _copyIn(fileSystem, '$flutterRoot/packages/flutter/pubspec.yaml');
    _copyIn(fileSystem, '$flutterRoot/pubspec.lock');
    _copyIn(fileSystem, '$flutterRoot/bin/cache/dart-sdk/version');
    _copyIn(fileSystem, cliRootPath('templates'));
    Cache.flutterRoot = flutterRoot;
  });

  tearDown(() {
    Cache.flutterRoot = savedFlutterRoot;
  });

  Future<void> create(FlutterCommand command, List<String> args, {bool pub = false}) async {
    final CommandRunner<void> runner = createTestCommandRunner(command);
    await runner.run(<String>[
      'create',
      if (!pub) '--no-pub',
      '--project-name',
      'hello_watch',
      ...args,
    ]);
  }

  Directory project(String name) => fileSystem.directory('/projects/$name');

  String read(String name, String path) => project(name).childFile(path).readAsStringSync();

  // Every file of the project, by its path in the project, outside the
  // platform folders and the tool's own .dart_tool/.
  Set<String> files(String name) {
    final Directory root = project(name);
    return <String>{
      for (final FileSystemEntity entity in root.listSync(recursive: true))
        if (entity is File) fileSystem.path.relative(entity.path, from: root.path),
    }..removeWhere(
      (String path) =>
          path.startsWith('watchos/') || path.startsWith('linux/') || path.startsWith('.dart_tool/'),
    );
  }

  final overrides = <Type, Generator>{
    FileSystem: () => fileSystem,
    ProcessManager: () => FakeProcessManager.any(),
    // Stock create on Linux needs no template images, and its shared files are
    // the ones it writes for every platform.
    FeatureFlags: () => TestFeatureFlags(isLinuxEnabled: true),
    TemplatePathProvider: () => _NoImagesTemplatePathProvider(),
  };

  // An incomplete checkout used to write the shared app, leave watchos/ out
  // and say it had created a watchOS project.
  testUsingContext(
    'a watch-only create without the watchos/ template stops before it writes anything',
    () async {
      fileSystem.directory(cliRootPath('templates')).deleteSync(recursive: true);

      await expectLater(
        create(WatchosCreateCommand(verboseHelp: false), <String>[
          '--watchos-only',
          '/projects/watch',
        ]),
        throwsToolExit(message: 'The flutter-watchos checkout looks incomplete.'),
      );

      expect(project('watch').existsSync(), isFalse);
    },
    overrides: overrides,
  );

  testUsingContext(
    'a watch-only create writes the files stock create writes, unmodified',
    () async {
      await create(WatchosCreateCommand(verboseHelp: false), <String>[
        '--watchos-only',
        '/projects/watch',
      ]);
      await create(CreateCommand(), <String>['--platforms=linux', '/projects/stock']);

      expect(files('watch'), files('stock'));
      for (final String path in files('stock')) {
        if (path == '.metadata' || path == 'analysis_options.yaml') {
          // Both name the platforms each create made.
          continue;
        }
        expect(read('watch', path), read('stock', path), reason: path);
      }
      expect(read('watch', '.metadata'), contains('project_type: app'));
      // Stock excludes the folder of each platform it made from analysis;
      // the watch-only app has none of those folders.
      expect(
        read('watch', 'analysis_options.yaml'),
        read('stock', 'analysis_options.yaml').replaceAll('    - linux/**\n', ''),
      );
      // The counter, as stock writes it.
      final String mainDart = read('watch', 'lib/main.dart');
      expect(mainDart, contains('You have pushed the button this many times:'));
      expect(mainDart, contains('FloatingActionButton('));
      // The lock holds the SDK's own versions, as stock's does.
      final packages =
          (json.decode(read('watch', 'pubspec.lock')) as Map<String, Object?>)['packages']!
              as Map<String, Object?>;
      expect(packages, isNotEmpty);
      // The watch app is beside it, and no other platform is.
      expect(project('watch').childDirectory('watchos').existsSync(), isTrue);
      for (final platform in <String>['ios', 'android', 'web', 'macos', 'linux', 'windows']) {
        expect(project('watch').childDirectory(platform).existsSync(), isFalse, reason: platform);
      }
      expect(testLogger.statusText, contains('Created watchOS-only project'));
      expect(testLogger.statusText, contains("The app is stock Flutter's counter"));
    },
    overrides: overrides,
  );

  testUsingContext(
    'a watch-only create honours --empty as stock does',
    () async {
      await create(WatchosCreateCommand(verboseHelp: false), <String>[
        '--watchos-only',
        '--empty',
        '/projects/watch',
      ]);
      await create(CreateCommand(), <String>['--platforms=linux', '--empty', '/projects/stock']);

      expect(files('watch'), files('stock'));
      expect(read('watch', 'lib/main.dart'), read('stock', 'lib/main.dart'));
      expect(project('watch').childFile('test/widget_test.dart').existsSync(), isFalse);
    },
    overrides: overrides,
  );

  testUsingContext(
    'a failed pub get still leaves the whole project, watchos/ included',
    () async {
      await expectLater(
        create(WatchosCreateCommand(verboseHelp: false), <String>[
          '--watchos-only',
          '/projects/watch',
        ], pub: true),
        throwsToolExit(message: 'Failed to update packages.'),
      );

      expect(project('watch').childFile('lib/main.dart').existsSync(), isTrue);
      expect(project('watch').childFile('watchos/Runner/Info.plist').existsSync(), isTrue);
    },
    overrides: <Type, Generator>{...overrides, Pub: () => _FailingPub()},
  );

  testUsingContext(
    'beside an iOS app, it says so and links the companion docs',
    () async {
      project('watch').childFile('ios/Runner.xcodeproj/project.pbxproj')
        ..createSync(recursive: true)
        ..writeAsStringSync(_iosPbxproj);

      await create(WatchosCreateCommand(verboseHelp: false), <String>[
        '--watchos-only',
        '/projects/watch',
      ]);

      expect(testLogger.statusText, contains('Added watchos/ beside the iOS app in ios/.'));
      expect(testLogger.statusText, isNot(contains('no other platforms')));
      expect(testLogger.statusText, contains('doc/companion-apps.md'));
    },
    overrides: overrides,
  );

  for (final (String label, List<String> args) in <(String, List<String>)>[
    ('another template', <String>['--template=package']),
    ('a sample', <String>['--sample=widgets.Text.1']),
  ]) {
    testUsingContext(
      'refuses $label before writing anything',
      () async {
        await expectLater(
          create(WatchosCreateCommand(verboseHelp: false), <String>[
            '--watchos-only',
            ...args,
            '/projects/watch',
          ]),
          throwsToolExit(),
        );
        expect(project('watch').existsSync(), isFalse);
      },
      overrides: overrides,
    );
  }

  // Stock create writes the samples list before it asks for a directory, so
  // the refusal comes first with a directory or without one.
  for (final (String label, List<String> directory) in <(String, List<String>)>[
    ('with a directory', <String>['/projects/watch']),
    ('without a directory', <String>[]),
  ]) {
    testUsingContext(
      'refuses --list-samples $label before writing anything',
      () async {
        await expectLater(
          create(WatchosCreateCommand(verboseHelp: false), <String>[
            '--watchos-only',
            '--list-samples=/projects/samples.json',
            ...directory,
          ]),
          throwsToolExit(message: 'does not take --list-samples'),
        );
        expect(fileSystem.directory('/projects').existsSync(), isFalse);
      },
      overrides: overrides,
    );
  }

  // With other platforms, stock create makes the project. A package or a
  // module has no app to run on a watch: it gets no watchos/, and one line
  // says so.
  for (final (String template, String what) in <(String, String)>[
    ('package', 'a package'),
    ('module', 'a module'),
  ]) {
    testUsingContext(
      'adds no watchos/ to $what made by stock create, and says so',
      () async {
        await create(WatchosCreateCommand(verboseHelp: false), <String>[
          '--template=$template',
          '/projects/$template',
        ]);

        expect(project(template).childFile('pubspec.yaml').existsSync(), isTrue);
        expect(project(template).childDirectory('watchos').existsSync(), isFalse);
        final List<String> watchosLines = testLogger.statusText
            .split('\n')
            .where((String line) => line.contains('watchos'))
            .toList();
        expect(watchosLines, <String>[
          'No watchos/ was added: $what has no app to run on a watch.',
        ]);
      },
      overrides: overrides,
    );
  }

  testUsingContext(
    'adds no watchos/ to an existing package that create . recreates',
    () async {
      await create(CreateCommand(), <String>['--template=package', '/projects/package']);
      testLogger.clear();

      // No --template: stock create finds the package's type in .metadata.
      await create(WatchosCreateCommand(verboseHelp: false), <String>['/projects/package']);

      expect(project('package').childDirectory('watchos').existsSync(), isFalse);
      expect(
        testLogger.statusText,
        contains('No watchos/ was added: a package has no app to run on a watch.'),
      );
    },
    overrides: overrides,
  );

  testUsingContext(
    'adds watchos/ beside an app made by stock create',
    () async {
      await create(WatchosCreateCommand(verboseHelp: false), <String>[
        '--platforms=linux',
        '/projects/app',
      ]);

      expect(project('app').childDirectory('linux').existsSync(), isTrue);
      expect(project('app').childFile('watchos/Runner/Info.plist').existsSync(), isTrue);
      expect(testLogger.statusText, isNot(contains('No watchos/ was added')));
    },
    overrides: overrides,
  );
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

/// A `pub get` that fails as the real one does when pub exits non-zero.
class _FailingPub extends Fake implements Pub {
  @override
  Future<void> get({
    required PubContext context,
    required FlutterProject project,
    bool upgrade = false,
    bool offline = false,
    String? flutterRootOverride,
    bool checkUpToDate = false,
    bool shouldSkipThirdPartyGenerator = true,
    bool enforceLockfile = false,
    PubOutputMode outputMode = PubOutputMode.all,
  }) async {
    throwToolExit('Failed to update packages.');
  }
}
