// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// Decides whether a debug suite run is green.
///
/// Every check of `tool/debug_suite/run.sh` writes one line to a results file:
/// `PASS <id> <detail>`, `FAIL <id> <detail>` or `SKIP <id> <reason>`.
/// `expectations.txt` lists every check once, as `<id> pass` or
/// `<id> xfail <F-id> <what is wrong>`. An expected failure is strict: a check
/// that is expected to fail and passes fails the suite, so the known-limitation
/// line in the docs gets updated in the same change that fixes it.
///
/// Usage: `dart tool/debug_suite/verdict.dart <expectations> <results>`.
/// Exits 0 when the run matches the expectations and 1 otherwise.
library;

import 'dart:convert';
import 'dart:io';

/// What a check is expected to do.
class Expectation {
  /// Creates an expectation for check [id].
  const Expectation(this.id, {required this.expectPass, this.failureId, this.reason});

  /// The check's id, as `run.sh` prints it.
  final String id;

  /// Whether the check is expected to pass.
  final bool expectPass;

  /// The known limitation the check measures (`F1`-`F10`), for an expected
  /// failure.
  final String? failureId;

  /// What is wrong while the limitation stands.
  final String? reason;
}

/// The outcome of one check in a run.
enum Outcome {
  /// The check passed.
  pass,

  /// The check failed.
  fail,

  /// The check did not run.
  skip,
}

/// One result line.
class CheckResult {
  /// Creates a result for check [id].
  const CheckResult(this.id, this.outcome, this.detail);

  /// The check's id.
  final String id;

  /// What happened.
  final Outcome outcome;

  /// The rest of the line.
  final String detail;
}

/// Parses `expectations.txt`. Blank lines and `#` lines are ignored.
///
/// Throws a [FormatException] for a malformed line or a repeated id.
Map<String, Expectation> parseExpectations(String text) {
  final expectations = <String, Expectation>{};
  for (final String raw in const LineSplitter().convert(text)) {
    final String line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) {
      continue;
    }
    final List<String> words = line.split(RegExp(r'\s+'));
    final Expectation expectation;
    if (words.length == 2 && words[1] == 'pass') {
      expectation = Expectation(words[0], expectPass: true);
    } else if (words.length >= 3 && words[1] == 'xfail' && RegExp(r'^F\d+$').hasMatch(words[2])) {
      expectation = Expectation(
        words[0],
        expectPass: false,
        failureId: words[2],
        reason: words.skip(3).join(' '),
      );
    } else {
      throw FormatException('Not "<id> pass" or "<id> xfail F<n> <reason>"', line);
    }
    if (expectations.containsKey(expectation.id)) {
      throw FormatException('Check listed twice', line);
    }
    expectations[expectation.id] = expectation;
  }
  return expectations;
}

/// Parses a results file. Lines that are not results are ignored, so tool
/// output may be mixed in.
List<CheckResult> parseResults(String text) {
  final results = <CheckResult>[];
  final pattern = RegExp(r'^(PASS|FAIL|SKIP) (\S+) ?(.*)$');
  for (final String line in const LineSplitter().convert(text)) {
    final RegExpMatch? match = pattern.firstMatch(line.trimRight());
    if (match == null) {
      continue;
    }
    final Outcome outcome = switch (match[1]) {
      'PASS' => Outcome.pass,
      'FAIL' => Outcome.fail,
      _ => Outcome.skip,
    };
    results.add(CheckResult(match[2]!, outcome, match[3]!));
  }
  return results;
}

/// The verdict of one run: one line per problem, and none when it is green.
class Verdict {
  /// Creates a verdict from its problem lines and its report.
  const Verdict(this.problems, this.report);

  /// Why the run is not green. Empty when it is.
  final List<String> problems;

  /// One line per check, for the log.
  final List<String> report;

  /// Whether the run matches the expectations.
  bool get isGreen => problems.isEmpty;
}

/// Compares [results] with [expectations].
///
/// The run is not green when a check expected to pass fails, when a check
/// expected to fail passes (strict), when a check reports twice or is not
/// listed, or when a listed check reports nothing and was not skipped.
Verdict judge(Map<String, Expectation> expectations, List<CheckResult> results) {
  final problems = <String>[];
  final report = <String>[];
  final seen = <String, CheckResult>{};
  for (final result in results) {
    if (seen.containsKey(result.id)) {
      problems.add('${result.id}: reported more than once');
      continue;
    }
    seen[result.id] = result;
    final Expectation? expectation = expectations[result.id];
    if (expectation == null) {
      problems.add('${result.id}: not in expectations.txt');
      continue;
    }
    switch ((result.outcome, expectation.expectPass)) {
      case (Outcome.pass, true):
        report.add('ok      ${result.id}');
      case (Outcome.fail, true):
        problems.add('${result.id}: failed: ${result.detail}');
      case (Outcome.fail, false):
        report.add('xfail   ${result.id} (${expectation.failureId}: ${expectation.reason})');
      case (Outcome.pass, false):
        problems.add(
          '${result.id}: passed, but ${expectation.failureId} expects it to fail. '
          'Update expectations.txt and the docs that describe ${expectation.failureId}.',
        );
      case (Outcome.skip, _):
        report.add('skipped ${result.id} (${result.detail})');
    }
  }
  for (final String id in expectations.keys) {
    if (!seen.containsKey(id)) {
      problems.add('$id: no result');
    }
  }
  return Verdict(problems, report);
}

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln('usage: dart verdict.dart <expectations.txt> <results.txt>');
    exitCode = 2;
    return;
  }
  final Verdict verdict = judge(
    parseExpectations(File(args[0]).readAsStringSync()),
    parseResults(File(args[1]).readAsStringSync()),
  );
  verdict.report.forEach(stdout.writeln);
  for (final String problem in verdict.problems) {
    stdout.writeln('PROBLEM $problem');
  }
  stdout.writeln(verdict.isGreen ? 'SUITE GREEN' : 'SUITE NOT GREEN');
  exitCode = verdict.isGreen ? 0 : 1;
}
