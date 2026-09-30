// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/config.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/commands/daemon.dart';
import 'package:flutter_tools/src/custom_devices/custom_device.dart';
import 'package:flutter_tools/src/custom_devices/custom_devices_config.dart';
import 'package:flutter_tools/src/daemon.dart';
import 'package:flutter_tools/src/features.dart';
import 'package:flutter_tools/src/flutter_features.dart';
import 'package:flutter_tools/src/flutter_features_config.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_watchos/executable.dart';

import '../../src/common.dart';
import '../../src/context.dart';
import '../../src/fakes.dart';

/// Daemon messages in and out, in memory.
class _Streams implements DaemonStreams {
  final inputs = StreamController<DaemonMessage>();
  final outputs = StreamController<DaemonMessage>();

  @override
  Stream<DaemonMessage> get inputStream => inputs.stream;

  @override
  void send(Map<String, Object?> message, [List<int>? binary]) {
    outputs.add(DaemonMessage(message));
  }

  @override
  Future<void> dispose() async {
    await inputs.close();
    unawaited(outputs.close());
  }
}

/// The flags flutter-watchos builds for [config] and [environment].
FeatureFlags _watchosFlags({Config? config, Map<String, String> environment = const {}}) =>
    createWatchosFeatureFlags(
      flutterVersion: FakeFlutterVersion(branch: 'stable'),
      globalConfig: config ?? Config.test(),
      platform: FakePlatform(environment: environment),
      projectManifest: null,
    );

void main() {
  group('createWatchosFeatureFlags', () {
    testWithoutContext('custom devices are on when nothing configures them', () {
      expect(_watchosFlags().areCustomDevicesEnabled, isTrue);
    });

    testWithoutContext('and nothing is written to the settings file', () {
      final config = Config.test();

      expect(_watchosFlags(config: config).areCustomDevicesEnabled, isTrue);
      expect(config.keys, isEmpty);
      expect(config.getValue('enable-custom-devices'), isNull);
    });

    testWithoutContext("the user's own flutter config setting still decides", () {
      final config = Config.test()..setValue('enable-custom-devices', false);

      expect(_watchosFlags(config: config).areCustomDevicesEnabled, isFalse);
    });

    testWithoutContext('FLUTTER_CUSTOM_DEVICES still decides', () {
      expect(
        _watchosFlags(
          environment: <String, String>{'FLUTTER_CUSTOM_DEVICES': 'false'},
        ).areCustomDevicesEnabled,
        isFalse,
      );
    });

    testWithoutContext("every other feature is stock's", () {
      final config = Config.test();
      final platform = FakePlatform();
      final FeatureFlags watchos = _watchosFlags(config: config);
      final stock = FlutterFeatureFlags(
        flutterVersion: FakeFlutterVersion(branch: 'stable'),
        featuresConfig: FlutterFeaturesConfig(
          globalConfig: config,
          platform: platform,
          projectManifest: null,
        ),
        platform: platform,
      );

      expect(stock.areCustomDevicesEnabled, isFalse);
      for (final Feature feature in stock.allFeatures) {
        if (feature != flutterCustomDevicesFeature) {
          expect(watchos.isEnabled(feature), stock.isEnabled(feature), reason: feature.name);
        }
      }
    });
  });

  group('daemon.getSupportedPlatforms', () {
    late _Streams streams;
    late DaemonConnection connection;
    late NotifyingLogger notifyingLogger;
    late Daemon daemon;

    setUp(() {
      final logger = BufferLogger.test();
      notifyingLogger = NotifyingLogger(verbose: false, parent: logger);
      streams = _Streams();
      connection = DaemonConnection(daemonStreams: streams, logger: logger);
    });

    tearDown(() async {
      await daemon.shutdown();
      notifyingLogger.dispose();
      await connection.dispose();
    });

    /// The daemon's `platformTypes` answer for a project at `/project`.
    Future<Map<String, Object?>> platformTypes() async {
      globals.fs.file('/project/pubspec.yaml')
        ..createSync(recursive: true)
        ..writeAsStringSync('name: app\n');
      daemon = Daemon(connection, notifyingLogger: notifyingLogger);
      streams.inputs.add(
        DaemonMessage(<String, Object?>{
          'id': 0,
          'method': 'daemon.getSupportedPlatforms',
          'params': <String, Object?>{'projectRoot': '/project'},
        }),
      );
      final DaemonMessage response = await streams.outputs.stream.firstWhere(
        (DaemonMessage message) => message.data['event'] == null,
      );
      final result = response.data['result']! as Map<String, Object?>;
      return result['platformTypes']! as Map<String, Object?>;
    }

    testUsingContext(
      'reports custom as supported, and writes no settings',
      () async {
        final Map<String, Object?> types = await platformTypes();

        expect(types['custom'], const <String, Object>{'isSupported': true});
        expect(globals.config.getValue('enable-custom-devices'), isNull);
      },
      overrides: <Type, Generator>{
        FileSystem: () => MemoryFileSystem.test(),
        ProcessManager: () => FakeProcessManager.any(),
        FeatureFlags: () => createWatchosFeatureFlags(
          flutterVersion: globals.flutterVersion,
          globalConfig: globals.config,
          platform: globals.platform,
          projectManifest: null,
        ),
      },
    );

    testUsingContext(
      "with stock's flags it would not",
      () async {
        final Map<String, Object?> types = await platformTypes();

        expect((types['custom']! as Map<String, Object?>)['isSupported'], isFalse);
      },
      overrides: <Type, Generator>{
        FileSystem: () => MemoryFileSystem.test(),
        ProcessManager: () => FakeProcessManager.any(),
        FeatureFlags: () => TestFeatureFlags(),
      },
    );
  });

  group('custom device discovery', () {
    testWithoutContext('lists no device when there is no custom devices config', () async {
      final fs = MemoryFileSystem.test();
      final Directory configDirectory = fs.directory('/config')..createSync();
      final discovery = CustomDevices(
        featureFlags: _watchosFlags(),
        processManager: FakeProcessManager.empty(),
        logger: BufferLogger.test(),
        config: CustomDevicesConfig.test(
          fileSystem: fs,
          logger: BufferLogger.test(),
          directory: configDirectory,
        ),
      );

      expect(discovery.canListAnything, isTrue);
      expect(await discovery.devices(), isEmpty);
      expect(configDirectory.listSync(recursive: true), isEmpty);
    });
  });
}
