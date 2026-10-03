// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Scroll physics that move like a native watchOS scroll view under the
/// finger.
///
/// Measured on an Apple Watch Series 10 (46 mm, watchOS 26) against a native
/// SwiftUI `ScrollView`, frame by frame:
///
///  * **Rubber band** — past an edge the content follows the finger at 0.55
///    of its travel, less the further it is stretched: UIKit's curve
///    `c·x·d / (d + c·x)` with `c` = 0.55, `x` the finger's distance past the
///    edge and `d` the viewport. The finger can hold it there.
///  * **Edge spring** — a critically damped spring of 11 rad/s brings the
///    content back, both when the finger lets go of a stretch and when a
///    fling runs into the edge: the overscroll follows `e^(-11t)·(x0 + v·t)`
///    from where it is (`x0`) with the velocity it has (`v`). A held stretch
///    is let go with the finger's velocity, so a still finger lets it fall
///    straight back and a flick outward carries it further first.
///  * **Fling** — UIKit's normal deceleration (0.998 per millisecond), which
///    [BouncingScrollPhysics] already uses, moving in the first frame after
///    the finger lifts. A flick made during a fling starts at the finger's
///    own velocity: nothing carries over, unlike iOS.
///
/// With the current watch host the Digital Crown does not go through these
/// physics: the native scroll view that owns the crown moves the content,
/// edges included. An app that still compiles its own watchOS runner keeps
/// the older crown, which scrolls through them.
///
/// Applied automatically by [WatchCrownScroll]; for app-wide use install
/// [WatchScrollBehavior] or pass the physics explicitly:
///
/// ```dart
/// ListView(physics: const WatchScrollPhysics(), children: [...])
/// ```
///
/// On other platforms it behaves as iOS-style bouncing physics, so it is safe
/// in cross-platform code.
class WatchScrollPhysics extends BouncingScrollPhysics {
  /// Creates watch-native scroll physics.
  const WatchScrollPhysics({super.parent});

  /// UIKit's rubber-band constant: how much of the finger's travel the
  /// content follows right at the edge.
  static const double rubberBand = 0.55;

  /// The edge spring's natural frequency, in radians per second (critically
  /// damped).
  static const double edgeFrequency = 11.0;

  @override
  WatchScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return WatchScrollPhysics(parent: buildParent(ancestor));
  }

  /// The rubber band's slope at a stretch of `overscrollFraction` of the
  /// viewport: `0.55 · (1 − f)²`, the derivative of UIKit's curve.
  @override
  double frictionFactor(double overscrollFraction) {
    final double f = overscrollFraction.clamp(0.0, 1.0).toDouble();
    return rubberBand * (1 - f) * (1 - f);
  }

  /// Moves the content by `offset` of finger travel, following the rubber
  /// band exactly instead of stepwise: the stretch is a function of how far
  /// past the edge the finger is, so any event size lands on the curve (a
  /// fast drag's large events included), stretching or easing back alike.
  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) {
    if (offset == 0) {
      return 0;
    }
    final double d = position.viewportDimension;
    if (d <= 0) {
      return offset;
    }
    // Positive offset moves pixels toward min (content down).
    final double pastStart =
        math.max(position.minScrollExtent - position.pixels, 0.0);
    final double pastEnd =
        math.max(position.pixels - position.maxScrollExtent, 0.0);
    if (pastStart == 0 && pastEnd == 0) {
      // In range: one to one up to the edge, rubber band beyond it.
      final double room = offset > 0
          ? position.pixels - position.minScrollExtent
          : position.maxScrollExtent - position.pixels;
      if (offset.abs() <= room) {
        return offset;
      }
      return offset.sign * (room + _stretchFor(offset.abs() - room, d));
    }
    // Out of range: where the finger is past the edge, moved by the event.
    final bool atStart = pastStart > 0;
    final double stretch = atStart ? pastStart : pastEnd;
    // Outward at the start is positive offset; at the end, negative.
    final double outward = atStart ? offset : -offset;
    final double finger = _fingerFor(stretch, d) + outward;
    if (finger >= 0) {
      return (atStart ? 1 : -1) * (_stretchFor(finger, d) - stretch);
    }
    // Eased all the way back and on into the content, which moves one to
    // one.
    return (atStart ? 1 : -1) * (finger - stretch);
  }

  /// Content stretch for a finger `x` past the edge: `c·x·d / (d + c·x)`.
  static double _stretchFor(double x, double d) =>
      rubberBand * x * d / (d + rubberBand * x);

  /// The inverse: how far past the edge the finger is for a `stretch`.
  static double _fingerFor(double stretch, double d) {
    final double s = math.min(stretch, d * 0.999);
    return s * d / (rubberBand * (d - s));
  }

  /// Critically damped at [edgeFrequency]: `mass` 1, `stiffness` ω²,
  /// `damping` 2ω.
  @override
  SpringDescription get spring => const SpringDescription(
        mass: 1,
        stiffness: edgeFrequency * edgeFrequency,
        damping: 2 * edgeFrequency,
      );

  /// A finger letting go of a stretch starts the edge spring so the
  /// overscroll runs `e^(-ωt)·(x0 + v·t)`: in spring terms, an initial
  /// velocity of `v − ω·x0`. A fling that reaches the edge in flight crosses
  /// it with `x0` = 0, which [BouncingScrollSimulation] already hands the
  /// spring. A ballistic restarted for any other reason (new dimensions in
  /// the middle of the spring) carries on with the content's own velocity.
  ///
  /// A native release moves in the first frame after the finger lifts,
  /// while a ballistic's first frame shows where it starts; a flick
  /// therefore runs one frame (1/60 s) ahead.
  @override
  Simulation? createBallisticSimulation(
      ScrollMetrics position, double velocity) {
    final bool release = _isRelease(position);
    double v = velocity;
    if (release) {
      if (position.pixels < position.minScrollExtent) {
        v -= edgeFrequency * (position.pixels - position.minScrollExtent);
      } else if (position.pixels > position.maxScrollExtent) {
        v -= edgeFrequency * (position.pixels - position.maxScrollExtent);
      }
    }
    final Simulation? simulation = super.createBallisticSimulation(position, v);
    if (simulation == null || !release || velocity == 0) {
      return simulation;
    }
    return _LeadSimulation(simulation, 1 / 60);
  }

  /// Whether this ballistic is a finger's release: the position is still in
  /// the drag (or hold) that ends with it. Bare metrics count as one.
  static bool _isRelease(ScrollMetrics position) {
    if (position is! ScrollPosition) {
      return true;
    }
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    final ScrollActivity? activity = position.activity;
    return activity is DragScrollActivity || activity is HoldScrollActivity;
  }

  /// No iOS momentum build-up: a native watchOS scroll view launches a
  /// flick made during a fling at the finger's own velocity (measured on a
  /// Series 10).
  @override
  double carriedMomentum(double existingVelocity) => 0.0;
}

/// [inner], [lead] seconds ahead.
class _LeadSimulation extends Simulation {
  _LeadSimulation(this.inner, this.lead) : super(tolerance: inner.tolerance);

  final Simulation inner;
  final double lead;

  @override
  double x(double time) => inner.x(time + lead);

  @override
  double dx(double time) => inner.dx(time + lead);

  @override
  bool isDone(double time) => inner.isDone(time + lead);
}

/// A [ScrollBehavior] that gives every descendant scrollable the native
/// watchOS feel ([WatchScrollPhysics]) with no overscroll glow or scrollbars.
///
/// Install it app-wide:
///
/// ```dart
/// MaterialApp(
///   scrollBehavior: const WatchScrollBehavior(),
///   home: ...,
/// )
/// ```
///
/// or for a subtree via [ScrollConfiguration] (which is what
/// [WatchCrownScroll] does for you). Scrollables that pass an explicit
/// `physics:` keep their own.
class WatchScrollBehavior extends ScrollBehavior {
  /// Creates the watch scroll behavior.
  const WatchScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const WatchScrollPhysics();

  // A watch screen has no room for glow effects or scrollbars.
  @override
  Widget buildOverscrollIndicator(
          BuildContext context, Widget child, ScrollableDetails details) =>
      child;

  @override
  Widget buildScrollbar(
          BuildContext context, Widget child, ScrollableDetails details) =>
      child;
}
