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
import 'package:flutter_watchos/watchos_auth.dart';
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

  Cache makeCache() => Cache.test(
    processManager: processManager,
    fileSystem: fs,
    platform: platform,
    logger: logger,
  );

  WatchosEngineArtifacts makeArtifacts([Cache? cache]) {
    return WatchosEngineArtifacts(
      cache ?? makeCache(),
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

  List<Pattern> curlCommand(String zipName, {bool signedIn = false}) => <Pattern>[
    'curl',
    '--location',
    '--silent',
    '--show-error',
    '--connect-timeout',
    '15',
    '--write-out',
    '%{http_code}',
    if (signedIn) ...<Pattern>['--config', RegExp(r'auth\.curl$')],
    '--output',
    RegExp('.*/$zipName'),
    '$_api/v1/artifacts/$_tag/$zipName',
  ];

  /// Where curl was told to write the response.
  String outputPath(List<String> command) => command[command.indexOf('--output') + 1];

  FakeCommand curlOk(String zipName, {bool signedIn = false}) => FakeCommand(
    command: curlCommand(zipName, signedIn: signedIn),
    stdout: '200',
    onRun: (List<String> command) {
      fs.file(outputPath(command))
        ..createSync(recursive: true)
        ..writeAsStringSync('PK');
    },
  );

  FakeCommand curlServerError(String zipName) => FakeCommand(
    command: curlCommand(zipName),
    stdout: '500',
  );

  /// The service refusing [zipName] with a JSON gate response.
  FakeCommand curlGated(
    String zipName,
    int status,
    String error,
    String message, {
    bool signedIn = false,
  }) => FakeCommand(
    command: curlCommand(zipName, signedIn: signedIn),
    stdout: '$status',
    onRun: (List<String> command) {
      fs.file(outputPath(command))
        ..createSync(recursive: true)
        ..writeAsStringSync('{"error":"$error","message":"$message"}');
    },
  );

  const needsAccountMessage = 'This engine needs a flutterwatch.dev account.';
  const inactiveMessage = 'Access for this account is inactive.';
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

  /// The retry of an owed zip unzips over the installed engine (`-o`).
  FakeCommand unzipOverOk(String zipName) => FakeCommand(
    command: <Pattern>['unzip', '-q', '-o', RegExp('.*/$zipName'), '-d', _location],
    onRun: (List<String> command) {
      final String stem = zipName.substring(0, zipName.length - '.zip'.length);
      fs
          .directory(command[5])
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

  void signIn() => writeWatchosCredentials(fs, platform, token: 'fw_test', login: 'someone');

  /// What a signed-out `precache` leaves: the Simulator engine, stamped, the
  /// other four owed, and the cache stamp current.
  Directory seedSignedOutInstall(Cache cache) {
    final Directory location = fs.directory(_location);
    location.childDirectory('watchos_debug_sim_arm64').createSync(recursive: true);
    writeEngineVersionStamp(location, _tag);
    writePendingEngineZips(location, kWatchosEngineZipNames.skip(1));
    cache.getRoot().createSync(recursive: true);
    cache.setStampFor(kWatchosEngineStampName, _tag);
    return location;
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
    'a later precache passes on what the service says about any other refusal, once',
    () async {
      signIn();
      final Directory location = fs.directory(_location);
      location.childDirectory('watchos_debug_sim_arm64').createSync(recursive: true);
      writeEngineVersionStamp(location, _tag);
      const owed = <String>['watchos_profile_arm64.zip', 'host_debug_unopt.zip'];
      writePendingEngineZips(location, owed);
      processManager.addCommands(<FakeCommand>[
        for (final String zip in owed)
          curlGated(zip, 403, 'access_inactive', inactiveMessage, signedIn: true),
      ]);

      await makeArtifacts().updateInner(makeUpdater(), fs, FakeOperatingSystemUtils());

      expect(readPendingEngineZips(location), owed);
      expect(inactiveMessage.allMatches(logger.statusText), hasLength(1));
      expect(logger.statusText, contains('refused, see below'));
      // Not a network hiccup: retrying on its own would not change it.
      expect(logger.statusText, isNot(contains('unavailable right now')));
      expect(logger.statusText, contains(kSimulatorStillReadyNote));
      expect(processManager, hasNoRemainingExpectations);
    },
    overrides: overrides,
  );

  testUsingContext(
    'a later precache with a sign-in the service no longer accepts says so',
    () async {
      signIn();
      final Directory location = fs.directory(_location);
      location.childDirectory('watchos_debug_sim_arm64').createSync(recursive: true);
      writeEngineVersionStamp(location, _tag);
      const owed = <String>['watchos_release_arm64.zip', 'host_release.zip'];
      writePendingEngineZips(location, owed);
      processManager.addCommands(<FakeCommand>[
        for (final String zip in owed)
          curlGated(zip, 401, 'auth_required', needsAccountMessage, signedIn: true),
      ]);

      await makeArtifacts().updateInner(makeUpdater(), fs, FakeOperatingSystemUtils());

      expect(readPendingEngineZips(location), owed);
      expect(needsAccountMessage.allMatches(logger.statusText), hasLength(1));
      expect(logger.statusText, contains(kSignInNotAcceptedNote));
    },
    overrides: overrides,
  );

  // The service serves the public Simulator engine even to an account it has
  // switched off. The download used to end at the first engine it refused and
  // throw away the Simulator engine that had already arrived, so that person
  // could not even build for the Simulator until they signed out.
  testUsingContext(
    'signed in to an account that is switched off, the Simulator engine is kept',
    () async {
      signIn();
      final String simulator = kWatchosEngineZipNames.first;
      processManager.addCommands(<FakeCommand>[
        curlOk(simulator, signedIn: true),
        unzipOk(simulator),
        for (final String zip in kWatchosEngineZipNames.skip(1))
          curlGated(zip, 403, 'access_inactive', inactiveMessage, signedIn: true),
      ]);

      await makeArtifacts().updateInner(makeUpdater(), fs, FakeOperatingSystemUtils());

      final Directory location = fs.directory(_location);
      expect(
        location.childDirectory('watchos_debug_sim_arm64').childFile('libflutter_engine.dylib').existsSync(),
        isTrue,
      );
      expect(readEngineVersionStamp(location), _tag);
      expect(readPendingEngineZips(location), kWatchosEngineZipNames.skip(1).toList());
      expect(inactiveMessage.allMatches(logger.statusText), hasLength(1));
      expect(logger.statusText, contains(kSimulatorStillReadyNote));
      // That person is signed in; sending them to `login` would be wrong.
      expect(logger.statusText, isNot(contains(kSignInForMoreEnginesHint)));
      expect(processManager, hasNoRemainingExpectations);
    },
    overrides: overrides,
  );

  testUsingContext(
    'signed in to an account that is switched off, a refused first engine fails',
    () async {
      signIn();
      seedPreviousEngine();
      processManager.addCommand(curlGated(
        kWatchosEngineZipNames.first, 403, 'access_inactive', inactiveMessage, signedIn: true,
      ));

      await expectLater(
        () => makeArtifacts().updateInner(makeUpdater(), fs, FakeOperatingSystemUtils()),
        throwsToolExit(message: inactiveMessage),
      );
      expect(readEngineVersionStamp(fs.directory(_location)), 'engine-previous00000');
    },
    overrides: overrides,
  );

  // Still fatal, by design: this person meant to be signed in. But the
  // service's text is written for a machine that never signed in, so the
  // tool says what actually happened.
  testUsingContext(
    'a sign-in the service no longer accepts ends the download, and says so',
    () async {
      signIn();
      seedPreviousEngine();
      final String simulator = kWatchosEngineZipNames.first;
      processManager.addCommands(<FakeCommand>[
        curlOk(simulator, signedIn: true),
        unzipOk(simulator),
        curlGated(kWatchosEngineZipNames[1], 401, 'auth_required', needsAccountMessage, signedIn: true),
      ]);

      await expectLater(
        () => makeArtifacts().updateInner(makeUpdater(), fs, FakeOperatingSystemUtils()),
        throwsToolExit(message: 'was not accepted'),
      );
      expect(readEngineVersionStamp(fs.directory(_location)), 'engine-previous00000');
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

  // Before this, a machine that never signed in was never up to date: every
  // run, build and drive asked the service again for the four engines that
  // need an account, printed four "skipped" lines and the sign-in hint, and
  // offline it waited on the network first.
  testUsingContext(
    'signed out, the engines left owed do not make the engine stale',
    () async {
      final Cache cache = makeCache();
      seedSignedOutInstall(cache);

      expect(await makeArtifacts(cache).isUpToDate(fs), isTrue);
      expect(processManager, hasNoRemainingExpectations);
    },
    overrides: overrides,
  );

  testUsingContext(
    'a missing engine nobody said was owed still makes the engine stale',
    () async {
      final Cache cache = makeCache();
      final Directory location = seedSignedOutInstall(cache);
      writePendingEngineZips(location, const <String>['host_release.zip']);

      expect(await makeArtifacts(cache).isUpToDate(fs), isFalse);
    },
    overrides: overrides,
  );

  testUsingContext(
    'the Simulator engine is never taken as owed',
    () async {
      final Cache cache = makeCache();
      final Directory location = seedSignedOutInstall(cache);
      location.childDirectory('watchos_debug_sim_arm64').deleteSync(recursive: true);
      writePendingEngineZips(location, kWatchosEngineZipNames);

      expect(await makeArtifacts(cache).isUpToDate(fs), isFalse);
    },
    overrides: overrides,
  );

  testUsingContext(
    'after login, the next update fetches exactly the owed engines, once',
    () async {
      final Cache cache = makeCache();
      final Directory location = seedSignedOutInstall(cache);
      final WatchosEngineArtifacts artifacts = makeArtifacts(cache);
      signIn();

      // What `login` does once the credentials are written.
      expect(retryOwedEnginesNextTime(location, cache), isTrue);
      expect(await artifacts.isUpToDate(fs), isFalse);

      for (final String zip in kWatchosEngineZipNames.skip(1)) {
        processManager.addCommands(<FakeCommand>[curlOk(zip, signedIn: true), unzipOverOk(zip)]);
      }
      await artifacts.update(makeUpdater(), logger, fs, FakeOperatingSystemUtils());

      expect(processManager, hasNoRemainingExpectations);
      expect(readPendingEngineZips(location), isEmpty);
      expect(await artifacts.isUpToDate(fs), isTrue);
    },
    overrides: overrides,
  );

  testUsingContext(
    'nothing owed, signing in leaves the engine alone',
    () async {
      final Cache cache = makeCache();
      final Directory location = seedSignedOutInstall(cache);
      writePendingEngineZips(location, const <String>[]);

      expect(retryOwedEnginesNextTime(location, cache), isFalse);
      expect(cache.getStampFor(kWatchosEngineStampName), _tag);
    },
    overrides: overrides,
  );

  // The retry's "will retry on the next precache" has to be true: a retry
  // that failed is not repeated by every build that follows.
  testUsingContext(
    'a retry that could not reach the service waits for the next precache',
    () async {
      final Cache cache = makeCache();
      final Directory location = seedSignedOutInstall(cache);
      final WatchosEngineArtifacts artifacts = makeArtifacts(cache);
      signIn();
      retryOwedEnginesNextTime(location, cache);
      processManager.addCommands(<FakeCommand>[
        for (final String zip in kWatchosEngineZipNames.skip(1))
          FakeCommand(
            command: curlCommand(zip, signedIn: true),
            exitCode: 28,
            stdout: '000',
            stderr: 'curl: (28) Connection timed out after 15001 milliseconds',
          ),
      ]);

      await artifacts.update(makeUpdater(), logger, fs, FakeOperatingSystemUtils());

      expect(logger.statusText, contains('will retry on the next precache'));
      expect(readPendingEngineZips(location), kWatchosEngineZipNames.skip(1).toList());
      expect(await artifacts.isUpToDate(fs), isTrue);
      expect(processManager, hasNoRemainingExpectations);
    },
    overrides: overrides,
  );
}
