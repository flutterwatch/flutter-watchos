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

    test('skips archive/export leftovers dropped into the build dir', () {
      seedSource();
      // Manual `xcodebuild archive` / Organizer export runs (and Finder)
      // leave these in build/watchos/ — none of them are Flutter assets, and
      // sweeping an .xcarchive into the bundle ships the whole app inside
      // itself.
      fs.file('/build/watchos/Runner.xcarchive/Info.plist').createSync(recursive: true);
      fs.file('/build/watchos/ipa/crown.ipa').createSync(recursive: true);
      fs.file('/build/watchos/Exported/app.ipa').createSync(recursive: true);
      fs.file('/build/watchos/exportOptions.plist').createSync(recursive: true);
      fs.file('/build/watchos/ExportOptions.plist').createSync(recursive: true);
      fs.file('/build/watchos/.DS_Store').createSync(recursive: true);

      NativeWatchosBundle.copyFlutterAssetsTree(
        source: fs.directory('/build/watchos'),
        target: fs.directory('/watchos/Flutter/flutter_assets'),
        stripJitArtifacts: false,
      );

      expect(fs.file('/watchos/Flutter/flutter_assets/kernel_blob.bin').existsSync(), isTrue);
      expect(fs.directory('/watchos/Flutter/flutter_assets/Runner.xcarchive').existsSync(), isFalse);
      expect(fs.directory('/watchos/Flutter/flutter_assets/ipa').existsSync(), isFalse);
      expect(fs.directory('/watchos/Flutter/flutter_assets/Exported').existsSync(), isFalse);
      expect(fs.file('/watchos/Flutter/flutter_assets/exportOptions.plist').existsSync(), isFalse);
      expect(fs.file('/watchos/Flutter/flutter_assets/ExportOptions.plist').existsSync(), isFalse);
      expect(fs.file('/watchos/Flutter/flutter_assets/.DS_Store').existsSync(), isFalse);
    });

    test('mirrors the source tree without nesting on the first copy', () {
      seedSource();
      NativeWatchosBundle.copyFlutterAssetsTree(
        source: fs.directory('/build/watchos'),
        target: fs.directory('/watchos/Flutter/flutter_assets'),
        stripJitArtifacts: false,
      );

      expect(fs.file('/watchos/Flutter/flutter_assets/kernel_blob.bin').existsSync(), isTrue);
      expect(fs.file('/watchos/Flutter/flutter_assets/assets/logo.png').existsSync(), isTrue);
      expect(fs.file('/watchos/Flutter/flutter_assets/assets/nested/data.bin').existsSync(), isTrue);
    });

    test('does NOT nest assets one level deep on a second copy', () {
      seedSource();
      final Directory source = fs.directory('/build/watchos');
      final Directory target = fs.directory('/watchos/Flutter/flutter_assets');

      NativeWatchosBundle.copyFlutterAssetsTree(source: source, target: target, stripJitArtifacts: false);
      NativeWatchosBundle.copyFlutterAssetsTree(source: source, target: target, stripJitArtifacts: false);

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
      NativeWatchosBundle.copyFlutterAssetsTree(source: source, target: target, stripJitArtifacts: false);

      // Simulate an asset removed from the project between builds.
      fs.file('/build/watchos/assets/logo.png').deleteSync();
      NativeWatchosBundle.copyFlutterAssetsTree(source: source, target: target, stripJitArtifacts: false);

      expect(
        fs.file('/watchos/Flutter/flutter_assets/assets/logo.png').existsSync(),
        isFalse,
        reason: 'a clean target should not retain assets deleted from the source',
      );
      expect(fs.file('/watchos/Flutter/flutter_assets/assets/nested/data.bin').existsSync(), isTrue);
    });

    test('strips JIT-only Dart payload in AOT builds', () {
      seedSource();
      fs.file('/build/watchos/isolate_snapshot_data').createSync(recursive: true);
      fs.file('/build/watchos/vm_snapshot_data').createSync(recursive: true);

      NativeWatchosBundle.copyFlutterAssetsTree(
        source: fs.directory('/build/watchos'),
        target: fs.directory('/watchos/Flutter/flutter_assets'),
        stripJitArtifacts: true,
      );

      // JIT-only payload gone...
      expect(fs.file('/watchos/Flutter/flutter_assets/kernel_blob.bin').existsSync(), isFalse);
      expect(fs.file('/watchos/Flutter/flutter_assets/isolate_snapshot_data').existsSync(), isFalse);
      expect(fs.file('/watchos/Flutter/flutter_assets/vm_snapshot_data').existsSync(), isFalse);
      // ...but real assets stay.
      expect(fs.file('/watchos/Flutter/flutter_assets/assets/logo.png').existsSync(), isTrue);
      expect(fs.file('/watchos/Flutter/flutter_assets/AssetManifest.json').existsSync(), isTrue);
    });

    test('skips xcodebuild output dirs sitting alongside the assets', () {
      seedSource();
      fs.file('/build/watchos/Release-watchos/Runner.app/Runner').createSync(recursive: true);
      fs.file('/build/watchos/Debug-watchsimulator/Runner.app/Runner').createSync(recursive: true);

      NativeWatchosBundle.copyFlutterAssetsTree(
        source: fs.directory('/build/watchos'),
        target: fs.directory('/watchos/Flutter/flutter_assets'),
        stripJitArtifacts: false,
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

    test('skips the aot/ gen_snapshot intermediates (22 MB of assembly)', () {
      seedSource();
      fs.file('/build/watchos/aot/snapshot_assembly.S').createSync(recursive: true);
      fs.file('/build/watchos/aot/snapshot_assembly.o').createSync(recursive: true);

      NativeWatchosBundle.copyFlutterAssetsTree(
        source: fs.directory('/build/watchos'),
        target: fs.directory('/watchos/Flutter/flutter_assets'),
        stripJitArtifacts: false,
      );

      expect(
        fs.directory('/watchos/Flutter/flutter_assets/aot').existsSync(),
        isFalse,
        reason: 'AOT compile intermediates must not ship inside the app bundle',
      );
    });
  });

  // The JIT core snapshots ship at the bundle root, referenced by Copy Bundle
  // Resources entries the app cannot lose. Only the JIT engine reads them, so
  // an AOT build must reduce them to placeholders rather than carrying 11 MB
  // of `isolate_snapshot.bin` into the App Store.
  group('stageJitCoreSnapshots', () {
    late MemoryFileSystem fs;
    late Directory snapshotSource;
    late Directory flutterDir;

    setUp(() {
      fs = MemoryFileSystem.test();
      snapshotSource = fs.directory('/engine/gen/flutter/lib/snapshot')
        ..createSync(recursive: true);
      flutterDir = fs.directory('/watchos/Flutter')..createSync(recursive: true);
      snapshotSource.childFile('vm_isolate_snapshot.bin').writeAsStringSync('vm');
      snapshotSource.childFile('isolate_snapshot.bin').writeAsStringSync('isolate-blob');
    });

    test('debug stages the real blobs and records them as inputs', () {
      final ({List<File> inputs, List<File> outputs}) result =
          NativeWatchosBundle.stageJitCoreSnapshots(
        snapshotSource: snapshotSource,
        flutterDir: flutterDir,
        isDebug: true,
      );

      expect(flutterDir.childFile('isolate_snapshot.bin').readAsStringSync(), 'isolate-blob');
      expect(flutterDir.childFile('vm_isolate_snapshot.bin').readAsStringSync(), 'vm');
      expect(result.inputs.map((File f) => f.basename), <String>[
        'vm_isolate_snapshot.bin',
        'isolate_snapshot.bin',
      ]);
      expect(result.outputs, hasLength(2));
    });

    test('AOT writes empty placeholders and reads no source', () {
      final ({List<File> inputs, List<File> outputs}) result =
          NativeWatchosBundle.stageJitCoreSnapshots(
        snapshotSource: snapshotSource,
        flutterDir: flutterDir,
        isDebug: false,
      );

      for (final name in <String>['vm_isolate_snapshot.bin', 'isolate_snapshot.bin']) {
        final File staged = flutterDir.childFile(name);
        expect(staged.existsSync(), isTrue, reason: '$name is a Copy Bundle Resources input');
        expect(staged.lengthSync(), 0);
      }
      expect(result.inputs, isEmpty);
      expect(result.outputs, hasLength(2));
    });

    test('a release build empties the blob a previous debug build staged', () {
      NativeWatchosBundle.stageJitCoreSnapshots(
        snapshotSource: snapshotSource,
        flutterDir: flutterDir,
        isDebug: true,
      );
      NativeWatchosBundle.stageJitCoreSnapshots(
        snapshotSource: snapshotSource,
        flutterDir: flutterDir,
        isDebug: false,
      );

      expect(
        flutterDir.childFile('isolate_snapshot.bin').lengthSync(),
        0,
        reason: 'switching to an AOT mode must not leave the JIT blob behind',
      );
    });

    test('debug tolerates an engine drop without the blobs', () {
      snapshotSource.childFile('isolate_snapshot.bin').deleteSync();

      final ({List<File> inputs, List<File> outputs}) result =
          NativeWatchosBundle.stageJitCoreSnapshots(
        snapshotSource: snapshotSource,
        flutterDir: flutterDir,
        isDebug: true,
      );

      expect(flutterDir.childFile('isolate_snapshot.bin').existsSync(), isFalse);
      expect(result.inputs, hasLength(1));
      expect(result.outputs, hasLength(1));
    });
  });
}
