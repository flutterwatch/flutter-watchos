// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_watchos/watchos_auth.dart';
import 'package:flutter_watchos/watchos_build_registry.dart';

import '../src/common.dart';
import '../src/fake_http_client.dart';

const ReleaseBuild _build = ReleaseBuild(
  bundleId: 'com.example.watchface',
  appVersion: '1.4.0+27',
  engineVersion: 'engine-151920b726dc',
);

FakePlatform _platform([Map<String, String> extra = const <String, String>{}]) =>
    FakePlatform(environment: <String, String>{'HOME': '/home/dev', ...extra});

/// What the registry tried to send, and the status it was given back.
class _Recorder {
  _Recorder([this.status = 200]);
  final int status;
  final List<(Uri, String, Map<String, Object?>)> calls = <(Uri, String, Map<String, Object?>)>[];

  Future<int> post(Uri uri, String token, Map<String, Object?> body) async {
    calls.add((uri, token, body));
    return status;
  }
}

void main() {
  late MemoryFileSystem fs;
  late BufferLogger logger;

  setUp(() {
    fs = MemoryFileSystem.test();
    logger = BufferLogger.test();
  });

  void signIn(FakePlatform platform) =>
      writeWatchosCredentials(fs, platform, token: 'fw_secret_token', login: 'dev');

  group('registerReleaseBuild', () {
    testWithoutContext('sends exactly four fields, under the account token, and says so', () async {
      final FakePlatform platform = _platform();
      signIn(platform);
      final recorder = _Recorder();

      final BuildRegistration result = await registerReleaseBuild(
        fileSystem: fs, platform: platform, logger: logger, build: _build, post: recorder.post,
      );

      expect(result, BuildRegistration.registered);
      final (Uri uri, String token, Map<String, Object?> body) = recorder.calls.single;
      expect(uri.toString(), 'https://api.flutterwatch.dev/v1/builds');
      expect(token, 'fw_secret_token');
      expect(body, <String, Object?>{
        'bundle_id': 'com.example.watchface',
        'app_version': '1.4.0+27',
        'engine_version': 'engine-151920b726dc',
        'build_mode': 'release',
      });
      // Never silent when it sends — and the token is never what it prints.
      expect(logger.statusText, contains('Registered this release build of com.example.watchface 1.4.0+27'));
      expect(logger.statusText, isNot(contains('fw_secret_token')));
    });

    testWithoutContext('explains itself in full the first time, and only the first time', () async {
      final FakePlatform platform = _platform();
      signIn(platform);

      await registerReleaseBuild(fileSystem: fs, platform: platform, logger: logger, build: _build, post: _Recorder().post);
      expect(logger.statusText, contains('nothing is added to your app'));
      expect(logger.statusText, contains('flutter-watchos build-registry --disable'));
      // Printed in the app's directory, which has no doc/ folder.
      expect(
        logger.statusText,
        contains('Details: https://github.com/flutterwatch/flutter-watchos/blob/main/doc/build-registry.md'),
      );

      final second = BufferLogger.test();
      await registerReleaseBuild(fileSystem: fs, platform: platform, logger: second, build: _build, post: _Recorder().post);
      expect(second.statusText, contains('Registered this release build'));
      expect(second.statusText, isNot(contains('nothing is added to your app')));
    });

    testWithoutContext('sends nothing when turned off — by setting, or by environment', () async {
      final FakePlatform platform = _platform();
      signIn(platform);
      setBuildRegistryEnabled(fs, platform, enabled: false);
      final recorder = _Recorder();

      expect(
        await registerReleaseBuild(fileSystem: fs, platform: platform, logger: logger, build: _build, post: recorder.post),
        BuildRegistration.disabled,
      );

      for (final value in <String>['0', 'false', 'OFF', ' no ']) {
        final FakePlatform ci = _platform(<String, String>{kBuildRegistryEnv: value});
        setBuildRegistryEnabled(fs, ci, enabled: true); // the environment wins over the saved setting
        expect(buildRegistryState(fs, ci), BuildRegistryState.disabledByEnvironment, reason: value);
        expect(
          await registerReleaseBuild(fileSystem: fs, platform: ci, logger: logger, build: _build, post: recorder.post),
          BuildRegistration.disabled,
        );
      }
      expect(recorder.calls, isEmpty);
      expect(logger.statusText, isEmpty);
    });

    testWithoutContext('sends nothing when signed out', () async {
      final recorder = _Recorder();
      expect(
        await registerReleaseBuild(fileSystem: fs, platform: _platform(), logger: logger, build: _build, post: recorder.post),
        BuildRegistration.notSignedIn,
      );
      expect(recorder.calls, isEmpty);
      expect(logger.statusText, isEmpty);
    });

    testWithoutContext('a refusal from the service is quiet, and is not the build’s problem', () async {
      final FakePlatform platform = _platform();
      signIn(platform);
      // 403 release_not_in_beta: the service does not give that account release engines.
      expect(
        await registerReleaseBuild(fileSystem: fs, platform: platform, logger: logger, build: _build, post: _Recorder(403).post),
        BuildRegistration.notAccepted,
      );
      expect(logger.statusText, isEmpty);
      expect(logger.errorText, isEmpty);
      expect(logger.traceText, contains('HTTP 403'));
    });

    testWithoutContext('never throws and never hangs: offline, timeouts and bad URLs all end quietly', () async {
      final FakePlatform platform = _platform();
      signIn(platform);

      Future<int> offline(Uri _, String _, Map<String, Object?> _) => throw const io.SocketException('no route to host');
      expect(
        await registerReleaseBuild(fileSystem: fs, platform: platform, logger: logger, build: _build, post: offline),
        BuildRegistration.notAccepted,
      );

      // A server that never answers must not hold the build: the call is bounded.
      Future<int> never(Uri _, String _, Map<String, Object?> _) => Completer<int>().future;
      final stopwatch = Stopwatch()..start();
      expect(
        await registerReleaseBuild(fileSystem: fs, platform: platform, logger: logger, build: _build, post: never),
        BuildRegistration.notAccepted,
      );
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 8)));
      expect(logger.statusText, isEmpty);
      expect(logger.errorText, isEmpty);
    });

    testWithoutContext('honours the API override, so a staging service gets staging builds', () async {
      final FakePlatform platform = _platform(<String, String>{'WATCHOS_ARTIFACTS_API': 'http://localhost:8787'});
      signIn(platform);
      final recorder = _Recorder();
      await registerReleaseBuild(fileSystem: fs, platform: platform, logger: logger, build: _build, post: recorder.post);
      expect(recorder.calls.single.$1.toString(), 'http://localhost:8787/v1/builds');
    });

    testWithoutContext('over real HTTP: a POST of the JSON body to /v1/builds', () async {
      final FakePlatform platform = _platform();
      signIn(platform);
      final client = FakeHttpClient.list(<FakeRequest>[
        FakeRequest(
          Uri.parse('https://api.flutterwatch.dev/v1/builds'),
          method: HttpMethod.post,
          body: utf8.encode(json.encode(_build.toJson())),
          response: FakeResponse(body: utf8.encode('{"ok":true,"build_id":1,"tier":null}')),
        ),
      ]);
      expect(
        await registerReleaseBuild(
          fileSystem: fs, platform: platform, logger: logger, build: _build, createHttpClient: () => client,
        ),
        BuildRegistration.registered,
      );
    });
  });

  group('describeBuiltApp', () {
    Directory appWith(Map<String, String> plist) {
      final Directory app = fs.directory('/proj/build/watchos/Release-watchos/Runner.app')..createSync(recursive: true);
      app.childFile('Info.plist').writeAsStringSync(json.encode(plist));
      return app;
    }

    // Stands in for plutil: the "plist" here is JSON.
    String? read(String path, String key) =>
        (json.decode(fs.file(path).readAsStringSync()) as Map<String, Object?>)[key] as String?;

    testWithoutContext('reads the resolved identity from the built app, not the project', () {
      final ReleaseBuild? build = describeBuiltApp(
        appDir: appWith(<String, String>{
          'CFBundleIdentifier': 'com.example.watchface',
          'CFBundleShortVersionString': '1.4.0',
          'CFBundleVersion': '27',
        }),
        engineVersion: 'engine-151920b726dc',
        readPlistValue: read,
      );
      expect(build!.toJson(), _build.toJson());
    });

    testWithoutContext('does not invent a build number, or a version', () {
      expect(
        describeBuiltApp(
          appDir: appWith(<String, String>{'CFBundleIdentifier': 'a.b', 'CFBundleShortVersionString': '2.0', 'CFBundleVersion': '2.0'}),
          engineVersion: null, readPlistValue: read,
        )!.appVersion,
        '2.0',
      );
      expect(
        describeBuiltApp(appDir: appWith(<String, String>{'CFBundleIdentifier': 'a.b'}), engineVersion: null, readPlistValue: read)!.appVersion,
        isNull,
      );
    });

    testWithoutContext('describes nothing when there is no app, or no bundle id, to describe', () {
      expect(describeBuiltApp(appDir: fs.directory('/nowhere/Runner.app'), engineVersion: null, readPlistValue: read), isNull);
      expect(describeBuiltApp(appDir: appWith(<String, String>{}), engineVersion: null, readPlistValue: read), isNull);
    });
  });

  group('settings', () {
    testWithoutContext('on by default; the choice survives signing out', () {
      final FakePlatform platform = _platform();
      expect(buildRegistryState(fs, platform), BuildRegistryState.enabled);

      signIn(platform);
      setBuildRegistryEnabled(fs, platform, enabled: false);
      deleteWatchosCredentials(fs, platform);
      expect(buildRegistryState(fs, platform), BuildRegistryState.disabledBySetting);

      setBuildRegistryEnabled(fs, platform, enabled: true);
      expect(buildRegistryState(fs, platform), BuildRegistryState.enabled);
    });

    testWithoutContext('a corrupt settings file means defaults, not a crash', () {
      final FakePlatform platform = _platform();
      watchosSettingsFile(fs, platform)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('{not json');
      expect(buildRegistryState(fs, platform), BuildRegistryState.enabled);
    });
  });
}
