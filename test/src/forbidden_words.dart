// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// The one rule for words that public text must not contain, and its
/// allow-list.
///
/// Test and group names, workflow files and CLI output are read in public CI
/// logs and terminals, so every check of them goes through this rule. Scripts
/// use its shell form, [kForbiddenWordsShellFilter], which gives the same
/// answers.
library;

import 'dart:io' as io;

/// The forbidden words. Each is also forbidden with a trailing "s".
const List<String> kForbiddenWords = <String>[
  'beta',
  'free',
  'paid',
  'pricing',
  'price',
  'trial',
  'preview',
];

/// The allow-list's path, relative to the repository root.
const String kForbiddenWordsAllowListPath = 'test/data/forbidden_words_allow.txt';

/// The rule as a shell filter: it prints each input line that holds a
/// forbidden word.
const String kForbiddenWordsShellFilter =
    r"sed -E 's/([a-z])([A-Z])/\1 \2/g' | LC_ALL=C grep -i -E "
    r"'(^|[^[:alpha:]])(beta|free|paid|pricing|price|trial|preview)s?([^[:alpha:]]|$)'";

final RegExp _camelCaseBoundary = RegExp('([a-z])([A-Z])');
final RegExp _nonLetters = RegExp('[^A-Za-z]+');
final Set<String> _forbiddenForms = <String>{
  for (final String word in kForbiddenWords) ...<String>[word, '${word}s'],
};

/// Splits [text] into words the way the rule does.
///
/// A word ends at every character that is not an ASCII letter and at every
/// change from a lower-case to an upper-case letter, so `rawPrice` is "raw"
/// and "Price", and `release_not_in_beta` ends in "beta".
List<String> ruleWords(String text) {
  return text
      .replaceAllMapped(_camelCaseBoundary, (Match match) => '${match[1]} ${match[2]}')
      .split(_nonLetters)
      .where((String word) => word.isNotEmpty)
      .toList();
}

/// The forbidden words in [text], in the order they appear.
///
/// The match ignores case: "Previews" and "PAID" are hits, "freeze" and
/// "unpaid" are not.
List<String> forbiddenWordsIn(String text) {
  return ruleWords(
    text,
  ).where((String word) => _forbiddenForms.contains(word.toLowerCase())).toList();
}

/// Converts a path glob to a regular expression over repository-relative
/// paths.
///
/// `*` and `?` stay inside one directory; `**` crosses directories, and
/// `**/` also matches no directory at all.
RegExp globToRegExp(String glob) {
  final buffer = StringBuffer('^');
  for (var i = 0; i < glob.length; i++) {
    final String char = glob[i];
    if (char == '*' && i + 1 < glob.length && glob[i + 1] == '*') {
      if (i + 2 < glob.length && glob[i + 2] == '/') {
        buffer.write('(?:.*/)?');
        i += 2;
      } else {
        buffer.write('.*');
        i += 1;
      }
    } else if (char == '*') {
      buffer.write('[^/]*');
    } else if (char == '?') {
      buffer.write('[^/]');
    } else {
      buffer.write(RegExp.escape(char));
    }
  }
  buffer.write(r'$');
  return RegExp(buffer.toString());
}

/// One line of the allow-list: text that may stand in the files [glob]
/// matches, and why.
class AllowListEntry {
  /// Creates an entry. [line] is its line in the allow-list file.
  AllowListEntry({required this.glob, required this.text, required this.reason, required this.line})
    : _pattern = globToRegExp(glob);

  /// The paths, relative to the repository root, where [text] is allowed.
  final String glob;

  /// The exact text that is allowed.
  final String text;

  /// Why the text is allowed: an identifier, an API name or a licence text.
  final String reason;

  /// The entry's line number in the allow-list file, from 1.
  final int line;

  final RegExp _pattern;

  /// Whether this entry applies to the repository-relative [path].
  bool appliesTo(String path) => _pattern.hasMatch(path);
}

/// The allow-list: text that may contain a forbidden word, and where.
///
/// Only code identifiers, API names and upstream licence texts belong on it.
/// Test and group names, job and step names, and what a command prints are
/// never allowed, so checks of those do not consult the list.
class AllowList {
  /// Creates an allow-list from [entries].
  AllowList(this.entries);

  /// Parses the allow-list format: one entry per line, as
  /// `<path glob> | <exact text> | <reason>`. Blank lines and lines that
  /// start with `#` are skipped. Throws a [FormatException] for a line
  /// without all three parts.
  factory AllowList.parse(String contents) {
    final entries = <AllowListEntry>[];
    final List<String> lines = contents.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final String line = lines[i].trimRight();
      if (line.trim().isEmpty || line.trimLeft().startsWith('#')) {
        continue;
      }
      final int first = line.indexOf(' | ');
      final int second = first < 0 ? -1 : line.indexOf(' | ', first + 3);
      if (first < 0 || second < 0) {
        throw FormatException('Allow-list line ${i + 1} needs "glob | text | reason": $line');
      }
      final String glob = line.substring(0, first).trim();
      final String text = line.substring(first + 3, second);
      final String reason = line.substring(second + 3).trim();
      if (glob.isEmpty || text.trim().isEmpty || reason.isEmpty) {
        throw FormatException('Allow-list line ${i + 1} has an empty part: $line');
      }
      entries.add(AllowListEntry(glob: glob, text: text, reason: reason, line: i + 1));
    }
    return AllowList(entries);
  }

  /// Reads the checked-in allow-list of the repository at [repositoryRoot].
  factory AllowList.load(String repositoryRoot) {
    return AllowList.parse(
      io.File('$repositoryRoot/$kForbiddenWordsAllowListPath').readAsStringSync(),
    );
  }

  /// The entries, in file order.
  final List<AllowListEntry> entries;

  /// [text] with every allowed text that applies to [path] blanked out, so
  /// that a forbidden word elsewhere on the same line is still found.
  String strip(String path, String text) {
    var result = text;
    for (final AllowListEntry entry in entries) {
      if (entry.appliesTo(path)) {
        result = result.replaceAll(entry.text, ' ' * entry.text.length);
      }
    }
    return result;
  }

  /// The forbidden words in [text], a line of the file at [path], that no
  /// entry allows.
  List<String> forbiddenWordsAt(String path, String text) {
    return forbiddenWordsIn(strip(path, text));
  }
}

/// A forbidden word found in public text.
class ForbiddenWordHit {
  /// Creates a hit.
  const ForbiddenWordHit({
    required this.path,
    required this.line,
    required this.text,
    required this.words,
  });

  /// The repository-relative path of the file.
  final String path;

  /// The line number in the file, from 1.
  final int line;

  /// The text that holds the words: the line, or a test or group name.
  final String text;

  /// The forbidden words found.
  final List<String> words;

  @override
  String toString() => '$path:$line: ${words.join(', ')} in "$text"';
}

/// Every line of [contents], the file at [path], that holds a forbidden word
/// the [allowList] does not allow. Without an allow-list nothing is allowed.
List<ForbiddenWordHit> scanText(String path, String contents, {AllowList? allowList}) {
  final hits = <ForbiddenWordHit>[];
  final List<String> lines = contents.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final List<String> words = allowList == null
        ? forbiddenWordsIn(lines[i])
        : allowList.forbiddenWordsAt(path, lines[i]);
    if (words.isNotEmpty) {
      hits.add(ForbiddenWordHit(path: path, line: i + 1, text: lines[i].trim(), words: words));
    }
  }
  return hits;
}
