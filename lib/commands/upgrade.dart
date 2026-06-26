// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';

import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/base/io.dart';
import 'package:flutter_tools/src/base/process.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/commands/upgrade.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/runner/flutter_command.dart';
import 'package:meta/meta.dart';

/// `flutter-watchos upgrade` — upgrades the flutter-watchos toolchain itself to
/// the latest released version.
///
/// Unlike stock `flutter upgrade` (which moves the vendored Flutter SDK toward
/// upstream and would break our pinned `flutter.version` ↔ engine-artifact
/// contract), this command upgrades the **flutter-watchos checkout** to its
/// newest release tag. A release tag bumps the pinned Flutter version *and* the
/// matching engine artifacts together, so after the upgrade `precache` pulls
/// the correct engine for the new pin.
///
/// Release tags follow `v<flutter-version>-watchos.<tool-version>`, e.g.
/// `v3.44.1-watchos.0.1.0`. The newest tag by version order is the target.
class WatchosUpgradeCommand extends UpgradeCommand {
  WatchosUpgradeCommand({required super.verboseHelp});

  @override
  String get description =>
      'Upgrade the flutter-watchos toolchain to the latest released version.';

  @override
  Future<FlutterCommandResult> runCommand() {
    final commandRunner = WatchosUpgradeCommandRunner();
    // Cache.flutterRoot points at the vendored `flutter/` SDK; its parent is
    // the flutter-watchos repo root (where `.git` and `bin/flutter-watchos`
    // live).
    commandRunner.workingDirectory =
        stringArg('working-directory') ?? globals.fs.directory(Cache.flutterRoot).parent.path;
    return commandRunner.runCommand(
      force: boolArg('force'),
      continueFlow: boolArg('continue'),
      testFlow: stringArg('working-directory') != null,
      verifyOnly: boolArg('verify-only'),
    );
  }
}

/// A resolved point in the flutter-watchos git history.
@immutable
class WatchosVersion {
  const WatchosVersion({required this.hash, required this.tag});

  /// Full git commit hash.
  final String hash;

  /// The exact release tag at this commit, or null if the commit is not
  /// tagged (e.g. a development checkout on a branch).
  final String? tag;

  String get hashShort => hash.length >= 10 ? hash.substring(0, 10) : hash;

  /// Human label: the tag when present, otherwise the short hash.
  String get label => tag ?? hashShort;
}

@visibleForTesting
class WatchosUpgradeCommandRunner {
  WatchosUpgradeCommandRunner({ProcessUtils? processUtils}) : _processUtils = processUtils;

  final ProcessUtils? _processUtils;

  ProcessUtils get _git => _processUtils ?? globals.processUtils;

  String? workingDirectory;

  /// Matches flutter-watchos release tags: `v<flutter>-watchos.<tool>`, e.g.
  /// `v3.44.1-watchos.0.1.0`.
  static final RegExp releaseTagPattern = RegExp(r'^v\d+\.\d+\.\d+-watchos\.\d+\.\d+\.\d+$');

  /// Selects the newest release tag from [tags], which are expected to be
  /// pre-sorted newest-first (`git tag -l --sort=-v:refname`). Non-release
  /// tags are ignored. Returns null when no release tag is present.
  @visibleForTesting
  static String? latestReleaseTag(List<String> tags) {
    for (final tag in tags) {
      if (releaseTagPattern.hasMatch(tag.trim())) {
        return tag.trim();
      }
    }
    return null;
  }

  Future<FlutterCommandResult> runCommand({
    required bool force,
    required bool continueFlow,
    required bool testFlow,
    required bool verifyOnly,
  }) async {
    if (!continueFlow) {
      await runCommandFirstHalf(force: force, testFlow: testFlow, verifyOnly: verifyOnly);
    } else {
      await runCommandSecondHalf();
    }
    return FlutterCommandResult.success();
  }

  Future<void> runCommandFirstHalf({
    required bool force,
    required bool testFlow,
    required bool verifyOnly,
  }) async {
    final WatchosVersion upstream = await fetchLatestReleaseVersion();
    final WatchosVersion current = await fetchCurrentVersion();

    if (current.hash == upstream.hash) {
      globals.printStatus('flutter-watchos is already up to date at ${upstream.label}.');
      return;
    }

    globals.printStatus('A new version of flutter-watchos is available.\n');
    globals.printStatus('  Latest:  ${upstream.label}', emphasis: true);
    globals.printStatus('  Current: ${current.label}\n');

    if (verifyOnly) {
      globals.printStatus('To upgrade now, run "flutter-watchos upgrade".');
      return;
    }

    // Guard against silently discarding local changes with `git reset --hard`.
    if (!force && await _hasUncommittedChanges()) {
      throwToolExit(
        'Your flutter-watchos checkout in $workingDirectory has uncommitted changes.\n'
        'Commit or stash them first, or re-run with --force to discard them and '
        'upgrade anyway.',
      );
    }

    globals.printStatus(
      'Upgrading flutter-watchos to ${upstream.label} from ${current.label} '
      'in $workingDirectory...',
    );
    await attemptReset(upstream.hash);
    if (!testFlow) {
      await flutterUpgradeContinue();
    }
  }

  /// Fetches tags from the remote and resolves the newest release tag.
  Future<WatchosVersion> fetchLatestReleaseVersion() async {
    String tag;
    String hash;
    try {
      await _git.run(
        <String>['git', 'fetch', '--tags'],
        throwOnError: true,
        workingDirectory: workingDirectory,
      );
      final RunResult result = await _git.run(
        <String>['git', 'tag', '-l', '--sort=-v:refname'],
        throwOnError: true,
        workingDirectory: workingDirectory,
      );
      final List<String> tags = const LineSplitter().convert(result.stdout.trim());
      final String? latest = latestReleaseTag(tags);
      if (latest == null) {
        throwToolExit(
          'Unable to upgrade flutter-watchos: no release tags '
          '(v<flutter>-watchos.<version>) were found.\n'
          'Make sure your flutter-watchos checkout tracks the upstream repository.',
        );
      }
      tag = latest;
      // Peel to the underlying commit with `^{commit}` (annotated tags).
      final RunResult revParse = await _git.run(
        <String>['git', 'rev-parse', '$tag^{commit}'],
        throwOnError: true,
        workingDirectory: workingDirectory,
      );
      hash = revParse.stdout.trim();
    } on ProcessException catch (e) {
      throwToolExit(
        'Unable to upgrade flutter-watchos: could not query git tags.\n${e.message}',
      );
    }
    return WatchosVersion(hash: hash, tag: tag);
  }

  /// Resolves the commit the checkout is currently on, and its exact tag if any.
  Future<WatchosVersion> fetchCurrentVersion() async {
    String hash;
    String? tag;
    try {
      final RunResult head = await _git.run(
        <String>['git', 'rev-parse', '--verify', 'HEAD'],
        throwOnError: true,
        workingDirectory: workingDirectory,
      );
      hash = head.stdout.trim();
    } on ProcessException catch (e) {
      throwToolExit(
        'Unable to upgrade flutter-watchos: could not determine the current '
        'revision of $workingDirectory.\n${e.message}',
      );
    }
    // An exact tag is best-effort; a development checkout legitimately has none.
    try {
      final RunResult describe = await _git.run(
        <String>['git', 'describe', '--exact-match', '--tags', 'HEAD'],
        workingDirectory: workingDirectory,
      );
      if (describe.exitCode == 0) {
        tag = describe.stdout.trim();
      }
    } on ProcessException {
      tag = null;
    }
    return WatchosVersion(hash: hash, tag: tag);
  }

  Future<bool> _hasUncommittedChanges() async {
    // Fail *closed*: this is the only guard before `git reset --hard`.
    try {
      final RunResult result = await _git.run(
        <String>['git', 'status', '-s'],
        throwOnError: true,
        workingDirectory: workingDirectory,
      );
      return result.stdout.trim().isNotEmpty;
    } on ProcessException catch (e) {
      throwToolExit(
        'The tool could not verify the status of the flutter-watchos checkout in '
        '$workingDirectory. Ensure git is installed and in your PATH and try '
        'again, or re-run with --force to skip this check.\n${e.message}',
      );
    }
  }

  Future<void> attemptReset(String newRevision) async {
    try {
      await _git.run(
        <String>['git', 'reset', '--hard', newRevision],
        throwOnError: true,
        workingDirectory: workingDirectory,
      );
    } on ProcessException catch (e) {
      throwToolExit(e.message, exitCode: e.errorCode);
    }
  }

  /// Re-invokes `flutter-watchos upgrade --continue` so the *new* version of
  /// the tool runs the second half (precache / pub get / doctor).
  Future<void> flutterUpgradeContinue() async {
    final int code = await globals.processUtils.stream(
      <String>[
        globals.fs.path.join('bin', 'flutter-watchos'),
        'upgrade',
        '--continue',
        '--no-version-check',
      ],
      workingDirectory: workingDirectory,
      allowReentrantFlutter: true,
      environment: Map<String, String>.of(globals.platform.environment),
    );
    if (code != 0) {
      throwToolExit(
        'flutter-watchos was upgraded to the new release, but finishing the '
        'upgrade (precache / doctor) failed. Your checkout is on the new '
        'version; re-run "flutter-watchos precache --force" and '
        '"flutter-watchos doctor" to complete it.',
        exitCode: code,
      );
    }
  }

  Future<void> runCommandSecondHalf() async {
    globals.persistentToolState?.setShouldRedisplayWelcomeMessage(false);
    await precacheArtifacts();
    await runDoctor();
    globals.persistentToolState?.setShouldRedisplayWelcomeMessage(true);
  }

  /// Re-downloads the watchOS engine artifacts that match the new pinned
  /// version.
  Future<void> precacheArtifacts() async {
    globals.printStatus('');
    globals.printStatus('Upgrading engine...');
    final int code = await globals.processUtils.stream(
      <String>[
        globals.fs.path.join('bin', 'flutter-watchos'),
        '--no-color',
        '--no-version-check',
        'precache',
        '--force',
      ],
      workingDirectory: workingDirectory,
      allowReentrantFlutter: true,
      environment: Map<String, String>.of(globals.platform.environment),
    );
    if (code != 0) {
      throwToolExit(
        'The flutter-watchos checkout was upgraded, but re-downloading the '
        'watchOS engine artifacts for the new version failed. Re-run '
        '"flutter-watchos precache --force" once your network is available.',
        exitCode: code,
      );
    }
  }

  Future<void> runDoctor() async {
    globals.printStatus('');
    globals.printStatus('Running flutter-watchos doctor...');
    await globals.processUtils.stream(
      <String>[
        globals.fs.path.join('bin', 'flutter-watchos'),
        '--no-version-check',
        'doctor',
      ],
      workingDirectory: workingDirectory,
      allowReentrantFlutter: true,
    );
  }
}
