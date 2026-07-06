// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/process.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/commands/build.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/project.dart';
import 'package:flutter_tools/src/runner/flutter_command.dart';

import '../watchos_build_info.dart';
import '../watchos_builder.dart';
import '../watchos_cache.dart';
import '../watchos_distribution.dart';
import '../watchos_plugins.dart';

/// Builds an App Store `.ipa` for a standalone (watch-only) app.
///
/// Top-level (`flutter-watchos archive`) rather than a `build` subcommand:
/// stock flutter_tools already owns `build ipa` (the iOS archiver, which is
/// the right tool for companion apps that embed a watch app in an iOS
/// host), and the two must not shadow each other.
///
/// Xcode 26's `xcodebuild -exportArchive` cannot produce App Store packages
/// from watch-only archives, so this command reproduces what Xcode Organizer
/// does: release build → `xcodebuild archive` → distribution re-sign →
/// watch-only iOS container synthesis → `Payload/*.ipa`. See
/// `watchos_distribution.dart` for the packaging rules (each one was dictated
/// by App Store Connect validation).
class WatchosArchiveCommand extends BuildSubCommand with WatchosRequiredArtifacts {
  WatchosArchiveCommand({required super.logger, required bool verboseHelp})
    : super(verboseHelp: verboseHelp) {
    addCommonDesktopBuildOptions(verboseHelp: verboseHelp);
    argParser
      ..addOption(
        'signing-cert',
        help: 'SHA-1 hash of the "Apple Distribution" certificate to sign '
            'with. Defaults to the first valid one in the keychain.',
      )
      ..addOption(
        'api-key-id',
        help: 'App Store Connect API key id, passed to xcodebuild for '
            'automatic provisioning during the archive step.',
      )
      ..addOption(
        'api-issuer',
        help: 'App Store Connect API issuer id (used with --api-key-id).',
      );
  }

  @override
  final String name = 'archive';

  @override
  List<String> get aliases => const <String>['ipa'];

  @override
  final String description =
      'Build an App Store .ipa for a standalone watchOS application.';

  @override
  Future<void> validateCommand() async {
    final FlutterProject project = FlutterProject.current();
    await ensureReadyForWatchosTooling(project);
    return super.validateCommand();
  }

  @override
  Future<FlutterCommandResult> runCommand() async {
    final FlutterProject project = FlutterProject.current();
    final BuildInfo buildInfo = await getBuildInfo();
    if (buildInfo.mode != BuildMode.release) {
      throwToolExit(
        'App Store packages are always release builds — '
        'remove --${buildInfo.mode.cliName} and try again.',
      );
    }

    // 1. Release build (stages engine + assets into watchos/Flutter/).
    await WatchosBuilder.buildBundle(
      project: project,
      watchosBuildInfo: WatchosBuildInfo(buildInfo, targetArch: 'arm64'),
      targetFile: targetFile,
    );

    final Directory buildDir =
        project.directory.childDirectory('build').childDirectory('watchos');
    final Directory ipaDir = buildDir.childDirectory('ipa');
    if (ipaDir.existsSync()) {
      ipaDir.deleteSync(recursive: true);
    }
    ipaDir.createSync(recursive: true);
    final Directory archivePath = ipaDir.childDirectory('Runner.xcarchive');

    // 2. Archive. Development signing is fine here — the store re-sign
    // happens during container synthesis below.
    final String? apiKeyId = stringArg('api-key-id');
    final String? apiIssuer = stringArg('api-issuer');
    final Status archiveStatus = globals.logger.startProgress('Archiving Runner.xcodeproj...');
    try {
      final RunResult archive = await globals.processUtils.run(<String>[
        'xcodebuild', 'archive',
        '-project', project.directory.childDirectory('watchos').childFile('Runner.xcodeproj').path,
        '-scheme', 'Runner',
        '-configuration', 'Release',
        '-destination', 'generic/platform=watchOS',
        '-archivePath', archivePath.path,
        '-allowProvisioningUpdates',
        if (apiKeyId != null && apiIssuer != null) ...<String>[
          '-authenticationKeyPath', _apiKeyPathFor(apiKeyId),
          '-authenticationKeyID', apiKeyId,
          '-authenticationKeyIssuerID', apiIssuer,
        ],
      ]);
      if (archive.exitCode != 0) {
        throwToolExit('xcodebuild archive failed:\n${archive.stderr}\n${archive.stdout}');
      }
    } finally {
      archiveStatus.stop();
    }

    final Directory archivedApp = archivePath
        .childDirectory('Products')
        .childDirectory('Applications')
        .childDirectory('Runner.app');
    if (!archivedApp.existsSync()) {
      throwToolExit('Archive did not produce ${archivedApp.path}.');
    }

    // 3. Package the watch-only container.
    final packager = WatchosIpaPackager(
      fileSystem: globals.fs,
      logger: globals.logger,
      processUtils: globals.processUtils,
      homeDirPath: globals.fsUtils.homeDirPath!,
    );
    final ({String bundleId, String shortVersion, String buildNumber, String displayName})
        identity0 = await packager.readAppIdentity(archivedApp);
    final String containerId = containerBundleIdFor(identity0.bundleId);
    final String watchId = watchBundleIdFor(identity0.bundleId);

    final Directory scratch = ipaDir.childDirectory('.scratch')..createSync(recursive: true);
    final List<ProvisioningProfileInfo> profiles = await packager.scanProfiles(scratch);
    final ProvisioningProfileInfo? hostProfile = selectStoreProfile(profiles, containerId);
    final ProvisioningProfileInfo? watchProfile = selectStoreProfile(profiles, watchId);
    if (hostProfile == null) {
      packager.missingProfileExit(containerId);
    }
    if (watchProfile == null) {
      packager.missingProfileExit(watchId);
    }
    globals.logger.printTrace('Host profile:  ${hostProfile.name}');
    globals.logger.printTrace('Watch profile: ${watchProfile.name}');

    final String identity =
        await packager.findDistributionIdentity(override: stringArg('signing-cert'));

    final Status packStatus =
        globals.logger.startProgress('Building watch-only App Store container...');
    File ipa;
    try {
      final Directory payload = await packager.synthesizeContainer(
        archivedWatchApp: archivedApp,
        appName: identity0.displayName,
        containerBundleId: containerId,
        shortVersion: identity0.shortVersion,
        buildNumber: identity0.buildNumber,
        hostProfile: hostProfile,
        watchProfile: watchProfile,
        identity: identity,
        workDir: scratch,
      );
      await packager.collectSwiftSupport(payload);
      ipa = await packager.packageIpa(
        payload,
        ipaDir.childFile('${project.manifest.appName}.ipa'),
      );
    } finally {
      packStatus.stop();
    }

    packager.printSummary(ipa, containerId, identity0.shortVersion, identity0.buildNumber);
    return FlutterCommandResult.success();
  }

  /// Resolves the .p8 path for [keyId] the way altool/xcodebuild do.
  String _apiKeyPathFor(String keyId) {
    final String home = globals.fsUtils.homeDirPath!;
    for (final dir in <String>[
      globals.fs.path.join(home, '.appstoreconnect', 'private_keys'),
      globals.fs.path.join(home, '.private_keys'),
      globals.fs.path.join(home, 'private_keys'),
    ]) {
      final File key = globals.fs.file(globals.fs.path.join(dir, 'AuthKey_$keyId.p8'));
      if (key.existsSync()) {
        return key.path;
      }
    }
    throwToolExit(
      'API key AuthKey_$keyId.p8 not found. Download it from App Store Connect '
      '(Users and Access > Integrations) and place it in '
      '~/.appstoreconnect/private_keys/.',
    );
  }
}
