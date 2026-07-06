// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/process.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/runner/flutter_command.dart';
import 'package:meta/meta.dart';

/// Uploads an App Store `.ipa` (built by `flutter-watchos build ipa`) to
/// App Store Connect via `xcrun altool`, validating first.
///
/// Authentication uses an App Store Connect API key: pass `--api-key-id` and
/// `--api-issuer` (or set APP_STORE_CONNECT_API_KEY_ID /
/// APP_STORE_CONNECT_API_ISSUER). The .p8 secret itself is read by altool
/// from `~/.appstoreconnect/private_keys/AuthKey_<id>.p8` — this tool never
/// touches it.
class WatchosUploadCommand extends FlutterCommand {
  WatchosUploadCommand() {
    argParser
      ..addOption(
        'ipa',
        help: 'Path to the .ipa to upload. Defaults to the most recent one '
            'under build/watchos/ipa/.',
      )
      ..addOption('api-key-id', help: 'App Store Connect API key id.')
      ..addOption('api-issuer', help: 'App Store Connect API issuer id.')
      ..addFlag(
        'validate-only',
        negatable: false,
        help: 'Run App Store Connect validation without uploading.',
      );
  }

  @override
  final String name = 'upload';

  @override
  final String description =
      'Validate and upload an App Store .ipa to App Store Connect.';

  @override
  final String category = FlutterCommandCategory.project;

  @override
  Future<Set<DevelopmentArtifact>> get requiredArtifacts async =>
      const <DevelopmentArtifact>{};

  /// The altool argv for a validate or upload call — pure, for testing.
  @visibleForTesting
  static List<String> altoolArgs({
    required bool upload,
    required String ipaPath,
    required String apiKeyId,
    required String apiIssuer,
  }) {
    return <String>[
      'xcrun', 'altool',
      if (upload) '--upload-app' else '--validate-app',
      '-f', ipaPath,
      // Watch-only containers are iOS packages as far as delivery goes.
      '--platform', 'ios',
      '--apiKey', apiKeyId,
      '--apiIssuer', apiIssuer,
      '--output-format', 'normal',
    ];
  }

  String _credential(String flagName, String envName) {
    final String? flag = stringArg(flagName);
    if (flag != null && flag.isNotEmpty) {
      return flag;
    }
    final String? env = globals.platform.environment[envName];
    if (env != null && env.isNotEmpty) {
      return env;
    }
    throwToolExit(
      'Missing --$flagName (or \$$envName).\n'
      'Create an App Store Connect API key at Users and Access > Integrations '
      '(role: App Manager), download the .p8 into '
      '~/.appstoreconnect/private_keys/, and pass the key id + issuer id.',
    );
  }

  File _resolveIpa() {
    final String? explicit = stringArg('ipa');
    if (explicit != null && explicit.isNotEmpty) {
      final File file = globals.fs.file(explicit);
      if (!file.existsSync()) {
        throwToolExit('No ipa at $explicit.');
      }
      return file;
    }
    final Directory ipaDir = globals.fs
        .directory('build')
        .childDirectory('watchos')
        .childDirectory('ipa');
    final List<File> candidates = ipaDir.existsSync()
        ? (ipaDir
            .listSync()
            .whereType<File>()
            .where((File f) => f.path.endsWith('.ipa'))
            .toList()
          ..sort((File a, File b) =>
              b.statSync().modified.compareTo(a.statSync().modified)))
        : <File>[];
    if (candidates.isEmpty) {
      throwToolExit(
        'No .ipa found under build/watchos/ipa/. '
        'Run `flutter-watchos build ipa` first, or pass --ipa.',
      );
    }
    return candidates.first;
  }

  Future<void> _runAltool({
    required bool upload,
    required File ipa,
    required String apiKeyId,
    required String apiIssuer,
  }) async {
    final verb = upload ? 'Uploading' : 'Validating';
    final Status status = globals.logger.startProgress(
        '$verb ${ipa.basename} with App Store Connect...');
    RunResult result;
    try {
      result = await globals.processUtils.run(altoolArgs(
        upload: upload,
        ipaPath: ipa.path,
        apiKeyId: apiKeyId,
        apiIssuer: apiIssuer,
      ));
    } finally {
      status.stop();
    }
    final output = '${result.stdout}\n${result.stderr}';
    if (result.exitCode != 0) {
      // altool's 409 payloads carry precise, actionable messages — surface
      // them verbatim.
      throwToolExit('${upload ? 'Upload' : 'Validation'} failed:\n$output');
    }
    final RegExpMatch? delivery =
        RegExp(r'Delivery UUID: (\S+)').firstMatch(output);
    if (upload) {
      globals.logger.printStatus('✓ Upload accepted by App Store Connect.');
      if (delivery != null) {
        globals.logger.printStatus('  Delivery UUID: ${delivery.group(1)}');
      }
      globals.logger.printStatus(
          '  The build appears under TestFlight/Builds after processing '
          '(typically a few minutes).');
    } else {
      globals.logger.printStatus('✓ Validation passed — no errors.');
    }
  }

  @override
  Future<FlutterCommandResult> runCommand() async {
    if (!globals.platform.isMacOS) {
      throwToolExit('flutter-watchos upload requires macOS with Xcode.');
    }
    final File ipa = _resolveIpa();
    final String apiKeyId = _credential('api-key-id', 'APP_STORE_CONNECT_API_KEY_ID');
    final String apiIssuer = _credential('api-issuer', 'APP_STORE_CONNECT_API_ISSUER');

    await _runAltool(upload: false, ipa: ipa, apiKeyId: apiKeyId, apiIssuer: apiIssuer);
    if (boolArg('validate-only')) {
      return FlutterCommandResult.success();
    }
    await _runAltool(upload: true, ipa: ipa, apiKeyId: apiKeyId, apiIssuer: apiIssuer);
    return FlutterCommandResult.success();
  }
}
