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

  testWithoutContext('extracts every .linkedLibrary("X") entry', () {
    final File f = packageSwift('''
.target(
  name: "foo",
  linkerSettings: [
    .linkedLibrary("z"),
    .linkedLibrary( "c++" )
  ]
)
''');
    expect(
      NativeWatchosBundle.parseLinkedLibraries(f),
      <String>['z', 'c++'],
    );
  });

  testWithoutContext('hasExternalSwiftPackages is false for a system-framework-only plugin', () {
    final File f = packageSwift('''
let package = Package(
  name: "foo",
  targets: [.target(name: "foo", linkerSettings: [.linkedFramework("Foundation")])]
)
''');
    expect(NativeWatchosBundle.hasExternalSwiftPackages(f), isFalse);
  });

  testWithoutContext('hasExternalSwiftPackages is true when a package url/path dependency is declared', () {
    final File urlDep = packageSwift('''
let package = Package(
  name: "foo",
  dependencies: [
    .package(url: "https://github.com/firebase/firebase-ios-sdk.git", .upToNextMajor(from: "11.0.0")),
  ],
)
''');
    expect(NativeWatchosBundle.hasExternalSwiftPackages(urlDep), isTrue);

    final File pathDep = packageSwift('''
dependencies: [ .package( path : "../vendored" ) ],
''');
    expect(NativeWatchosBundle.hasExternalSwiftPackages(pathDep), isTrue);
  });

  testWithoutContext('hasExternalSwiftPackages is false when the manifest is absent', () {
    expect(
      NativeWatchosBundle.hasExternalSwiftPackages(fileSystem.file('/nope/Package.swift')),
      isFalse,
    );
  });

  testWithoutContext('hasExternalSwiftPackages matches the legacy name-first form', () {
    final File f = packageSwift('''
dependencies: [
  .package(name: "Firebase", url: "https://github.com/firebase/firebase-ios-sdk.git", from: "11.0.0"),
],
''');
    expect(NativeWatchosBundle.hasExternalSwiftPackages(f), isTrue);
  });

  testWithoutContext('hasExternalSwiftPackages ignores commented-out dependencies', () {
    final File f = packageSwift('''
let package = Package(
  name: "foo",
  // dependencies: [ .package(url: "https://example.com/sdk.git", from: "1.0.0") ],
  targets: [.target(name: "foo", linkerSettings: [.linkedFramework("Foundation")])]
)
''');
    expect(NativeWatchosBundle.hasExternalSwiftPackages(f), isFalse);
  });

  testWithoutContext('parseResolvedPins reads v2 pins and tolerates absence', () {
    final File resolved = fileSystem.file('/plugin/watchos/Package.resolved')
      ..createSync(recursive: true)
      ..writeAsStringSync('''
{
  "pins": [
    {
      "identity": "firebase-ios-sdk",
      "kind": "remoteSourceControl",
      "state": {"revision": "abc123", "version": "11.15.0"}
    },
    {
      "identity": "nanopb",
      "state": {"revision": "def456"}
    }
  ],
  "version": 2
}
''');
    expect(
      NativeWatchosBundle.parseResolvedPins(resolved),
      <String, String>{'firebase-ios-sdk': '11.15.0', 'nanopb': 'def456'},
    );
    expect(
      NativeWatchosBundle.parseResolvedPins(fileSystem.file('/nope/Package.resolved')),
      isEmpty,
    );
  });

  testWithoutContext('parseResolvedPins returns empty for malformed JSON', () {
    final File resolved = fileSystem.file('/plugin/watchos/Package.resolved')
      ..createSync(recursive: true)
      ..writeAsStringSync('not json');
    expect(NativeWatchosBundle.parseResolvedPins(resolved), isEmpty);
  });
}
