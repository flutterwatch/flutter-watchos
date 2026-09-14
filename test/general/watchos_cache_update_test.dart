// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// The engine download itself: `WatchosEngineArtifacts.updateInner`, driven
// through a fake curl and a fake unzip. The pure helpers around it (stamps,
// pending markers, the auth config file) are covered in
// watchos_precache_test.dart; this file covers the part that touches disk.

import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_watchos/watchos_cache.dart';

import '../src/common.dart';
import '../src/context.dart';
import '../src/fake_http_client.dart';
import '../src/fake_process_manager.dart';
import '../src/fakes.dart';

const String _tag = 'engine-0123456789ab';
const String _api = 'https://api.flutterwatch.dev';
const String _location = '/cli/engine_artifacts';
const String _staging = '/cli/.engine_artifacts.staging';

void main() {
  late MemoryFileSystem fs;
  late FakeProcessManager processManager;
  late FakePlatform platform;
  late BufferLogger logger;

  setUp(() {
    fs = MemoryFileSystem.test();
    Cache.flutterRoot = '/cli/flutter';
    fs.file('/cli/bin/internal/engine.version')
      ..createSync(recursive: true)
      ..writeAsStringSync('$_tag\n');
    processManager = FakeProcessManager.empty();
    // No credentials under HOME: the download goes out anonymously, which
    // keeps the curl command line free of the auth config argument.
    platform = FakePlatform(
      operatingSystem: 'macos',
      environment: <String, String>{'HOME': '/home/u'},
    );
    logger = BufferLogger.test();
  });

  WatchosEngineArtifacts makeArtifacts() {
    final cache = Cache.test(
      processManager: processManager,
      fileSystem: fs,
      platform: platform,
      logger: logger,
    );
    return WatchosEngineArtifacts(
      cache,
      logger: logger,
      platform: platform,
      processManager: processManager,
    );
  }

  ArtifactUpdater makeUpdater() => ArtifactUpdater(
    operatingSystemUtils: FakeOperatingSystemUtils(),
    logger: logger,
    fileSystem: fs,
    tempStorage: fs.directory('/tmp')..createSync(recursive: true),
    httpClient: FakeHttpClient.any(),
    platform: platform,
    allowedBaseUrls: const <String>[],
  );

  List<Pattern> curlCommand(String zipName) => <Pattern>[
    'curl',
    '--location',
    '--silent',
    '--show-error',
    '--write-out',
    '%{http_code}',
    '--output',
    RegExp('.*/$zipName'),
    '$_api/v1/artifacts/$_tag/$zipName',
  ];

  FakeCommand curlOk(String zipName) => FakeCommand(
    command: curlCommand(zipName),
    stdout: '200',
    onRun: (List<String> command) {
      fs.file(command[7])
        ..createSync(recursive: true)
        ..writeAsStringSync('PK');
    },
  );

  FakeCommand curlServerError(String zipName) => FakeCommand(
    command: curlCommand(zipName),
    stdout: '500',
  );

  List<Pattern> unzipCommand(String zipName) => <Pattern>[
    'unzip',
    '-q',
    RegExp('.*/$zipName'),
    '-d',
    RegExp('.*'),
  ];

  FakeCommand unzipOk(String zipName) => FakeCommand(
    command: unzipCommand(zipName),
    onRun: (List<String> command) {
      final String stem = zipName.substring(0, zipName.length - '.zip'.length);
      fs
          .directory(command[4])
          .childDirectory(stem)
          .childFile('libflutter_engine.dylib')
          .createSync(recursive: true);
    },
  );

  FakeCommand unzipCorrupt(String zipName) => FakeCommand(
    command: unzipCommand(zipName),
    exitCode: 9,
    stderr: 'End-of-central-directory signature not found.',
  );

  void seedPreviousEngine() {
    fs
        .file('$_location/watchos_debug_sim_arm64/keep')
        .createSync(recursive: true);
    writeEngineVersionStamp(fs.directory(_location), 'engine-previous00000');
  }

  final overrides = <Type, Generator>{
    FileSystem: () => fs,
    ProcessManager: () => processManager,
    Platform: () => platform,
  };

  testUsingContext(
    'extracts every zip and moves the finished tree into place, stamped',
    () async {
      for (final String zip in kWatchosEngineZipNames) {
        processManager.addCommands(<FakeCommand>[curlOk(zip), unzipOk(zip)]);
      }

      await makeArtifacts().updateInner(makeUpdater(), fs, FakeOperatingSystemUtils());

      final Directory location = fs.directory(_location);
      for (final String zip in kWatchosEngineZipNames) {
        final String stem = zip.substring(0, zip.length - '.zip'.length);
        expect(
          location.childDirectory(stem).childFile('libflutter_engine.dylib').existsSync(),
          isTrue,
          reason: '$stem was extracted',
        );
      }
      expect(readEngineVersionStamp(location), _tag);
      expect(fs.directory(_staging).existsSync(), isFalse);
      expect(processManager, hasNoRemainingExpectations);
    },
    overrides: overrides,
  );

  // The failure that motivated staging: a download that dies after the first
  // zip used to leave an unstamped, half-populated engine_artifacts/ which
  // the next run then reused as if it were a hand-built engine.
  testUsingContext(
    'a download that fails partway leaves the previous engine untouched',
    () async {
      seedPreviousEngine();
      final String first = kWatchosEngineZipNames[0];
      final String second = kWatchosEngineZipNames[1];
      processManager.addCommands(<FakeCommand>[
        curlOk(first),
        unzipOk(first),
        curlServerError(second),
      ]);

      await expectLater(
        () => makeArtifacts().updateInner(makeUpdater(), fs, FakeOperatingSystemUtils()),
        throwsToolExit(message: 'HTTP 500'),
      );

      final Directory location = fs.directory(_location);
      expect(location.childDirectory('watchos_debug_sim_arm64').childFile('keep').existsSync(),
          isTrue);
      expect(readEngineVersionStamp(location), 'engine-previous00000');
      expect(fs.directory(_staging).existsSync(), isFalse,
          reason: 'the partial download is discarded, not left for reuse');
    },
    overrides: overrides,
  );

  testUsingContext(
    'a corrupt zip leaves the previous engine untouched',
    () async {
      seedPreviousEngine();
      final String first = kWatchosEngineZipNames[0];
      processManager.addCommands(<FakeCommand>[curlOk(first), unzipCorrupt(first)]);

      await expectLater(
        () => makeArtifacts().updateInner(makeUpdater(), fs, FakeOperatingSystemUtils()),
        throwsToolExit(message: 'Failed to extract'),
      );

      expect(readEngineVersionStamp(fs.directory(_location)), 'engine-previous00000');
      expect(fs.directory(_staging).existsSync(), isFalse);
    },
    overrides: overrides,
  );

  testUsingContext(
    'a staging directory left by a killed run is discarded, not merged',
    () async {
      fs.file('$_staging/watchos_debug_sim_arm64/stale').createSync(recursive: true);
      for (final String zip in kWatchosEngineZipNames) {
        processManager.addCommands(<FakeCommand>[curlOk(zip), unzipOk(zip)]);
      }

      await makeArtifacts().updateInner(makeUpdater(), fs, FakeOperatingSystemUtils());

      expect(
        fs.file('$_location/watchos_debug_sim_arm64/stale').existsSync(),
        isFalse,
      );
      expect(readEngineVersionStamp(fs.directory(_location)), _tag);
    },
    overrides: overrides,
  );

  testUsingContext(
    'a stamped engine of the wanted version is reused without a download',
    () async {
      final Directory location = fs.directory(_location);
      location.childDirectory('watchos_debug_sim_arm64').createSync(recursive: true);
      writeEngineVersionStamp(location, _tag);

      await makeArtifacts().updateInner(makeUpdater(), fs, FakeOperatingSystemUtils());

      expect(processManager, hasNoRemainingExpectations);
      expect(readEngineVersionStamp(location), _tag);
    },
    overrides: overrides,
  );
}
