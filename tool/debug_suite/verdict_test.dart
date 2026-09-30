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
vm.cpu_samples xfail F1 the CPU profiler records no samples
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
    expect(verdict.report, contains(startsWith('xfail   vm.cpu_samples (F1:')));
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
      startsWith('vm.cpu_samples: passed, but F1 expects it to fail'),
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
    expect(() => parseExpectations('vm.a xfail X1 why\n'), throwsFormatException);
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

  // A limitation is either still an expected failure or, once fixed, named in
  // the comment above the check that now passes, so none is dropped silently.
  test('the shipped expectations parse and account for F1-F10', () {
    final String text = File('tool/debug_suite/expectations.txt').readAsStringSync();
    final Map<String, Expectation> shipped = parseExpectations(text);
    final Set<String> mentioned = RegExp(
      r'\bF\d+\b',
    ).allMatches(text).map((Match m) => m[0]!).toSet();
    for (var n = 1; n <= 10; n++) {
      expect(mentioned, contains('F$n'));
    }
    for (final Expectation e in shipped.values.where((Expectation e) => !e.expectPass)) {
      expect(int.parse(e.failureId!.substring(1)), inInclusiveRange(1, 10), reason: e.id);
    }
  });
}
