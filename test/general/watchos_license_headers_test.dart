// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Every source file of this repository starts with its license header: the
// FlutterWatch copyright line, then the BSD notice that points to LICENSE. A
// file adapted from Flutter keeps Flutter's copyright line after the first.
//
// templates/ is not checked. Its files become the user's own project, which
// carries no header of ours, as the templates of `flutter create` carry none.

import 'dart:io' as io;

import '../src/common.dart';
import '../src/host_sources.dart';

/// The directories whose source files carry the header.
const List<String> _directories = <String>[
  'bin',
  'host',
  'lib',
  'packages',
  'runtime',
  'test',
  'tool',
];

/// The ends of the names of source files whose comments start with `//`.
/// `.dart.tmpl` is the Dart file the debug suite copies into an app.
const List<String> _slashSources = <String>[
  '.dart',
  '.dart.tmpl',
  '.swift',
  '.h',
  '.m',
  '.mm',
  '.c',
  '.cc',
];

/// The ends of the names of source files whose comments start with `#`. A
/// file that starts with a `#!` line is a script too, whatever its name.
const List<String> _hashSources = <String>['.sh', '.py'];

/// The comment marker of the source file at [path] whose first line is
/// [firstLine], or null when it is not a source file.
String? _commentMarker(String path, String firstLine) {
  if (_slashSources.any(path.endsWith)) {
    return '//';
  }
  if (_hashSources.any(path.endsWith) || firstLine.startsWith('#!')) {
    return '#';
  }
  return null;
}

/// Why the file at [path] with [contents] lacks the license header, or null
/// when it has it.
///
/// The header comes first. Only a `#!` line, or the `// swift-tools-version`
/// line that Swift Package Manager reads from the first line, may come
/// before it.
String? _headerProblem(String path, String contents) {
  final List<String> lines = contents.split('\n');
  final String? marker = _commentMarker(path, lines.first);
  if (marker == null) {
    return null;
  }
  var i = 0;
  if (lines.first.startsWith('#!') || lines.first.startsWith('// swift-tools-version')) {
    i++;
  }
  String line(int index) => index < lines.length ? lines[index] : '';
  final copyright = RegExp(
    '^${RegExp.escape(marker)} Copyright \\d{4} The FlutterWatch Authors\\. All rights reserved\\.\$',
  );
  if (!copyright.hasMatch(line(i))) {
    return 'line ${i + 1} is not "$marker Copyright <year> The FlutterWatch Authors. '
        'All rights reserved."';
  }
  i++;
  final flutterCopyright = RegExp(
    '^${RegExp.escape(marker)} Copyright \\d{4} The Flutter Authors\\. All rights reserved\\.\$',
  );
  if (flutterCopyright.hasMatch(line(i))) {
    i++;
  }
  const notice = <String>[
    'Use of this source code is governed by a BSD-style license that can be',
    'found in the LICENSE file.',
  ];
  for (final text in notice) {
    if (line(i) != '$marker $text') {
      return 'line ${i + 1} is not "$marker $text"';
    }
    i++;
  }
  return null;
}

String get _repositoryRoot => io.File(cliRootPath('pubspec.yaml')).parent.path;

void main() {
  group('the header check', () {
    const header =
        '// Copyright 2026 The FlutterWatch Authors. All rights reserved.\n'
        '// Use of this source code is governed by a BSD-style license that can be\n'
        '// found in the LICENSE file.\n';

    test('accepts the header at the top of each kind of source', () {
      expect(_headerProblem('lib/a.dart', '$header\nvoid main() {}\n'), isNull);
      expect(_headerProblem('host/A.swift', '$header\nimport SwiftUI\n'), isNull);
      expect(
        _headerProblem('tool/a.sh', '#!/usr/bin/env bash\n${header.replaceAll('//', '#')}\n'),
        isNull,
      );
      expect(_headerProblem('bin/tool', '#!/bin/sh\n${header.replaceAll('//', '#')}'), isNull);
      expect(
        _headerProblem('packages/p/Package.swift', '// swift-tools-version:5.9\n$header'),
        isNull,
      );
      expect(
        _headerProblem(
          'lib/b.dart',
          header.replaceFirst(
            '\n',
            '\n// Copyright 2014 The Flutter Authors. All rights reserved.\n',
          ),
        ),
        isNull,
      );
    });

    test('names what is missing or out of place', () {
      expect(_headerProblem('host/A.swift', '// The host half.\n$header'), contains('line 1'));
      expect(_headerProblem('lib/a.dart', '\n$header'), contains('line 1'));
      expect(
        _headerProblem('lib/a.dart', header.replaceFirst('FlutterWatch', 'FlutterTV')),
        contains('line 1'),
      );
      expect(
        _headerProblem('lib/a.dart', header.replaceFirst('BSD-style', 'MIT')),
        contains('line 2'),
      );
      expect(_headerProblem('tool/a.sh', '#!/usr/bin/env bash\n$header'), contains('line 2'));
      expect(_headerProblem('lib/a.dart', header.split('\n').first), contains('line 2'));
    });

    test('leaves files that are not sources alone', () {
      expect(_headerProblem('lib/a.json', '{}\n'), isNull);
      expect(_headerProblem('host/module.modulemap', 'module FlutterWatchOS {}\n'), isNull);
      expect(_headerProblem('tool/README.md', '# A heading\n'), isNull);
    });
  });

  testWithoutContext('every source file in this repository has the header', () {
    final io.ProcessResult result = io.Process.runSync('git', <String>[
      'ls-files',
      '--cached',
      '--others',
      '--exclude-standard',
      '--',
      ..._directories,
    ], workingDirectory: _repositoryRoot);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    final problems = <String>[];
    var checked = 0;
    for (final String path in (result.stdout as String).split('\n')) {
      final file = io.File('$_repositoryRoot/$path');
      if (path.isEmpty || !file.existsSync()) {
        continue;
      }
      final String contents;
      try {
        contents = file.readAsStringSync();
      } on io.FileSystemException {
        continue; // Not text, so not a source file.
      }
      if (_commentMarker(path, contents.split('\n').first) == null) {
        continue;
      }
      checked++;
      final String? problem = _headerProblem(path, contents);
      if (problem != null) {
        problems.add('$path: $problem');
      }
    }
    expect(checked, greaterThan(200));
    expect(problems, isEmpty, reason: problems.join('\n'));
  });
}
