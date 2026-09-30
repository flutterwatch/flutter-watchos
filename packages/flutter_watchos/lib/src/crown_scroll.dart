// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/widgets.dart';

import 'scroll_physics.dart';

/// The key of the mark [WatchCrownScroll] puts above its child; the crown
/// runtime the flutter-watchos CLI compiles into every watch app looks for
/// it.
const String _crownScrollMarker = 'flutter_watchos.crownScroll';

/// Chooses how the Digital Crown treats the scrollables in [child], and
/// gives them the native watchOS feel under the finger as well.
///
/// Every watch app built with flutter-watchos scrolls with the crown the way
/// a native scroll view does, without this widget: a hidden native scroll
/// view owns the crown, so watchOS itself supplies the acceleration, the
/// momentum, the detent haptics, the spring at either end and the crown
/// scroll indicator, and the content follows it exactly. The crown drives
/// the vertical scrollable that fills most of the screen in the frontmost
/// route, among those actually drawn (not a hidden tab, not under a dialog).
///
/// Use this widget for the cases that rule does not decide the way an app
/// wants:
///
///  * choose a scrollable, for example a list that shares the screen with a
///    larger one: the outermost vertical scrollable in [child] is preferred;
///  * keep the crown off the scrollables in [child] with [enabled] false;
///  * hide watchOS's scroll indicator with [scrollIndicator] false.
///
/// ```dart
/// WatchCrownScroll(
///   child: ListView(children: const [/* ... */]),
/// )
/// ```
///
/// Wrapping a whole app applies to every page; the same rule then picks the
/// list on each. It also gives the subtree [WatchScrollPhysics] (via
/// [ScrollConfiguration]): a finger stretches, releases and bounces as on a
/// native scroll view. Scrollables that pass an explicit `physics:` keep it;
/// set [nativePhysics] to false to keep the ambient physics for the whole
/// subtree. On other platforms this only applies the physics.
///
/// ## Lists and the safe area
///
/// A watchOS list covers the whole screen and scrolls its rows under the
/// clock and down to the bottom edge. To get that, leave a list's `padding`
/// null, or add `MediaQuery.paddingOf(context)` to your own, and do not wrap
/// a scrolling view in a `SafeArea`: that turns the list into a window
/// between the insets, and no row ever shows above or below it.
///
/// ```dart
/// // A ListView or GridView with no padding takes the insets itself.
/// WatchCrownScroll(child: ListView(children: rows));
///
/// // With your own padding, add the insets to it.
/// WatchCrownScroll(
///   child: ListView(
///     padding: MediaQuery.paddingOf(context) +
///         const EdgeInsets.symmetric(horizontal: 10),
///     children: rows,
///   ),
/// );
///
/// // A SingleChildScrollView never pads itself: give it the insets.
/// WatchCrownScroll(
///   child: SingleChildScrollView(
///     padding: MediaQuery.paddingOf(context),
///     child: Column(children: rows),
///   ),
/// );
///
/// // In a CustomScrollView, a SliverSafeArea insets the slivers.
/// WatchCrownScroll(
///   child: CustomScrollView(
///     slivers: [SliverSafeArea(sliver: SliverList.list(children: rows))],
///   ),
/// );
/// ```
///
/// By default the watch's safe area leaves the clock out, so the first row
/// of such a list starts under the clock. A list whose first row must start
/// below the clock takes its top padding from `WatchStatusBar.heightOf`
/// instead.
class WatchCrownScroll extends StatelessWidget {
  /// Applies the crown options to the scrollables in [child].
  const WatchCrownScroll({
    super.key,
    required this.child,
    this.enabled = true,
    this.scrollIndicator = true,
    this.nativePhysics = true,
  });

  /// The subtree containing the scrollables.
  final Widget child;

  /// Whether the crown may drive the scrollables in [child]. Defaults to
  /// true, which also prefers the outermost one over the rest of the screen.
  /// False keeps the crown off all of them; it then drives another
  /// scrollable, or nothing.
  final bool enabled;

  /// Whether watchOS shows its scroll indicator by the crown while the
  /// scrollable moves. Defaults to true, as on a native scroll view.
  final bool scrollIndicator;

  /// Whether to install [WatchScrollPhysics] for the subtree. Defaults to
  /// true; set false to keep the ambient physics.
  final bool nativePhysics;

  @override
  Widget build(BuildContext context) {
    final Widget marked = MetaData(
      metaData: <String, Object>{
        _crownScrollMarker: true,
        'enabled': enabled,
        'scrollIndicator': scrollIndicator,
      },
      child: child,
    );
    if (!nativePhysics) {
      return marked;
    }
    return ScrollConfiguration(
      behavior: const WatchScrollBehavior(),
      child: marked,
    );
  }
}
