// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Tests for the FlutterWatchOS host module build step (the CLI-compiled
// runner glue) and the slimmed app template that imports it. The template's
// Runner/ holds only App.swift + assets + plists — the machinery lives in the
// CLI's host/ sources, compiled per build into watchos/Flutter/ — mirroring
// stock Flutter, whose iOS Runner is a dozen lines because the machinery
// lives in Flutter.framework.

import 'dart:io' as io;

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

  // The per-configuration target itself is tested with the other deployment
  // target rules, in watchos_deployment_target_test.dart.
  group('hostModuleArchs', () {
    testWithoutContext('the Simulator is arm64 only', () {
      for (final target in <String>['26.0', '26.5', '27.0']) {
        expect(hostModuleArchs(simulator: true, deploymentTarget: target), <String>['arm64']);
      }
    });

    // Xcode's Standard Architectures build an arm64_32 slice of App.swift
    // below 27.0, and its `import FlutterWatchOS` must resolve there too.
    testWithoutContext('a device below 27.0 adds arm64_32', () {
      for (final target in <String>['26.0', '26.5', '26.99']) {
        expect(hostModuleArchs(simulator: false, deploymentTarget: target), <String>[
          'arm64',
          'arm64_32',
        ]);
      }
    });

    testWithoutContext('a device from 27.0 is arm64 only', () {
      for (final target in <String>['27.0', '27.1', '27', '28.0']) {
        expect(hostModuleArchs(simulator: false, deploymentTarget: target), <String>['arm64']);
      }
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
        optimize: true,
        enableStatusBarSpi: false,
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
        optimize: true,
        enableStatusBarSpi: false,
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
        optimize: true,
        enableStatusBarSpi: false,
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
        optimize: true,
        enableStatusBarSpi: false,
      );
      expect(args, contains('arm64-apple-watchos26.0-simulator'));
    });
  });

  group('hostModuleSwiftcArgs optimisation', () {
    List<String> argsFor({required bool optimize}) => hostModuleSwiftcArgs(
      sdkName: 'watchos',
      simulator: false,
      arch: 'arm64',
      deploymentTarget: '26.0',
      moduleOutputPath: '/f/m.swiftmodule',
      objectOutputPath: '/f/o.o',
      cModuleSearchPath: '/f',
      sources: <String>['/s.swift'],
      enableVmBridge: false,
      optimize: optimize,
      enableStatusBarSpi: false,
    );

    // swiftc defaults to -Onone when neither flag is given. The host module
    // — the frame path, gesture handling, every overlay mirror — shipped
    // unoptimised in release apps for exactly that reason, while Xcode
    // compiled the app's own App.swift with -O.
    testWithoutContext('compiles with -O outside debug', () {
      final List<String> args = argsFor(optimize: true);
      expect(args, contains('-O'));
      expect(args, isNot(contains('-Onone')));
    });

    testWithoutContext('compiles with -Onone for debug', () {
      final List<String> args = argsFor(optimize: false);
      expect(args, contains('-Onone'));
      expect(args, isNot(contains('-O')));
    });

    testWithoutContext('always emits debug info, for the dSYM', () {
      expect(argsFor(optimize: true), contains('-g'));
      expect(argsFor(optimize: false), contains('-g'));
    });
  });

  group('hostModuleSwiftcArgs status-bar SPI', () {
    List<String> argsFor({required bool enableStatusBarSpi}) => hostModuleSwiftcArgs(
      sdkName: 'watchos',
      simulator: false,
      arch: 'arm64',
      deploymentTarget: '26.0',
      moduleOutputPath: '/f/m.swiftmodule',
      objectOutputPath: '/f/o.o',
      cModuleSearchPath: '/f',
      sources: <String>['/s.swift'],
      enableVmBridge: false,
      optimize: true,
      enableStatusBarSpi: enableStatusBarSpi,
    );

    // The SwiftUI `_statusBarHidden` SPI is only reachable through
    // package:flutter_watchos, so an app without that package must not
    // carry a reference to it at all — a private-API scan does not care
    // whether the code path is taken.
    testWithoutContext('is compiled in only for apps that depend on flutter_watchos', () {
      expect(argsFor(enableStatusBarSpi: true),
          containsAllInOrder(<String>['-D', kStatusBarSpiSwiftDefine]));
      expect(argsFor(enableStatusBarSpi: false), isNot(contains(kStatusBarSpiSwiftDefine)));
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

  group('host sources and the arm64_32 slice', () {
    // Below watchOS 27.0 a device build compiles the host module for arm64
    // and for arm64_32, the slice Xcode's Standard Architectures add for the
    // App Store. The engine is arm64-only and the template's arm64_32 slice
    // links no engine at all, so a host source that reaches the engine must
    // be compiled out of that slice whole. The only other way to stay in it
    // is to be a listed exception that names nothing of the engine outside
    // its comments (spec 0002, criterion 23).
    final List<String> hostFunctions = _declaredHostFunctions(
      readHostSource('flutter_watchos_host.h'),
    );

    test('every host/*.swift is guarded whole-file or a listed exception', () {
      final names = <String>[
        for (final io.FileSystemEntity entity in io.Directory(cliRootPath('host')).listSync())
          if (entity is io.File && entity.path.endsWith('.swift')) entity.uri.pathSegments.last,
      ]..sort();
      // The five sources this test was written against; a new one is picked
      // up by the listing above and checked the same way.
      expect(
        names,
        containsAll(<String>[
          'FlutterAppDelegate.swift',
          'FlutterHostView.swift',
          'FlutterRunner.swift',
          'FlutterWatchOSVmBridge.swift',
          'WatchAccessibility.swift',
        ]),
      );
      final problems = <String>[
        for (final name in names) ?_hostSourceProblem(name, readHostSource(name), hostFunctions),
      ];
      expect(problems, isEmpty);
    });

    test('every listed exception exists and says why', () {
      for (final MapEntry<String, String> entry in _unguardedHostSources.entries) {
        expect(io.File(cliRootPath('host/${entry.key}')).existsSync(), isTrue, reason: entry.key);
        expect(entry.value, isNotEmpty, reason: entry.key);
      }
    });

    test('reads the functions the header declares, not its comments or typedefs', () {
      expect(hostFunctions, contains('FlutterWatchOSHostRun'));
      expect(hostFunctions, contains('FlutterWatchOSTextInputCopyFields'));
      expect(hostFunctions, contains('FlutterWatchOSA11yPerformCustomAction'));
      // A typedef names a type, not an entry point.
      expect(hostFunctions, isNot(contains('FlutterWatchOSFrameCallback')));
      // Resolved with dlsym, so the header names it only in a comment.
      expect(hostFunctions, isNot(contains('FlutterWatchOSHostSetLayersCallback')));
    });

    // The mutations of criterion 23, applied to the real sources: each one
    // must be reported.
    test('reports WatchAccessibility.swift without its guard', () {
      final String source = readHostSource('WatchAccessibility.swift');
      expect(source, contains('import FlutterWatchOSHostC'));
      expect(
        _hostSourceProblem('WatchAccessibility.swift', _withoutGuard(source), hostFunctions),
        isNotNull,
      );
    });

    test('reports FlutterHostView.swift without its guard', () {
      // It has no FlutterWatchOSHostC import; it reaches the engine through
      // FlutterRunner, which an import check alone would not notice.
      final String source = readHostSource('FlutterHostView.swift');
      expect(source, isNot(contains('import FlutterWatchOSHostC')));
      expect(
        _hostSourceProblem('FlutterHostView.swift', _withoutGuard(source), hostFunctions),
        isNotNull,
      );
    });

    test('reports FlutterRunner named in code in FlutterWatchOSVmBridge.swift', () {
      final String source = readHostSource('FlutterWatchOSVmBridge.swift');
      // Named in a comment only, which is allowed.
      expect(source, contains('FlutterRunner'));
      expect(_hostSourceProblem('FlutterWatchOSVmBridge.swift', source, hostFunctions), isNull);
      final String mutated = source.replaceFirst(
        '#else',
        'private let runner = FlutterRunner.shared\n\n#else',
      );
      expect(_hostSourceProblem('FlutterWatchOSVmBridge.swift', mutated, hostFunctions), isNotNull);
    });

    test('reports a new host file without the guard', () {
      expect(
        _hostSourceProblem(
          'NewHostFile.swift',
          '// A new host source.\nimport SwiftUI\n\nstruct NewHostView: View {}\n',
          hostFunctions,
        ),
        isNotNull,
      );
    });

    test('reports an engine call in an exception', () {
      const source = 'import Foundation\n\nfunc tick() { FlutterWatchOSHostNotifyVsync() }\n';
      expect(
        _hostSourceProblem('FlutterWatchOSVmBridge.swift', source, hostFunctions),
        contains('FlutterWatchOSHostNotifyVsync'),
      );
      expect(
        _hostSourceProblem(
          'FlutterWatchOSVmBridge.swift',
          'import FlutterWatchOSHostC\n',
          hostFunctions,
        ),
        contains('FlutterWatchOSHostC'),
      );
    });

    test('reports a guard that closes before the end of the file', () {
      const source = '#if !arch(arm64_32)\nimport SwiftUI\n#endif\nstruct Late {}\n';
      expect(_hostSourceProblem('Late.swift', source, hostFunctions), isNotNull);
    });

    test('reports a guard with an #else branch for the arm64_32 slice', () {
      const source = '#if !arch(arm64_32)\nimport SwiftUI\n#else\nstruct Stub {}\n#endif\n';
      expect(_hostSourceProblem('Else.swift', source, hostFunctions), isNotNull);
    });

    test('accepts a header comment above the guard and nested conditions inside', () {
      const source =
          '// Copyright header.\n'
          '/* A block comment. */\n'
          '#if !arch(arm64_32)\n'
          'import SwiftUI\n'
          '#if FLUTTER_WATCHOS_STATUS_BAR_SPI\n'
          'let url = "http://example.com" // not a comment start inside the string\n'
          '#endif\n'
          '#endif  // !arch(arm64_32)\n';
      expect(_hostSourceProblem('Nested.swift', source, hostFunctions), isNull);
    });
  });

  group('host API comments', () {
    // Spec 0007, criterion 27: the host module is the Swift API every app
    // compiles against, and its C header is the contract with the engine, so
    // both carry their documentation in the source.
    test('every public or open Swift declaration has a doc comment', () {
      final documented = <String>[];
      final undocumented = <String>[];
      for (final io.FileSystemEntity entity in io.Directory(cliRootPath('host')).listSync()) {
        if (entity is! io.File || !entity.path.endsWith('.swift')) {
          continue;
        }
        final String name = entity.uri.pathSegments.last;
        final List<String> lines = readHostSource(name).split('\n');
        final List<String> code = _withoutComments(readHostSource(name)).split('\n');
        for (var i = 0; i < code.length; i++) {
          if (!_publicSwiftDeclaration.hasMatch(code[i])) {
            continue;
          }
          // The doc comment sits above the declaration or above its
          // attributes (`@objc`, `@discardableResult`, …).
          int above = i - 1;
          while (above >= 0 && _swiftAttributeLine.hasMatch(lines[above])) {
            above--;
          }
          final where = '$name:${i + 1}: ${lines[i].trim()}';
          if (above >= 0 && lines[above].trimLeft().startsWith('///')) {
            documented.add(where);
          } else {
            undocumented.add(where);
          }
        }
      }
      // 24 when the spec was written; more is fine, fewer means the scan
      // stopped finding them.
      expect(documented.length, greaterThanOrEqualTo(24));
      expect(undocumented, isEmpty);
    });

    test('the header says the thread and pointer ownership of 18 prototypes', () {
      const names = <String>[
        'FlutterWatchOSTextInputCopyFields',
        'FlutterWatchOSTextInputGeneration',
        'FlutterWatchOSTextInputSetChangeCallback',
        'FlutterWatchOSTextInputGetText',
        'FlutterWatchOSTextInputBeginEditing',
        'FlutterWatchOSTextInputSetText',
        'FlutterWatchOSTextInputSubmitEditing',
        'FlutterWatchOSTextInputEndEditing',
        'FlutterWatchOSPlatformViewsCopy',
        'FlutterWatchOSPlatformViewsGeneration',
        'FlutterWatchOSPlatformViewsSetChangeCallback',
        'FlutterWatchOSA11yCopyElements',
        'FlutterWatchOSA11yGeneration',
        'FlutterWatchOSA11ySetChangeCallback',
        'FlutterWatchOSA11yFocusGained',
        'FlutterWatchOSA11yFocusLost',
        'FlutterWatchOSA11yPerformAction',
        'FlutterWatchOSA11yPerformCustomAction',
      ];
      final String header = readHostSource('flutter_watchos_host.h');
      final List<String> lines = header.split('\n');
      final List<String> code = _withoutComments(header).split('\n');
      final List<String> declared = _declaredHostFunctions(header);
      for (final name in names) {
        expect(declared, contains(name));
        final int at = code.indexWhere(
          (String line) => RegExp('\\b${RegExp.escape(name)}\\s*\\(').hasMatch(line),
        );
        expect(at, greaterThan(0), reason: name);
        expect(lines[at - 1].trimLeft(), startsWith('//'), reason: 'no comment above $name');
        // The comment says which thread may call it or where its callback
        // runs.
        final int start = lines.lastIndexWhere(
          (String line) => !line.trimLeft().startsWith('//'),
          at - 1,
        );
        final String comment = lines.sublist(start + 1, at).join(' ');
        expect(comment, contains('thread'), reason: name);
      }
    });
  });

  group('host module sources', () {
    final String runner = readHostSource('FlutterRunner.swift');
    final String hostView = readHostSource('FlutterHostView.swift');

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
      // `didPublish` runs once the pixels have reached SwiftUI (or, on the
      // experimental texture path, the presenter), so the cross-fade has
      // something to reveal. Verified against the Metal (Impeller) engine on
      // a watch simulator: six 30 fps samples of ramp.
      expect(runner, contains('displayingFlutterUI = true'));
      expect(hostView, contains('onChange(of: runner.displayingFlutterUI'));
      final int publishAt = runner.indexOf('private func didPublish(');
      expect(publishAt, greaterThan(-1));
      expect(runner.indexOf('displayingFlutterUI = true'), greaterThan(publishAt));
      // Both delivery forms end there: the flag is set from the display tick
      // in either case, never from the engine's threads.
      final int presentAt = runner.indexOf('func presentLatestFrame()');
      expect(presentAt, greaterThan(-1));
      final String present = runner.substring(presentAt, publishAt);
      expect(present, contains('store.layers = image'));
      expect(present, contains('FlutterTexturePresenter.shared.present(texture)'));
      expect(present, contains('FlutterTexturePresenter.shared.present(texture: texture'));
      expect('didPublish()'.allMatches(present).length, 3);
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

/// The host sources that may be compiled into the arm64_32 slice, each with
/// the reason. Outside comments such a file must not use
/// `FlutterWatchOSHostC`, `FlutterRunner`, `FlutterHostView` or any function
/// that `host/flutter_watchos_host.h` declares.
const _unguardedHostSources = <String, String>{
  'FlutterWatchOSVmBridge.swift':
      'It is guarded by FLUTTER_WATCHOS_VM_BRIDGE instead, and a release build '
      'compiles its stub. It imports only Compression and Foundation, so it '
      'compiles for any architecture.',
};

/// What is wrong with the host source [fileName], or null when it follows
/// the rule: wrapped whole in `#if !arch(arm64_32)` … `#endif`, or listed in
/// [_unguardedHostSources] and naming nothing of the engine outside comments.
/// [hostFunctions] are the functions the host C header declares.
String? _hostSourceProblem(String fileName, String source, List<String> hostFunctions) {
  if (!_unguardedHostSources.containsKey(fileName)) {
    return _isGuardedWholeFile(source)
        ? null
        : '$fileName is not wrapped whole in #if !arch(arm64_32) ... #endif. Guard it, '
              'or list it in _unguardedHostSources with the reason.';
  }
  final String code = _withoutComments(source);
  final found = <String>[
    for (final name in <String>[
      'FlutterWatchOSHostC',
      'FlutterRunner',
      'FlutterHostView',
      ...hostFunctions,
    ])
      if (RegExp('\\b${RegExp.escape(name)}\\b').hasMatch(code)) name,
  ];
  return found.isEmpty
      ? null
      : '$fileName is compiled for arm64_32 but names ${found.join(', ')} outside comments.';
}

/// Whether [source], comments aside, starts with `#if !arch(arm64_32)`, ends
/// with the `#endif` that closes it, and gives that `#if` no `#else` or
/// `#elseif` branch.
bool _isGuardedWholeFile(String source) {
  final lines = <String>[
    for (final String line in _withoutComments(source).split('\n'))
      if (line.trim().isNotEmpty) line.trim(),
  ];
  if (lines.length < 2 || lines.first != '#if !arch(arm64_32)' || lines.last != '#endif') {
    return false;
  }
  var depth = 0;
  for (var i = 0; i < lines.length; i++) {
    final String line = lines[i];
    if (line.startsWith('#if')) {
      depth++;
    } else if (line.startsWith('#endif')) {
      depth--;
      if (depth == 0 && i != lines.length - 1) {
        return false;
      }
    } else if (depth == 1 && (line.startsWith('#else') || line.startsWith('#elseif'))) {
      return false;
    }
  }
  return depth == 0;
}

/// [source] with the whole-file guard lines removed, as if it had never had
/// them.
String _withoutGuard(String source) =>
    source.replaceFirst('#if !arch(arm64_32)\n', '').replaceFirst('#endif  // !arch(arm64_32)', '');

/// The names of the functions that the C header [header] declares, read from
/// its code (not its comments), leaving out typedefs.
List<String> _declaredHostFunctions(String header) {
  final String code = <String>[
    for (final String line in _withoutComments(header).split('\n'))
      if (!line.trimLeft().startsWith('#')) line,
  ].join('\n');
  return <String>[
    for (final RegExpMatch match in RegExp(
      r'(?:^|[;}])\s*(?!typedef\b)[A-Za-z_][\w\s*]*?\b([A-Za-z_]\w*)\s*\(',
    ).allMatches(code))
      match.group(1)!,
  ];
}

/// [source] with its `//` and `/* */` comments removed and its line breaks
/// kept. Block comments may nest, as in Swift, and a string literal is copied
/// as it is, so a `//` inside one does not start a comment.
String _withoutComments(String source) {
  final out = StringBuffer();
  var i = 0;
  while (i < source.length) {
    if (source.startsWith('//', i)) {
      final int end = source.indexOf('\n', i);
      i = end == -1 ? source.length : end;
    } else if (source.startsWith('/*', i)) {
      var depth = 0;
      while (i < source.length) {
        if (source.startsWith('/*', i)) {
          depth++;
          i += 2;
        } else if (source.startsWith('*/', i)) {
          depth--;
          i += 2;
          if (depth == 0) {
            break;
          }
        } else {
          if (source[i] == '\n') {
            out.write('\n');
          }
          i++;
        }
      }
    } else if (source[i] == '"') {
      final bool multiline = source.startsWith('"""', i);
      final quote = multiline ? '"""' : '"';
      int end = i + quote.length;
      while (end < source.length && !source.startsWith(quote, end)) {
        if (!multiline && source[end] == '\n') {
          break;
        }
        end += source[end] == r'\' ? 2 : 1;
      }
      end = end < source.length && source.startsWith(quote, end) ? end + quote.length : end;
      end = end > source.length ? source.length : end;
      out.write(source.substring(i, end));
      i = end;
    } else {
      out.write(source[i]);
      i++;
    }
  }
  return out.toString();
}

/// A line of Swift code that declares something `public` or `open`, after
/// any attributes and modifiers.
final _publicSwiftDeclaration = RegExp(
  r'^\s*(?:@\w+(?:\([^)]*\))?\s+)*'
  r'(?:(?:override|final|required|convenience|static|class|nonisolated|mutating)\s+)*'
  r'(?:public|open)\s',
);

/// A line that holds only a Swift attribute, such as `@objc` or
/// `@available(watchOS 26, *)`.
final _swiftAttributeLine = RegExp(r'^\s*@\w+(?:\(.*\))?\s*$');
