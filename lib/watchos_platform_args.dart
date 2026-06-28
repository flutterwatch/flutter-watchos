// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// Makes `--platforms=watchos` a first-class option for `flutter-watchos
/// create`.
///
/// Upstream Flutter's `--platforms` multi-option has a hardcoded `allowed:`
/// whitelist (`ios, android, macos, windows, linux, web`) enforced by the
/// argument parser *before* any command code runs, so `watchos` would be
/// rejected outright. We don't patch Flutter, so this rewrites argv at our
/// own entrypoint — the one seam we fully control:
///
///   * `--platforms=watchos`           → `--watchos-only` (no `--platforms`)
///     `WatchosCreateCommand` self-generates the shared app + `watchos/`; it
///     never runs upstream `flutter create`, so no iOS/Android app is
///     scaffolded — nothing is created then deleted.
///   * `--platforms=watchos,ios,...`   → `--platforms=ios,...`
///     (drop `watchos`; the other platforms are scaffolded normally and
///     `watchos/` is added alongside.)
///   * no `watchos` / no `create`      → returned unchanged.
///
/// Pure function: no I/O, so it unit-tests directly.
List<String> expandWatchosPlatformArgs(List<String> args) {
  if (!args.contains('create')) {
    return args;
  }

  final withoutPlatforms = <String>[];
  final requested = <String>{};
  var sawPlatforms = false;

  for (var i = 0; i < args.length; i++) {
    final String a = args[i];
    if (a == '--platforms') {
      sawPlatforms = true;
      if (i + 1 < args.length) {
        requested.addAll(_split(args[i + 1]));
        i++; // consume the value token
      }
      continue; // drop; re-added below
    }
    if (a.startsWith('--platforms=')) {
      sawPlatforms = true;
      requested.addAll(_split(a.substring('--platforms='.length)));
      continue; // drop; re-added below
    }
    withoutPlatforms.add(a);
  }

  if (!sawPlatforms || !requested.contains('watchos')) {
    // Nothing watchOS-specific to do — leave the original argv untouched so
    // non-watchos `create` behaviour is byte-for-byte unchanged.
    return args;
  }

  final List<String> others = requested.where((String p) => p != 'watchos').toList();
  if (others.isEmpty) {
    // Pure watchOS: self-generated, no upstream flutter create at all.
    return <String>[...withoutPlatforms, '--watchos-only'];
  }
  // watchos + siblings: scaffold the siblings normally; watchos/ added alongside.
  return <String>[...withoutPlatforms, '--platforms=${others.join(',')}'];
}

Iterable<String> _split(String csv) =>
    csv.split(',').map((String s) => s.trim()).where((String s) => s.isNotEmpty);
