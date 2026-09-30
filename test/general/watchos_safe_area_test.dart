// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Contract tests for the watch safe area: what the host module (the
// CLI-compiled runner glue in host/) reports to the engine as
// `MediaQuery.padding`.
//
// The host measures SwiftUI's safe area with an overlay, divides it by the
// content scale and passes it to the engine through
// `FlutterWatchOSHostSetSafeAreaInsets`. The `FlutterWatchOSSafeArea`
// Info.plist key selects between watchOS's own insets and a uniform inset
// that only keeps content clear of the display's rounded corners. None of
// this can run off the watch, so these tests read the Swift sources and pin
// the parts that decide the numbers: a change to any of them shows up here as
// a failing assertion, next to the code that changed.

import 'dart:convert';
import 'dart:io' as io;
import 'dart:math' as math;

import '../src/common.dart';
import '../src/host_sources.dart';

void main() {
  final String hostView = _blankComments(readHostSource('FlutterHostView.swift'));
  final String runner = _blankComments(readHostSource('FlutterRunner.swift'));
  final String header = _blankComments(readHostSource('flutter_watchos_host.h'));
  final Map<String, double> cornerFixture = _readCornerFixture();

  group('watchOS safe area: the measuring overlay', () {
    final int report = hostView.indexOf('runner.reportSafeArea(');
    final int reader = hostView.lastIndexOf('GeometryReader', report);
    final int overlay = hostView.lastIndexOf('.overlay {', reader);
    final int surface = hostView.lastIndexOf('.ignoresSafeArea()', overlay);

    test('is found', () {
      expect(report, greaterThan(-1));
      expect(reader, greaterThan(-1));
      expect(overlay, greaterThan(-1));
      expect(surface, greaterThan(-1));
    });

    test('sits after the full-bleed surface, outside its .ignoresSafeArea()', () {
      // A GeometryReader that ignores the safe area reports all zeros. The
      // overlay has to be a modifier of the same view as the surface's
      // `.ignoresSafeArea()`, attached after it: same nesting depth, later in
      // the chain, and no `.ignoresSafeArea` of its own.
      expect(surface, lessThan(overlay));
      expect(_depthAt(hostView, overlay), _depthAt(hostView, surface));
      expect(_block(hostView, overlay), isNot(contains('ignoresSafeArea')));
    });

    test('is not inside a ScrollView', () {
      // A reader inside a ScrollView reports zero top and bottom: the scroll
      // view turns the safe area into a content inset.
      for (final RegExpMatch match in RegExp(
        r'ScrollView\s*(\([^)]*\))?\s*\{',
      ).allMatches(hostView)) {
        final int end = match.start + _block(hostView, match.start).length;
        expect(
          reader < match.start || reader > end,
          isTrue,
          reason: 'the safe-area reader is inside the ScrollView at offset ${match.start}',
        );
      }
    });

    test('takes no touches', () {
      expect(_block(hostView, overlay), contains('.allowsHitTesting(false)'));
    });

    test('reports on appear and on every change', () {
      final String block = _flat(_block(hostView, reader));
      expect(block, contains('.onAppear { runner.reportSafeArea(proxy.safeAreaInsets) }'));
      expect(
        block,
        contains(
          '.onChange(of: proxy.safeAreaInsets) { _, insets in runner.reportSafeArea(insets) }',
        ),
      );
    });
  });

  group('watchOS safe area: reportSafeArea', () {
    late final String body = _flat(
      _block(runner, runner.indexOf('func reportSafeArea(_ insets: EdgeInsets)')),
    );

    test('divides every edge by the content scale', () {
      expect(body, contains('let scale = WatchContentScale.value'));
      expect(
        body,
        contains(
          'FlutterWatchOSHostSetSafeAreaInsets(insets.top / scale, '
          'insets.trailing / scale, insets.bottom / scale, insets.leading / scale)',
        ),
      );
      expect(body, contains('let d = inset / scale'));
      expect(body, contains('FlutterWatchOSHostSetSafeAreaInsets(d, d, d, d)'));
    });

    test(
      "passes top, trailing, bottom, leading in the header's top, right, bottom, left order",
      () {
        expect(
          _flat(header),
          contains(
            'void FlutterWatchOSHostSetSafeAreaInsets(double top_points, '
            'double right_points, double bottom_points, double left_points);',
          ),
        );
      },
    );

    test('is the only place the host sets the insets', () {
      expect('FlutterWatchOSHostSetSafeAreaInsets('.allMatches(runner).length, 2);
      expect('FlutterWatchOSHostSetSafeAreaInsets('.allMatches(body).length, 2);
    });

    test('keeps the platform insets on a screen size the table does not know', () {
      // The corners branch needs a radius; without one it falls through to
      // watchOS's own insets rather than guessing.
      expect(
        body,
        contains(
          'if WatchSafeAreaMode.usesCornerInset, let inset = WatchDisplayCorner.uniformInset {',
        ),
      );
      final String inset = _flat(_block(runner, runner.indexOf('static var uniformInset')));
      expect(inset, contains('guard let r = radius else { return nil }'));
      expect(inset, contains('return (r * (1 - 1 / 2.0.squareRoot())).rounded(.up)'));
      expect(
        runner,
        contains(
          r'return radiusByScreenSize["\(Int(b.width.rounded()))x\(Int(b.height.rounded()))"]',
        ),
      );
    });
  });

  group('watchOS safe area: FlutterWatchOSSafeArea', () {
    late final String mode = _flat(_block(runner, runner.indexOf('enum WatchSafeAreaMode')));

    test('reads the Info.plist key as a string and lowercases it', () {
      expect(mode, contains('forInfoDictionaryKey: "FlutterWatchOSSafeArea") as? String'));
      expect(mode, contains('.lowercased()'));
    });

    test('selects the corner inset unless the key is platform, in any letter case', () {
      // `corners` is the default: a missing key (nil), a value that is not a
      // string (nil after `as? String`), `corners` and any other string all
      // report the corner inset. Only `platform`, in any letter case, reports
      // watchOS's own insets.
      expect(mode, contains('return value?.lowercased() != "platform"'));
      expect(mode, isNot(contains('"corners"')));
    });

    test('is documented with corners as the default and platform as the opt-in', () {
      final String doc = _docCommentAbove(
        readHostSource('FlutterRunner.swift'),
        'enum WatchSafeAreaMode',
      );
      expect(doc, contains('`corners` (the default)'));
      expect(doc, contains('`platform`, the opt-in,'));
      expect(doc, contains('<string>platform</string>'));
      // The seven words that public text must not contain, each with one
      // letter in a character class, so that this file, which the same word
      // scan reads, does not contain them either. The first may not appear
      // in any form; the others not as a word, or as a word plus "s".
      final forbidden = RegExp(
        r'f[r]ee|(^|[^A-Za-z])(b[e]ta|p[a]id|pr[i]cing|pr[i]ce|tr[i]al|pr[e]view)s?([^A-Za-z]|$)',
        caseSensitive: false,
      );
      expect(forbidden.firstMatch(doc)?.group(0), isNull);
    });

    test('is left unset by the app template, so a new app gets the default', () {
      expect(readRunnerTemplate('Info.plist.tmpl'), isNot(contains('FlutterWatchOSSafeArea')));
    });
  });

  group('watchOS safe area: the corner radius table', () {
    test('equals test/fixtures/watch_corner_radii.json', () {
      // The dictionary literal starts at the `[` after `=`; the first `[`
      // on the line is the type's.
      final int declaration = runner.indexOf('radiusByScreenSize: [String: Double] =');
      expect(declaration, greaterThan(-1));
      final String table = _block(runner, runner.indexOf('=', declaration), '[', ']');
      final parsed = <String, double>{
        for (final RegExpMatch m in RegExp(r'"(\d+x\d+)":\s*([0-9.]+)').allMatches(table))
          m.group(1)!: double.parse(m.group(2)!),
      };
      expect(cornerFixture, hasLength(8));
      expect(parsed, cornerFixture);
    });

    test('gives a corner inset of 9, 10, 12, 13, 13, 15, 16 and 17 points', () {
      final Map<String, int> insets = cornerFixture.map(
        (String size, double r) => MapEntry<String, int>(size, (r * (1 - 1 / math.sqrt2)).ceil()),
      );
      expect(insets, <String, int>{
        '162x197': 9,
        '176x215': 12,
        '184x224': 10,
        '187x223': 13,
        '198x242': 13,
        '205x251': 16,
        '208x248': 15,
        '211x257': 17,
      });
      expect(insets.values.toList()..sort(), <int>[9, 10, 12, 13, 13, 15, 16, 17]);
    });
  });
}

/// Reads `test/fixtures/watch_corner_radii.json`: screen size in points
/// (`"162x197"`) to Apple's `DeviceCornerRadius`, in points.
Map<String, double> _readCornerFixture() {
  final Object? decoded = json.decode(
    io.File(cliRootPath('test/fixtures/watch_corner_radii.json')).readAsStringSync(),
  );
  return <String, double>{
    for (final MapEntry<String, Object?> entry in (decoded! as Map<String, Object?>).entries)
      entry.key: (entry.value! as num).toDouble(),
  };
}

/// The `///` comment lines directly above the first line that starts with
/// [declaration], without their `///` prefix.
String _docCommentAbove(String source, String declaration) {
  final List<String> lines = source.split('\n');
  final int at = lines.indexWhere((String line) => line.startsWith(declaration));
  if (at < 0) {
    throw StateError('$declaration not found');
  }
  var first = at;
  while (first > 0 && lines[first - 1].trimLeft().startsWith('///')) {
    first--;
  }
  return lines.sublist(first, at).map((String line) => line.trimLeft().substring(3)).join('\n');
}

/// Replaces every `//` comment with spaces, so offsets stay those of the
/// original source while prose in comments can neither match a search nor
/// unbalance a brace count.
String _blankComments(String source) {
  return source.replaceAllMapped(RegExp(r'//[^\n]*'), (Match m) => ' ' * m.group(0)!.length);
}

/// The text from [start] to the bracket that closes the first [open] at or
/// after it, inclusive.
String _block(String source, int start, [String open = '{', String close = '}']) {
  if (start < 0) {
    throw StateError('the block to read was not found');
  }
  final int first = source.indexOf(open, start);
  if (first < 0) {
    throw StateError('no $open after offset $start');
  }
  var depth = 0;
  for (var i = first; i < source.length; i++) {
    if (source[i] == open) {
      depth++;
    } else if (source[i] == close) {
      depth--;
      if (depth == 0) {
        return source.substring(start, i + 1);
      }
    }
  }
  throw StateError('unbalanced $open at offset $first');
}

/// How many `{` are open at [offset].
int _depthAt(String source, int offset) {
  final String prefix = source.substring(0, offset);
  return '{'.allMatches(prefix).length - '}'.allMatches(prefix).length;
}

/// Collapses every run of whitespace to one space, so an assertion does not
/// depend on how a call is wrapped.
String _flat(String source) => source.replaceAll(RegExp(r'\s+'), ' ');
