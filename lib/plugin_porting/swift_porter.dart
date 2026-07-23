// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'compatibility_database.dart';
import 'porting_result.dart';

export 'porting_result.dart';

/// Pure-function Swift transformer.
///
/// Applies [compatibilityDatabase] to a Swift source file. Stateless; safe
/// to call concurrently across files. The implementation is deliberately
/// shallow — no real Swift parser, just regexes and brace tracking — so
/// it can be confidently audited by anyone reviewing a port.
class SwiftPorter {
  SwiftPorter({
    List<ApiPattern> database = compatibilityDatabase,
  }) : _patterns = <_CompiledPattern>[
         for (final ApiPattern p in database)
           _CompiledPattern(p, RegExp(p.pattern)),
       ];

  final List<_CompiledPattern> _patterns;

  /// `@available(...)` attribute or `#available(...)` runtime check.
  /// Group 1 = the keyword (`@available`/`#available`), group 2 = the
  /// platform list between the parentheses.
  static final RegExp _availabilityClause =
      RegExp(r'(@available|#available)\s*\(([^)]*)\)', dotAll: true);

  /// An `iOS <version>` entry inside an availability clause. Group 1 is
  /// the version (`15`, `15.0`, `17.4`, …). The leading boundary avoids
  /// matching the `iOS` inside identifiers (there are none in practice,
  /// but be safe).
  static final RegExp _iosVersionInClause =
      RegExp(r'(?<![A-Za-z])iOS (\d+(?:\.\d+)*)');

  /// Transforms [source] (the raw file content) and returns the result.
  ///
  /// [fileRelativePath] is recorded into each [PortingFinding] so the
  /// porting report can locate the issue. It should be the path the file
  /// will live at in the OUTPUT package, e.g.
  /// `watchos/Classes/URLLauncherPlugin.swift`.
  PortingResult port(String source, {required String fileRelativePath}) {
    final List<String> originalLines = source.split('\n');
    final outputLines = <String>[...originalLines];
    final findings = <PortingFinding>[];
    final strippedImports = <String>{};

    // Pass 1 — detect `case "<method>":` blocks. Build a map line → method
    // name so per-line findings can be tagged with their enclosing method.
    final Map<int, String> caseAt = _detectCaseBlocks(originalLines);
    final methodToFirstLine = <String, int>{};
    final methodToLastLine = <String, int>{};
    _computeCaseExtents(originalLines, methodToFirstLine, methodToLastLine);

    // Pass 1b — make watchOS follow the iOS code paths. The watchOS
    // embedder mirrors the iOS Flutter API (same `Flutter` module, same
    // `FlutterPluginRegistrar.messenger()` shape, and the platform even
    // reports `Platform.isIOS == true`), NOT macOS. Plugins routinely
    // branch `#if os(iOS) … #elseif os(macOS) … #else #error(...)`; on
    // watchOS the iOS branch is the correct one. So in every `#if` /
    // `#elseif` directive, widen each `os(iOS)` test to also match
    // watchOS. Parenthesised so precedence with `&&`/`!` is preserved
    // (`os(iOS) && X` → `(os(iOS) || os(watchOS)) && X`). Genuinely
    // iOS-only APIs inside such branches are still caught and stubbed by
    // the compatibility-database passes below.
    for (var i = 0; i < originalLines.length; i++) {
      final String t = originalLines[i].trimLeft();
      if ((!t.startsWith('#if ') && !t.startsWith('#elseif ')) ||
          !t.contains('os(iOS)') ||
          t.contains('os(watchOS)')) {
        continue;
      }
      outputLines[i] = originalLines[i]
          .replaceAll('os(iOS)', '(os(iOS) || os(watchOS))');
    }

    // Pass 1c — Flutter's bundled-asset resolution fallback. The
    // federated Apple plugins resolve an asset shipped in
    // `flutter_assets/` with the shared idiom:
    //
    //   var path = Bundle.main.path(forResource: key, ofType: nil)
    //   #if os(macOS)
    //     if path == nil { path = URL(string: key,
    //         relativeTo: Bundle.main.bundleURL)?.path }
    //   #endif
    //
    // The fallback is Foundation-only and harmless on watchOS (it only
    // runs when the primary lookup returned nil), so widen exactly those
    // guards to also run on watchOS. The rule is scoped to the
    // asset-fallback idiom — keyed on `Bundle.main.bundleURL` inside the
    // guarded block — so `#if os(macOS) import FlutterMacOS` branches
    // (which must NOT compile on watchOS) are deliberately left alone.
    _widenMacOSAssetFallback(originalLines, outputLines);

    // Pass 1d — widen `@available` / `#available` availability clauses to
    // also cover watchOS. Plugins gate newer-OS APIs with e.g.
    // `@available(iOS 15.0, macOS 12.0, *)` or `if #available(iOS 16.0, *)`.
    // Apple generally ships those same symbols on watchOS in the release
    // that PAIRED with that iOS version — which, unlike tvOS, is NOT the
    // same number: watchOS trails iOS by 7 majors up to iOS 18/watchOS 11,
    // then unifies at 26 (see [watchosVersionForIosVersion]). Because the
    // clause names only `iOS`, the Swift compiler treats the symbol as
    // unavailable when building for watchOS; mirror the mapped version
    // onto watchOS in every clause that names `iOS <v>` and not already
    // `watchOS`. Genuinely watchOS-*unavailable* APIs (no version makes
    // them exist) are still caught and reported by the
    // compatibility-database passes.
    for (var i = 0; i < originalLines.length; i++) {
      final String line = outputLines[i];
      if (!line.contains('available(') ||
          !line.contains('iOS ') ||
          line.contains('watchOS ')) {
        continue;
      }
      outputLines[i] = line.replaceAllMapped(
        _availabilityClause,
        (Match m) {
          final String inner = m.group(2)!;
          if (inner.contains('watchOS ')) {
            return m.group(0)!;
          }
          final Match? ios = _iosVersionInClause.firstMatch(inner);
          if (ios == null) {
            return m.group(0)!;
          }
          // Insert `, watchOS <mappedVersion>` right after the iOS entry.
          final String mapped = watchosVersionForIosVersion(ios.group(1)!);
          final String widened = inner.replaceFirst(
            ios.group(0)!,
            '${ios.group(0)!}, watchOS $mapped',
          );
          return '${m.group(1)!}($widened)';
        },
      );
    }

    // Pass 2 — strip iOS-only `import` lines. This is deliberately
    // independent of the API regex: a file that does `import WebKit` must
    // not keep that import on watchOS even when the specific call site
    // (e.g. a `WKWebView` subclass via `typealias`) slips past the usage
    // regex. The compatibility DB's `stripSwiftImports` is the
    // authoritative list of import directives to comment out.
    for (var i = 0; i < originalLines.length; i++) {
      final String trimmed = originalLines[i].trim();
      if (!trimmed.startsWith('import ')) {
        continue;
      }
      for (final _CompiledPattern cp in _patterns) {
        if (cp.entry.stripSwiftImports.contains(trimmed)) {
          outputLines[i] =
              '// ${originalLines[i]}  // removed by `flutter-watchos plugin port` (watchOS-incompatible)';
          strippedImports.add(trimmed);
          findings.add(PortingFinding(
            fileRelativePath: fileRelativePath,
            line: i + 1,
            column: 1,
            matchedText: trimmed,
            pattern: cp.entry,
            enclosingMethod: null,
            action: FindingAction.importStripped,
          ));
          break;
        }
      }
    }

    // Pass 3 — API pattern scan over non-import lines. Apply the
    // appropriate action (stub, disable-region, flag).
    final stubbedMethods = <String>{};
    // line index → unsupported API name; the enclosing declaration of
    // each anchor is later wrapped in `#if !os(watchOS)` so the package
    // still compiles, with the feature disabled on watchOS.
    final disableAnchors = <int, String>{};

    for (var i = 0; i < originalLines.length; i++) {
      final String line = originalLines[i];
      if (line.trimLeft().startsWith('import ')) {
        continue;
      }
      for (final _CompiledPattern cp in _patterns) {
        final RegExpMatch? m = cp.regex.firstMatch(line);
        if (m == null) {
          continue;
        }

        switch (cp.entry.severity) {
          case Severity.unsupported:
            final String? method = caseAt[i];
            if (method != null) {
              // Inside a recognised case: stub the entire body.
              stubbedMethods.add(method);
              findings.add(PortingFinding(
                fileRelativePath: fileRelativePath,
                line: i + 1,
                column: line.indexOf(m.group(0)!) + 1,
                matchedText: m.group(0)!,
                pattern: cp.entry,
                enclosingMethod: method,
                action: FindingAction.stubbedMethod,
              ));
            } else {
              // Type / top-level use the porter can't stub behind a
              // method channel. Record the line; its enclosing
              // declaration is wrapped in `#if !os(watchOS)` in Pass 5 so
              // the rest of the package still compiles. Feature is
              // disabled on watchOS and listed in the port summary.
              disableAnchors.putIfAbsent(i, () => cp.entry.name);
              findings.add(PortingFinding(
                fileRelativePath: fileRelativePath,
                line: i + 1,
                column: line.indexOf(m.group(0)!) + 1,
                matchedText: m.group(0)!,
                pattern: cp.entry,
                enclosingMethod: null,
                action: FindingAction.disabledOnWatchos,
              ));
            }
          case Severity.partial:
          case Severity.info:
            findings.add(PortingFinding(
              fileRelativePath: fileRelativePath,
              line: i + 1,
              column: line.indexOf(m.group(0)!) + 1,
              matchedText: m.group(0)!,
              pattern: cp.entry,
              enclosingMethod: caseAt[i],
              action: FindingAction.flagged,
            ));
        }
      }
    }

    // Pass 4 — apply the stub replacement for marked cases.
    if (stubbedMethods.isNotEmpty) {
      _stubCaseBodies(
        outputLines,
        stubbedMethods,
        methodToFirstLine,
        methodToLastLine,
      );
    }

    // Pass 5 — wrap the enclosing declaration of every type-level
    // unsupported use in `#if !os(watchOS)` so the package still compiles
    // on watchOS with that feature disabled (graceful partial port).
    final List<String> finalLines = disableAnchors.isEmpty
        ? outputLines
        : _disableWatchosRegions(outputLines, originalLines, disableAnchors);

    String transformed = finalLines.join('\n');
    if (!transformed.endsWith('\n')) {
      transformed = '$transformed\n';
    }

    return PortingResult(
      transformed: transformed,
      findings: findings,
      strippedImports: strippedImports.toList(),
      stubbedCases: stubbedMethods.toList()..sort(),
      detectedMethods: methodToFirstLine.keys.toList()..sort(),
    );
  }

  /// Walks the source and returns a map from line index → method name for
  /// every line inside a `case "<method>":` block.
  ///
  /// Cases are detected by the regex `case\s+"([^"]+)"\s*:`. Their extent
  /// runs from the case label line down to (but not including) the next
  /// `case`/`default` at the same indentation, or the closing brace of
  /// the enclosing `switch`.
  ///
  /// Heuristic, not a parser: works for the conventional `switch
  /// call.method` pattern that 90%+ of Flutter plugins use; falls back
  /// to "no enclosing method" for unusual structures.
  Map<int, String> _detectCaseBlocks(List<String> lines) {
    final result = <int, String>{};
    String? activeCase;
    var activeIndent = -1;
    for (var i = 0; i < lines.length; i++) {
      final String line = lines[i];
      final RegExpMatch? caseMatch =
          RegExp(r'^(\s*)case\s+"([^"]+)"\s*:').firstMatch(line);
      final RegExpMatch? defaultMatch =
          RegExp(r'^(\s*)default\s*:').firstMatch(line);
      if (caseMatch != null) {
        activeCase = caseMatch.group(2);
        activeIndent = caseMatch.group(1)!.length;
        // The case label line itself isn't "inside" the body for our
        // purposes — pattern matches on the label string would be a
        // false positive.
        continue;
      }
      if (defaultMatch != null && defaultMatch.group(1)!.length == activeIndent) {
        activeCase = null;
        continue;
      }
      // A close-brace at a lesser indent ends the switch.
      if (line.trim() == '}' && _leadingSpaces(line) < activeIndent) {
        activeCase = null;
      }
      if (activeCase != null) {
        result[i] = activeCase;
      }
    }
    return result;
  }

  /// Builds `methodToFirstLine` / `methodToLastLine` maps so the stubber
  /// knows the bounds of each `case` body. First/last refer to source
  /// lines INSIDE the body (not the case label line itself, not the next
  /// case label).
  void _computeCaseExtents(
    List<String> lines,
    Map<String, int> firstLine,
    Map<String, int> lastLine,
  ) {
    String? activeCase;
    var activeIndent = -1;
    int? bodyStart;
    for (var i = 0; i < lines.length; i++) {
      final String line = lines[i];
      final RegExpMatch? caseMatch =
          RegExp(r'^(\s*)case\s+"([^"]+)"\s*:').firstMatch(line);
      final RegExpMatch? otherCase = RegExp(r'^(\s*)(case\s|default\s*:)').firstMatch(line);
      if (caseMatch != null) {
        // Close out the prior case if any.
        if (activeCase != null && bodyStart != null) {
          firstLine[activeCase] = bodyStart;
          lastLine[activeCase] = i - 1;
        }
        activeCase = caseMatch.group(2);
        activeIndent = caseMatch.group(1)!.length;
        bodyStart = i + 1;
        continue;
      }
      if (otherCase != null && activeCase != null && bodyStart != null) {
        if (otherCase.group(1)!.length == activeIndent) {
          firstLine[activeCase] = bodyStart;
          lastLine[activeCase] = i - 1;
          activeCase = null;
          bodyStart = null;
        }
      }
      if (activeCase != null && line.trim() == '}' && _leadingSpaces(line) < activeIndent) {
        firstLine[activeCase] = bodyStart!;
        lastLine[activeCase] = i - 1;
        activeCase = null;
        bodyStart = null;
      }
    }
    // Handle the last case if the file ends inside one.
    if (activeCase != null && bodyStart != null) {
      firstLine[activeCase] = bodyStart;
      lastLine[activeCase] = lines.length - 1;
    }
  }

  /// Replaces the body of each method in [stubbedMethods] with a single
  /// `result(FlutterMethodNotImplemented)` line, preserving indentation.
  /// The original body is commented out so the user can see what was
  /// removed.
  void _stubCaseBodies(
    List<String> lines,
    Set<String> stubbedMethods,
    Map<String, int> firstLine,
    Map<String, int> lastLine,
  ) {
    for (final method in stubbedMethods) {
      final int? first = firstLine[method];
      final int? last = lastLine[method];
      if (first == null || last == null || first > last) {
        continue;
      }
      // Detect the indent from the first non-empty body line.
      var indent = '    ';
      for (int i = first; i <= last; i++) {
        if (lines[i].trim().isNotEmpty) {
          indent = lines[i].substring(
            0,
            lines[i].length - lines[i].trimLeft().length,
          );
          break;
        }
      }
      // Comment out original body.
      for (int i = first; i <= last; i++) {
        if (lines[i].isNotEmpty) {
          lines[i] = '// ${lines[i]}';
        }
      }
      // Insert the stub at the top by prefixing the first line; we don't
      // want to add new lines (which would change line numbers reported
      // by previous findings). Pre-pending preserves layout enough for
      // the user to navigate.
      final stub =
          '${indent}result(FlutterMethodNotImplemented)  // TODO(porter): watchOS-incompatible API stubbed';
      lines[first] = '$stub\n${lines[first]}';
    }
  }

  static int _leadingSpaces(String s) => s.length - s.trimLeft().length;

  static final RegExp _swiftTypeDecl = RegExp(
      r'^(?:@[\w.]+(?:\([^)]*\))?\s*)*(?:(?:public|private|internal|fileprivate|open|final)\s+)*(?:class|struct|extension|enum|protocol|actor)\b');
  static final RegExp _swiftMemberDecl = RegExp(
      r'^(?:@[\w.]+(?:\([^)]*\))?\s*)*(?:(?:public|private|internal|fileprivate|open|final|static|class|override|lazy|weak|unowned|convenience|required|mutating|nonisolated|dynamic)\s+)*(?:func|init|deinit|subscript|var|let)\b');

  /// Wraps the enclosing declaration of every type-level unsupported use
  /// in `#if !os(watchOS)` / `#endif`, so the rest of the package compiles
  /// on watchOS with that one declaration disabled. Best-effort and
  /// brace-shallow: well-isolated members/properties/types are excluded
  /// cleanly; a symbol referenced from elsewhere may still need manual
  /// work — every region is recorded in the port summary.
  List<String> _disableWatchosRegions(
    List<String> out,
    List<String> orig,
    Map<int, String> anchors,
  ) {
    // anchor → [start, end] enclosing-declaration range.
    final ranges = <List<int>>[];
    final namesByStart = <int, Set<String>>{};
    for (final MapEntry<int, String> e in anchors.entries) {
      final List<int> r = _memberRange(orig, e.key);
      ranges.add(r);
      namesByStart.putIfAbsent(r[0], () => <String>{}).add(e.value);
    }
    ranges.sort((List<int> a, List<int> b) => a[0].compareTo(b[0]));
    // Merge only genuinely overlapping ranges (not merely adjacent) so a
    // healthy member sitting between two disabled ones stays live.
    final merged = <List<int>>[];
    for (final r in ranges) {
      if (merged.isNotEmpty && r[0] <= merged.last[1]) {
        if (r[1] > merged.last[1]) {
          merged.last[1] = r[1];
        }
        (namesByStart[merged.last[0]] ??= <String>{})
            .addAll(namesByStart[r[0]] ?? const <String>{});
      } else {
        merged.add(<int>[r[0], r[1]]);
      }
    }
    final result = <String>[];
    var ri = 0;
    for (var i = 0; i < out.length; i++) {
      if (ri < merged.length && i == merged[ri][0]) {
        final int end = merged[ri][1];
        final String names =
            (namesByStart[merged[ri][0]]?.toList()?..sort())?.join(', ') ?? '';
        result.add('#if !os(watchOS)');
        for (var j = i; j <= end && j < out.length; j++) {
          result.add(out[j]);
        }
        result.add(
            '#endif  // flutter-watchos plugin port: disabled on watchOS ($names) — see PORTING_REPORT.md');
        i = end;
        ri++;
        continue;
      }
      result.add(out[i]);
    }
    return result;
  }

  /// Smallest enclosing declaration of [a]: the property/member it lives
  /// in, or the whole type when the unsupported token is on the type's
  /// own header/conformance line. Returns inclusive `[start, end]`.
  List<int> _memberRange(List<String> lines, int a) {
    for (var i = a; i >= 0; i--) {
      final String tl = lines[i].trimLeft();
      if (_swiftMemberDecl.hasMatch(tl)) {
        final int end = _constructEnd(lines, i);
        if (end >= a) {
          return <int>[i, end];
        }
        continue; // member ended before the anchor — keep climbing.
      }
      if (_swiftTypeDecl.hasMatch(tl)) {
        if (i == a) {
          return <int>[i, _constructEnd(lines, i)]; // header/conformance.
        }
        return <int>[a, _constructEnd(lines, a)]; // stmt in type body.
      }
    }
    return <int>[a, _constructEnd(lines, a)]; // file scope.
  }

  /// Last line of the construct that starts at [s]: the matching `}` when
  /// it opens a brace, otherwise the end of the (possibly paren- or
  /// bracket-continued) simple statement.
  int _constructEnd(List<String> lines, int s) {
    var depth = 0;
    var sawBrace = false;
    var round = 0;
    var square = 0;
    for (var j = s; j < lines.length; j++) {
      final String l = lines[j];
      for (var c = 0; c < l.length; c++) {
        switch (l[c]) {
          case '{':
            depth++;
            sawBrace = true;
          case '}':
            depth--;
            if (sawBrace && depth <= 0) {
              return j;
            }
          case '(':
            round++;
          case ')':
            round--;
          case '[':
            square++;
          case ']':
            square--;
        }
      }
      if (!sawBrace) {
        final String t = l.trimRight();
        final bool continues = t.endsWith(',') ||
            t.endsWith('=') ||
            t.endsWith('&&') ||
            t.endsWith('||') ||
            round > 0 ||
            square > 0;
        if (!continues) {
          return j;
        }
      }
    }
    return lines.length - 1;
  }

  /// Signature of the Flutter shared bundled-asset fallback: a
  /// `Bundle.main.bundleURL`-relative path resolution. Foundation-only,
  /// so it is safe on watchOS; it appears only in the asset-resolution
  /// helper, never in `import FlutterMacOS` / AppKit branches.
  static const String _assetFallbackSignature = 'Bundle.main.bundleURL';

  /// Widens `#if os(macOS)` / `#elseif os(macOS)` guards to also run on
  /// watchOS, but ONLY when the guarded branch is the bundled-asset
  /// fallback (identified by [_assetFallbackSignature]). Every other
  /// `os(macOS)` guard — notably `import FlutterMacOS` — is left
  /// untouched so it stays compiled out on watchOS.
  void _widenMacOSAssetFallback(
    List<String> originalLines,
    List<String> outputLines,
  ) {
    for (var i = 0; i < originalLines.length; i++) {
      final String t = originalLines[i].trimLeft();
      final bool isGuard =
          (t.startsWith('#if ') || t.startsWith('#elseif ')) &&
          t.contains('os(macOS)') &&
          !t.contains('os(watchOS)');
      if (!isGuard) {
        continue;
      }
      // Walk this branch's body to its terminating directive, tracking
      // nested `#if`/`#endif` so an inner conditional can't end it early.
      var depth = 0;
      var hasSignature = false;
      for (int j = i + 1; j < originalLines.length; j++) {
        final String tj = originalLines[j].trimLeft();
        if (tj.startsWith('#if') ||
            tj.startsWith('#ifdef') ||
            tj.startsWith('#ifndef')) {
          depth++;
          continue;
        }
        if (tj.startsWith('#endif')) {
          if (depth == 0) {
            break;
          }
          depth--;
          continue;
        }
        if (depth == 0 &&
            (tj.startsWith('#elseif') || tj.startsWith('#else'))) {
          break;
        }
        if (originalLines[j].contains(_assetFallbackSignature)) {
          hasSignature = true;
          break;
        }
      }
      if (hasSignature) {
        outputLines[i] = outputLines[i]
            .replaceAll('os(macOS)', '(os(macOS) || os(watchOS))');
      }
    }
  }
}

class _CompiledPattern {
  _CompiledPattern(this.entry, this.regex);
  final ApiPattern entry;
  final RegExp regex;
}
