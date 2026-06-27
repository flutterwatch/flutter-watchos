// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Regression tests for the flutter_assets copy step: a naive `cp -R` nests
// assets one level deep on rebuilds (flutter_assets/assets/assets/...) and
// leaves stale files behind. `copyFlutterAssetsTree` must produce a target
// that exactly mirrors the source every time, skipping xcodebuild output dirs.

import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:flutter_watchos/build_targets/application.dart';

import '../src/common.dart';

void main() {
  group('copyFlutterAssetsTree', () {
    late MemoryFileSystem fs;

    setUp(() {
      fs = MemoryFileSystem.test();
    });

    void seedSource() {
      fs.file('/build/watchos/kernel_blob.bin').createSync(recursive: true);
      fs.file('/build/watchos/AssetManifest.json').createSync(recursive: true);
      fs.file('/build/watchos/assets/logo.png')
        ..createSync(recursive: true)
        ..writeAsStringSync('logo');
      fs.file('/build/watchos/assets/nested/data.bin')
        ..createSync(recursive: true)
        ..writeAsStringSync('data');
    }

    test('mirrors the source tree without nesting on the first copy', () {
      seedSource();
      NativeWatchosBundle.copyFlutterAssetsTree(
        source: fs.directory('/build/watchos'),
        target: fs.directory('/watchos/Flutter/flutter_assets'),
      );

      expect(fs.file('/watchos/Flutter/flutter_assets/kernel_blob.bin').existsSync(), isTrue);
      expect(fs.file('/watchos/Flutter/flutter_assets/assets/logo.png').existsSync(), isTrue);
      expect(fs.file('/watchos/Flutter/flutter_assets/assets/nested/data.bin').existsSync(), isTrue);
    });

    test('does NOT nest assets one level deep on a second copy', () {
      seedSource();
      final Directory source = fs.directory('/build/watchos');
      final Directory target = fs.directory('/watchos/Flutter/flutter_assets');

      NativeWatchosBundle.copyFlutterAssetsTree(source: source, target: target);
      NativeWatchosBundle.copyFlutterAssetsTree(source: source, target: target);

      expect(
        fs.directory('/watchos/Flutter/flutter_assets/assets/assets').existsSync(),
        isFalse,
        reason: 'assets must not be nested inside themselves on rebuild',
      );
      expect(fs.file('/watchos/Flutter/flutter_assets/assets/logo.png').existsSync(), isTrue);
    });

    test('wipes stale files so the target exactly mirrors the source', () {
      seedSource();
      final Directory source = fs.directory('/build/watchos');
      final Directory target = fs.directory('/watchos/Flutter/flutter_assets');
      NativeWatchosBundle.copyFlutterAssetsTree(source: source, target: target);

      // Simulate an asset removed from the project between builds.
      fs.file('/build/watchos/assets/logo.png').deleteSync();
      NativeWatchosBundle.copyFlutterAssetsTree(source: source, target: target);

      expect(
        fs.file('/watchos/Flutter/flutter_assets/assets/logo.png').existsSync(),
        isFalse,
        reason: 'a clean target should not retain assets deleted from the source',
      );
      expect(fs.file('/watchos/Flutter/flutter_assets/assets/nested/data.bin').existsSync(), isTrue);
    });

    test('skips xcodebuild output dirs sitting alongside the assets', () {
      seedSource();
      fs.file('/build/watchos/Release-watchos/Runner.app/Runner').createSync(recursive: true);
      fs.file('/build/watchos/Debug-watchsimulator/Runner.app/Runner').createSync(recursive: true);

      NativeWatchosBundle.copyFlutterAssetsTree(
        source: fs.directory('/build/watchos'),
        target: fs.directory('/watchos/Flutter/flutter_assets'),
      );

      expect(
        fs.directory('/watchos/Flutter/flutter_assets/Release-watchos').existsSync(),
        isFalse,
      );
      expect(
        fs.directory('/watchos/Flutter/flutter_assets/Debug-watchsimulator').existsSync(),
        isFalse,
      );
    });
  });
}
