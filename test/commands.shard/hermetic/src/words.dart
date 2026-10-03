// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// The word rule for what a command prints, for the command tests.
///
/// It is the rule of spec 0007 D8, with the same answers and the same
/// function name as `test/src/forbidden_words.dart`, which lands on another
/// branch. Once both are in one tree, this file becomes an export of that
/// one, so the rule keeps one home.
library;

const List<String> _words = <String>[
  'beta',
  'free',
  'paid',
  'pricing',
  'price',
  'trial',
  'preview',
];

final Set<String> _forms = <String>{
  for (final String word in _words) ...<String>[word, '${word}s'],
};

/// The forbidden words in [text], in the order they appear.
///
/// Text is split into words at every character that is not an ASCII letter
/// and at every change from a lower-case to an upper-case letter; a word is a
/// hit when, ignoring case, it is a forbidden word or one plus "s".
List<String> forbiddenWordsIn(String text) {
  return text
      .replaceAllMapped(RegExp('([a-z])([A-Z])'), (Match match) => '${match[1]} ${match[2]}')
      .split(RegExp('[^A-Za-z]+'))
      .where((String word) => _forms.contains(word.toLowerCase()))
      .toList();
}
