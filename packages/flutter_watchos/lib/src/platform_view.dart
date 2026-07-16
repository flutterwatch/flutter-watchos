// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'watchos_ffi_bindings.dart';
import 'watchos_info_platform.dart' as platform;

/// Embeds a native SwiftUI view in the Flutter widget tree on watchOS.
///
/// watchOS platform views are **overlay-composited**: the widget reserves
/// space in the Flutter layout, and the watch host overlays the native view
/// registered for [viewType] on top of the rendered Flutter frame at exactly
/// that position — the same composition model the engine already uses for
/// native text input. The native side of a [viewType] is registered in the
/// app's runner (see `WatchPlatformViewRegistry.register` in the generated
/// `FlutterRunner.swift`):
///
/// ```swift
/// WatchPlatformViewRegistry.register("birthday-picker") { params in
///     AnyView(MyDatePicker(params: params))
/// }
/// ```
///
/// ```dart
/// SizedBox(
///   height: 64,
///   child: WatchPlatformView(
///     viewType: 'birthday-picker',
///     creationParams: '{"initial": "2026-07-14"}',
///   ),
/// )
/// ```
///
/// The widget tracks scrolling, animation, and route changes through the
/// semantics tree (the engine positions the native overlay from it), so the
/// native view follows its slot and hides when scrolled out of the viewport
/// or covered by an opaque route.
///
/// The composition layer of a [WatchPlatformView], relative to the rendered
/// Flutter frame. Whichever side is on top also owns the touches — that is a
/// watchOS platform constraint (SwiftUI has no event forwarding), so pick the
/// layer by what the view needs:
///
///  * [aboveFlutter] — interactive native views (pickers, buttons). The
///    native view receives touches directly, but no Flutter content can
///    appear over it.
///  * [belowFlutter] — display views (gauges, charts, animations) that
///    Flutter content may overlap: dialogs, snackbars, badges all draw on
///    top. The native view gets no direct touches; wrap the widget in a
///    [GestureDetector] to handle interaction in Dart.
enum WatchPlatformViewLayer {
  /// The native view is composited on top of the Flutter frame (default).
  aboveFlutter,

  /// The native view is composited under the Flutter frame; the widget
  /// punches a transparent hole in the scene so it shows through.
  belowFlutter,
}

/// Because the native view is an overlay above the frame (the default
/// [WatchPlatformViewLayer.aboveFlutter]):
///
///  * Flutter content cannot draw ON TOP of a platform view. Design around
///    it (no snackbars/dialogs overlapping the view's rect) — or use
///    [WatchPlatformViewLayer.belowFlutter], which inverts the trade.
///  * Overlapping platform views stack in creation order.
///  * Touches inside the view's rect are consumed by the native view.
///
/// With `layer: WatchPlatformViewLayer.belowFlutter` the native view sits
/// UNDER the frame instead and the widget clears its rect to transparent
/// ([BlendMode.clear]), so the view shows through the hole while any Flutter
/// content painted above the widget draws over it. Two caveats:
///
///  * Touches go to Flutter, not the native view (handle them in Dart).
///  * The hole must reach the surface: an ancestor that composites through
///    an intermediate layer over this widget's rect (e.g. [Opacity]) fills
///    the hole with its own backdrop.
///
/// On non-watchOS platforms — and on a watch running an engine that predates
/// platform views — the widget just paints nothing and is otherwise inert, so
/// it is safe in cross-platform code. Use [isSupported] to offer a Flutter
/// fallback instead.
class WatchPlatformView extends LeafRenderObjectWidget {
  /// Creates a watchOS platform view that displays the native view registered
  /// for [viewType].
  const WatchPlatformView({
    super.key,
    required this.viewType,
    this.creationParams = '',
    this.layer = WatchPlatformViewLayer.aboveFlutter,
  });

  /// The factory key the watch host resolves to build the native view.
  final String viewType;

  /// Opaque creation parameters handed to the native factory (by convention a
  /// JSON string). Changing it re-delivers the params to the native side.
  final String creationParams;

  /// Where the native view is composited relative to the Flutter frame. On
  /// engines that predate the underlay layer, [WatchPlatformViewLayer
  /// .belowFlutter] silently degrades to the overlay layer (check
  /// [isUnderlaySupported]).
  final WatchPlatformViewLayer layer;

  /// Whether the running engine supports platform views (always false off
  /// watchOS). When false, [WatchPlatformView] renders nothing.
  static bool get isSupported => _PlatformViewHost.instance.isSupported;

  /// Whether the running engine supports [WatchPlatformViewLayer.belowFlutter]
  /// (always false off watchOS). When false, that layer degrades to
  /// [WatchPlatformViewLayer.aboveFlutter].
  static bool get isUnderlaySupported =>
      _PlatformViewHost.instance.isUnderlaySupported;

  /// Test seam: inject fake bindings (and reset the id counter so tests are
  /// deterministic). Pass null to restore the real ones.
  @visibleForTesting
  static set bindingsOverride(WatchOSNativeBindings? bindings) {
    _PlatformViewHost.instance.bindingsOverride = bindings;
  }

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderWatchPlatformView(
          viewType: viewType, params: creationParams, layer: layer);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderWatchPlatformView)
        .update(viewType: viewType, params: creationParams, layer: layer);
  }
}

/// Package-private owner of the FFI bindings and the view-id counter, shared
/// by every [WatchPlatformView] in the app.
class _PlatformViewHost {
  _PlatformViewHost._();

  static final _PlatformViewHost instance = _PlatformViewHost._();

  WatchOSNativeBindings? _bindings;

  WatchOSNativeBindings get bindings => _bindings ??= platform.isWatch
      ? WatchOSNativeBindings()
      : WatchOSNativeBindings.forTesting();

  set bindingsOverride(WatchOSNativeBindings? bindings) {
    _bindings = bindings;
    _nextViewId = 1;
  }

  bool get isSupported => bindings.supportsPlatformViews;

  bool get isUnderlaySupported => bindings.supportsPlatformViewUnderlay;

  // Engine-side platformViewId is int32; ids stay tiny in practice (one per
  // WatchPlatformView element created over the app's lifetime).
  int _nextViewId = 1;

  int allocateViewId() => _nextViewId++;
}

class _RenderWatchPlatformView extends RenderBox {
  _RenderWatchPlatformView(
      {required String viewType,
      required String params,
      required WatchPlatformViewLayer layer})
      : _viewType = viewType,
        _params = params,
        _layer = layer,
        _viewId = _PlatformViewHost.instance.allocateViewId() {
    _PlatformViewHost.instance.bindings.platformViewCreate(
        _viewId, _viewType, _params,
        belowFrame: layer == WatchPlatformViewLayer.belowFlutter);
  }

  final int _viewId;
  String _viewType;
  String _params;
  WatchPlatformViewLayer _layer;

  /// Whether this render object punches the transparent hole: only in the
  /// underlay layer, and only when the engine actually honors it — under an
  /// old engine the view degrades to overlay, and a hole beneath nothing
  /// would just expose the window background.
  bool get _punchesHole =>
      _layer == WatchPlatformViewLayer.belowFlutter &&
      _PlatformViewHost.instance.isUnderlaySupported;

  void update(
      {required String viewType,
      required String params,
      required WatchPlatformViewLayer layer}) {
    if (viewType == _viewType && params == _params && layer == _layer) {
      return;
    }
    final bool layerChanged = layer != _layer;
    _viewType = viewType;
    _params = params;
    _layer = layer;
    // Re-create in place: the engine updates type/params/layer and preserves
    // the published geometry, so no semantics flush is needed afterwards.
    _PlatformViewHost.instance.bindings.platformViewCreate(
        _viewId, _viewType, _params,
        belowFrame: layer == WatchPlatformViewLayer.belowFlutter);
    markNeedsSemanticsUpdate();
    if (layerChanged) {
      markNeedsPaint(); // the hole appears or fills in
    }
  }

  @override
  void dispose() {
    _PlatformViewHost.instance.bindings.platformViewDispose(_viewId);
    super.dispose();
  }

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  /// Last size reported to the engine, to skip redundant FFI on relayouts.
  Size _reportedSize = Size.zero;

  @override
  void performLayout() {
    // Report the full layout size so the engine publishes UNCLIPPED rects:
    // the framework clips a semantics node's rect to the viewport, which
    // would make a half-scrolled-off view shrink toward the screen edge
    // instead of sliding past it; with the true size the engine maps
    // (0,0,w,h) through the (unclipped) node transform instead. Layout —
    // not paint — is the right hook: it runs whenever the size can change
    // and never during plain scrolling.
    if (size != _reportedSize) {
      _reportedSize = size;
      _PlatformViewHost.instance.bindings
          .platformViewSetSize(_viewId, size.width, size.height);
    }
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    // Overlay layer: the native view consumes touches inside its rect before
    // they reach Flutter, so claiming the slot here only matters off-watch /
    // under an old engine — where the slot is empty anyway. Underlay layer:
    // staying transparent lets a wrapping GestureDetector (or content behind)
    // own the touches, which is how underlay interaction is handled in Dart.
    return false;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    // Overlay layer: nothing — the slot stays transparent and the native
    // overlay covers it. Underlay layer: clear the rect to transparent so the
    // native view UNDER the frame shows through; content painted after this
    // widget draws over the hole (and thus over the native view). Either way,
    // positioning rides the semantics tree, not paint — see the engine's
    // flutter_watchos_platform_views.h for why.
    if (_punchesHole) {
      // The clear blend only reaches the surface if this picture is played
      // back directly. The raster cache would flatten it to a transparent
      // image composited srcOver — filling the hole with whatever is behind
      // (typically the scaffold background) after a few scroll frames. The
      // hint opts the containing picture out of caching.
      context.setWillChangeHint();
      context.canvas
          .drawRect(offset & size, Paint()..blendMode = BlendMode.clear);
    }
  }

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    // The engine's semantics walk harvests nodes tagged with a platformViewId
    // and positions the native overlay from them.
    config
      ..isSemanticBoundary = true
      ..platformViewId = _viewId;
  }
}
