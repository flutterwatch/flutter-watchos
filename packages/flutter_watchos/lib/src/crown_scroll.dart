// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/widgets.dart';

import 'haptics.dart';

/// Adds the native watchOS "end of content" bump haptic to scrollables in
/// [child].
///
/// The Digital Crown's scroll motion, acceleration and detent ticks are
/// produced by the watchOS host (see `FlutterRunner.swift`). This widget
/// supplies the one piece of native crown feel that can only come from the
/// Flutter side — the edge bump — because only Flutter knows when a scrollable
/// has actually reached its limit. It listens for [OverscrollNotification] and
/// plays a haptic once per edge contact, re-arming when scrolling returns
/// in-bounds.
///
/// Wrap a scrollable subtree (commonly a whole screen or the app body):
///
/// ```dart
/// WatchCrownScroll(
///   child: ListView(children: const [/* ... */]),
/// )
/// ```
///
/// On non-watchOS platforms and on the simulator the haptic is a safe no-op
/// (see [WatchHaptics]), so this widget is harmless to leave in a cross-platform
/// tree.
class WatchCrownScroll extends StatefulWidget {
  /// Creates an edge-feedback wrapper around [child].
  const WatchCrownScroll({
    super.key,
    required this.child,
    this.edgeHaptic = WatchHapticType.stop,
    this.minOverscroll = 0.5,
  });

  /// The subtree containing the scrollable(s) to add edge feedback to.
  final Widget child;

  /// Haptic played once when a scrollable first reaches its limit. Defaults to
  /// [WatchHapticType.stop] — a firm "you've hit the end" bump.
  final WatchHapticType edgeHaptic;

  /// Minimum overscroll (in logical pixels) before the bump fires, to ignore
  /// sub-pixel jitter at rest.
  final double minOverscroll;

  @override
  State<WatchCrownScroll> createState() => _WatchCrownScrollState();
}

class _WatchCrownScrollState extends State<WatchCrownScroll> {
  // Debounce: one bump per edge entry, re-armed once scrolling leaves the edge.
  bool _atEdge = false;

  bool _onNotification(ScrollNotification notification) {
    if (notification is OverscrollNotification) {
      if (!_atEdge && notification.overscroll.abs() >= widget.minOverscroll) {
        _atEdge = true;
        WatchHaptics.play(widget.edgeHaptic);
      }
    } else if (notification is ScrollUpdateNotification ||
        notification is ScrollEndNotification) {
      // Back in-bounds (or stopped): re-arm so the next edge contact bumps.
      _atEdge = false;
    }
    // Never consume the notification — let app listeners see it too.
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: _onNotification,
      child: widget.child,
    );
  }
}
