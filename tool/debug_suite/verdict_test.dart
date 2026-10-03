// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Self-test of the debug suite's expected-failure logic, on made-up output.
// Run with: flutter/bin/dart test tool/debug_suite/verdict_test.dart

import 'dart:io';

import 'package:test/test.dart';

import 'verdict.dart';

void main() {
  const expectationsText = '''
# comment
vm.evaluate pass
vm.cpu_samples xfail empty-cpu-profile the CPU profiler records no samples
''';

  Verdict run(String results) => judge(parseExpectations(expectationsText), parseResults(results));

  test('a run that matches the expectations is green', () {
    final Verdict verdict = run('''
some tool output
PASS vm.evaluate 1 + 2 = 3
FAIL vm.cpu_samples sampleCount=0
''');
    expect(verdict.problems, isEmpty);
    expect(verdict.isGreen, isTrue);
    expect(verdict.report, contains(startsWith('xfail   vm.cpu_samples (empty-cpu-profile:')));
  });

  test('a check expected to pass that fails is a problem', () {
    final Verdict verdict = run('FAIL vm.evaluate timeout\nFAIL vm.cpu_samples 0\n');
    expect(verdict.isGreen, isFalse);
    expect(verdict.problems, <String>['vm.evaluate: failed: timeout']);
  });

  test('an expected failure that passes fails the suite (strict)', () {
    final Verdict verdict = run('PASS vm.evaluate ok\nPASS vm.cpu_samples sampleCount=412\n');
    expect(verdict.isGreen, isFalse);
    expect(
      verdict.problems.single,
      startsWith('vm.cpu_samples: passed, but empty-cpu-profile expects it to fail'),
    );
  });

  test('a listed check with no result is a problem, a skipped one is not', () {
    expect(run('PASS vm.evaluate ok\n').problems, <String>['vm.cpu_samples: no result']);
    final Verdict skipped = run('PASS vm.evaluate ok\nSKIP vm.cpu_samples no profiler\n');
    expect(skipped.isGreen, isTrue);
  });

  test('an unknown or repeated check is a problem', () {
    final Verdict verdict = run('''
PASS vm.evaluate ok
PASS vm.evaluate ok
FAIL vm.cpu_samples 0
PASS vm.new_check ok
''');
    expect(verdict.problems, <String>[
      'vm.evaluate: reported more than once',
      'vm.new_check: not in expectations.txt',
    ]);
  });

  test('malformed or repeated expectation lines are rejected', () {
    expect(() => parseExpectations('vm.a maybe\n'), throwsFormatException);
    expect(() => parseExpectations('vm.a xfail Lost_Stdio why\n'), throwsFormatException);
    expect(() => parseExpectations('vm.a xfail lost-stdio\n'), throwsFormatException);
    expect(parseExpectations('vm.a xfail lost-stdio why\n')['vm.a']!.limitation, 'lost-stdio');
    expect(() => parseExpectations('vm.a pass\nvm.a pass\n'), throwsFormatException);
  });

  test('every check run.sh and vmcheck report is listed, and nothing else', () {
    final Set<String> listed = parseExpectations(
      File('tool/debug_suite/expectations.txt').readAsStringSync(),
    ).keys.toSet();
    final String runSh = File('tool/debug_suite/run.sh').readAsStringSync();
    final String vmcheck = File('tool/debug_suite/vmcheck.dart').readAsStringSync();
    final reported = <String>{
      for (final RegExpMatch m in RegExp(
        r'(?:check|result (?:PASS|FAIL|SKIP)) "?([a-z_]+(?:\.[a-z_]+)+)(?![.$a-z_])',
      ).allMatches(runSh))
        m[1]!,
      for (final RegExpMatch m in RegExp(r"'(vm\.[a-z_]+)'").allMatches(vmcheck))
        if (m[1] != 'vm.connect') m[1]!,
    };
    // run.sh names the log checks through a loop variable.
    for (final kind in <String>['print', 'debug_print', 'stdout', 'stderr']) {
      reported.add('run.log.$kind');
    }
    expect(reported.difference(listed), isEmpty, reason: 'reported but not listed');
    expect(listed.difference(reported), isEmpty, reason: 'listed but never reported');
  });

  test('run.sh stops before it makes anything when space is short', () {
    final Directory scratch = Directory.systemTemp.createTempSync('debug_suite_test');
    addTearDown(() => scratch.deleteSync(recursive: true));
    final ProcessResult result = Process.runSync(
      'bash',
      <String>['tool/debug_suite/run.sh', '00000000-0000-0000-0000-000000000000'],
      environment: <String, String>{
        'TMPDIR': scratch.path,
        'WATCHOS_ENGINE_ARTIFACTS': scratch.path,
        'FLUTTER_WATCHOS_CLI': '/bin/echo',
        'DEBUG_SUITE_MIN_GIB': '999999',
      },
    );
    expect(result.exitCode, 2);
    expect(result.stderr, contains('the suite needs 999999'));
    expect(scratch.listSync(), isEmpty);
  });

  // The suite runs the CLI under a temporary HOME, which it deletes at the
  // end. Packages resolved there would leave the CLI's checkout pointing into
  // a pub cache that is gone, and nothing in it would compile again.
  group('run.sh and the packages of the CLI under test', () {
    late Directory scratch;
    late Directory tmp;
    late String ran;

    setUp(() {
      scratch = Directory.systemTemp.createTempSync('debug_suite_cli');
      tmp = Directory('${scratch.path}/tmp')..createSync();
      ran = '${scratch.path}/ran.txt';
    });

    tearDown(() => scratch.deleteSync(recursive: true));

    /// A checkout at `<scratch>/cli` whose bin/flutter-watchos writes its
    /// HOME and its arguments to [ran], with [packageConfig] as its package
    /// config, if given. Returns the CLI's path.
    String fakeCli({String? packageConfig}) {
      final cli = File('${scratch.path}/cli/bin/flutter-watchos')
        ..createSync(recursive: true)
        ..writeAsStringSync('#!/bin/sh\nprintf "%s\\n" "\$HOME" "\$*" > "$ran"\n');
      Process.runSync('chmod', <String>['+x', cli.path]);
      if (packageConfig != null) {
        File('${scratch.path}/cli/.dart_tool/package_config.json')
          ..createSync(recursive: true)
          ..writeAsStringSync(packageConfig);
      }
      return cli.path;
    }

    /// run.sh for a made-up Simulator, which stops at its space check if
    /// nothing stops it before.
    ProcessResult runSuite(String cli) => Process.runSync(
      'bash',
      <String>['tool/debug_suite/run.sh', '00000000-0000-0000-0000-000000000000'],
      environment: <String, String>{
        'HOME': '${scratch.path}/caller-home',
        'TMPDIR': tmp.path,
        'WATCHOS_ENGINE_ARTIFACTS': tmp.path,
        'FLUTTER_WATCHOS_CLI': cli,
        'DEBUG_SUITE_MIN_GIB': '999999',
      },
    );

    test('it refuses a checkout that an earlier run left pointing into its temporary HOME', () {
      final String cli = fakeCli(
        packageConfig:
            '{"packages":[{"name":"path","rootUri":'
            '"file:///private/var/folders/x/T/fw_debug_suite.AbC123/home/.pub-cache/'
            'hosted/pub.dev/path-1.9.1"}]}',
      );
      final String root = Directory('${scratch.path}/cli').resolveSymbolicLinksSync();

      final ProcessResult result = runSuite(cli);

      expect(result.exitCode, 2);
      expect(
        result.stderr,
        contains('points into the temporary directory of an earlier suite run'),
      );
      expect(result.stderr, contains('  rm "$root/.dart_tool/package_config.json"\n'));
      expect(result.stderr, contains('  "$root/bin/flutter-watchos" --version'));
      expect(File(ran).existsSync(), isFalse);
      expect(tmp.listSync(), isEmpty);
    });

    test("it runs the CLI once under the caller's HOME before it makes anything", () {
      final ProcessResult result = runSuite(
        fakeCli(packageConfig: '{"packages":[{"name":"path","rootUri":"file:///pub-cache/path"}]}'),
      );

      expect(result.exitCode, 2);
      expect(result.stderr, contains('the suite needs 999999'));
      expect(File(ran).readAsLinesSync(), <String>['${scratch.path}/caller-home', '--version']);
      expect(tmp.listSync(), isEmpty);
    });

    test("it keeps the caller's pub cache when it switches to its own HOME", () {
      final List<String> lines = File('tool/debug_suite/run.sh').readAsLinesSync();
      final int pubCache = lines.indexOf(r'export PUB_CACHE="${PUB_CACHE:-$HOME/.pub-cache}"');
      final int home = lines.indexOf(r'export HOME="$WORK/home"');

      expect(pubCache, isNonNegative);
      expect(home, pubCache + 1);
    });
  });

  // A limitation is either still an expected failure or, once fixed, named in
  // the "Fixed:" comment above the check that now passes, so none is dropped
  // silently. A new limitation is added here too.
  test('the shipped expectations parse and account for every known limitation', () {
    const known = <String>{
      'empty-cpu-profile',
      'dropped-launch-options',
      'unnamed-log-reader',
      'dropped-engine-lines',
      'cut-quoted-message',
      'lost-stdio',
      'machine-logger-error',
      'mode-stack-trace',
      'empty-screenshot',
      'integration-test-warning',
      'reload-after-detach',
    };
    final String text = File('tool/debug_suite/expectations.txt').readAsStringSync();
    final Map<String, Expectation> shipped = parseExpectations(text);
    final expectedToFail = <String>{
      for (final Expectation e in shipped.values)
        if (!e.expectPass) e.limitation!,
    };
    final fixed = <String>{
      for (final RegExpMatch m in RegExp(
        r'^# .*Fixed: ([a-z0-9-]+)\.',
        multiLine: true,
      ).allMatches(text))
        m[1]!,
    };
    expect(expectedToFail.difference(known), isEmpty, reason: 'an xfail names no known limitation');
    expect(fixed.difference(known), isEmpty, reason: 'a Fixed: comment names no known limitation');
    expect(known.difference(expectedToFail.union(fixed)), isEmpty, reason: 'dropped silently');
    expect(expectedToFail.intersection(fixed), isEmpty, reason: 'both fixed and expected to fail');
  });
}
