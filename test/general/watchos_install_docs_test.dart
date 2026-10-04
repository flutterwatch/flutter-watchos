// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// The install docs put the checkout's bin/ at the front of PATH.
//
// Appended to PATH, a new clone loses to any older checkout already there:
// `flutter-watchos` keeps running the old one and nothing says so. Flutter's
// own install docs prepend for the same reason.

import 'dart:io' as io;

import '../src/common.dart';
import '../src/host_sources.dart';

/// `export PATH=<value>`, with the value up to the first space.
final _exportPath = RegExp(r'export PATH=(\S+)');

/// A value that puts one `bin` directory in front of the existing PATH, such
/// as `"$PWD/bin:$PATH"`.
final _binFirst = RegExp(r'^"?[^:"\s]+/bin:\$PATH"?$');

/// An `export PATH=` line: where it is (`file:line: text`) and the value it
/// sets.
typedef _ExportLine = ({String where, String value});

/// What a line that writes into the shell profile holds.
const _profileAppend = '>> ~/.zshrc';

void main() {
  // doc/get-started.md, unlike README.md, names this checkout and no other.
  final String root = io.File(cliRootPath('doc/get-started.md')).parent.parent.path;
  final docs = <io.File>[
    io.File('$root/README.md'),
    io.File('$root/CONTRIBUTING.md'),
    for (final io.File file in io.Directory('$root/doc').listSync().whereType<io.File>())
      if (file.path.endsWith('.md')) file,
  ];

  /// Every `export PATH=` line in the docs, except one that writes the
  /// export into a shell profile, which [profileLines] checks.
  List<_ExportLine> exportLines() => <_ExportLine>[
    for (final io.File file in docs)
      for (final (int index, String line) in file.readAsLinesSync().indexed)
        if (!line.contains(_profileAppend))
          if (_exportPath.firstMatch(line) case final Match match)
            (
              where: '${file.path.substring(root.length + 1)}:${index + 1}: ${line.trim()}',
              value: match.group(1)!,
            ),
  ];

  /// Every line in the docs that appends to `~/.zshrc`.
  List<String> profileLines() => <String>[
    for (final io.File file in docs)
      for (final String line in file.readAsLinesSync())
        if (line.contains(_profileAppend)) line.trim(),
  ];

  test('the README and get-started both set PATH', () {
    final Iterable<String> files = exportLines().map(
      (_ExportLine line) => line.where.split(':').first,
    );

    expect(files, containsAll(<String>['README.md', 'doc/get-started.md']));
  });

  test('every export PATH line puts bin first', () {
    final appended = <String>[
      for (final _ExportLine line in exportLines())
        if (!_binFirst.hasMatch(line.value)) line.where,
    ];

    expect(appended, isEmpty, reason: r'write export PATH="$PWD/bin:$PATH"');
  });

  // `$PWD` in ~/.zshrc is the directory a new terminal starts in, so the line
  // that makes the setting permanent must write the checkout's own path. Each
  // such line is run as written, in zsh as a pasted line would be, from a
  // stand-in checkout with an empty HOME.
  test('the line that makes it permanent writes the checkout path, bin first', () {
    final List<String> lines = profileLines();
    expect(lines, isNotEmpty);
    final shell = io.File('/bin/zsh').existsSync() ? '/bin/zsh' : 'bash';
    // Resolved, because the test harness only lets a test write under the
    // canonical temp directory.
    final io.Directory scratch = io.Directory(
      io.Directory.systemTemp.resolveSymbolicLinksSync(),
    ).createTempSync('install_docs_test.');
    try {
      for (final (int index, String line) in lines.indexed) {
        final home = io.Directory('${scratch.path}/home$index')..createSync();
        final checkout = io.Directory('${scratch.path}/my clone $index/flutter-watchos')
          ..createSync(recursive: true);

        final io.ProcessResult result = io.Process.runSync(
          shell,
          <String>[if (shell == '/bin/zsh') '-f', '-c', line],
          workingDirectory: checkout.path,
          environment: <String, String>{'HOME': home.path, 'PATH': '/usr/bin:/bin'},
          includeParentEnvironment: false,
        );

        expect(result.exitCode, 0, reason: '$line: ${result.stderr}');
        expect(
          io.File('${home.path}/.zshrc').readAsStringSync(),
          'export PATH="${checkout.path}/bin:\$PATH"\n',
          reason: line,
        );
      }
    } finally {
      scratch.deleteSync(recursive: true);
    }
  });
}
