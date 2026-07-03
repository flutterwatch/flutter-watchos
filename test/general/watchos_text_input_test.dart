// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Contract tests for the watchOS Runner template. The runtime is ENGINE-side:
// the engine owns bootstrap (renderer, Dart snapshots, window metrics,
// semantics), the frame->CGImage pipeline, touch phase tracking, the full
// Digital Crown scroll model (including the plugin raw-crown handoff), and the
// flutter/textinput protocol with per-field state — all behind an exported C
// ABI. The host template is generic glue: it displays frames, forwards
// gesture points and raw crown deltas, plays the detent haptic on request,
// and renders an invisible native input per engine-published rect. The
// runtime behaviour is exercised manually on the Simulator (and the engine
// logic by the engine repo's gtest suites); these guard the template
// invariants that behaviour depends on, so a refactor that silently drops the
// wiring — or re-grows host-side logic — fails fast in CI rather than at the
// next manual run.

import 'dart:io' as io;

import '../src/common.dart';

/// Reads a file from the watchOS Runner template, locating the template by
/// walking up from the current directory (tests may run from the package root
/// or a workspace root).
String _readRunnerTemplate(String fileName) {
  io.Directory dir = io.Directory.current.absolute;
  while (true) {
    final candidate = io.File(
      '${dir.path}/templates/app/swift/watchos.tmpl/Runner/$fileName',
    );
    if (candidate.existsSync()) {
      return candidate.readAsStringSync();
    }
    final io.Directory parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('Could not find watchOS Runner template: $fileName');
    }
    dir = parent;
  }
}

void main() {
  final String runner = _readRunnerTemplate('FlutterRunner.swift.tmpl');
  final String app = _readRunnerTemplate('App.swift.tmpl');
  final String bridge = _readRunnerTemplate('Bridge.h.tmpl');

  group('watchOS engine C ABI (Bridge.h)', () {
    test('declares the host-runtime ABI', () {
      for (final symbol in <String>[
        'FlutterWatchOSFrameCallback',
        'FlutterWatchOSHostRun',
        'FlutterWatchOSHostTouch',
        'FlutterWatchOSCrownTickCallback',
        'FlutterWatchOSCrownSetTickCallback',
        'FlutterWatchOSCrownDelta',
      ]) {
        expect(bridge, contains(symbol));
      }
    });

    test('declares the proxy-field struct and the full text-input ABI', () {
      expect(bridge, contains('FlutterWatchOSProxyField'));
      for (final symbol in <String>[
        'FlutterWatchOSTextInputCopyFields',
        'FlutterWatchOSTextInputGeneration',
        'FlutterWatchOSTextInputSetChangeCallback',
        'FlutterWatchOSTextInputGetText',
        'FlutterWatchOSTextInputBeginEditing',
        'FlutterWatchOSTextInputSetText',
        'FlutterWatchOSTextInputSubmitEditing',
        'FlutterWatchOSTextInputEndEditing',
      ]) {
        expect(bridge, contains(symbol));
      }
    });

    test('keeps engine-internal calls out of the public surface', () {
      // The pixel ratio rides FlutterWatchOSHostRun; the engine wires its own
      // text-input geometry from it. No host code should call this again.
      expect(bridge, isNot(contains('FlutterWatchOSTextInputSetPixelRatio')));
      expect(runner, isNot(contains('FlutterWatchOSTextInputSetPixelRatio')));
    });
  });

  group('watchOS FlutterRunner — engine-side bootstrap', () {
    test('boots through the engine host runtime, passing the display metrics',
        () {
      expect(runner, contains('FlutterWatchOSHostRun'));
      expect(runner, contains('Bundle.main.bundlePath'));
      expect(runner, contains('pixelRatio'));
    });

    test('publishes the engine-delivered frame on the main thread', () {
      expect(runner, contains('DispatchQueue.main.async { runner.publish(image) }'));
    });

    test('hosts no bootstrap logic (that moved into the engine)', () {
      // Renderer config, Dart snapshot resolution, window metrics, semantics,
      // pixel-format knowledge, and platform-message responses are all
      // engine-side now; none may re-grow in the template.
      expect(runner, isNot(contains('FlutterEngineRun(')));
      expect(runner, isNot(contains('FlutterProjectArgs')));
      expect(runner, isNot(contains('FlutterRendererConfig')));
      expect(runner, isNot(contains('kDartVmSnapshotData')));
      expect(runner, isNot(contains('vm_isolate_snapshot.bin')));
      expect(runner, isNot(contains('FlutterEngineSendWindowMetricsEvent')));
      expect(runner, isNot(contains('FlutterEngineUpdateSemanticsEnabled')));
      expect(runner, isNot(contains('CGImageCreate')));
      expect(runner, isNot(contains('FlutterEngineSendPlatformMessage')));
      expect(runner, isNot(contains('platform_message_callback')));
    });

    test('forwards touches in points through the host ABI', () {
      expect(runner, contains('FlutterWatchOSHostTouch'));
      expect(runner, isNot(contains('FlutterEngineSendPointerEvent')));
    });
  });

  group('watchOS Digital Crown — engine-side scroll model', () {
    test('forwards raw deltas to the engine', () {
      expect(runner, contains('FlutterWatchOSCrownDelta'));
      expect(app, contains('runner.sendCrownDelta'));
    });

    test('plays the detent haptic only when the engine asks', () {
      expect(runner, contains('FlutterWatchOSCrownSetTickCallback'));
      expect(runner, contains('play(.click)'));
    });

    test('hosts no scroll model (calibration lives in the engine)', () {
      // The tanh saturation, tunables, pan/zoom synthesis, idle timer, and
      // the plugin raw-mode dlsym all moved into the engine dylib so
      // re-calibration reaches existing apps via engine updates.
      expect(runner, isNot(contains('tanh')));
      expect(runner, isNot(contains('crownPointsPerUnit')));
      expect(runner, isNot(contains('kPanZoom')));
      expect(runner, isNot(contains('flutter_watchos_crown_mode')));
      expect(runner, isNot(contains('flutter_watchos_crown_push_delta')));
    });

    test('Bridge.h declares no crown C prototypes (engine resolves the plugin)',
        () {
      expect(bridge,
          isNot(contains('int32_t flutter_watchos_crown_mode(void)')));
    });
  });

  group('watchOS text input — FlutterRunner engine wiring', () {
    test('starts the WatchTextInput mirror after the engine is running', () {
      expect(runner, contains('WatchTextInput.shared.start()'));
    });

    test('mirrors the engine-published field list, holding no logic itself', () {
      // The adapter re-copies on the engine's change callback; generation
      // gates redundant copies. All protocol/state logic lives in the engine.
      expect(runner, contains('FlutterWatchOSTextInputSetChangeCallback'));
      expect(runner, contains('FlutterWatchOSTextInputCopyFields'));
      expect(runner, contains('FlutterWatchOSTextInputGeneration'));
      expect(runner, contains('class WatchTextInput'));
    });

    test('forwards focus and edits to the engine, never interpreting them', () {
      expect(runner, contains('FlutterWatchOSTextInputBeginEditing'));
      expect(runner, contains('FlutterWatchOSTextInputSetText'));
      expect(runner, contains('FlutterWatchOSTextInputEndEditing'));
    });

    test('hosts no text-input protocol logic (that moved into the engine)', () {
      // The host must not re-grow the old host-side implementation: no
      // textinput channel handling, no semantics parsing, no per-node state.
      expect(runner, isNot(contains('"flutter/textinput"')));
      expect(runner, isNot(contains('update_semantics_callback')));
      expect(runner, isNot(contains('is_text_field')));
      expect(runner, isNot(contains('TextInputClient')));
      // And the obsolete one-shot Quickboard path stays gone.
      expect(runner, isNot(contains('presentTextInputController')));
    });
  });

  group('watchOS text input — App.swift proxy overlay', () {
    test('renders a proxy per engine-published field', () {
      expect(app, contains('ForEach(textInput.fields'));
      expect(app, contains(r'.focused($focusedField, equals: field.id)'));
    });

    test('uses a SecureField for obscured fields and a TextField for plain', () {
      expect(app, contains('SecureField'));
      expect(app, contains('TextField'));
      expect(app, contains('field.isObscured'));
    });

    test('keeps the proxy invisible without suppressing the keyboard', () {
      // `.opacity(0)` / `.hidden()` make watchOS refuse to raise the keyboard;
      // near-zero opacity plus clear text/cursor is the working combination,
      // and `contentShape` keeps the full rect tappable.
      expect(app, contains('.opacity(0.02)'));
      expect(app, contains('.foregroundStyle(.clear)'));
      expect(app, contains('.tint(.clear)'));
      expect(app, contains('.contentShape(Rectangle())'));
      expect(app, isNot(contains('.opacity(0)\n')));
    });

    test('positions each proxy over its engine-computed rect', () {
      expect(app, contains('.position(x: field.rect.midX, y: field.rect.midY)'));
    });

    test('notifies the engine as proxy focus changes', () {
      expect(app, contains('textInput.beginEditing'));
      expect(app, contains('textInput.endEditing()'));
    });

    test('Done submits through the engine, not through FocusState', () {
      // @FocusState never fires on watchOS, so `focusedField = nil` alone is
      // a no-op — the submit must go to the engine directly, which delivers
      // TextInputAction.done (onSubmitted fires; the framework unfocuses and
      // closes the connection).
      expect(app, contains('textInput.submitEditing()'));
      expect(runner, contains('FlutterWatchOSTextInputSubmitEditing'));
    });

    test('taps outside every proxy end editing', () {
      expect(app, contains('textInput.endEditing()'));
    });
  });

  group('watchOS system status bar (time) control', () {
    test('time is visible by default and hidden only on plugin opt-in', () {
      // The hide is driven by WatchStatusBar (package:flutter_watchos) via a
      // dlsym-resolved flag — never applied unconditionally. `_statusBarHidden`
      // is SwiftUI SPI, so the default path must not touch it.
      expect(app,
          contains('.modifier(SystemTimeHidden(hidden: runner.statusBarHidden))'));
      expect(app, contains('if hidden {'));
      // The old unconditional form (modifier chained directly on the view
      // tree, not inside the opt-in branch) must not come back.
      expect(app, isNot(contains('\n        ._statusBarHidden()')));
    });

    test('runner mirrors the plugin flag via dlsym (no hard link)', () {
      // This is the ONE dlsym left in the host: the status-bar flag feeds a
      // SwiftUI @Published property, so the host must read it. The crown
      // plugin symbols are resolved by the engine now.
      expect(runner, contains('flutter_watchos_status_bar_hidden'));
      expect(runner, contains('var statusBarHidden = false'));
      expect(runner, contains('UnsafeMutableRawPointer(bitPattern: -2)'));
    });
  });

  group('watchOS platform-message hygiene', () {
    test('no message handling in the host — everything rides FFI or the engine',
        () {
      // Haptics ride FFI (flutter_watchos_play_haptic); unhandled messages
      // are auto-answered INSIDE the engine so Dart futures complete. The
      // host has no platform-message path at all.
      expect(runner, isNot(contains('haptics_channel')));
      expect(runner, isNot(contains('handlePlatformMessage')));
    });
  });
}
