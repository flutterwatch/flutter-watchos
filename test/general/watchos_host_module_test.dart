// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Tests for the FlutterWatchOS host module build step (the CLI-compiled
// runner glue) and the slimmed app template that imports it. The template's
// Runner/ holds only App.swift + assets + plists — the machinery lives in the
// CLI's host/ sources, compiled per build into watchos/Flutter/ — mirroring
// stock Flutter, whose iOS Runner is a dozen lines because the machinery
// lives in Flutter.framework.

import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:flutter_watchos/build_targets/watchos_host_module.dart';

import '../src/common.dart';
import '../src/host_sources.dart';

void main() {
  group('isLegacyRunnerProject', () {
    late MemoryFileSystem fileSystem;

    setUp(() {
      fileSystem = MemoryFileSystem.test();
    });

    testWithoutContext('true when the app compiles its own runner glue', () {
      fileSystem.file('/app/watchos/Runner/FlutterRunner.swift')
        ..createSync(recursive: true)
        ..writeAsStringSync('// legacy glue');
      expect(
        isLegacyRunnerProject(fileSystem.directory('/app/watchos')),
        isTrue,
      );
    });

    testWithoutContext('false for a project created from the slim template', () {
      fileSystem.file('/app/watchos/Runner/App.swift')
        ..createSync(recursive: true)
        ..writeAsStringSync('// tiny app entry');
      expect(
        isLegacyRunnerProject(fileSystem.directory('/app/watchos')),
        isFalse,
      );
    });
  });

  group('parseWatchosDeploymentTarget', () {
    late MemoryFileSystem fileSystem;

    setUp(() {
      fileSystem = MemoryFileSystem.test();
    });

    testWithoutContext('reads the project declaration', () {
      final File file = fileSystem.file('/p/project.pbxproj')
        ..createSync(recursive: true)
        ..writeAsStringSync('WATCHOS_DEPLOYMENT_TARGET = 26.0;');
      expect(parseWatchosDeploymentTarget(file), '26.0');
    });

    testWithoutContext('falls back when the project file is missing', () {
      expect(
        parseWatchosDeploymentTarget(fileSystem.file('/nope/project.pbxproj')),
        '26.0',
      );
    });

    testWithoutContext('falls back when the declaration is absent', () {
      final File file = fileSystem.file('/p/project.pbxproj')
        ..createSync(recursive: true)
        ..writeAsStringSync('SWIFT_VERSION = 5.0;');
      expect(parseWatchosDeploymentTarget(file), '26.0');
    });
  });

  group('collectHostModuleSources', () {
    testWithoutContext('collects only .swift files, sorted', () {
      final fileSystem = MemoryFileSystem.test();
      for (final name in <String>[
        'FlutterRunner.swift',
        'FlutterHostView.swift',
        'flutter_watchos_host.h',
        'module.modulemap',
      ]) {
        fileSystem.file('/cli/host/$name')
          ..createSync(recursive: true)
          ..writeAsStringSync('// $name');
      }
      expect(
        collectHostModuleSources(fileSystem.directory('/cli/host')),
        <String>['/cli/host/FlutterHostView.swift', '/cli/host/FlutterRunner.swift'],
      );
    });
  });

  group('hostModuleSwiftcArgs', () {
    testWithoutContext('targets the device triple and emits module + object', () {
      final List<String> args = hostModuleSwiftcArgs(
        sdkName: 'watchos',
        simulator: false,
        arch: 'arm64',
        deploymentTarget: '26.0',
        moduleOutputPath: '/f/FlutterWatchOS.swiftmodule/arm64-apple-watchos.swiftmodule',
        objectOutputPath: '/f/.host_build/FlutterWatchOS_arm64.o',
        cModuleSearchPath: '/f',
        sources: <String>['/cli/host/FlutterRunner.swift'],
        enableVmBridge: true,
      );
      expect(args, containsAllInOrder(<String>['xcrun', '-sdk', 'watchos', 'swiftc']));
      expect(args, contains('-target'));
      expect(args, contains('arm64-apple-watchos26.0'));
      expect(args, containsAllInOrder(<String>['-module-name', 'FlutterWatchOS']));
      expect(args, contains('-emit-module-path'));
      expect(args, contains('-emit-object'));
      // The C module (module.modulemap next to the staged header) must be
      // resolvable while compiling the glue.
      expect(args, containsAllInOrder(<String>['-I', '/f']));
      expect(args.last, '/cli/host/FlutterRunner.swift');
    });

    // A release app must not carry the VM Service bridge's networking code at
    // all. The define is the only thing standing between a shipping binary and
    // ~600 lines of URLSession/socket/compression code, so pin it both ways.
    testWithoutContext('defines the VM bridge condition for debug and profile', () {
      final List<String> args = hostModuleSwiftcArgs(
        sdkName: 'watchos',
        simulator: false,
        arch: 'arm64',
        deploymentTarget: '26.0',
        moduleOutputPath: '/f/m.swiftmodule',
        objectOutputPath: '/f/o.o',
        cModuleSearchPath: '/f',
        sources: <String>['/s.swift'],
        enableVmBridge: true,
      );
      expect(args, containsAllInOrder(<String>['-D', kVmBridgeSwiftDefine]));
    });

    testWithoutContext('omits the VM bridge condition for release', () {
      final List<String> args = hostModuleSwiftcArgs(
        sdkName: 'watchos',
        simulator: false,
        arch: 'arm64',
        deploymentTarget: '26.0',
        moduleOutputPath: '/f/m.swiftmodule',
        objectOutputPath: '/f/o.o',
        cModuleSearchPath: '/f',
        sources: <String>['/s.swift'],
        enableVmBridge: false,
      );
      // Only the bridge define is the contract here. Asserting release emits
      // no `-D` at all would fail the day an unrelated one is added, which
      // says nothing about whether a shipping app carries the bridge.
      expect(args, isNot(contains(kVmBridgeSwiftDefine)));
    });

    testWithoutContext('simulator triple carries the -simulator suffix', () {
      final List<String> args = hostModuleSwiftcArgs(
        sdkName: 'watchsimulator',
        simulator: true,
        arch: 'arm64',
        deploymentTarget: '26.0',
        moduleOutputPath: '/f/m.swiftmodule',
        objectOutputPath: '/f/o.o',
        cModuleSearchPath: '/f',
        sources: <String>['/s.swift'],
        enableVmBridge: true,
      );
      expect(args, contains('arm64-apple-watchos26.0-simulator'));
    });
  });

  group('swiftmoduleFileName', () {
    testWithoutContext('names the triple without an OS version', () {
      expect(
        swiftmoduleFileName(arch: 'arm64', simulator: true),
        'arm64-apple-watchos-simulator.swiftmodule',
      );
      expect(
        swiftmoduleFileName(arch: 'arm64_32', simulator: false),
        'arm64_32-apple-watchos.swiftmodule',
      );
    });
  });

  group('host module sources', () {
    final String runner = readHostSource('FlutterRunner.swift');
    final String hostView = readHostSource('FlutterHostView.swift');

    test('are compiled out entirely for the arm64_32 stub slice', () {
      // Device builds compile the module for arm64 AND arm64_32 (the App
      // Store's fat-executable requirement); the glue references engine
      // symbols that don't exist in the arm64_32 engine stub, so every
      // source must be guarded whole-file.
      for (final source in <String>[runner, hostView]) {
        expect(source.trimLeft(), isNot(startsWith('import')));
        expect(source, contains('#if !arch(arm64_32)'));
        expect(source, contains('#endif  // !arch(arm64_32)'));
      }
    });

    test('reach the engine ABI through the FlutterWatchOSHostC clang module', () {
      // The glue is a standalone module: no bridging header exists anymore,
      // so the C declarations must arrive via the staged module map.
      expect(runner, contains('import FlutterWatchOSHostC'));
    });

    test('export exactly the app-facing surface', () {
      // App.swift codes against FlutterHostView and the platform-view
      // registry; everything else stays internal to the module.
      expect(hostView, contains('public struct FlutterHostView<Splash: View>: View'));
      expect(hostView, contains('public init(@ViewBuilder splashScreen: () -> Splash)'));
      expect(runner, contains('public enum WatchPlatformViewRegistry'));
      expect(runner, contains('public static func register('));
      // The mirrors and the runner are implementation detail.
      expect(runner, isNot(contains('public final class')));
    });

    test('FlutterHostView() still resolves, with the default placeholder', () {
      // Every app ever created writes `FlutterHostView()`; the generic
      // parameter must not break them, so the no-argument init survives as a
      // constrained extension that fills in the default black placeholder.
      expect(hostView, contains('extension FlutterHostView where Splash == Color'));
      expect(hostView, contains('public init()'));
      expect(hostView, contains('self.init { Color.black }'));
    });
  });

  group('launch placeholder', () {
    final String runner = readHostSource('FlutterRunner.swift');
    final String hostView = readHostSource('FlutterHostView.swift');

    test('comes down when the frame reaches SwiftUI, not when it rasterises', () {
      // `publish` is the moment the pixels are on screen, so the cross-fade
      // has something to reveal. Verified against the Metal (Impeller) engine
      // on a watch simulator: six 30 fps samples of ramp.
      expect(runner, contains('displayingFlutterUI = true'));
      expect(hostView, contains('onChange(of: runner.displayingFlutterUI'));
      final int publishAt = runner.indexOf('private func publish(');
      expect(publishAt, greaterThan(-1));
      expect(runner.indexOf('displayingFlutterUI = true'), greaterThan(publishAt));
    });

    test('does not arm the engine first-frame callback', () {
      // The ABI exists for this job and is deliberately unused. Its premise —
      // "the Metal path produces no CGImage" — does not hold on this engine
      // (Impeller reads its texture back through the same CGImage callback),
      // and being armed with FlutterEngineSetNextFrameCallback it reports
      // RASTERISATION, a display tick or more before the pixels reach SwiftUI.
      // Measured: taking the placeholder down there faded it out over black
      // and let content pop in behind it — one hard sample instead of a ramp.
      // The name still appears in prose explaining the choice; what must not
      // exist is a call site.
      expect(runner, isNot(contains('FlutterWatchOSHostSetFirstFrameCallback(')));
      expect(runner, isNot(contains('setFirstFrameCallbackFn')));
    });

    test('first-frame state is one-way and runner-owned', () {
      // Nothing outside the runner may lower it: a placeholder that can come
      // back would flash over a running app.
      expect(runner, contains('@Published private(set) var displayingFlutterUI = false'));
      expect(runner, isNot(contains('displayingFlutterUI = false\n        ')));
    });

    test("fades out over iOS's 0.2 s rather than cutting", () {
      // FlutterViewController.removeSplashScreenWithCompletion animates alpha
      // to 0 over 0.2 s; matching it keeps the two platforms feeling the same.
      expect(hostView, contains('.transition(.opacity)'));
      expect(hostView, contains('withAnimation(.easeOut(duration: 0.2))'));
    });

    test('opens the fade explicitly, not with an implicit .animation', () {
      // The flag flips inside the display-tick update that also publishes the
      // first frame. `.animation(_:value:)` does not animate across that
      // transaction: measured on a real app it cut straight from black to the
      // first frame in a single 30 fps sample, where `withAnimation` gives the
      // intended six-frame ramp.
      expect(hostView, isNot(contains('.animation(.easeOut')));
      expect(hostView, contains('withAnimation(.easeOut'));
    });

    test('never swallows touches and is full-bleed', () {
      // A splash covering the screen must not eat the first tap on the live
      // app during the fade, and one inset by the clock would not line up with
      // the full-bleed frame it hands over to. Both modifiers belong to the
      // placeholder's own overlay, so scope the search to it.
      final int gate = hostView.indexOf('if splashVisible {');
      expect(gate, greaterThan(-1));
      final String block =
          hostView.substring(gate, hostView.indexOf('// System time visibility'));
      expect(block, isNotEmpty);
      expect(block, contains('.allowsHitTesting(false)'));
      expect(block, contains('.ignoresSafeArea()'));
    });
  });

  group('slim app template', () {
    final String app = readRunnerTemplate('App.swift.tmpl');

    test('imports the host module and shows FlutterHostView', () {
      expect(app, contains('import FlutterWatchOS'));
      expect(app, contains('FlutterHostView()'));
    });

    test('keeps the arm64_32 fallback screen', () {
      expect(app, contains('#if arch(arm64_32)'));
      expect(app, contains('UnsupportedDeviceView()'));
      expect(app, contains('Requires Apple Watch Series 9 or later.'));
    });

    test('holds no runner glue (that lives in the host module)', () {
      expect(app, isNot(contains('FlutterWatchOSHostRun')));
      expect(app, isNot(contains('digitalCrownRotation')));
      expect(app, isNot(contains('simultaneousGesture')));
      expect(app, isNot(contains('WatchTextInput')));
    });

    test('project has no bridging header and no glue sources', () {
      final String pbxproj =
          readRunnerTemplate('../Runner.xcodeproj/project.pbxproj.tmpl');
      expect(pbxproj, isNot(contains('SWIFT_OBJC_BRIDGING_HEADER')));
      expect(pbxproj, isNot(contains('FlutterRunner.swift')));
      expect(pbxproj, isNot(contains('Bridge.h')));
    });
  });
}
