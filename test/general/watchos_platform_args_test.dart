// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_watchos/watchos_platform_args.dart';

import '../src/common.dart';

void main() {
  group('expandWatchosPlatformArgs', () {
    test('leaves non-create argv untouched', () {
      final a = <String>['build', 'watchos', '--platforms=watchos'];
      expect(expandWatchosPlatformArgs(a), same(a));
    });

    test('leaves create without --platforms untouched', () {
      final a = <String>['create', '--org', 'com.x', '.'];
      expect(expandWatchosPlatformArgs(a), same(a));
    });

    test('leaves create --platforms=ios (no watchos) untouched', () {
      final a = <String>['create', '--platforms=ios', '.'];
      expect(expandWatchosPlatformArgs(a), same(a));
    });

    test('--platforms=watchos → self-generated watchOS-only (internal --watchos-only)', () {
      expect(
        expandWatchosPlatformArgs(<String>['create', '--platforms=watchos', '--org', 'com.x', '.']),
        <String>['create', '--org', 'com.x', '.', '--watchos-only'],
      );
    });

    test('--platforms watchos (space form) is handled', () {
      expect(
        expandWatchosPlatformArgs(<String>['create', '--platforms', 'watchos', '.']),
        <String>['create', '.', '--watchos-only'],
      );
    });

    test('--platforms=watchos,ios keeps ios, drops watchos, no strip', () {
      expect(
        expandWatchosPlatformArgs(<String>['create', '--platforms=watchos,ios', '.']),
        <String>['create', '.', '--platforms=ios'],
      );
    });

    test('repeated --platforms tokens are merged', () {
      expect(
        expandWatchosPlatformArgs(
            <String>['create', '--platforms', 'watchos', '--platforms', 'macos', '.']),
        <String>['create', '.', '--platforms=macos'],
      );
    });

    test('preserves all other create args and their order', () {
      final List<String> got = expandWatchosPlatformArgs(<String>[
        '--suppress-analytics',
        'create',
        '--project-name',
        'foo_example',
        '--platforms=watchos',
        '--org',
        'com.example',
        '.',
      ]);
      expect(got, <String>[
        '--suppress-analytics',
        'create',
        '--project-name',
        'foo_example',
        '--org',
        'com.example',
        '.',
        '--watchos-only',
      ]);
    });
  });
}
