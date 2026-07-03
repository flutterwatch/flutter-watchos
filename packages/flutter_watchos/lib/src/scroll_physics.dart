// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Scroll physics tuned to feel like a native watchOS list.
///
/// Flutter's default [BouncingScrollPhysics] is calibrated for iPhone: the
/// content can be dragged far past its edge (a large elastic stretch) and a
/// fling bounces deep before settling. Native watchOS is much firmer — the
/// crown or a drag can pull content only a *small* distance past the edge,
/// and a fling ends in a quick, shallow bounce that settles right at the end
/// of the list.
///
/// [WatchScrollPhysics] reproduces that:
///
///  * **Hard stretch cap** — overscroll resistance rises steeply and reaches
///    infinity at [maxStretchFraction] of the viewport (default 12%, ≈30
///    logical points on a 46 mm watch), so no amount of crown turning can drag
///    the list further than a native one.
///  * **Firm, fast settle** — a stiffer, slightly overdamped spring snaps the
///    content back to the edge without the phone-style deep wobble.
///
/// Applied automatically by [WatchCrownScroll]; for app-wide use install
/// [WatchScrollBehavior] or pass the physics explicitly:
///
/// ```dart
/// ListView(physics: const WatchScrollPhysics(), children: [...])
/// ```
///
/// On non-watch platforms it simply behaves as a firmer bouncing physics, so
/// it is safe in cross-platform code.
class WatchScrollPhysics extends BouncingScrollPhysics {
  /// Creates watch-native scroll physics.
  const WatchScrollPhysics({
    this.maxStretchFraction = 0.12,
    this.edgeRelaxation = 0.3,
    super.parent,
  });

  /// The maximum overscroll, as a fraction of the viewport, that a drag or
  /// crown turn can reach. Resistance grows steeply toward this limit and the
  /// content cannot be pulled past it.
  final double maxStretchFraction;

  /// Fraction of the current overscroll released back toward the edge on
  /// every input event while tensioning. This is what keeps the edge ALIVE
  /// under sustained crown input, like the native home screen: instead of
  /// freezing at the stretch cap (a dead zone where further rotation is
  /// ignored), the stretch settles at an equilibrium proportional to how hard
  /// the crown is being turned — slow turning holds a few points, a hard turn
  /// holds near the cap, and the fluctuation of real crown deltas makes it
  /// visibly breathe. When input stops, the regular spring settles it.
  final double edgeRelaxation;

  @override
  WatchScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return WatchScrollPhysics(
      maxStretchFraction: maxStretchFraction,
      edgeRelaxation: edgeRelaxation,
      parent: buildParent(ancestor),
    );
  }

  /// The native-watch overscroll resistance curve.
  ///
  /// Same shape as the iOS curve, but compressed so friction hits zero at
  /// [maxStretchFraction] of the viewport instead of at a full viewport —
  /// that zero is what turns the soft iPhone stretch into a hard watch limit
  /// (see [BouncingScrollPhysics.applyPhysicsToUserOffset]: zero friction
  /// means further input moves the content not at all).
  @override
  double frictionFactor(double overscrollFraction) {
    final double fraction =
        (overscrollFraction / maxStretchFraction).clamp(0.0, 1.0).toDouble();
    return 0.52 * math.pow(1 - fraction, 2);
  }

  /// Reworks overscroll input handling for crown-scale events. Two stock
  /// assumptions break on the watch:
  ///
  ///  1. Stock physics applies NO friction to an input event that STARTS in
  ///     range. Finger drags deliver a few pixels per event, so crossing the
  ///     edge unfrictioned is invisible on a phone — but a single crown sample
  ///     can move much more than a finger drag, and one sample crossing the
  ///     edge would plant the content most of a screen deep with no
  ///     resistance. Such an event is split at the edge: the in-range part
  ///     moves freely, the excess is friction-integrated.
  ///
  ///  2. Stock friction freezes at the stretch limit — a dead zone where the
  ///     crown visibly stops doing anything. The native edge stays live: while
  ///     tensioning, each event both pushes (frictioned) and relaxes the
  ///     stretch back by [edgeRelaxation], reaching a breathing equilibrium
  ///     that tracks how hard the crown is turned (never past the cap, never
  ///     dead).
  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) {
    if (offset == 0) {
      return 0;
    }
    if (!position.outOfRange) {
      // In-range travel available before the edge in the travel direction
      // (positive offset moves pixels toward min, negative toward max).
      final double free = offset > 0
          ? position.pixels - position.minScrollExtent
          : position.maxScrollExtent - position.pixels;
      if (offset.abs() > free) {
        final double excess = offset.abs() - free;
        return offset.sign *
            (free + _integrateFriction(position.viewportDimension, 0, excess));
      }
      return offset;
    }

    final double overscrollPastStart =
        math.max(position.minScrollExtent - position.pixels, 0.0);
    final double overscrollPastEnd =
        math.max(position.pixels - position.maxScrollExtent, 0.0);
    final double overscrollPast =
        math.max(overscrollPastStart, overscrollPastEnd);
    final bool easing = (overscrollPastStart > 0.0 && offset < 0.0) ||
        (overscrollPastEnd > 0.0 && offset > 0.0);
    if (easing) {
      // Turning back toward the content: stock behavior reads fine.
      return super.applyPhysicsToUserOffset(position, offset);
    }

    // Tensioning while already stretched: push out (frictioned from the
    // current stretch) minus the live relaxation pull-back. Net can be
    // negative — the stretch shrinking under weak input IS the alive feel —
    // but never snaps past the edge itself.
    final double pushed = _integrateFriction(
        position.viewportDimension, overscrollPast, offset.abs());
    double net = pushed - overscrollPast * edgeRelaxation;
    if (net < -overscrollPast) {
      net = -overscrollPast;
    }
    return offset.sign * net;
  }

  /// Overscroll produced by `input` pixels of user movement starting at
  /// `startOverscroll` of existing stretch, integrating [frictionFactor] as
  /// the stretch grows. Bounded by the stretch cap (friction reaches zero
  /// there).
  double _integrateFriction(
      double viewport, double startOverscroll, double input) {
    double over = startOverscroll;
    double moved = 0;
    const int steps = 24;
    final double h = input / steps;
    for (int i = 0; i < steps; i++) {
      final double step = h * frictionFactor(over / viewport);
      over += step;
      moved += step;
    }
    return moved;
  }

  /// A stiff, slightly overdamped spring: the fling bounce is shallow and the
  /// settle is quick and wobble-free, like a native watch list hitting its
  /// end. (Flutter's default scroll spring is calibrated for phone-sized
  /// travel and lets a hard fling overshoot by hundreds of pixels.)
  @override
  SpringDescription get spring => SpringDescription.withDampingRatio(
      mass: 0.5, stiffness: 800.0, ratio: 1.15);

  /// Phone flings reach 8000 px/s — several times a watch screen per frame.
  /// Native watch travel per flick is shorter, and this cap also bounds how
  /// hard a fling can slam into the edge spring (i.e. the bounce depth).
  @override
  double get maxFlingVelocity => 4000.0;

  /// Repeated crown/wheel bursts stack momentum ([carriedMomentum] alone
  /// allows up to 40 000 px/s) and would blow through the edge spring for a
  /// deep phone-style bounce. Clamp the ballistic entry velocity so the
  /// bounce stays shallow no matter how the fling was accumulated.
  @override
  Simulation? createBallisticSimulation(
      ScrollMetrics position, double velocity) {
    return super.createBallisticSimulation(
      position,
      velocity.clamp(-maxFlingVelocity, maxFlingVelocity).toDouble(),
    );
  }
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
