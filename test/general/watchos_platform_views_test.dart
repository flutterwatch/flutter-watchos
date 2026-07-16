// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Contract tests for the watchOS Runner template's platform-view wiring. The
// runtime is ENGINE-side: identity (create/dispose + viewType/params) arrives
// over FFI from package:flutter_watchos, geometry rides the engine's
// semantics walk (the same one that positions the text-input proxy fields),
// and the registry is published behind the exported C ABI. The host template
// is a pure mirror: it copies the slot list on the engine's change callback
// and overlays the SwiftUI view the app registered for each slot's viewType.
// These tests guard those template invariants — a refactor that drops the
// wiring or re-grows host-side geometry logic fails fast in CI.

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

  group('watchOS platform views — engine C ABI (Bridge.h)', () {
    test('declares the slot struct and the full mirror ABI', () {
      expect(bridge, contains('FlutterWatchOSPlatformViewSlot'));
      for (final symbol in <String>[
        'FlutterWatchOSPlatformViewsCopy',
        'FlutterWatchOSPlatformViewsGeneration',
        'FlutterWatchOSPlatformViewsSetChangeCallback',
        'FlutterWatchOSPlatformViewGetType',
        'FlutterWatchOSPlatformViewGetParams',
        'FlutterWatchOSPlatformViewGetBelowFrame',
      ]) {
        expect(bridge, contains(symbol));
      }
    });

    test('keeps the Dart-facing ABI out of the host surface', () {
      // Create/Dispose are called from package:flutter_watchos over FFI; the
      // host only mirrors. It must never mutate the registry.
      expect(bridge, isNot(contains('FlutterWatchOSPlatformViewCreate')));
      expect(bridge, isNot(contains('FlutterWatchOSPlatformViewDispose')));
      expect(runner, isNot(contains('FlutterWatchOSPlatformViewCreate')));
      expect(runner, isNot(contains('FlutterWatchOSPlatformViewDispose')));
    });
  });

  group('watchOS platform views — FlutterRunner mirror', () {
    test('starts the WatchPlatformViews mirror after the engine is running',
        () {
      expect(runner, contains('WatchPlatformViews.shared.start()'));
    });

    test('mirrors the engine-published slot list, holding no logic itself',
        () {
      expect(runner, contains('FlutterWatchOSPlatformViewsSetChangeCallback'));
      expect(runner, contains('FlutterWatchOSPlatformViewsCopy'));
      expect(runner, contains('FlutterWatchOSPlatformViewsGeneration'));
      expect(runner, contains('class WatchPlatformViews'));
    });

    test('resolves viewType, params, and layer through the engine getters',
        () {
      expect(runner, contains('FlutterWatchOSPlatformViewGetType'));
      expect(runner, contains('FlutterWatchOSPlatformViewGetParams'));
      expect(runner, contains('FlutterWatchOSPlatformViewGetBelowFrame'));
    });

    test('exposes the app-facing factory registry', () {
      expect(runner, contains('enum WatchPlatformViewRegistry'));
      expect(runner, contains('static func register('));
    });

    test('hosts no geometry logic (that lives in the engine semantics walk)',
        () {
      // Scroll tracking, culling, and hot-restart cleanup are engine-side;
      // the host must not re-grow rect math or visibility heuristics.
      expect(runner, isNot(contains('platformViewId')));
      expect(runner, isNot(contains('update_semantics_callback')));
    });
  });

  group('watchOS platform views — App.swift overlay', () {
    test('renders the registered native view per engine-published slot', () {
      expect(app, contains('platformViewGroup(_ slots: [WatchPlatformViewSlot])'));
      expect(app, contains('ForEach(slots)'));
      expect(app, contains('WatchPlatformViewRegistry.view('));
    });

    test('splits slots into the underlay and overlay layers', () {
      // Underlay slots (widget layer: .belowFlutter) render UNDER the frame
      // image so the Flutter scene's transparent hole reveals them; overlay
      // slots keep the classic above-the-frame composition.
      expect(app,
          contains(r'platformViewGroup(platformViews.slots.filter(\.belowFrame))'));
      expect(
          app,
          contains(
              r'platformViewGroup(platformViews.slots.filter { !$0.belowFrame })'));
      final int background = app.indexOf('.background {');
      final int overlay = app.indexOf(
          r'platformViewGroup(platformViews.slots.filter { !$0.belowFrame })');
      expect(background, greaterThan(-1));
      expect(overlay, greaterThan(background));
    });

    test('underlay views never receive native touches', () {
      // Touch routing must stay deterministic: the frame image above an
      // underlay view owns all touches (interaction is handled in Dart).
      final int underlay = app
          .indexOf(r'platformViewGroup(platformViews.slots.filter(\.belowFrame))');
      final int hitTestingOff = app.indexOf('.allowsHitTesting(false)');
      expect(underlay, greaterThan(-1));
      expect(hitTestingOff, greaterThan(underlay));
    });

    test('positions and clips each native view to its engine-computed rect',
        () {
      expect(app,
          contains('.frame(width: slot.rect.width, height: slot.rect.height)'));
      expect(app, contains('.position(x: slot.rect.midX, y: slot.rect.midY)'));
      expect(app, contains('.clipped()'));
    });

    test('honors the engine visibility flag (culled views stay hidden)', () {
      // Hidden via opacity + hit-testing, NOT removal — removing the view
      // from the hierarchy would destroy its native @State (a toggle would
      // reset while covered by a dialog). The registry contract is "keep the
      // native view alive but hidden".
      expect(app, contains('.opacity(slot.visible ? 1 : 0)'));
      expect(app, contains('.allowsHitTesting(slot.visible)'));
      expect(app, isNot(contains('if slot.visible,')));
    });

    test('keeps text-input proxies above platform views', () {
      // The text-entry overlay must come LATER in the modifier chain (later
      // overlays sit on top), so a text field over a platform view still
      // raises the keyboard.
      final int platformViewOverlay = app.indexOf(
          r'platformViewGroup(platformViews.slots.filter { !$0.belowFrame })');
      final int textInputOverlay = app.indexOf('ForEach(textInput.fields');
      expect(platformViewOverlay, greaterThan(-1));
      expect(textInputOverlay, greaterThan(platformViewOverlay));
    });

    test('documents factory registration in the app initializer', () {
      expect(app, contains('WatchPlatformViewRegistry.register('));
    });
  });

  group('watchOS platform views — touch routing', () {
    test('frame drag gesture is simultaneous, never exclusive', () {
      // An exclusive zero-distance drag wins the gesture arena against the
      // internal gestures of overlaid native controls on REAL hardware (a
      // SwiftUI Toggle stopped responding mid-screen on a physical watch;
      // the simulator, whose taps carry no micro-movement, hid the bug).
      expect(app, contains('.simultaneousGesture('));
      expect(app, isNot(contains('.gesture(')));
    });

    test('native-owned touches are dropped by the frame gesture', () {
      // Simultaneity means the frame gesture also sees touches that start on
      // a native overlay or a text-input proxy; forwarding them would
      // ghost-fire Flutter content behind the slot and unfocus a field the
      // tap just focused.
      expect(app, contains('nativeOwnsTouch(at: value.startLocation)'));
      expect(
          app,
          contains(
              'slot.visible && !slot.belowFrame && slot.rect.contains(point)'));
      expect(app,
          contains(r'textInput.fields.contains { $0.rect.contains(point) }'));
    });

    test('ownership is decided once per gesture, not per event', () {
      // Slot rects move while Flutter scrolls; re-evaluating ownership
      // against live rects can flip the answer mid-drag and strand Flutter
      // with a pointer that never gets its end event (scroll felt broken on
      // a physical watch).
      expect(app, contains('@State private var dragOwnedByNative: Bool?'));
      expect(app, contains('dragOwnedByNative = nil'));
    });

    test('the whole slot rect is a native hit surface', () {
      // contentShape makes transparent parts of an overlay view hit-testable
      // too — the documented contract is "touches inside the slot are
      // consumed by the native view".
      final int clipped = app.indexOf('.clipped()');
      final int shape = app.indexOf('.contentShape(Rectangle())', clipped);
      final int position = app.indexOf('.position(x: slot.rect.midX');
      expect(clipped, greaterThan(-1));
      expect(shape, greaterThan(clipped));
      expect(position, greaterThan(shape));
    });
  });
}
