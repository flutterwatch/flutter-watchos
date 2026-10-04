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
// `capabilities.ScreenDimensionsCapability`). check_insets.sh reads launch
// logs; the fake logs here hold SAFEAREA| lines in the format the probe and
// the created app's log entrypoint print. The scripts use `plutil`, so these
// tests run on macOS only, where the CLI's CI runs.

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

  group('check_insets.sh', () {
    final String script = cliRootPath('tool/safe_area/check_insets.sh');
    final String insetsFixturePath = cliRootPath(
      'tool/safe_area/fixtures/watch_safe_area_insets.json',
    );

    io.ProcessResult check(String log, {String? fixture, String? runtime}) {
      final logFile = io.File('${tmp.path}/launch.log')..writeAsStringSync(log);
      return io.Process.runSync('bash', <String>[
        script,
        logFile.path,
        fixture ?? insetsFixturePath,
        fixturePath,
        ?runtime,
      ]);
    }

    test('the insets fixture has the eight screen sizes of the corner fixture', () {
      final insets =
          json.decode(io.File(insetsFixturePath).readAsStringSync()) as Map<String, Object?>;
      final corners = json.decode(io.File(fixturePath).readAsStringSync()) as Map<String, Object?>;
      expect(insets.keys.toSet(), corners.keys.toSet());
      expect(insets, hasLength(8));
      for (final Object? entry in insets.values) {
        expect((entry! as Map<String, Object?>).keys.toSet(), <String>{
          'top',
          'bottom',
          'left',
          'right',
        });
      }
    });

    // One test per screen size: each runs the script twice, well within the
    // 2 s every test gets, where all eight sizes in one test took up to 4 s.
    final insets =
        json.decode(io.File(insetsFixturePath).readAsStringSync()) as Map<String, Object?>;
    final corners = json.decode(io.File(fixturePath).readAsStringSync()) as Map<String, Object?>;
    for (final String size in insets.keys) {
      test('exits 0 on a matching line in each mode, for the $size screen', () {
        final entry = insets[size]! as Map<String, Object?>;
        final List<num> wh = size.split('x').map(num.parse).toList();
        final logical = '${wh[0].toStringAsFixed(2)}x${wh[1].toStringAsFixed(2)}';
        final platform = _SafeAreaLine(
          size: logical,
          padding: _edges(
            entry['left']! as num,
            entry['top']! as num,
            entry['right']! as num,
            entry['bottom']! as num,
          ),
          band: (entry['top']! as num).toStringAsFixed(2),
        );
        final io.ProcessResult platformResult = check(platform.toString());
        expect(platformResult.exitCode, 0, reason: '$size platform: ${platformResult.stderr}');

        final int inset = ((corners[size]! as num) * 0.2928932188134524).ceil();
        final cornerLine = _SafeAreaLine(
          mode: 'corners',
          size: logical,
          padding: _edges(inset, inset, inset, inset),
          band: (entry['top']! as num).toStringAsFixed(2),
        );
        final io.ProcessResult cornerResult = check(cornerLine.toString());
        expect(cornerResult.exitCode, 0, reason: '$size corners: ${cornerResult.stderr}');
      });
    }

    test('reads the first SAFEAREA| line of an os_log dump', () {
      final io.ProcessResult result = check(
        '2026-09-30 21:00:00.100 Df Runner[4242:9f1] [com.apple.flutter] launched\n'
        '2026-09-30 21:00:00.300 Df Runner[4242:9f1] flutter: ${_SafeAreaLine()}\n'
        '2026-09-30 21:00:00.900 Df Runner[4242:9f1] flutter: ${_SafeAreaLine(padding: _edges(9, 9, 9, 9))}\n',
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(result.stdout, contains('check_insets: OK: mode=platform size=211x257'));
      // A later line that would pass does not rescue a first line that does not.
      final io.ProcessResult firstWrong = check(
        'flutter: ${_SafeAreaLine(padding: _edges(9, 9, 9, 9))}\n'
        'flutter: ${_SafeAreaLine()}\n',
      );
      expect(firstWrong.exitCode, 1);
    });

    test('divides the expectation by the content scale taken from dpr', () {
      // Ultra 3 at FlutterWatchOSContentScale 0.6: a logical 351.67x428.33
      // at pixel ratio 1.2 (Simulator measurement, 2026-09-29).
      final platform = _SafeAreaLine(
        size: '351.67x428.33',
        dpr: '1.2',
        padding: 'L3.33,T94.17,R3.33,B66.67',
        band: '94.17',
      );
      expect(check('$platform').exitCode, 0, reason: '${check('$platform').stderr}');
      final corners = _SafeAreaLine(
        mode: 'corners',
        size: '351.67x428.33',
        dpr: '1.2',
        padding: 'L28.33,T28.33,R28.33,B28.33',
        band: '94.17',
      );
      expect(check('$corners').exitCode, 0, reason: '${check('$corners').stderr}');
    });

    test('allows 0.01 pt and no more', () {
      expect(check('${_SafeAreaLine(padding: 'L2.00,T56.51,R2.00,B40.00')}').exitCode, 0);
      final io.ProcessResult off = check('${_SafeAreaLine(padding: 'L2.00,T56.52,R2.00,B40.00')}');
      expect(off.exitCode, 1);
      expect(off.stderr, contains('padding T is 56.52, expected 56.50'));
    });

    test('exits non-zero when an edge is off in either mode', () {
      expect(check('${_SafeAreaLine(padding: 'L2.00,T56.50,R2.00,B39.00')}').exitCode, 1);
      expect(
        check('${_SafeAreaLine(mode: 'corners', padding: _edges(17, 17, 17, 16))}').exitCode,
        1,
      );
      // A corners line that carries the platform insets: the mode decides.
      expect(check('${_SafeAreaLine(mode: 'corners')}').exitCode, 1);
      // viewPadding is held to the same values as padding.
      expect(check('${_SafeAreaLine(viewPadding: 'L2.00,T0.00,R2.00,B40.00')}').exitCode, 1);
    });

    test('exits non-zero when viewInsets or systemGestureInsets is not zero', () {
      final io.ProcessResult insets = check(
        '${_SafeAreaLine(viewInsets: 'L0.00,T0.00,R0.00,B80.00')}',
      );
      expect(insets.exitCode, 1);
      expect(insets.stderr, contains('viewInsets B is 80.00, expected 0.00'));
      expect(
        check('${_SafeAreaLine(systemGestureInsets: 'L20.00,T0.00,R0.00,B0.00')}').exitCode,
        1,
      );
    });

    test('exits non-zero when displayFeatures is not empty', () {
      final io.ProcessResult result = check(
        '${_SafeAreaLine(displayFeatures: '[DisplayFeature(rect: Rect.zero)]')}',
      );
      expect(result.exitCode, 1);
      expect(result.stderr, contains('displayFeatures is not empty'));
    });

    test('exits non-zero when mode= is missing or unknown', () {
      final io.ProcessResult missing = check('${_SafeAreaLine(mode: null)}');
      expect(missing.exitCode, 1);
      expect(missing.stderr, contains('the line has no mode='));
      final io.ProcessResult unknown = check('${_SafeAreaLine(mode: 'platform-cs0.6')}');
      expect(unknown.exitCode, 1);
      expect(unknown.stderr, contains('unknown mode=platform-cs0.6'));
    });

    test('exits non-zero when band= is off, in either mode', () {
      final io.ProcessResult platform = check('${_SafeAreaLine(band: '40.00')}');
      expect(platform.exitCode, 1);
      expect(platform.stderr, contains('band is 40.00, expected 56.50'));
      // In corners mode the band is still the platform top, not the padding.
      expect(
        check(
          '${_SafeAreaLine(mode: 'corners', padding: _edges(17, 17, 17, 17), band: '17.00')}',
        ).exitCode,
        1,
      );
    });

    test('exits non-zero when the log has no SAFEAREA| line', () {
      final io.ProcessResult result = check('flutter: nothing to see\n');
      expect(result.exitCode, 1);
      expect(result.stderr, contains('no SAFEAREA| line'));
    });

    test('exits non-zero on a screen size the fixture does not have', () {
      final io.ProcessResult result = check('${_SafeAreaLine(size: '200.00x240.00')}');
      expect(result.exitCode, 1);
      expect(result.stderr, contains('200x240'));
    });

    test("uses an entry's per-runtime value only for that runtime", () {
      final fixture = io.File('${tmp.path}/insets.json')
        ..writeAsStringSync(
          io.File(insetsFixturePath).readAsStringSync().replaceFirst(
            '"211x257": { "top": 56.5,',
            '"211x257": { "26.5": { "top": 57.5, "bottom": 40, "left": 2, "right": 2 }, "top": 56.5,',
          ),
        );
      final line = '${_SafeAreaLine(padding: 'L2.00,T57.50,R2.00,B40.00')}';
      expect(check(line, fixture: fixture.path, runtime: '26.5').exitCode, 0);
      expect(check(line, fixture: fixture.path, runtime: '27.0').exitCode, 1);
      expect(check(line, fixture: fixture.path).exitCode, 1);
    });
  }, skip: skip);
}

/// `L..,T..,R..,B..`, as the probe prints an `EdgeInsets`.
String _edges(num left, num top, num right, num bottom) =>
    'L${left.toStringAsFixed(2)},T${top.toStringAsFixed(2)},'
    'R${right.toStringAsFixed(2)},B${bottom.toStringAsFixed(2)}';

/// A SAFEAREA| line as the probe prints it. The defaults are an Ultra 3 in
/// `platform` mode at content scale 1.0 (Simulator, watchOS 27.0).
class _SafeAreaLine {
  _SafeAreaLine({
    this.mode = 'platform',
    this.size = '211.00x257.00',
    this.dpr = '2.0',
    this.padding = 'L2.00,T56.50,R2.00,B40.00',
    String? viewPadding,
    this.viewInsets = 'L0.00,T0.00,R0.00,B0.00',
    this.systemGestureInsets = 'L0.00,T0.00,R0.00,B0.00',
    this.displayFeatures = '[]',
    this.band,
  }) : viewPadding = viewPadding ?? padding;

  final String? mode;
  final String size;
  final String dpr;
  final String padding;
  final String viewPadding;
  final String viewInsets;
  final String systemGestureInsets;
  final String displayFeatures;
  final String? band;

  @override
  String toString() => <String>[
    'SAFEAREA',
    'dev=U3',
    if (mode != null) 'mode=$mode',
    'page=0',
    'size=$size',
    'dpr=$dpr',
    'physical=422.0x514.0',
    'padding=$padding',
    'viewPadding=$viewPadding',
    'viewInsets=$viewInsets',
    'systemGestureInsets=$systemGestureInsets',
    'displayFeatures=$displayFeatures',
    'textScale=1.0',
    'display=422.0x514.0@2.0',
    if (band != null) 'band=$band',
  ].join('|');
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
