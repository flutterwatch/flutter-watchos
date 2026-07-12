// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';

/// How the watch app reaches the App Store.
///
/// Apple has no watch-only submission path: every watch app ships inside an
/// iOS app's `Watch/` folder. What varies is what that iOS app *is*:
///
/// * [standalone] — the thin `HostApp` container generated inside `watchos/`
///   (`ITSWatchOnlyContainer`, `LSApplicationLaunchProhibited`). The watch app
///   declares `WKWatchOnly`. A project without an iOS app.
/// * [companion] — the project's real Flutter iOS app in `ios/`. The watch
///   app is embedded into the iOS Runner by an "Embed Prebuilt watchOS App"
///   build phase and declares `WKCompanionAppBundleIdentifier` instead of
///   `WKWatchOnly`.
///
/// The mode is never configured anywhere — like stock Flutter, the project
/// shape is the source of truth ([detectWatchosHostMode]): an `ios/` app
/// means the watch app is its companion; no iOS app means watch-only.
///
/// The two modes disagree about Info.plist keys and Xcode wiring, and a
/// half-converted project (e.g. `WKWatchOnly` still set while the watch app
/// ships inside a launchable iOS app) is rejected by App Store validation.
/// [reconcileWatchosHostMode] makes the project consistent with one mode and
/// is safe to re-run (idempotent), so the create/build/run commands self-heal
/// via [syncWatchosHostMode].
enum WatchosHostMode { standalone, companion }

const String _embedPhaseName = 'Embed Prebuilt watchOS App';
// Synthetic UUID in the same style as the watchos template's AB00…/CE00…
// identifiers. pbxproj UUIDs are 24 hex chars; FA-prefixed so it cannot
// collide with template or Xcode-generated ids.
const String _embedPhaseUuid = 'FA0000000000000000000001';

// Copies the prebuilt watch Runner.app (produced by
// `flutter-watchos build watchos`) into the iOS app's Watch/ folder. Debug
// iOS builds pair with the Simulator watch build (the only debug watch
// build that exists — the watch has no device JIT); everything else
// (Release/Profile) pairs with the AOT device build.
// pbxproj shellScript values are single-line strings with the script's
// newlines written as literal `\n` escapes — hence the raw-string join.
final String _embedPhaseShellScript = <String>[
  r'if [ \"$CONFIGURATION\" = \"Debug\" ]; then',
  r'  WATCHOS_CONF=\"Debug-watchsimulator\"',
  r'else',
  r'  WATCHOS_CONF=\"Release-watchos\"',
  r'fi',
  r'',
  r'WATCHOS_APP_SRC=\"${SRCROOT}/../build/watchos/${WATCHOS_CONF}/Runner.app\"',
  r'WATCHOS_APP_DST=\"${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/Watch\"',
  r'',
  r'if [ -d \"$WATCHOS_APP_SRC\" ]; then',
  r'  mkdir -p \"$WATCHOS_APP_DST\"',
  r'  cp -R \"$WATCHOS_APP_SRC\" \"$WATCHOS_APP_DST/\"',
  r'  echo \"Embedded watchOS app from $WATCHOS_APP_SRC\"',
  r'else',
  r'  echo \"warning: watchOS app not found at $WATCHOS_APP_SRC. Run flutter-watchos build watchos --release (device) or --simulator first.\"',
  r'fi',
  r'',
].join(r'\n');

/// The logical host mode for the project's current shape: [WatchosHostMode.companion]
/// when a Flutter iOS app exists at `ios/Runner.xcodeproj` (an app that ships
/// an iPhone version carries its watch app inside that), otherwise
/// [WatchosHostMode.standalone].
WatchosHostMode detectWatchosHostMode(Directory projectDir) {
  return _iosPbxproj(projectDir).existsSync()
      ? WatchosHostMode.companion
      : WatchosHostMode.standalone;
}

/// Detects the host mode from the project shape and makes the Xcode wiring /
/// Info.plist keys consistent with it. Idempotent, and quiet when nothing
/// needs changing — so create/build/run call it unconditionally and the
/// project follows its shape automatically (add an iOS app and the watch app
/// becomes its companion; remove it and the watch app is watch-only again).
///
/// Returns the detected mode, or null when the project has no watch runner
/// to reconcile (plugin projects, bare `watchos/` directories).
Future<WatchosHostMode?> syncWatchosHostMode({
  required Directory projectDir,
  required Logger logger,
}) async {
  if (!_watchInfoPlist(projectDir).existsSync()) {
    return null;
  }
  final WatchosHostMode mode = detectWatchosHostMode(projectDir);
  await reconcileWatchosHostMode(projectDir: projectDir, mode: mode, logger: logger);
  return mode;
}

/// The iOS Runner's bundle identifier, read from
/// `ios/Runner.xcodeproj/project.pbxproj`. Test-bundle ids (`*.RunnerTests`)
/// are ignored. Null when there is no iOS project.
String? iosBundleIdentifier(Directory projectDir) {
  final File pbxproj = _iosPbxproj(projectDir);
  if (!pbxproj.existsSync()) {
    return null;
  }
  final Iterable<RegExpMatch> matches = RegExp('PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);')
      .allMatches(pbxproj.readAsStringSync());
  final counts = <String, int>{};
  for (final m in matches) {
    final String id = m[1]!.trim().replaceAll('"', '');
    if (id.endsWith('.RunnerTests') || id.contains(r'$(')) {
      continue;
    }
    counts[id] = (counts[id] ?? 0) + 1;
  }
  if (counts.isEmpty) {
    return null;
  }
  return (counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;
}

/// The watch Runner's bundle identifier from
/// `watchos/Runner.xcodeproj/project.pbxproj`.
String? watchosBundleIdentifier(Directory projectDir) {
  final File pbxproj = projectDir
      .childDirectory('watchos')
      .childDirectory('Runner.xcodeproj')
      .childFile('project.pbxproj');
  if (!pbxproj.existsSync()) {
    return null;
  }
  final RegExpMatch? m = RegExp('PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);')
      .firstMatch(pbxproj.readAsStringSync());
  return m?[1]?.trim().replaceAll('"', '');
}

/// Whether the iOS Runner already carries the embed-watch-app build phase.
bool iosEmbedPhasePresent(Directory projectDir) {
  final File pbxproj = _iosPbxproj(projectDir);
  return pbxproj.existsSync() &&
      pbxproj.readAsStringSync().contains('/* $_embedPhaseName */');
}

/// Whether the watch Info.plist declares `WKWatchOnly`.
bool watchosPlistIsWatchOnly(Directory projectDir) {
  final File plist = _watchInfoPlist(projectDir);
  return plist.existsSync() &&
      plist.readAsStringSync().contains('<key>WKWatchOnly</key>');
}

/// Brings the project's Xcode wiring and Info.plist keys in line with [mode].
/// Idempotent: running it on an already-consistent project changes nothing
/// and prints nothing.
Future<void> reconcileWatchosHostMode({
  required Directory projectDir,
  required WatchosHostMode mode,
  required Logger logger,
}) async {
  final File watchPlist = _watchInfoPlist(projectDir);
  if (!watchPlist.existsSync()) {
    throwToolExit('No watch app Info.plist at ${watchPlist.path}. '
        'Is this a flutter-watchos project?');
  }

  switch (mode) {
    case WatchosHostMode.standalone:
      _reconcileStandalone(projectDir, watchPlist, logger);
    case WatchosHostMode.companion:
      _reconcileCompanion(projectDir, watchPlist, logger);
  }
}

void _reconcileStandalone(Directory projectDir, File watchPlist, Logger logger) {
  String xml = watchPlist.readAsStringSync();
  final original = xml;
  xml = _removePlistKey(xml, 'WKCompanionAppBundleIdentifier');
  xml = _removePlistKey(xml, 'WKRunsIndependentlyOfCompanionApp');
  xml = _setPlistBool(xml, 'WKWatchOnly', true);
  if (xml != original) {
    watchPlist.writeAsStringSync(xml);
    logger.printStatus(
      'watchos/Runner/Info.plist: set WKWatchOnly, removed companion keys.',
    );
  }

  // A leftover embed phase would still copy the watch app into the real iOS
  // app — shipping it as a companion by accident. Remove the wiring.
  final File pbxproj = _iosPbxproj(projectDir);
  if (pbxproj.existsSync()) {
    final String content = pbxproj.readAsStringSync();
    final String stripped = _removeEmbedPhase(content);
    if (stripped != content) {
      pbxproj.writeAsStringSync(stripped);
      logger.printStatus('ios/Runner.xcodeproj: removed "$_embedPhaseName" build phase.');
    }
  }
  _stripWatchosWorkspaceRef(projectDir, logger);
}

void _reconcileCompanion(Directory projectDir, File watchPlist, Logger logger) {
  final File pbxproj = _iosPbxproj(projectDir);
  if (!pbxproj.existsSync()) {
    throwToolExit(
      'Companion mode needs a Flutter iOS app, but ios/Runner.xcodeproj was '
      'not found.\n'
      'Add one with: flutter create --platforms=ios .\n'
      'Or stay watch-only with: flutter-watchos host standalone',
    );
  }
  final String? iosId = iosBundleIdentifier(projectDir);
  if (iosId == null) {
    throwToolExit('Could not read PRODUCT_BUNDLE_IDENTIFIER from ${pbxproj.path}.');
  }

  // Apple requires the watch app's bundle id to be prefixed by its
  // companion's (<ios-id>.<suffix>); a mismatch fails App Store validation.
  final String? watchId = watchosBundleIdentifier(projectDir);
  if (watchId != null && !watchId.startsWith('$iosId.')) {
    logger.printWarning(
      'Watch bundle id "$watchId" is not prefixed by the iOS app id "$iosId". '
      'App Store validation requires e.g. "$iosId.watchkitapp".',
    );
  }

  String xml = watchPlist.readAsStringSync();
  final original = xml;
  xml = _removePlistKey(xml, 'WKWatchOnly');
  xml = _setPlistString(xml, 'WKCompanionAppBundleIdentifier', iosId);
  xml = _setPlistBool(xml, 'WKRunsIndependentlyOfCompanionApp', true);
  if (xml != original) {
    watchPlist.writeAsStringSync(xml);
    logger.printStatus(
      'watchos/Runner/Info.plist: set WKCompanionAppBundleIdentifier=$iosId, '
      'removed WKWatchOnly.',
    );
  }

  String content = pbxproj.readAsStringSync();
  if (!content.contains('/* $_embedPhaseName */')) {
    content = _injectEmbedPhase(content);
    pbxproj.writeAsStringSync(content);
    logger.printStatus('ios/Runner.xcodeproj: added "$_embedPhaseName" build phase.');
  }

  // The watchos project must NOT be referenced from ios/Runner.xcworkspace:
  // both projects have a scheme named "Runner", and the ambiguity makes
  // `flutter build ios` resolve the watch scheme (watch-simulator
  // destinations only) and fail. The embed phase above is the only wiring
  // companion mode needs; strip the reference from projects that got one
  // from earlier versions of this tool.
  _stripWatchosWorkspaceRef(projectDir, logger);
}

void _stripWatchosWorkspaceRef(Directory projectDir, Logger logger) {
  final File workspace = _iosWorkspaceData(projectDir);
  if (!workspace.existsSync()) {
    return;
  }
  final String content = workspace.readAsStringSync();
  final String stripped = _removeWorkspaceRef(content);
  if (stripped != content) {
    workspace.writeAsStringSync(stripped);
    logger.printStatus(
      'ios/Runner.xcworkspace: removed watchos project reference (its '
      '"Runner" scheme shadows the iOS one and breaks flutter build ios).',
    );
  }
}

// ── Info.plist string surgery ────────────────────────────────────────────────
// The watch Info.plist is template-generated XML; targeted edits keep user
// formatting/comments intact where a parse–serialize round trip would not.

String _removePlistKey(String xml, String key) {
  return xml.replaceAll(
    RegExp('[ \t]*<key>$key</key>\\s*\n[ \t]*(?:<true/>|<false/>|<string>[^<]*</string>)[ \t]*\n'),
    '',
  );
}

String _insertBeforeFinalDictClose(String xml, String entry) {
  final int idx = xml.lastIndexOf('</dict>');
  if (idx < 0) {
    throwToolExit('Malformed Info.plist: no closing </dict>.');
  }
  return xml.replaceRange(idx, idx, entry);
}

String _setPlistBool(String xml, String key, bool value) {
  xml = _removePlistKey(xml, key);
  return _insertBeforeFinalDictClose(
    xml,
    '\t<key>$key</key>\n\t<${value ? 'true' : 'false'}/>\n',
  );
}

String _setPlistString(String xml, String key, String value) {
  xml = _removePlistKey(xml, key);
  return _insertBeforeFinalDictClose(xml, '\t<key>$key</key>\n\t<string>$value</string>\n');
}

// ── pbxproj / workspace surgery ──────────────────────────────────────────────

String _injectEmbedPhase(String content) {
  // 1. Register the phase on the Runner target: right after the Flutter
  //    "Thin Binary" phase, which every stock Flutter iOS Runner target has.
  final thinBinaryEntry = RegExp(r'([ \t]*)([A-F0-9]{24} /\* Thin Binary \*/,\n)');
  final RegExpMatch? entry = thinBinaryEntry.firstMatch(content);
  if (entry == null) {
    throwToolExit(
      'ios/Runner.xcodeproj does not look like a Flutter iOS project '
      '(no "Thin Binary" build phase found); cannot wire companion mode.',
    );
  }
  content = content.replaceRange(
    entry.end,
    entry.end,
    '${entry[1]}$_embedPhaseUuid /* $_embedPhaseName */,\n',
  );

  // 2. Define the phase in the PBXShellScriptBuildPhase section (present in
  //    every Flutter iOS project — Run Script + Thin Binary live there).
  const sectionEnd = '/* End PBXShellScriptBuildPhase section */';
  final int endIdx = content.indexOf(sectionEnd);
  if (endIdx < 0) {
    throwToolExit('ios pbxproj has no PBXShellScriptBuildPhase section.');
  }
  final block =
      '\t\t$_embedPhaseUuid /* $_embedPhaseName */ = {\n'
      '\t\t\tisa = PBXShellScriptBuildPhase;\n'
      '\t\t\talwaysOutOfDate = 1;\n'
      '\t\t\tbuildActionMask = 2147483647;\n'
      '\t\t\tfiles = (\n'
      '\t\t\t);\n'
      '\t\t\tinputPaths = (\n'
      '\t\t\t);\n'
      '\t\t\tname = "$_embedPhaseName";\n'
      '\t\t\toutputPaths = (\n'
      '\t\t\t);\n'
      '\t\t\trunOnlyForDeploymentPostprocessing = 0;\n'
      '\t\t\tshellPath = /bin/bash;\n'
      '\t\t\tshellScript = "$_embedPhaseShellScript";\n'
      '\t\t};\n';
  return content.replaceRange(endIdx, endIdx, block);
}

String _removeEmbedPhase(String content) {
  // Reference in a buildPhases list (any UUID — the phase may have been added
  // by hand, as in older projects).
  content = content.replaceAll(
    RegExp('[ \t]*[A-F0-9]{24} /\\* $_embedPhaseName \\*/,\n'),
    '',
  );
  // The section block, from its header line through the matching "};".
  content = content.replaceAll(
    RegExp(
      '[ \t]*[A-F0-9]{24} /\\* $_embedPhaseName \\*/ = \\{.*?\n[ \t]*\\};\n',
      dotAll: true,
    ),
    '',
  );
  return content;
}

String _removeWorkspaceRef(String content) {
  return content.replaceAll(
    RegExp(
      '[ \t]*<FileRef\\s*\n[ \t]*location = "group:\\.\\./watchos/Runner\\.xcodeproj">\\s*\n[ \t]*</FileRef>\n',
    ),
    '',
  );
}

File _iosPbxproj(Directory projectDir) => projectDir
    .childDirectory('ios')
    .childDirectory('Runner.xcodeproj')
    .childFile('project.pbxproj');

File _iosWorkspaceData(Directory projectDir) => projectDir
    .childDirectory('ios')
    .childDirectory('Runner.xcworkspace')
    .childFile('contents.xcworkspacedata');

File _watchInfoPlist(Directory projectDir) => projectDir
    .childDirectory('watchos')
    .childDirectory('Runner')
    .childFile('Info.plist');
