// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io' as io;

import '../../src/common.dart';

/// `bin/internal/shared.sh` of this checkout; tests run from its root.
final String _sharedSh = '${io.Directory.current.path}/bin/internal/shared.sh';

void main() {
  late io.Directory root;

  setUp(() {
    root = io.Directory(
      io.Directory.systemTemp.createTempSync('watchos_wrapper_test.').resolveSymbolicLinksSync(),
    );
    io.Directory('${root.path}/bin').createSync();
  });

  tearDown(() {
    root.deleteSync(recursive: true);
  });

  /// Sources the wrapper's shared.sh for a clone at the root, and runs
  /// [function] from it.
  io.ProcessResult run(String function) => io.Process.runSync('bash', <String>[
    '-c',
    r'set -e; BIN_DIR="$1"; source "$2"; "$3"',
    'bash',
    '${root.path}/bin',
    _sharedSh,
    function,
  ]);

  group('setup_proxy_root', () {
    /// Where the link at [path] under proxy_root points.
    String link(String path) => io.Link('${root.path}/proxy_root/$path').targetSync();

    test('links the five entries an IDE reads', () {
      final io.ProcessResult result = run('setup_proxy_root');

      expect(result.exitCode, 0, reason: '${result.stderr}');
      final flutter = '${root.path}/flutter';
      expect(link('packages'), '$flutter/packages');
      expect(link('bin/dart'), '$flutter/bin/cache/dart-sdk/bin/dart');
      expect(link('bin/cache/dart-sdk'), '$flutter/bin/cache/dart-sdk');
      expect(link('bin/cache/flutter.version.json'), '$flutter/bin/cache/flutter.version.json');
      final String proxy = io.File('${root.path}/proxy_root/bin/flutter').readAsStringSync();
      expect(proxy, contains('exec "${root.path}/bin/flutter-watchos" "\$@"'));
    });

    test('a second run replaces the links instead of nesting them', () {
      io.Directory('${root.path}/flutter/bin/cache/dart-sdk/bin').createSync(recursive: true);

      expect(run('setup_proxy_root').exitCode, 0);
      final io.ProcessResult again = run('setup_proxy_root');

      expect(again.exitCode, 0, reason: '${again.stderr}');
      expect(link('bin/cache/dart-sdk'), '${root.path}/flutter/bin/cache/dart-sdk');
      // With a plain `ln -sf`, the second link lands inside the SDK.
      expect(io.Link('${root.path}/flutter/bin/cache/dart-sdk/dart-sdk').existsSync(), isFalse);
    });
  });
}
