// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/widgets.dart';

import 'scroll_physics.dart';
import 'watchos_ffi_bindings.dart';
import 'watchos_info_platform.dart' as platform;

/// Crown scroll sensitivity, mirroring the options native (SwiftUI)
/// developers get from `.digitalCrownRotation(sensitivity:)`.
///
/// The value scales how far one unit of crown rotation scrolls: [high] is the
/// system default; [medium] and [low] need progressively more rotation for
/// the same travel — for fine positioning in dense content.
enum WatchCrownSensitivity {
  /// Most rotation per scroll distance — precise, slow travel.
  low(0.25),

  /// Between [low] and [high].
  medium(0.5),

  /// The native default (matches a watchOS `List`).
  high(1.0);

  const WatchCrownSensitivity(this.multiplier);

  /// The delta multiplier the engine applies in scroll mode.
  final double multiplier;
}

/// Options for the Digital Crown's **scroll** mode — the same knobs native
/// watchOS developers get on `.digitalCrownRotation`.
///
/// The crown's scroll motion (acceleration, fling momentum, detent ticks) is
/// produced by the engine; these settings tell it how to behave. They take
/// effect from the next crown movement and apply app-wide:
///
/// ```dart
/// WatchCrownScrolling.sensitivity = WatchCrownSensitivity.medium;
/// WatchCrownScrolling.detentHaptics = false; // silent scrolling
/// ```
///
/// Raw crown input ([WatchCrown]) is unaffected — raw consumers always
/// receive unscaled rotation. On non-watchOS platforms this is a safe no-op.
abstract final class WatchCrownScrolling {
  static WatchOSNativeBindings? _bindings;
  static WatchCrownSensitivity _sensitivity = WatchCrownSensitivity.high;

  static WatchOSNativeBindings get _native => _bindings ??= platform.isApple
      ? WatchOSNativeBindings()
      : WatchOSNativeBindings.forTesting();

  /// Test seam: inject fake bindings and reset to defaults.
  @visibleForTesting
  static set bindingsOverride(WatchOSNativeBindings? bindings) {
    _bindings = bindings;
    _sensitivity = WatchCrownSensitivity.high;
  }

  /// How much the content scrolls per unit of crown rotation.
  static WatchCrownSensitivity get sensitivity => _sensitivity;

  static set sensitivity(WatchCrownSensitivity value) {
    _sensitivity = value;
    _native.crownScrollMultiplier = value.multiplier;
  }

  /// Whether the detent-click haptic plays as the content scrolls
  /// (the native `isHapticFeedbackEnabled`). Defaults to `true`.
  static bool get detentHaptics => _native.crownDetentHaptics;

  static set detentHaptics(bool enabled) {
    _native.crownDetentHaptics = enabled;
  }
}

/// Gives the scrollables in [child] the native watchOS feel.
///
/// The Digital Crown's scroll motion, acceleration and detent ticks are
/// produced by the engine. This widget supplies the piece that can only come
/// from the Flutter side: it installs [WatchScrollPhysics] for the subtree
/// (via [ScrollConfiguration]), so content stops at its end with the small,
/// live, firm bounce a native watchOS 26 list has, instead of the
/// iPhone-style deep elastic stretch.
///
/// Note there is deliberately NO haptic at the list edge: native watchOS 26
/// plays none — the end of content is communicated by the rubber-band alone.
/// An app that wants its own edge cue can listen for its scrollable's metrics
/// going out of range and call `WatchHaptics` itself.
///
/// Wrap a scrollable subtree (commonly a whole screen or the app body):
///
/// ```dart
/// WatchCrownScroll(
///   child: ListView(children: const [/* ... */]),
/// )
/// ```
///
/// Scrollables that pass an explicit `physics:` keep it (set
/// [nativePhysics] to false to opt the subtree out entirely). On non-watchOS
/// platforms this simply applies the firmer physics, so it is harmless in a
/// cross-platform tree.
class WatchCrownScroll extends StatelessWidget {
  /// Creates a native-feel wrapper around [child].
  const WatchCrownScroll({
    super.key,
    required this.child,
    this.nativePhysics = true,
  });

  /// The subtree containing the scrollable(s) to add native feel to.
  final Widget child;

  /// Whether to install [WatchScrollPhysics] for the subtree. Defaults to
  /// true; set false to keep Flutter's default physics.
  final bool nativePhysics;

  @override
  Widget build(BuildContext context) {
    if (!nativePhysics) {
      return child;
    }
    return ScrollConfiguration(
      behavior: const WatchScrollBehavior(),
      child: child,
    );
  }
}
