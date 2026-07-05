// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/scheduler.dart';

import 'watchos_ffi_bindings.dart';
import 'watchos_info_platform.dart' as platform;

/// A single Digital Crown rotation sample.
class CrownRotationEvent {
  /// Creates a rotation event.
  const CrownRotationEvent({required this.delta, required this.velocity});

  /// Rotation since the previous event, in abstract crown units. Positive means
  /// the crown turned forward (clockwise from the wearer's view); negative,
  /// backward. Magnitude grows with how fast the crown is turned.
  final double delta;

  /// Rotation speed in crown units per second (this event's [delta] divided by
  /// the time since the previous event). Useful for momentum/fling mechanics.
  final double velocity;

  @override
  String toString() => 'CrownRotationEvent(delta: '
      '${delta.toStringAsFixed(3)}, velocity: ${velocity.toStringAsFixed(1)})';
}

/// Direct access to the Apple Watch Digital Crown as an input device — instead
/// of as scroll.
///
/// By default the watch host forwards crown rotation to Flutter as trackpad
/// scroll, so lists scroll naturally (see `WatchCrownScroll`). Apps that need
/// the crown as a *control* — a game, a value picker, a custom gauge — use
/// [WatchCrown] to switch it into **raw/exclusive** mode: while active, the
/// crown stops driving scroll and its rotation is delivered here.
///
/// Two ways to read it:
///
/// 1. As a stream (convenient) — frame-polled, emits while the crown turns.
///    The first listener switches the crown into raw mode; cancelling the last
///    listener returns it to scroll:
///    ```dart
///    final sub = WatchCrown.instance.rotations.listen((e) {
///      setState(() => paddleX += e.delta * sensitivity);
///    });
///    // ...later
///    await sub.cancel();
///    ```
///
/// 2. By manual drain (for apps with their own game loop) — pull the rotation
///    accumulated since the last call, with zero stream overhead:
///    ```dart
///    WatchCrown.instance.enable();
///    // each tick of your loop:
///    final delta = WatchCrown.instance.drain();
///    // when finished:
///    WatchCrown.instance.disable();
///    ```
///
/// On non-watchOS platforms (and the simulator without a crown) the stream
/// simply never emits and [drain] returns 0, so it's safe in cross-platform
/// code.
class WatchCrown {
  WatchCrown._();

  /// The shared instance.
  static final WatchCrown instance = WatchCrown._();

  WatchOSNativeBindings? _bindings;

  WatchOSNativeBindings get _native => _bindings ??= platform.isWatch
      ? WatchOSNativeBindings()
      : WatchOSNativeBindings.forTesting();

  /// Test seam: inject fake bindings. Resets the enable count and any active
  /// ticker so each test starts clean.
  @visibleForTesting
  set bindingsOverride(WatchOSNativeBindings? bindings) {
    _stopTicker();
    _enableCount = 0;
    _bindings = bindings;
  }

  int _enableCount = 0;

  /// Switches the crown into raw/exclusive mode (it stops driving scroll).
  ///
  /// Reference-counted with [disable] so nested users (e.g. the [rotations]
  /// stream plus a manual reader) compose safely — the crown only returns to
  /// scroll once every [enable] has a matching [disable].
  void enable() {
    if (_enableCount++ == 0) {
      _native.crownMode = 1;
    }
  }

  /// Returns the crown to scroll mode once every [enable] is balanced.
  void disable() {
    if (_enableCount == 0) return;
    if (--_enableCount == 0) {
      _native.crownMode = 0;
    }
  }

  /// Whether the crown is currently in raw/exclusive mode.
  bool get isEnabled => _enableCount > 0;

  /// Pulls the crown rotation accumulated since the previous call (0 when idle
  /// or unsupported). For apps driving their own frame loop; call [enable]
  /// first and [disable] when done.
  double drain() => _native.consumeCrownDelta();

  Ticker? _ticker;
  StreamController<CrownRotationEvent>? _controller;
  Duration _lastTick = Duration.zero;

  /// Test seam: when false, [rotations] doesn't start a real [Ticker], so tests
  /// can drive polling deterministically via [debugPoll].
  @visibleForTesting
  bool debugAutoTick = true;

  /// A frame-polled stream of crown rotation. Activating the first subscription
  /// switches the crown into raw mode; cancelling the last one returns it to
  /// scroll. Broadcast, so multiple listeners share one poll.
  Stream<CrownRotationEvent> get rotations {
    _controller ??= StreamController<CrownRotationEvent>.broadcast(
      onListen: _startTicker,
      onCancel: _stopTicker,
    );
    return _controller!.stream;
  }

  void _startTicker() {
    enable();
    _lastTick = Duration.zero;
    if (debugAutoTick) {
      _ticker = Ticker(debugPoll)..start();
    }
  }

  void _stopTicker() {
    _ticker?.dispose();
    _ticker = null;
    disable();
  }

  /// Runs one poll: drains the crown and emits an event if it rotated. Called
  /// once per frame by the [Ticker]; exposed for deterministic testing.
  @visibleForTesting
  void debugPoll(Duration elapsed) {
    final double delta = drain();
    final double dt = (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    if (delta == 0.0) return;
    final double velocity = dt > 0 ? delta / dt : 0.0;
    _controller?.add(CrownRotationEvent(delta: delta, velocity: velocity));
  }
}
