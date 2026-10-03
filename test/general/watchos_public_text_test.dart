// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Public text holds no forbidden word.
//
// The CI log prints every test and group name, and GitHub shows the workflow
// files and the commands they run. So `.github/**` and the test and group
// names under `test/` and `packages/flutter_watchos/` go through the rule in
// test/src/forbidden_words.dart. Workflow files may use the allow-list for
// code they run; test and group names may not use it at all.

import 'dart:io' as io;

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';

import '../src/common.dart';
import '../src/forbidden_words.dart';
import '../src/host_sources.dart';

/// A test or group name found in Dart source.
class _TestName {
  const _TestName(this.line, this.text);

  final int line;
  final String text;
}

/// Collects the first argument of every call that declares a test or a group:
/// `test`, `group`, `testWidgets`, `testWithoutContext`, `testUsingContext`
/// and local wrappers whose names start with `test` or `group`.
class _TestNameVisitor extends RecursiveAstVisitor<void> {
  _TestNameVisitor(this.lineInfo);

  final LineInfo lineInfo;
  final names = <_TestName>[];

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final String name = node.methodName.name;
    final NodeList<Expression> arguments = node.argumentList.arguments;
    if (node.target == null &&
        (name.startsWith('test') || name.startsWith('group')) &&
        arguments.isNotEmpty &&
        arguments.first is StringLiteral) {
      names.add(
        _TestName(
          lineInfo.getLocation(node.offset).lineNumber,
          _literalText(arguments.first as StringLiteral),
        ),
      );
    }
    super.visitMethodInvocation(node);
  }

  // The static text of a literal. An interpolated value is unknown here, so it
  // stands as a space: the words around it are still checked.
  static String _literalText(StringLiteral literal) {
    if (literal is AdjacentStrings) {
      return literal.strings.map(_literalText).join();
    }
    if (literal is StringInterpolation) {
      return literal.elements
          .map(
            (InterpolationElement element) => element is InterpolationString ? element.value : ' ',
          )
          .join();
    }
    return literal.stringValue ?? '';
  }
}

List<_TestName> _testNamesIn(String source) {
  final ParseStringResult result = parseString(content: source, throwIfDiagnostics: false);
  final visitor = _TestNameVisitor(result.lineInfo);
  result.unit.accept(visitor);
  return visitor.names;
}

List<ForbiddenWordHit> _testNameHits(String path, String source) {
  return <ForbiddenWordHit>[
    for (final _TestName name in _testNamesIn(source))
      if (forbiddenWordsIn(name.text).isNotEmpty)
        ForbiddenWordHit(
          path: path,
          line: name.line,
          text: name.text,
          words: forbiddenWordsIn(name.text),
        ),
  ];
}

String get _repositoryRoot => io.File(cliRootPath('pubspec.yaml')).parent.path;

/// Tracked and untracked (not ignored) files of this repository under
/// [directory], relative to its root.
List<String> _repositoryFiles(String directory) {
  final io.ProcessResult result = io.Process.runSync('git', <String>[
    'ls-files',
    '--cached',
    '--others',
    '--exclude-standard',
    '--',
    directory,
  ], workingDirectory: _repositoryRoot);
  expect(result.exitCode, 0, reason: '${result.stderr}');
  return (result.stdout as String)
      .split('\n')
      .where((String path) => path.isNotEmpty && io.File('$_repositoryRoot/$path').existsSync())
      .toList();
}

String _read(String path) => io.File('$_repositoryRoot/$path').readAsStringSync();

void main() {
  // Each sample and whether the rule finds a forbidden word in it.
  const samples = <String, bool>{
    'two previews': true,
    'rawPrice': true,
    'release_not_in_beta': true,
    '0.0.1-beta.1': true,
    'will find a random free port': true,
    'PAID': true,
    'Betas and Trials': true,
    'pricing': true,
    'freeze': false,
    'industrial': false,
    'unpaid': false,
    'priced': false,
    'freedom': false,
    'betamax': false,
    'a plain sentence': false,
  };

  group('the word rule', () {
    testWithoutContext('each sample gets the expected answer', () {
      samples.forEach((String sample, bool expected) {
        expect(forbiddenWordsIn(sample).isNotEmpty, expected, reason: sample);
      });
    });

    testWithoutContext('camelCase and snake_case split into words', () {
      expect(ruleWords('rawPrice'), <String>['raw', 'Price']);
      expect(ruleWords('release_not_in_beta'), <String>['release', 'not', 'in', 'beta']);
      expect(ruleWords('v0.1.0-beta.2'), <String>['v', 'beta']);
    });

    testWithoutContext('the shell form gives the same answers', () async {
      final List<String> lines = samples.keys.toList();
      // Each line starts with its index and a colon. Digits and the colon
      // separate words, so the prefix changes no answer.
      final io.Process process = await io.Process.start('bash', <String>[
        '-c',
        kForbiddenWordsShellFilter,
      ]);
      process.stdin.write(
        <String>[for (var i = 0; i < lines.length; i++) '$i:${lines[i]}\n'].join(),
      );
      await process.stdin.close();
      final Future<String> stdout = process.stdout
          .transform(const io.SystemEncoding().decoder)
          .join();
      final Future<String> stderr = process.stderr
          .transform(const io.SystemEncoding().decoder)
          .join();
      // grep exits 1 when no line matches, and 2 on an error.
      expect(await process.exitCode, anyOf(0, 1), reason: await stderr);
      final Set<int> shellHits = (await stdout)
          .split('\n')
          .where((String line) => line.isNotEmpty)
          .map((String line) => int.parse(line.substring(0, line.indexOf(':'))))
          .toSet();
      final dartHits = <int>{
        for (var i = 0; i < lines.length; i++)
          if (forbiddenWordsIn(lines[i]).isNotEmpty) i,
      };
      expect(dartHits, isNotEmpty);
      expect(shellHits, dartHits);
    });
  });

  group('the allow-list', () {
    testWithoutContext('blanks only the allowed text, only where it applies', () {
      final allowList = AllowList.parse('lib/a.dart | release_not_in_beta | a code identifier\n');
      const line = "'release_not_in_beta' => 'free',";
      expect(allowList.forbiddenWordsAt('lib/a.dart', line), <String>['free']);
      expect(allowList.forbiddenWordsAt('lib/b.dart', line), <String>['beta', 'free']);
    });

    testWithoutContext('a line without a reason is refused', () {
      expect(() => AllowList.parse('lib/a.dart | release_not_in_beta\n'), throwsFormatException);
      expect(
        () => AllowList.parse('lib/a.dart | release_not_in_beta |   \n'),
        throwsFormatException,
      );
    });

    testWithoutContext('comments and blank lines are skipped', () {
      final allowList = AllowList.parse('# a comment\n\nlib/a.dart | x_beta | why\n');
      expect(allowList.entries, hasLength(1));
      expect(allowList.entries.single.line, 3);
      expect(allowList.entries.single.text, 'x_beta');
    });

    testWithoutContext('globs match the paths they name', () {
      expect(globToRegExp('test/general/*.dart').hasMatch('test/general/a_test.dart'), isTrue);
      expect(globToRegExp('test/general/*.dart').hasMatch('test/general/sub/a.dart'), isFalse);
      expect(globToRegExp('packages/**').hasMatch('packages/a/lib/b.dart'), isTrue);
      expect(globToRegExp('**/ci.yml').hasMatch('ci.yml'), isTrue);
      expect(globToRegExp('**/ci.yml').hasMatch('.github/workflows/ci.yml'), isTrue);
      expect(globToRegExp('lib/a?.dart').hasMatch('lib/ab.dart'), isTrue);
      expect(globToRegExp('lib/a.dart').hasMatch('lib/a_dart'), isFalse);
    });
  });

  group('test and group names', () {
    testWithoutContext('are read from every call that declares a test or a group', () {
      const source = r'''
void main() {
  group('outer', () {
    test('one', () {});
    testWithoutContext('two', () {});
    testUsingContext('three ' 'joined', () {});
    testWidgets('four $value', (tester) async {});
    testInContext('five', () {});
    helper('not a test');
    expect('not a test either', isNotNull);
  });
}
''';
      expect(_testNamesIn(source).map((_TestName name) => '${name.line}:${name.text}'), <String>[
        '2:outer',
        '3:one',
        '4:two',
        '5:three joined',
        '6:four  ',
        '7:five',
      ]);
    });

    testWithoutContext('a name in each word form is a hit', () {
      const source = '''
void main() {
  group('shows two previews', () {
    test('reads rawPrice', () {});
    testWithoutContext('maps release_not_in_beta', () {});
    testUsingContext('sorts 0.1.0-beta.2 first', () {});
    test('a plain name', () {});
  });
}
''';
      expect(
        _testNameHits('fixture_test.dart', source).map((ForbiddenWordHit hit) => hit.toString()),
        <String>[
          'fixture_test.dart:2: previews in "shows two previews"',
          'fixture_test.dart:3: Price in "reads rawPrice"',
          'fixture_test.dart:4: beta in "maps release_not_in_beta"',
          'fixture_test.dart:5: beta in "sorts 0.1.0-beta.2 first"',
        ],
      );
    });
  });

  group('workflow files', () {
    testWithoutContext('a job or step name with a forbidden word is a hit', () {
      const workflow = '''
jobs:
  build:
    steps:
      - name: Build the trial app
        run: echo done
''';
      expect(
        scanText('.github/workflows/x.yml', workflow).map((ForbiddenWordHit hit) => hit.line),
        <int>[4],
      );
    });

    testWithoutContext('allowed code in a run line is not a hit, the rest still is', () {
      final allowList = AllowList.parse(
        '.github/workflows/x.yml | versionsort.suffix=-beta | the tag sort\n',
      );
      const workflow = '''
      - name: Pick the tag
        run: git -c versionsort.suffix=-beta tag -l
      - name: Pick the beta tag
''';
      expect(
        scanText(
          '.github/workflows/x.yml',
          workflow,
          allowList: allowList,
        ).map((ForbiddenWordHit hit) => hit.line),
        <int>[3],
      );
    });
  });

  group('public text in this repository', () {
    testWithoutContext('.github holds no forbidden word', () {
      final allowList = AllowList.load(_repositoryRoot);
      final List<String> files = _repositoryFiles('.github');
      expect(files, isNotEmpty);
      final hits = <ForbiddenWordHit>[
        for (final String path in files) ...scanText(path, _read(path), allowList: allowList),
      ];
      expect(hits, isEmpty, reason: hits.join('\n'));
    });

    for (final directory in <String>['test', 'packages/flutter_watchos']) {
      testWithoutContext('test and group names under $directory/ hold no forbidden word', () {
        final List<String> files = _repositoryFiles(
          directory,
        ).where((String path) => path.endsWith('_test.dart')).toList();
        expect(files, isNotEmpty);
        final hits = <ForbiddenWordHit>[
          for (final String path in files) ..._testNameHits(path, _read(path)),
        ];
        expect(hits, isEmpty, reason: hits.join('\n'));
      });
    }

    testWithoutContext('every allow-list entry names text that is there', () {
      final allowList = AllowList.load(_repositoryRoot);
      expect(allowList.entries, isNotEmpty);
      final List<String> files = _repositoryFiles('.');
      for (final AllowListEntry entry in allowList.entries) {
        final List<String> matched = files.where(entry.appliesTo).toList();
        if (matched.isEmpty) {
          // An entry for the plugins repository, which keeps a copy of this
          // file.
          expect(
            entry.glob.startsWith('packages/') &&
                !entry.glob.startsWith('packages/flutter_watchos/'),
            isTrue,
            reason: 'line ${entry.line}: ${entry.glob} matches no file here',
          );
          continue;
        }
        expect(
          matched.any((String path) => _read(path).contains(entry.text)),
          isTrue,
          reason: 'line ${entry.line}: "${entry.text}" is not in ${entry.glob}',
        );
      }
    });
  });
}
