// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// tool/xcode_matrix.sh builds and runs apps with this machine's Xcode, which
// no unit test can do. These tests hold the script to what it promises
// before any of that: a script that parses, the usage it prints, and the
// settings every run uses.

import 'dart:io' as io;

import '../src/common.dart';
import '../src/host_sources.dart';

void main() {
  final String script = cliRootPath('tool/xcode_matrix.sh');
  final String source = io.File(script).readAsStringSync();

  test('parses as bash', () {
    final io.ProcessResult result = io.Process.runSync('bash', <String>['-n', script]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
  });

  test('--help prints the usage, with the default steps and what a run needs', () {
    final io.ProcessResult result = io.Process.runSync('bash', <String>[script, '--help']);

    expect(result.exitCode, 0, reason: '${result.stderr}');
    final usage = result.stdout as String;
    expect(usage, startsWith('The Xcode and watchOS matrix'));
    expect(usage, contains('(default: 2,3,4,5,6,6b,7,10,17)'));
    expect(usage, contains('--only 7b'));
    expect(usage, contains('DEVELOPMENT_TEAM'));
    expect(usage, contains('FLUTTER_WATCHOS_BUILD_REGISTRY=0'));
  });

  test('runs the default steps without 7b, which no release of the CLI passes yet', () {
    final RegExpMatch? only = RegExp(r'^ONLY="([^"]*)"$', multiLine: true).firstMatch(source);

    expect(only, isNotNull);
    expect(only![1]!.split(','), <String>['2', '3', '4', '5', '6', '6b', '7', '10', '17']);
  });

  // At the top level, before the first section that runs anything: every
  // step, and the CLI in it, inherits the setting.
  test('turns the build registry off before it runs anything', () {
    final List<String> lines = source.split('\n');
    final int export = lines.indexOf('export FLUTTER_WATCHOS_BUILD_REGISTRY=0');
    final int firstSection = lines.indexWhere((String line) => line.startsWith('# --- '));

    expect(export, isNonNegative);
    expect(firstSection, isNonNegative);
    expect(export, lessThan(firstSection));
  });

  test('creates a watch-only app', () {
    final Iterable<String> creates = source
        .split('\n')
        .where((String line) => line.contains(r'"$FW" create'));

    expect(creates, isNotEmpty);
    for (final line in creates) {
      expect(line, contains(r'"$FW" create --platforms=watchos '));
    }
  });
}
