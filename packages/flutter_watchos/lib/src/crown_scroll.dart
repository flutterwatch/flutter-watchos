// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'haptics.dart';
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

/// Gives the scrollables in [child] the full native watchOS feel.
///
/// The Digital Crown's scroll motion, acceleration and detent ticks are
/// produced by the engine. This widget supplies the two pieces that can only
/// come from the Flutter side:
///
///  * **Native edge feel** — installs [WatchScrollPhysics] for the subtree
///    (via [ScrollConfiguration]), so content stops at its end with a small,
///    firm bounce instead of the iPhone-style deep elastic stretch.
///  * **Edge bump haptic** — plays the native "end of content" bump once per
///    edge contact, because only Flutter knows when a scrollable has actually
///    reached its limit. It listens for [OverscrollNotification] and re-arms
///    when scrolling returns in-bounds.
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
/// platforms and on the simulator the haptic is a safe no-op (see
/// [WatchHaptics]), so this widget is harmless to leave in a cross-platform
/// tree.
class WatchCrownScroll extends StatefulWidget {
  /// Creates a native-feel wrapper around [child].
  const WatchCrownScroll({
    super.key,
    required this.child,
    this.edgeHaptic = WatchHapticType.stop,
    this.minOverscroll = 0.5,
    this.nativePhysics = true,
  });

  /// The subtree containing the scrollable(s) to add native feel to.
  final Widget child;

  /// Haptic played once when a scrollable first reaches its limit. Defaults to
  /// [WatchHapticType.stop] — a firm "you've hit the end" bump.
  final WatchHapticType edgeHaptic;

  /// Minimum overscroll (in logical pixels) before the bump fires, to ignore
  /// sub-pixel jitter at rest.
  final double minOverscroll;

  /// Whether to install [WatchScrollPhysics] for the subtree. Defaults to
  /// true; set false to keep Flutter's default physics and only add the edge
  /// haptic.
  final bool nativePhysics;

  @override
  State<WatchCrownScroll> createState() => _WatchCrownScrollState();
}

class _WatchCrownScrollState extends State<WatchCrownScroll> {
  // Debounce: one bump per edge entry, re-armed once scrolling leaves the edge.
  bool _atEdge = false;

  bool _onNotification(ScrollNotification notification) {
    // Edge contact must be read from the METRICS going out of range, not from
    // OverscrollNotification: with bouncing-style physics (ours included) the
    // position elastically leaves the range and OverscrollNotification is
    // NEVER dispatched — it is the clamping-physics "input rejected" event.
    // Relying on it silently muted the bump for every bouncing scrollable.
    if (notification is ScrollUpdateNotification ||
        notification is OverscrollNotification ||
        notification is ScrollEndNotification) {
      final ScrollMetrics metrics = notification.metrics;
      final double overscroll = metrics.hasPixels &&
              metrics.hasContentDimensions
          ? math.max(metrics.minScrollExtent - metrics.pixels,
              metrics.pixels - metrics.maxScrollExtent)
          : 0.0;
      if (overscroll >= widget.minOverscroll) {
        if (!_atEdge) {
          _atEdge = true;
          WatchHaptics.play(widget.edgeHaptic);
        }
      } else {
        // Back in-bounds: re-arm so the next edge contact bumps.
        _atEdge = false;
      }
    }
    // Never consume the notification — let app listeners see it too.
    return false;
  }

  @override
  Widget build(BuildContext context) {
    Widget result = NotificationListener<ScrollNotification>(
      onNotification: _onNotification,
      child: widget.child,
    );
    if (widget.nativePhysics) {
      result = ScrollConfiguration(
        behavior: const WatchScrollBehavior(),
        child: result,
      );
    }
    return result;
  }
}
