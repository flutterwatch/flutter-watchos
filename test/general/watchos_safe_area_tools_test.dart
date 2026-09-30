// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Script tests for tool/safe_area/: each script runs as a subprocess on fake
// input in a temporary directory, so what CI checks is the script itself,
// not a copy of its logic.
//
// check_corner_table.sh reads Simulator device types. The fake trees here
// hold the two plists it reads, written in the shape Xcode ships them
// (profile.plist: `modelIdentifier`, `maxRuntimeVersion`; capabilities.plist:
// `capabilities.DeviceCornerRadius` and
// `capabilities.ScreenDimensionsCapability`). The scripts use `plutil`, so
// these tests run on macOS only, where the CLI's CI runs.

import 'dart:convert';
import 'dart:io' as io;

import '../src/common.dart';
import '../src/host_sources.dart';

void main() {
  final Object skip = io.Platform.isMacOS ? false : 'the scripts need plutil (macOS)';
  final String fixturePath = cliRootPath('test/fixtures/watch_corner_radii.json');

  late io.Directory tmp;

  setUp(() {
    // Resolved, because the test harness only lets a test write under the
    // canonical temp directory (/private/var on macOS, not /var).
    tmp = io.Directory(
      io.Directory.systemTemp.resolveSymbolicLinksSync(),
    ).createTempSync('safe_area_tools_test.');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  group('check_corner_table.sh', () {
    final String script = cliRootPath('tool/safe_area/check_corner_table.sh');

    io.ProcessResult run(String root, [String? fixture]) =>
        io.Process.runSync('bash', <String>[script, root, fixture ?? fixturePath]);

    /// The watch device types that Xcode 27.0 lists with no
    /// maxRuntimeVersion, one per screen size, with Apple's radius.
    Map<String, _DeviceType> currentWatches() => <String, _DeviceType>{
      'Apple Watch SE 3 (40mm)': const _DeviceType('Watch7,13', 324, 394, 28),
      'Apple Watch Series 9 (41mm)': const _DeviceType('Watch7,1', 352, 430, 38.5),
      'Apple Watch SE 3 (44mm)': const _DeviceType('Watch7,15', 368, 448, 34),
      'Apple Watch Series 10 (42mm)': const _DeviceType('Watch7,8', 374, 446, 44),
      'Apple Watch Series 9 (45mm)': const _DeviceType('Watch7,3', 396, 484, 42.5),
      'Apple Watch Ultra 2 (49mm)': const _DeviceType('Watch7,5', 410, 502, 54),
      'Apple Watch Series 12 (46mm)': const _DeviceType('Watch8,2', 416, 496, 50),
      'Apple Watch Ultra 3 (49mm)': const _DeviceType('Watch7,12', 422, 514, 57),
    };

    String tree(Map<String, _DeviceType> types) {
      final root = io.Directory('${tmp.path}/DeviceTypes')..createSync();
      types.forEach((String name, _DeviceType type) => type.writeTo(root, name));
      return root.path;
    }

    test('exits 0 and prints the fixture when the device types match it', () {
      final String root = tree(<String, _DeviceType>{
        ...currentWatches(),
        // Read (26.99 is at least 26.0), and the same size and radius as SE 3.
        'Apple Watch SE (40mm) (2nd generation)': const _DeviceType(
          'Watch6,10',
          324,
          394,
          28,
          maxRuntimeVersion: '26.99',
        ),
        // Not a watch.
        'iPhone 17': const _DeviceType('iPhone18,3', 1206, 2622, 55, scale: 3),
      });
      final io.ProcessResult result = run(root);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(
        json.decode(result.stdout as String),
        json.decode(io.File(fixturePath).readAsStringSync()),
      );
      expect(result.stdout, io.File(fixturePath).readAsStringSync());
    });

    test('ignores a device type whose maxRuntimeVersion is below 26.0', () {
      final String root = tree(<String, _DeviceType>{
        ...currentWatches(),
        // Would conflict with SE 3 (40mm) and differ from the fixture if read.
        'Apple Watch Series 4 (40mm)': const _DeviceType(
          'Watch4,1',
          324,
          394,
          27,
          maxRuntimeVersion: '10.99',
        ),
        // A size the fixture does not have, and no radius at all.
        'Apple Watch Series 3 (38mm)': const _DeviceType(
          'Watch3,1',
          272,
          340,
          null,
          maxRuntimeVersion: '8.255.255',
        ),
      });
      final io.ProcessResult result = run(root);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(result.stderr, contains('2 below 26.0 skipped'));
    });

    test('exits non-zero when one radius differs from the fixture', () {
      final String root = tree(<String, _DeviceType>{
        ...currentWatches(),
        'Apple Watch Ultra 3 (49mm)': const _DeviceType('Watch7,12', 422, 514, 58),
      });
      final io.ProcessResult result = run(root);
      expect(result.exitCode, 1);
      expect(result.stderr, contains('211x257: Xcode 58, fixture 57'));
      expect(result.stdout, contains('"211x257": 58'));
    });

    test('exits non-zero when a size is in only one of the two', () {
      final Map<String, _DeviceType> types = currentWatches()..remove('Apple Watch Ultra 2 (49mm)');
      types['Apple Watch Series 13 (44mm)'] = const _DeviceType('Watch9,1', 400, 480, 48);
      final io.ProcessResult result = run(tree(types));
      expect(result.exitCode, 1);
      expect(result.stderr, contains('200x240: Xcode 48, fixture -'));
      expect(result.stderr, contains('205x251: Xcode -, fixture 54'));
    });

    test('exits non-zero when one screen size maps to two radii', () {
      final String root = tree(<String, _DeviceType>{
        ...currentWatches(),
        'Apple Watch Ultra 4 (49mm)': const _DeviceType('Watch8,5', 422, 514, 56),
      });
      final io.ProcessResult result = run(root);
      expect(result.exitCode, 3);
      expect(result.stderr, contains('211x257 maps to more than one radius'));
      expect(result.stderr, contains('Apple Watch Ultra 4 (49mm)'));
      expect(result.stderr, contains('Apple Watch Ultra 3 (49mm)'));
    });

    test('exits non-zero when a supported watch has no DeviceCornerRadius', () {
      final String root = tree(<String, _DeviceType>{
        ...currentWatches(),
        'Apple Watch Series 13 (44mm)': const _DeviceType('Watch9,1', 400, 480, null),
      });
      final io.ProcessResult result = run(root);
      expect(result.exitCode, 2);
      expect(result.stderr, contains('Apple Watch Series 13 (44mm): no DeviceCornerRadius'));
    });

    test('exits non-zero when there is no watch device type to read', () {
      final io.ProcessResult empty = run(tree(<String, _DeviceType>{}));
      expect(empty.exitCode, 2);
      final io.ProcessResult missing = run('${tmp.path}/nowhere');
      expect(missing.exitCode, 2);
    });
  }, skip: skip);
}

/// One fake `<name>.simdevicetype` bundle: the two plists the script reads.
class _DeviceType {
  const _DeviceType(
    this.model,
    this.widthPixels,
    this.heightPixels,
    this.cornerRadius, {
    this.scale = 2,
    this.maxRuntimeVersion,
  });

  final String model;
  final int widthPixels;
  final int heightPixels;
  final double? cornerRadius;
  final int scale;
  final String? maxRuntimeVersion;

  void writeTo(io.Directory root, String name) {
    final resources = io.Directory('${root.path}/$name.simdevicetype/Contents/Resources')
      ..createSync(recursive: true);
    io.File('${resources.path}/profile.plist').writeAsStringSync(
      _plist(<String>[
        '<key>modelIdentifier</key><string>$model</string>',
        if (maxRuntimeVersion != null)
          '<key>maxRuntimeVersion</key><string>$maxRuntimeVersion</string>',
        '<key>minRuntimeVersion</key><string>4.0</string>',
      ]),
    );
    io.File('${resources.path}/capabilities.plist').writeAsStringSync(
      _plist(<String>[
        '<key>capabilities</key>',
        '<dict>',
        if (cornerRadius != null) '<key>DeviceCornerRadius</key><real>$cornerRadius</real>',
        '<key>ScreenDimensionsCapability</key>',
        '<dict>',
        '<key>main-screen-height</key><integer>$heightPixels</integer>',
        '<key>main-screen-scale</key><integer>$scale</integer>',
        '<key>main-screen-width</key><integer>$widthPixels</integer>',
        '</dict>',
        '</dict>',
      ]),
    );
  }

  static String _plist(List<String> body) =>
      '<?xml version="1.0" encoding="UTF-8"?>\n'
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
      '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
      '<plist version="1.0">\n<dict>\n${body.join('\n')}\n</dict>\n</plist>\n';
}
