// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Contract tests for the watchOS Runner template's text-input wiring and the
// Digital Crown FFI linking. Text input is ENGINE-side: the engine owns the
// flutter/textinput protocol, semantics ingestion, and per-field state, and
// publishes proxy-field rects over a C ABI; the host template is a dumb
// overlay that renders an invisible native input per published rect. The
// runtime behaviour is exercised manually on the Simulator (and the engine
// logic by the engine repo's gtest suite); these guard the template
// invariants that behaviour depends on, so a refactor that silently drops the
// wiring fails fast in CI rather than at the next manual run.

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

  group('watchOS text input — engine C ABI (Bridge.h)', () {
    test('declares the proxy-field struct and the full text-input ABI', () {
      expect(bridge, contains('FlutterWatchOSProxyField'));
      for (final String symbol in <String>[
        'FlutterWatchOSTextInputSetPixelRatio',
        'FlutterWatchOSTextInputCopyFields',
        'FlutterWatchOSTextInputGeneration',
        'FlutterWatchOSTextInputSetChangeCallback',
        'FlutterWatchOSTextInputGetText',
        'FlutterWatchOSTextInputBeginEditing',
        'FlutterWatchOSTextInputSetText',
        'FlutterWatchOSTextInputEndEditing',
      ]) {
        expect(bridge, contains(symbol));
      }
    });
  });

  group('watchOS text input — FlutterRunner engine wiring', () {
    test('enables the semantics tree (field rects come from semantics)', () {
      expect(runner, contains('FlutterEngineUpdateSemanticsEnabled(engine, true)'));
    });

    test('starts the WatchTextInput mirror with the display pixel ratio', () {
      expect(runner, contains('WatchTextInput.shared.start(pixelRatio:'));
      expect(runner, contains('FlutterWatchOSTextInputSetPixelRatio'));
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

    test('dismisses focus on Done and on taps outside every proxy', () {
      expect(app, contains('.onSubmit { focusedField = nil }'));
      expect(app, contains('focusedField = nil'));
    });
  });

  group('watchOS system status bar (time) control', () {
    test('time is visible by default and hidden only on plugin opt-in', () {
      // The hide is driven by WatchStatusBar (package:flutter_watchos) via a
      // dlsym-resolved flag — never applied unconditionally. `_statusBarHidden`
      // is SwiftUI SPI, so the default path must not touch it.
      expect(app, contains('.modifier(SystemTimeHidden(hidden: runner.statusBarHidden))'));
      expect(app, contains('if hidden {'));
      // The old unconditional form (modifier chained directly on the view
      // tree, not inside the opt-in branch) must not come back.
      expect(app, isNot(contains('\n        ._statusBarHidden()')));
    });

    test('runner mirrors the plugin flag via dlsym (no hard link)', () {
      expect(runner, contains('flutter_watchos_status_bar_hidden'));
      expect(runner, contains('var statusBarHidden = false'));
    });
  });

  group('watchOS platform-message hygiene', () {
    test('no channel handling in the host — everything rides FFI or the engine', () {
      // haptics moved to FFI (flutter_watchos_play_haptic); the old
      // haptics_channel branch must stay gone.
      expect(runner, isNot(contains('haptics_channel')));
      // But unanswered messages leak Dart futures: the response must be sent.
      expect(runner, contains('FlutterEngineSendPlatformMessageResponse'));
    });
  });

  group('watchOS Digital Crown FFI linking', () {
    test('resolves crown symbols at runtime via dlsym', () {
      // An app that does not depend on flutter_watchos must still link; the
      // crown C symbols are resolved with dlsym rather than a hard link
      // reference. The process-wide handle is the dlsym sentinel (bitPattern -2).
      expect(runner, contains('dlsym'));
      expect(runner, contains('flutter_watchos_crown_mode'));
      expect(runner, contains('flutter_watchos_crown_push_delta'));
      expect(runner, contains('UnsafeMutableRawPointer(bitPattern: -2)'));
    });

    test('Bridge.h declares no crown C prototypes (dlsym-resolved instead)', () {
      expect(bridge, contains('resolved at runtime via dlsym'));
      // The prototype form must be gone, or the symbol would be a hard link
      // reference again and break standalone apps.
      expect(bridge, isNot(contains('int32_t flutter_watchos_crown_mode(void)')));
    });
  });
}
