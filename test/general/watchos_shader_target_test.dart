// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Guards the impellerc backend set a watchOS bundle is built with.
//
// The renderer is chosen at runtime, not at build time, so one bundle has to
// serve both: SkSL for the software rasterizer and Metal for Impeller. Upstream
// CopyFlutterBundle hardcodes TargetPlatform.android, whose bucket is
// SkSL + GLES + GLES3 + Vulkan — no Metal at all. A bundle built that way loses
// every `flutter.shaders` entry the moment the app runs on Impeller, and it
// loses them silently: FragmentProgram.fromAsset rejects the blob and apps
// routinely guard that load with a null fallback, so the effect just never
// appears. That is why this is a test and not a comment.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file/memory.dart';
import 'package:flutter_tools/src/artifacts.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/build_system/build_system.dart';
import 'package:flutter_watchos/build_targets/application.dart';

import '../../flutter/packages/flutter_tools/test/src/package_config.dart';
import '../src/common.dart';
import '../src/context.dart';

/// Wraps a fake so the impellerc invocation can be read back. FakeProcessManager
/// matches commands, it does not keep them.
class _RecordingProcessManager implements ProcessManager {
  _RecordingProcessManager(this._inner);

  final ProcessManager _inner;
  final commands = <List<String>>[];

  /// The impellerc invocation, or null when the build never compiled a shader.
  List<String>? get shaderCommand {
    for (final List<String> command in commands) {
      if (command.isNotEmpty && command.first.contains('impellerc')) {
        return command;
      }
    }
    return null;
  }

  @override
  Future<ProcessResult> run(
    List<Object> command, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    Encoding? stdoutEncoding = systemEncoding,
    Encoding? stderrEncoding = systemEncoding,
  }) {
    commands.add(command.map((Object part) => part.toString()).toList());
    return _inner.run(
      command,
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: includeParentEnvironment,
      runInShell: runInShell,
      stdoutEncoding: stdoutEncoding,
      stderrEncoding: stderrEncoding,
    );
  }

  @override
  Future<Process> start(
    List<Object> command, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) {
    commands.add(command.map((Object part) => part.toString()).toList());
    return _inner.start(
      command,
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: includeParentEnvironment,
      runInShell: runInShell,
      mode: mode,
    );
  }

  @override
  ProcessResult runSync(
    List<Object> command, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    Encoding? stdoutEncoding = systemEncoding,
    Encoding? stderrEncoding = systemEncoding,
  }) {
    commands.add(command.map((Object part) => part.toString()).toList());
    return _inner.runSync(
      command,
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: includeParentEnvironment,
      runInShell: runInShell,
      stdoutEncoding: stdoutEncoding,
      stderrEncoding: stderrEncoding,
    );
  }

  @override
  bool canRun(dynamic executable, {String? workingDirectory}) =>
      _inner.canRun(executable, workingDirectory: workingDirectory);

  @override
  bool killPid(int pid, [ProcessSignal signal = ProcessSignal.sigterm]) =>
      _inner.killPid(pid, signal);
}

void main() {
  late FileSystem fileSystem;
  late Artifacts artifacts;
  late _RecordingProcessManager processManager;

  setUp(() {
    fileSystem = MemoryFileSystem.test();
    artifacts = Artifacts.test();
    processManager = _RecordingProcessManager(FakeProcessManager.any());

    fileSystem.file(artifacts.getHostArtifact(HostArtifact.impellerc).path)
        .createSync(recursive: true);
    fileSystem.file('pubspec.yaml')
      ..createSync()
      ..writeAsStringSync('''
name: example
flutter:
  shaders:
    - shaders/neon.frag
''');
    fileSystem.file('shaders/neon.frag').createSync(recursive: true);
    writePackageConfigFiles(
      directory: fileSystem.currentDirectory,
      mainLibName: 'example',
    );
  });

  Environment buildEnv() {
    final env = Environment.test(
      fileSystem.currentDirectory,
      defines: <String, String>{
        kBuildMode: BuildMode.release.cliName,
        // watchOS rides the iOS pipeline.
        kTargetPlatform: getNameForTargetPlatform(TargetPlatform.ios),
      },
      inputs: <String, String>{},
      artifacts: artifacts,
      processManager: processManager,
      fileSystem: fileSystem,
      logger: BufferLogger.test(),
      platform: FakePlatform(),
    );
    env.buildDir.createSync(recursive: true);
    return env;
  }

  group('WatchosCopyFlutterBundle shader backends', () {
    testUsingContext('compiles shaders for Metal, so Impeller can load them', () async {
      await const WatchosCopyFlutterBundle().build(buildEnv());

      expect(processManager.shaderCommand, isNotNull,
          reason: 'the build never invoked impellerc');
      expect(processManager.shaderCommand, contains('--runtime-stage-metal'));
    }, overrides: <Type, Generator>{
      FileSystem: () => fileSystem,
      ProcessManager: () => processManager,
    });

    testUsingContext('also compiles SkSL, so the software renderer still works', () async {
      await const WatchosCopyFlutterBundle().build(buildEnv());

      expect(processManager.shaderCommand, contains('--sksl'));
    }, overrides: <Type, Generator>{
      FileSystem: () => fileSystem,
      ProcessManager: () => processManager,
    });

    testUsingContext('does not carry backends no watch can run', () async {
      await const WatchosCopyFlutterBundle().build(buildEnv());

      expect(processManager.shaderCommand, isNot(contains('--runtime-stage-gles')));
      expect(processManager.shaderCommand, isNot(contains('--runtime-stage-vulkan')));
    }, overrides: <Type, Generator>{
      FileSystem: () => fileSystem,
      ProcessManager: () => processManager,
    });
  });
}
