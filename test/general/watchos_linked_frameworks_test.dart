// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:flutter_watchos/build_targets/application.dart';

import '../src/common.dart';

void main() {
  late MemoryFileSystem fileSystem;

  setUp(() {
    fileSystem = MemoryFileSystem.test();
  });

  File packageSwift(String contents) {
    final File f = fileSystem.file('/plugin/watchos/Package.swift');
    f.createSync(recursive: true);
    f.writeAsStringSync(contents);
    return f;
  }

  testWithoutContext('returns an empty list when the manifest is absent', () {
    expect(
      NativeWatchosBundle.parseLinkedFrameworks(fileSystem.file('/nope/Package.swift')),
      isEmpty,
    );
  });

  testWithoutContext('returns an empty list when no linkedFramework entries exist', () {
    final File f = packageSwift('''
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "foo", targets: [.target(name: "foo")])
''');
    expect(NativeWatchosBundle.parseLinkedFrameworks(f), isEmpty);
  });

  testWithoutContext('extracts every .linkedFramework("X") entry, tolerating whitespace', () {
    final File f = packageSwift('''
.target(
  name: "foo",
  linkerSettings: [
    .linkedFramework("WatchKit"),
    .linkedFramework( "Foundation" ),
    .linkedFramework("CoreMotion")
  ]
)
''');
    expect(
      NativeWatchosBundle.parseLinkedFrameworks(f),
      <String>['WatchKit', 'Foundation', 'CoreMotion'],
    );
  });
}
