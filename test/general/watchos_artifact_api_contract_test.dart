// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// The artifact API contract, as the CLI relies on it.
//
// test/data/artifact_api_contract.json states what the artifact service
// answers for each engine zip, and the service's repository keeps a
// byte-identical copy that its own tests hold the service to. This test holds
// the CLI to the same file: the zips and their order, the one public zip, the
// pinned engine id, the download URL, and which answers a download may skip.

import 'dart:convert';
import 'dart:io' as io;

import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_watchos/watchos_cache.dart';

import '../src/common.dart';
import '../src/context.dart';
import '../src/forbidden_words.dart';
import '../src/host_sources.dart';

const _contractPath = 'test/data/artifact_api_contract.json';

/// The problems of a contract file on its own, before the CLI is compared
/// with it: values outside `keys`, key combinations that no answer or more
/// than one answer covers, zips out of shape. Empty when the file is sound.
List<String> _contractProblems(Map<String, Object?> contract) {
  final problems = <String>[];
  final artifacts = contract['artifacts']! as Map<String, Object?>;
  final keys = artifacts['keys']! as Map<String, Object?>;
  final List<Map<String, Object?>> answers = (artifacts['answers']! as List<Object?>)
      .cast<Map<String, Object?>>();
  final List<String> keyNames = keys.keys.toList();

  for (var i = 0; i < answers.length; i++) {
    final Map<String, Object?> answer = answers[i];
    for (final key in keyNames) {
      final Object? values = answer[key];
      if (values is! List<Object?> || values.isEmpty) {
        problems.add('answer $i has no values for "$key"');
        continue;
      }
      for (final Object? value in values) {
        if (!(keys[key]! as List<Object?>).contains(value)) {
          problems.add('answer $i: "$value" is not a value of "$key"');
        }
      }
    }
    final Set<String> extra = answer.keys.toSet().difference(<String>{
      ...keyNames,
      'status',
      'error',
    });
    if (extra.isNotEmpty) {
      problems.add('answer $i has unknown fields $extra');
    }
    if (answer['status'] is! int) {
      problems.add('answer $i has no status');
    } else if ((answer['status'] == 200) != (answer['error'] == null)) {
      problems.add('answer $i: a 200 has no error, and anything else has one');
    }
  }

  // Every combination of the key values matches exactly one answer.
  var combinations = <Map<String, Object?>>[<String, Object?>{}];
  for (final key in keyNames) {
    combinations = <Map<String, Object?>>[
      for (final Map<String, Object?> partial in combinations)
        for (final Object? value in keys[key]! as List<Object?>)
          <String, Object?>{...partial, key: value},
    ];
  }
  for (final combination in combinations) {
    final int matches = answers.where((Map<String, Object?> answer) {
      return keyNames.every((String key) {
        final Object? values = answer[key];
        return values is List<Object?> && values.contains(combination[key]);
      });
    }).length;
    if (matches != 1) {
      problems.add('$combination matches $matches answers');
    }
  }

  final List<Map<String, Object?>> zips = (artifacts['zips']! as List<Object?>)
      .cast<Map<String, Object?>>();
  for (final zip in zips) {
    if (!const <String>['anonymous', 'account'].contains(zip['access'])) {
      problems.add('${zip['name']} has access "${zip['access']}"');
    }
  }
  final anonymous = <Object?>[
    for (final zip in zips)
      if (zip['access'] == 'anonymous') zip['name'],
  ];
  if (zips.isEmpty || anonymous.length != 1 || anonymous.single != zips.first['name']) {
    problems.add('the first zip must be the only anonymous one, not $anonymous');
  }
  return problems;
}

Map<String, Object?> _readContract() {
  return json.decode(io.File(cliRootPath(_contractPath)).readAsStringSync())
      as Map<String, Object?>;
}

Map<String, Object?> _artifacts(Map<String, Object?> contract) =>
    contract['artifacts']! as Map<String, Object?>;

List<Map<String, Object?>> _zips(Map<String, Object?> contract) =>
    (_artifacts(contract)['zips']! as List<Object?>).cast<Map<String, Object?>>();

List<Map<String, Object?>> _answers(Map<String, Object?> contract) =>
    (_artifacts(contract)['answers']! as List<Object?>).cast<Map<String, Object?>>();

/// A deep copy of [contract], to change in a fixture.
Map<String, Object?> _copy(Map<String, Object?> contract) =>
    json.decode(json.encode(contract)) as Map<String, Object?>;

void main() {
  final Map<String, Object?> contract = _readContract();

  group('the contract file', () {
    testWithoutContext('is sound: one answer per key combination, the anonymous zip first', () {
      expect(_contractProblems(contract), isEmpty);
    });

    testWithoutContext('holds no forbidden word and no internal tier name', () {
      final String text = io.File(cliRootPath(_contractPath)).readAsStringSync();
      // The service's names for its two account tiers are forbidden words too,
      // so this also keeps them out: "anonymous" is the only tier name the file
      // may use.
      expect(forbiddenWordsIn(text), isEmpty);
    });

    testWithoutContext('a combination with no answer is a problem', () {
      final Map<String, Object?> broken = _copy(contract);
      _answers(broken).removeLast();
      expect(_contractProblems(broken), isNotEmpty);
    });

    testWithoutContext('two answers for one combination are a problem', () {
      final Map<String, Object?> broken = _copy(contract);
      (_answers(broken)[4]['token']! as List<Object?>).add('active');
      expect(
        _contractProblems(broken),
        contains(startsWith('{tag: valid, zip: account, token: active, stored: true}')),
      );
    });

    testWithoutContext('a value outside the keys is a problem', () {
      final Map<String, Object?> broken = _copy(contract);
      (_answers(broken)[0]['token']! as List<Object?>).add('expired');
      expect(_contractProblems(broken), contains('answer 0: "expired" is not a value of "token"'));
    });

    testWithoutContext('a second anonymous zip is a problem', () {
      final Map<String, Object?> broken = _copy(contract);
      _zips(broken)[1]['access'] = 'anonymous';
      expect(_contractProblems(broken), isNotEmpty);
    });
  });

  group('the CLI agrees with the contract', () {
    testWithoutContext('the zips, in download order', () {
      expect(
        kWatchosEngineZipNames,
        _zips(contract).map((Map<String, Object?> zip) => zip['name']).toList(),
      );
    });

    testWithoutContext('the Simulator zip is the anonymous one, and first', () {
      final Map<String, Object?> first = _zips(contract).first;
      expect(first['name'], kWatchosSimulatorEngineZipName);
      expect(first['access'], 'anonymous');
      expect(kWatchosEngineZipNames.first, kWatchosSimulatorEngineZipName);
    });

    testWithoutContext('every engine directory of a mode is a listed zip', () {
      final Set<Object?> listed = _zips(
        contract,
      ).map((Map<String, Object?> zip) => zip['name']).toSet();
      for (final MapEntry<String, List<String>> mode in kWatchosEngineModes.entries) {
        for (final String directory in mode.value) {
          expect(listed, contains('$directory.zip'), reason: mode.key);
        }
      }
    });

    testWithoutContext('a profile or release build asks for exactly its own listed zips', () {
      final fileSystem = MemoryFileSystem.test();
      final Directory artifactDir = fileSystem.directory('/engine')..createSync();
      for (final Map<String, Object?> zip in _zips(contract)) {
        final name = zip['name']! as String;
        final String directory = name.substring(0, name.length - '.zip'.length);
        writePendingEngineZips(artifactDir, <String>[name]);
        for (final release in <bool>[false, true]) {
          final bool needed = kWatchosEngineModes[release ? 'release' : 'profile']!.contains(
            directory,
          );
          expect(
            owedEngineAdvice(artifactDir, release: release, signedIn: false) != null,
            needed,
            reason: '$name owed, ${release ? 'release' : 'profile'} build',
          );
        }
      }
    });

    testWithoutContext('the pinned engine id is a tag the service accepts', () {
      final String pin = io.File(
        cliRootPath('bin/internal/engine.version'),
      ).readAsStringSync().trim();
      expect(pin, matches(RegExp(_artifacts(contract)['tag']! as String)));
    });

    testWithoutContext('the tag pattern refuses a path', () {
      final tag = RegExp(_artifacts(contract)['tag']! as String);
      expect(tag.hasMatch('engine-0123456789ab'), isTrue);
      expect(tag.hasMatch('engine/0123456789ab'), isFalse);
      expect(tag.hasMatch('../engine'), isFalse);
      expect(tag.hasMatch(''), isFalse);
    });

    const pin = 'engine-0123456789ab';
    final fileSystem = MemoryFileSystem.test();
    final platform = FakePlatform(
      operatingSystem: 'macos',
      environment: <String, String>{
        'HOME': '/home/u',
        'WATCHOS_ARTIFACTS_API': 'http://localhost:8787',
      },
    );
    testUsingContext(
      'each download URL follows the path',
      () {
        Cache.flutterRoot = '/cli/flutter';
        fileSystem.file('/cli/bin/internal/engine.version')
          ..createSync(recursive: true)
          ..writeAsStringSync('$pin\n');
        final artifacts = WatchosEngineArtifacts(
          Cache.test(processManager: FakeProcessManager.empty(), fileSystem: fileSystem),
          logger: BufferLogger.test(),
          platform: platform,
          processManager: FakeProcessManager.empty(),
        );
        final path = _artifacts(contract)['path']! as String;
        for (final Map<String, Object?> zip in _zips(contract)) {
          final name = zip['name']! as String;
          expect(
            artifacts.artifactDownloadUrl(name),
            'http://localhost:8787${path.replaceAll('{tag}', pin).replaceAll('{zip}', name)}',
          );
        }
      },
      overrides: <Type, Generator>{
        FileSystem: () => fileSystem,
        ProcessManager: () => FakeProcessManager.empty(),
        Platform: () => platform,
      },
    );

    testWithoutContext('a download skips only the answers it may go on without', () {
      for (final Map<String, Object?> answer in _answers(contract)) {
        final error = answer['error'] as String?;
        if (error == null) {
          continue;
        }
        for (final token in answer['token']! as List<Object?>) {
          final signedIn = token != 'none';
          for (final haveAnEngine in <bool>[false, true]) {
            // auth_required is skipped only with no token and an engine in
            // hand; access_inactive only with an engine in hand; anything else
            // ends the download.
            final SkippedGate? expected = switch (error) {
              'auth_required' when !signedIn && haveAnEngine => SkippedGate.needsAccount,
              'access_inactive' when haveAnEngine => SkippedGate.refused,
              _ => null,
            };
            expect(
              skippableGate(error, signedIn: signedIn, haveAnEngine: haveAnEngine),
              expected,
              reason: '$error, token $token, engine in hand: $haveAnEngine',
            );
          }
        }
      }
    });
  });
}
