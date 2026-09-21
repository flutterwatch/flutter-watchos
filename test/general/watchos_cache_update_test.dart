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

  /// The service refusing [zipName] with a JSON gate response.
  FakeCommand curlGated(String zipName, int status, String error, String message) => FakeCommand(
    command: curlCommand(zipName),
    stdout: '$status',
    onRun: (List<String> command) {
      fs.file(command[7])
        ..createSync(recursive: true)
        ..writeAsStringSync('{"error":"$error","message":"$message"}');
    },
  );

  const needsAccountMessage = 'This engine needs a flutterwatch.dev account.';
  FakeCommand curlNeedsAccount(String zipName) =>
      curlGated(zipName, 401, 'auth_required', needsAccountMessage);

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

  // The Simulator engine is public; every other engine needs an account. A
  // machine that never signed in must end up with a working Simulator setup,
  // not with an error and the one engine it was allowed thrown away.
  testUsingContext(
    'signed out, the Simulator engine is installed and the rest is left owed',
    () async {
      final String simulator = kWatchosEngineZipNames.first;
      processManager.addCommands(<FakeCommand>[
        curlOk(simulator),
        unzipOk(simulator),
        for (final String zip in kWatchosEngineZipNames.skip(1)) curlNeedsAccount(zip),
      ]);

      await makeArtifacts().updateInner(makeUpdater(), fs, FakeOperatingSystemUtils());

      final Directory location = fs.directory(_location);
      expect(
        location
            .childDirectory('watchos_debug_sim_arm64')
            .childFile('libflutter_engine.dylib')
            .existsSync(),
        isTrue,
      );
      expect(readEngineVersionStamp(location), _tag);
      expect(readPendingEngineZips(location), kWatchosEngineZipNames.skip(1).toList());
      expect(logger.statusText, contains('needs an account, skipped'));
      expect(logger.statusText, contains('flutter-watchos login'));
      expect(processManager, hasNoRemainingExpectations);
    },
    overrides: overrides,
  );

  // A service that wants an account for everything refuses the first zip.
  // There is nothing to install, so that is an error, in the service's words.
  testUsingContext(
    'signed out and refused the very first engine, the download fails',
    () async {
      seedPreviousEngine();
      processManager.addCommand(curlNeedsAccount(kWatchosEngineZipNames.first));

      await expectLater(
        () => makeArtifacts().updateInner(makeUpdater(), fs, FakeOperatingSystemUtils()),
        throwsToolExit(message: needsAccountMessage),
      );

      expect(readEngineVersionStamp(fs.directory(_location)), 'engine-previous00000');
      expect(fs.directory(_staging).existsSync(), isFalse);
    },
    overrides: overrides,
  );

  testUsingContext(
    'an engine the account does not have is left owed, without a sign-in hint',
    () async {
      const release = 'watchos_release_arm64.zip';
      const hostRelease = 'host_release.zip';
      for (final String zip in kWatchosEngineZipNames) {
        if (zip == release || zip == hostRelease) {
          processManager.addCommand(
            curlGated(zip, 403, 'release_not_in_beta', 'Not part of this account.'),
          );
        } else {
          processManager.addCommands(<FakeCommand>[curlOk(zip), unzipOk(zip)]);
        }
      }

      await makeArtifacts().updateInner(makeUpdater(), fs, FakeOperatingSystemUtils());

      final Directory location = fs.directory(_location);
      expect(readPendingEngineZips(location), <String>[release, hostRelease]);
      expect(logger.statusText, contains('not available to this account, skipped'));
      expect(logger.statusText, isNot(contains('flutter-watchos login')));
      // What the account has is the service's to describe, whatever it is
      // called this month; the tool does not name a programme.
      expect(logger.statusText.toLowerCase(), isNot(contains('beta')));
    },
    overrides: overrides,
  );

  testUsingContext(
    'signed out, a later precache says again what the owed engines need',
    () async {
      final Directory location = fs.directory(_location);
      location.childDirectory('watchos_debug_sim_arm64').createSync(recursive: true);
      writeEngineVersionStamp(location, _tag);
      const owed = <String>['watchos_profile_arm64.zip', 'host_debug_unopt.zip'];
      writePendingEngineZips(location, owed);
      processManager.addCommands(owed.map(curlNeedsAccount).toList());

      await makeArtifacts().updateInner(makeUpdater(), fs, FakeOperatingSystemUtils());

      expect(readPendingEngineZips(location), owed);
      expect(logger.statusText, contains('needs an account, skipped'));
      expect(logger.statusText, contains('flutter-watchos login'));
      expect(processManager, hasNoRemainingExpectations);
    },
    overrides: overrides,
  );

  testUsingContext(
    'a later precache passes on what the service says about any other refusal',
    () async {
      final Directory location = fs.directory(_location);
      location.childDirectory('watchos_debug_sim_arm64').createSync(recursive: true);
      writeEngineVersionStamp(location, _tag);
      writePendingEngineZips(location, const <String>['watchos_profile_arm64.zip']);
      processManager.addCommand(curlGated(
        'watchos_profile_arm64.zip', 403, 'access_inactive', 'Access for this account is inactive.',
      ));

      await makeArtifacts().updateInner(makeUpdater(), fs, FakeOperatingSystemUtils());

      expect(readPendingEngineZips(location), const <String>['watchos_profile_arm64.zip']);
      expect(logger.statusText, contains('Access for this account is inactive.'));
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
