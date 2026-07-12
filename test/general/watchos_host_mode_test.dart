// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_watchos/watchos_host_mode.dart';

import '../src/common.dart';

const String _watchPlistWatchOnly = '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>my_app</string>
	<key>WKApplication</key>
	<true/>
	<key>WKWatchOnly</key>
	<true/>
</dict>
</plist>
''';

// A stock Flutter iOS pbxproj skeleton: the pieces _injectEmbedPhase anchors
// on (a Runner target buildPhases list with Thin Binary, a
// PBXShellScriptBuildPhase section, PRODUCT_BUNDLE_IDENTIFIER settings).
const String _iosPbxproj = '''
		97C146ED1CF9000F007C117D /* Runner */ = {
			isa = PBXNativeTarget;
			buildPhases = (
				97C146EA1CF9000F007C117D /* Sources */,
				97C146EB1CF9000F007C117D /* Frameworks */,
				97C146EC1CF9000F007C117D /* Resources */,
				9705A1C41CF9048500538489 /* Embed Frameworks */,
				3B06AD1E1E4923F5004D2608 /* Thin Binary */,
			);
		};
/* Begin PBXShellScriptBuildPhase section */
		3B06AD1E1E4923F5004D2608 /* Thin Binary */ = {
			isa = PBXShellScriptBuildPhase;
			shellScript = "/bin/sh xcode_backend.sh embed_and_thin";
		};
/* End PBXShellScriptBuildPhase section */
		249021D4217E4FDB00AE95B9 /* Profile */ = {
			buildSettings = {
				PRODUCT_BUNDLE_IDENTIFIER = "com.example.myapp";
			};
		};
		331C8088294A63A400263BE5 /* Debug */ = {
			buildSettings = {
				PRODUCT_BUNDLE_IDENTIFIER = "com.example.myapp.RunnerTests";
			};
		};
		97C147061CF9000F007C117D /* Debug */ = {
			buildSettings = {
				PRODUCT_BUNDLE_IDENTIFIER = "com.example.myapp";
			};
		};
''';

const String _watchPbxproj = '''
		AA0000000000000000000002 /* Debug */ = {
			buildSettings = {
				PRODUCT_BUNDLE_IDENTIFIER = "com.example.myapp.watchkitapp";
			};
		};
''';

const String _workspaceData = '''
<?xml version="1.0" encoding="UTF-8"?>
<Workspace
   version = "1.0">
   <FileRef
      location = "group:Runner.xcodeproj">
   </FileRef>
</Workspace>
''';

void main() {
  late MemoryFileSystem fs;
  late BufferLogger logger;
  late Directory projectDir;

  setUp(() {
    fs = MemoryFileSystem.test();
    logger = BufferLogger.test();
    projectDir = fs.directory('/project')..createSync();
    projectDir.childFile('pubspec.yaml').writeAsStringSync('name: my_app\n');
    projectDir
        .childDirectory('watchos')
        .childDirectory('Runner')
        .childFile('Info.plist')
      ..createSync(recursive: true)
      ..writeAsStringSync(_watchPlistWatchOnly);
    projectDir
        .childDirectory('watchos')
        .childDirectory('Runner.xcodeproj')
        .childFile('project.pbxproj')
      ..createSync(recursive: true)
      ..writeAsStringSync(_watchPbxproj);
  });

  void writeIosProject({String pbxproj = _iosPbxproj}) {
    projectDir
        .childDirectory('ios')
        .childDirectory('Runner.xcodeproj')
        .childFile('project.pbxproj')
      ..createSync(recursive: true)
      ..writeAsStringSync(pbxproj);
    projectDir
        .childDirectory('ios')
        .childDirectory('Runner.xcworkspace')
        .childFile('contents.xcworkspacedata')
      ..createSync(recursive: true)
      ..writeAsStringSync(_workspaceData);
  }

  String watchPlist() => projectDir
      .childDirectory('watchos')
      .childDirectory('Runner')
      .childFile('Info.plist')
      .readAsStringSync();

  String iosPbxproj() => projectDir
      .childDirectory('ios')
      .childDirectory('Runner.xcodeproj')
      .childFile('project.pbxproj')
      .readAsStringSync();

  String workspace() => projectDir
      .childDirectory('ios')
      .childDirectory('Runner.xcworkspace')
      .childFile('contents.xcworkspacedata')
      .readAsStringSync();

  group('companion reconcile', () {
    testWithoutContext('rewrites plist and injects Xcode wiring', () async {
      writeIosProject();

      await reconcileWatchosHostMode(
        projectDir: projectDir,
        mode: WatchosHostMode.companion,
        logger: logger,
      );

      final String plist = watchPlist();
      expect(plist, isNot(contains('WKWatchOnly')));
      expect(plist, contains('<key>WKCompanionAppBundleIdentifier</key>'));
      expect(plist, contains('<string>com.example.myapp</string>'));
      expect(plist, contains('<key>WKRunsIndependentlyOfCompanionApp</key>'));

      final String pbx = iosPbxproj();
      expect(pbx, contains('/* Embed Prebuilt watchOS App */,'));
      expect(pbx, contains('name = "Embed Prebuilt watchOS App";'));
      expect(pbx, contains('build/watchos/'));
      // The watchos project must never be referenced from the iOS workspace:
      // its "Runner" scheme shadows the iOS one and breaks flutter build ios.
      expect(workspace(), isNot(contains('../watchos/Runner.xcodeproj')));
    });

    testWithoutContext('strips a watchos workspace reference left by older versions',
        () async {
      writeIosProject();
      final File ws = projectDir
          .childDirectory('ios')
          .childDirectory('Runner.xcworkspace')
          .childFile('contents.xcworkspacedata');
      ws.writeAsStringSync(ws.readAsStringSync().replaceFirst(
            '</Workspace>',
            '   <FileRef\n'
                '      location = "group:../watchos/Runner.xcodeproj">\n'
                '   </FileRef>\n'
                '</Workspace>',
          ));

      await reconcileWatchosHostMode(
        projectDir: projectDir,
        mode: WatchosHostMode.companion,
        logger: logger,
      );

      expect(workspace(), isNot(contains('../watchos/Runner.xcodeproj')));
      expect(workspace(), _workspaceData);
    });

    testWithoutContext('is idempotent', () async {
      writeIosProject();

      await reconcileWatchosHostMode(
        projectDir: projectDir,
        mode: WatchosHostMode.companion,
        logger: logger,
      );
      final String plistOnce = watchPlist();
      final String pbxOnce = iosPbxproj();
      final String wsOnce = workspace();

      await reconcileWatchosHostMode(
        projectDir: projectDir,
        mode: WatchosHostMode.companion,
        logger: logger,
      );
      expect(watchPlist(), plistOnce);
      expect(iosPbxproj(), pbxOnce);
      expect(workspace(), wsOnce);
      // Exactly one phase reference + one definition.
      expect(RegExp('Embed Prebuilt watchOS App').allMatches(iosPbxproj()).length, 3);
    });

    testWithoutContext('fails without an ios/ project', () async {
      await expectLater(
        reconcileWatchosHostMode(
          projectDir: projectDir,
          mode: WatchosHostMode.companion,
          logger: logger,
        ),
        throwsToolExit(message: 'Companion mode needs a Flutter iOS app'),
      );
    });

    testWithoutContext('warns when the watch bundle id is not prefixed by the iOS id',
        () async {
      writeIosProject();
      projectDir
          .childDirectory('watchos')
          .childDirectory('Runner.xcodeproj')
          .childFile('project.pbxproj')
          .writeAsStringSync('''
		AA0000000000000000000002 /* Debug */ = {
			buildSettings = {
				PRODUCT_BUNDLE_IDENTIFIER = "com.other.watchapp";
			};
		};
''');

      await reconcileWatchosHostMode(
        projectDir: projectDir,
        mode: WatchosHostMode.companion,
        logger: logger,
      );
      expect(logger.warningText, contains('not prefixed by the iOS app id'));
    });
  });

  group('standalone reconcile', () {
    testWithoutContext('restores WKWatchOnly and removes companion wiring', () async {
      writeIosProject();

      // Convert to companion first, then back.
      await reconcileWatchosHostMode(
        projectDir: projectDir,
        mode: WatchosHostMode.companion,
        logger: logger,
      );
      await reconcileWatchosHostMode(
        projectDir: projectDir,
        mode: WatchosHostMode.standalone,
        logger: logger,
      );

      final String plist = watchPlist();
      expect(plist, contains('<key>WKWatchOnly</key>'));
      expect(plist, isNot(contains('WKCompanionAppBundleIdentifier')));
      expect(plist, isNot(contains('WKRunsIndependentlyOfCompanionApp')));

      expect(iosPbxproj(), isNot(contains('Embed Prebuilt watchOS App')));
      expect(workspace(), isNot(contains('../watchos/Runner.xcodeproj')));
      // The Xcode files are structurally what we started with.
      expect(iosPbxproj(), _iosPbxproj);
      expect(workspace(), _workspaceData);
    });

    testWithoutContext('removes a hand-added embed phase with a foreign UUID', () async {
      // Mirrors projects wired manually before the CLI managed host modes.
      writeIosProject();
      String pbx = iosPbxproj();
      pbx = pbx.replaceFirst(
        '3B06AD1E1E4923F5004D2608 /* Thin Binary */,\n',
        '3B06AD1E1E4923F5004D2608 /* Thin Binary */,\n'
            '\t\t\t\t79CBC4A973E1035BD120776C /* Embed Prebuilt watchOS App */,\n',
      );
      pbx = pbx.replaceFirst(
        '/* End PBXShellScriptBuildPhase section */',
        '\t\t79CBC4A973E1035BD120776C /* Embed Prebuilt watchOS App */ = {\n'
            '\t\t\tisa = PBXShellScriptBuildPhase;\n'
            '\t\t\tshellScript = "cp -R something";\n'
            '\t\t};\n'
            '/* End PBXShellScriptBuildPhase section */',
      );
      projectDir
          .childDirectory('ios')
          .childDirectory('Runner.xcodeproj')
          .childFile('project.pbxproj')
          .writeAsStringSync(pbx);

      await reconcileWatchosHostMode(
        projectDir: projectDir,
        mode: WatchosHostMode.standalone,
        logger: logger,
      );
      expect(iosPbxproj(), isNot(contains('Embed Prebuilt watchOS App')));
    });
  });

  group('shape-derived sync', () {
    testWithoutContext('detects standalone without ios/ and companion with it', () {
      expect(detectWatchosHostMode(projectDir), WatchosHostMode.standalone);

      writeIosProject();
      expect(detectWatchosHostMode(projectDir), WatchosHostMode.companion);
    });

    testWithoutContext('keeps a watch-only project standalone', () async {
      final WatchosHostMode? mode =
          await syncWatchosHostMode(projectDir: projectDir, logger: logger);

      expect(mode, WatchosHostMode.standalone);
      expect(watchPlist(), contains('<key>WKWatchOnly</key>'));
      // Already consistent — sync must be silent.
      expect(logger.statusText, isEmpty);
    });

    testWithoutContext('wires companion mode when the project has an iOS app', () async {
      writeIosProject();

      final WatchosHostMode? mode =
          await syncWatchosHostMode(projectDir: projectDir, logger: logger);

      expect(mode, WatchosHostMode.companion);
      final String plist = watchPlist();
      expect(plist, isNot(contains('WKWatchOnly')));
      expect(plist, contains('<key>WKCompanionAppBundleIdentifier</key>'));
      expect(iosPbxproj(), contains('Embed Prebuilt watchOS App'));
      expect(workspace(), isNot(contains('../watchos/Runner.xcodeproj')));
    });

    testWithoutContext('follows the shape when ios/ is added and removed again', () async {
      // watch-only → companion once an iOS app appears…
      writeIosProject();
      await syncWatchosHostMode(projectDir: projectDir, logger: logger);
      expect(watchPlist(), contains('WKCompanionAppBundleIdentifier'));

      // …and back to watch-only when it is deleted.
      projectDir.childDirectory('ios').deleteSync(recursive: true);
      final WatchosHostMode? mode =
          await syncWatchosHostMode(projectDir: projectDir, logger: logger);

      expect(mode, WatchosHostMode.standalone);
      final String plist = watchPlist();
      expect(plist, contains('<key>WKWatchOnly</key>'));
      expect(plist, isNot(contains('WKCompanionAppBundleIdentifier')));
    });

    testWithoutContext('is a no-op when the watch runner is absent', () async {
      // Plugin templates and non-app projects have no watchos/Runner.
      final Directory bare = fs.directory('/bare')..createSync();
      bare.childFile('pubspec.yaml').writeAsStringSync('name: bare\n');

      final WatchosHostMode? mode =
          await syncWatchosHostMode(projectDir: bare, logger: logger);

      expect(mode, isNull);
      expect(logger.statusText, isEmpty);
    });
  });

  group('state probes', () {
    testWithoutContext('report plist and pbxproj state', () async {
      expect(watchosPlistIsWatchOnly(projectDir), isTrue);
      expect(iosEmbedPhasePresent(projectDir), isFalse);
      expect(iosBundleIdentifier(projectDir), isNull);

      writeIosProject();
      expect(iosBundleIdentifier(projectDir), 'com.example.myapp');
      expect(watchosBundleIdentifier(projectDir), 'com.example.myapp.watchkitapp');

      await reconcileWatchosHostMode(
        projectDir: projectDir,
        mode: WatchosHostMode.companion,
        logger: logger,
      );
      expect(watchosPlistIsWatchOnly(projectDir), isFalse);
      expect(iosEmbedPhasePresent(projectDir), isTrue);
    });
  });
}
