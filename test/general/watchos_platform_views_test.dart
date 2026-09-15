// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Contract tests for the FlutterWatchOS host module's platform-view wiring.
// The runtime is ENGINE-side: identity (create/dispose + viewType/params)
// arrives over FFI from package:flutter_watchos, all geometry is computed in
// the engine, and the registry is published behind the exported C ABI. The
// host module is a pure mirror: it copies the slot list on the engine's
// change callback and overlays the SwiftUI view the app registered for each
// slot's viewType. These tests guard those host invariants — a refactor that
// drops the wiring or re-grows host-side geometry logic fails fast in CI.

import '../src/common.dart';
import '../src/host_sources.dart';

void main() {
  final String runner = readHostSource('FlutterRunner.swift');
  final String app = readHostSource('FlutterHostView.swift');
  final String bridge = readHostSource('flutter_watchos_host.h');

  group('watchOS platform views — engine C ABI (flutter_watchos_host.h)', () {
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

    test('hosts no geometry logic (that lives in the engine)', () {
      // Scroll tracking, culling, and hot-restart cleanup are engine-side;
      // the host must not re-grow rect math or visibility heuristics.
      expect(runner, isNot(contains('platformViewId')));
      expect(runner, isNot(contains('update_semantics_callback')));
    });
  });

  group('watchOS platform views — FlutterHostView overlay', () {
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
          contains('platformViewGroup(platformViews.underlaySlots)'));
      expect(
          app,
          contains(
              'platformViewGroup(platformViews.overlaySlots)'));
      final int background = app.indexOf('.background {');
      final int overlay = app.indexOf(
          'platformViewGroup(platformViews.overlaySlots)');
      expect(background, greaterThan(-1));
      expect(overlay, greaterThan(background));
    });

    test('underlay views never receive native touches', () {
      // Touch routing must stay deterministic: the frame image above an
      // underlay view owns all touches (interaction is handled in Dart).
      final int underlay = app
          .indexOf('platformViewGroup(platformViews.underlaySlots)');
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
          'platformViewGroup(platformViews.overlaySlots)');
      final int textInputOverlay = app.indexOf('ForEach(textInput.fields');
      expect(platformViewOverlay, greaterThan(-1));
      expect(textInputOverlay, greaterThan(platformViewOverlay));
    });

    test('documents factory registration in the app template initializer', () {
      // The app-facing registration example lives in the (now tiny) template
      // App.swift, where apps actually register their factories.
      expect(readRunnerTemplate('App.swift.tmpl'),
          contains('WatchPlatformViewRegistry.register('));
    });
  });

  group('watchOS platform views — composited frames', () {
    // With an engine that composites platform views from the layer tree
    // (FlutterCompositor), each frame arrives as an ordered layer list and
    // the host places the native views inside it, in paint order. The
    // legacy overlay/underlay path stays for engines that predate it.
    test('declares the layer struct and callback in the host header', () {
      expect(bridge, contains('} FlutterWatchOSLayer;'));
      expect(bridge, contains('kFlutterWatchOSLayerFlutter'));
      expect(bridge, contains('kFlutterWatchOSLayerPlatformView'));
      for (final field in <String>[
        'CGImageRef image;',
        'const double* region;',
        'int64_t view_id;',
        'double opacity;',
        'bool has_clip;',
        'double clip_radius;',
      ]) {
        expect(bridge, contains(field));
      }
      expect(bridge, contains('typedef void (*FlutterWatchOSLayersCallback)('));
    });

    test('resolves the layers ABI with dlsym so older engines still link', () {
      expect(runner, contains('"FlutterWatchOSHostSetLayersCallback"'));
      expect(runner, contains('"FlutterWatchOSHostHitTest"'));
      expect(runner, contains('static let compositesLayers: Bool'));
      // Never a direct reference: that would fail to link on an old engine.
      expect(runner, isNot(contains('FlutterWatchOSHostSetLayersCallback(')));
      expect(runner, isNot(contains('FlutterWatchOSHostHitTest(')));
      // The header names them in a comment only; a declaration would let a
      // direct call slip in.
      expect(bridge, isNot(contains('\nint64_t FlutterWatchOSHostHitTest(')));
      expect(bridge, isNot(contains('\nvoid FlutterWatchOSHostSetLayersCallback(')));
    });

    test('registers the layers callback before Run and stashes by value', () {
      final int registerAt = runner.indexOf('Self.setLayersCallbackFn?(');
      final int runAt = runner.indexOf('let running = FlutterWatchOSHostRun(');
      expect(registerAt, greaterThan(-1));
      expect(runAt, greaterThan(registerAt));
      // The C structs live only during the callback; the host copies them.
      expect(runner, contains('func stash(layers: UnsafeBufferPointer<FlutterWatchOSLayer>)'));
      expect(runner, contains('takeUnretainedValue()'));
      expect(runner, contains(r'id: "pv\(layer.view_id)"'));
    });

    test('the frame view draws the layer stack in order', () {
      expect(app, contains('ForEach(frames.layers)'));
      expect(app, contains('ZStack(alignment: .topLeading)'));
      // Flutter content never swallows touches meant for a view beneath it.
      final int imageAt = app.indexOf('Image(decorative: image, scale: pixelRatio)');
      expect(imageAt, greaterThan(-1));
      expect(app.substring(imageAt, imageAt + 500), contains('.allowsHitTesting(false)'));
    });

    test('texture present shows platform views: the bottom layer as a texture', () {
      // Registered before Run, like the image layers callback, and only when
      // the engine has the ABI; an engine that predates it keeps the
      // single-texture path.
      final int registerAt = runner.indexOf('Self.setTextureLayersCallbackFn?(');
      final int runAt = runner.indexOf('let running = FlutterWatchOSHostRun(');
      expect(registerAt, greaterThan(-1));
      expect(runAt, greaterThan(registerAt));
      expect(runner, contains('"FlutterWatchOSHostSetTextureLayersCallback"'));
      expect(runner, contains('"FlutterWatchOSHostReleaseFrameTextures"'));
      // The lease goes back when the last reference to the frame does, so a
      // stashed frame the display tick never collected cannot starve the pool.
      expect(runner, contains('deinit { release(lease) }'));
    });

    test('only the bottom layer is a SceneView; layers above views stay images', () {
      // SceneView is opaque on watchOS, and blending extra SceneViews for the
      // layers above native views flashed white on a watch while scrolling.
      expect(app, isNot(contains('.blendMode(')));
      expect('SceneView('.allMatches(app).length, 1);
      final int textureAt = app.indexOf('if layer.isTexture {');
      final int imageAt = app.indexOf('} else if let image = layer.image {');
      expect(textureAt, greaterThan(-1));
      expect(imageAt, greaterThan(textureAt));
    });

    test('places a view at the layer geometry, clipped and faded as told', () {
      expect(app, contains('.frame(width: layer.rect.width, height: layer.rect.height)'));
      expect(app, contains('.clipShape(FrameLayerClip('));
      expect(app, contains('.opacity(layer.opacity)'));
      expect(app, contains('.position(x: layer.rect.midX, y: layer.rect.midY)'));
      expect(app, contains('.allowsHitTesting(!slot.belowFrame && !coveredAbove(layer))'));
    });

    test('keeps every registered view alive when the frame does not place it', () {
      expect(app, contains('ForEach(parkedSlots)'));
      final int parkedAt = app.indexOf('private func parked(');
      expect(parkedAt, greaterThan(-1));
      final String parked = app.substring(parkedAt, parkedAt + 800);
      expect(parked, contains('.opacity(0)'));
      expect(parked, contains('.allowsHitTesting(false)'));
      expect(parked, contains('frames.lastRects[slot.id]'));
    });

    test('asks the engine who owns a touch', () {
      expect(runner, contains('func platformView(owningTouchAt location: CGPoint) -> Int64?'));
      expect(app, contains('runner.platformView(owningTouchAt: point)'));
      // Content scale applies to the point going in, like touches.
      expect(runner, contains('location.x / WatchContentScale.value'));
    });

    test('keeps the legacy overlays only for engines without layers', () {
      expect(app, contains('if !FlutterRunner.compositesLayers {'));
      expect(app, contains('if FlutterRunner.compositesLayers {'));
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
