// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'watchos_ffi_bindings.dart';
import 'watchos_info_platform.dart' as platform;

/// Which side owns the touches that land inside a [WatchPlatformView]'s rect.
///
/// SwiftUI has no event forwarding, so whichever side takes the touch-down
/// owns the whole gesture — that is a watchOS platform constraint, and the
/// only thing this enum decides on a compositor-capable engine
/// ([WatchPlatformView.isComposited]). WHERE the native view is drawn is not
/// a choice: it is composited at the widget's position in paint order, so
/// Flutter content painted after the widget draws over it either way.
///
///  * [aboveFlutter] — interactive native views (pickers, buttons, toggles).
///    The native view receives touches inside its rect directly, unless
///    Flutter content painted above it covers that point (then Flutter gets
///    them).
///  * [belowFlutter] — display views (gauges, charts, animations). Touches
///    always go to Flutter; wrap the widget in a [GestureDetector] to handle
///    interaction in Dart.
///
/// On an engine that predates the compositor the value also picks the
/// composition side, see [WatchPlatformView].
enum WatchPlatformViewLayer {
  /// The native view owns touches inside its rect that no Flutter content
  /// painted above it covers (default).
  ///
  /// Legacy engines: the native view is overlaid on top of the whole
  /// Flutter frame.
  aboveFlutter,

  /// Touches always go to Flutter; the native view is display-only.
  ///
  /// Legacy engines: the native view is composited under the Flutter frame
  /// and the widget punches a transparent hole in the scene for it.
  belowFlutter,
}

/// Embeds a native SwiftUI view in the Flutter widget tree on watchOS.
///
/// The widget reserves space in the Flutter layout, and the watch host shows
/// the native view registered for [viewType] at exactly that position. The
/// native side of a [viewType] is registered in the app's `App.swift`
/// initializer (`WatchPlatformViewRegistry` comes with the `FlutterWatchOS`
/// host module every app imports):
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
/// ## Composition
///
/// On a compositor-capable engine ([isComposited]) the widget is a real
/// platform view in the layer tree: the native view is composited **at the
/// widget's position in paint order**. Flutter content painted before the
/// widget is below it, and content painted after it — a badge in a [Stack],
/// a border in a `foregroundDecoration`, a dialog, a snackbar — is above it.
/// Geometry comes from the layer tree, so ancestor clips, opacity and
/// transforms apply to the native view like to any other content, and it
/// tracks scrolling and animation frame-accurately. It hides whenever it is
/// not painted: scrolled out of the viewport, or covered by an opaque route.
///
/// [layer] then only decides **touch ownership**. SwiftUI has no event
/// forwarding, so whichever side takes the touch-down owns the whole
/// gesture:
///
///  * [WatchPlatformViewLayer.aboveFlutter] (default) — the native view
///    receives touches inside its rect, unless Flutter content painted above
///    it covers that point.
///  * [WatchPlatformViewLayer.belowFlutter] — touches always go to Flutter.
///    Handle them in Dart with a [GestureDetector] around the widget.
///
/// ## Engines that predate the compositor
///
/// On a watch running an older engine ([isComposited] false) the widget
/// falls back to the overlay/underlay model, where [layer] also picks the
/// composition side. The native overlay is positioned from the semantics
/// tree, follows its slot through scrolling and route changes, and hides
/// when scrolled out of the viewport or covered by an opaque route — but:
///
///  * [WatchPlatformViewLayer.aboveFlutter] overlays the native view on the
///    whole Flutter frame: no Flutter content can draw over it, overlapping
///    platform views stack in creation order, and touches inside its rect
///    always go to the native view.
///  * [WatchPlatformViewLayer.belowFlutter] composites the native view
///    UNDER the frame and the widget clears its rect to transparent
///    ([BlendMode.clear]) so it shows through; content painted after the
///    widget draws over it. The hole must reach the surface: an ancestor
///    that composites through an intermediate layer over the widget's rect
///    (e.g. [Opacity]) fills it with its own backdrop. On engines without
///    the underlay layer ([isUnderlaySupported] false) the view degrades to
///    the overlay.
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

  /// Which side owns touches inside the native view's rect (see
  /// [WatchPlatformViewLayer]).
  ///
  /// On a compositor-capable engine ([isComposited]) this affects touch
  /// routing only: the native view is always composited at the widget's
  /// position in paint order. On older engines it also picks the
  /// composition side, and [WatchPlatformViewLayer.belowFlutter] silently
  /// degrades to the overlay when the engine lacks the underlay layer
  /// (check [isUnderlaySupported]).
  final WatchPlatformViewLayer layer;

  /// Whether the running engine supports platform views (always false off
  /// watchOS). When false, [WatchPlatformView] renders nothing.
  static bool get isSupported => _PlatformViewHost.instance.isSupported;

  /// Whether the running engine supports [WatchPlatformViewLayer.belowFlutter]
  /// (always false off watchOS). When false, that layer degrades to
  /// [WatchPlatformViewLayer.aboveFlutter].
  ///
  /// Only meaningful on engines that predate the compositor: with
  /// [isComposited] the layer never affects composition.
  static bool get isUnderlaySupported =>
      _PlatformViewHost.instance.isUnderlaySupported;

  /// Whether the running engine composites platform views from the layer
  /// tree (always false off watchOS).
  ///
  /// When true the native view is drawn at the widget's position in paint
  /// order and [layer] only decides touch ownership. When false — an engine
  /// that predates the compositor — the legacy overlay/underlay model
  /// documented on [WatchPlatformView] applies.
  static bool get isComposited => _PlatformViewHost.instance.isComposited;

  /// Test seam: inject fake bindings (and reset the id counter so tests are
  /// deterministic). Pass null to restore the real ones.
  @visibleForTesting
  static set bindingsOverride(WatchOSNativeBindings? bindings) {
    _PlatformViewHost.instance.bindingsOverride = bindings;
  }

  @override
  RenderWatchPlatformView createRenderObject(BuildContext context) =>
      RenderWatchPlatformView(
          viewType: viewType, params: creationParams, layer: layer);

  @override
  void updateRenderObject(
      BuildContext context, covariant RenderWatchPlatformView renderObject) {
    renderObject.update(
        viewType: viewType, params: creationParams, layer: layer);
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(StringProperty('viewType', viewType))
      ..add(StringProperty('creationParams', creationParams, defaultValue: ''))
      ..add(EnumProperty<WatchPlatformViewLayer>('layer', layer,
          defaultValue: WatchPlatformViewLayer.aboveFlutter));
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

  bool get isComposited => bindings.supportsCompositedPlatformViews;

  // Engine-side platformViewId is int32; ids stay tiny in practice (one per
  // WatchPlatformView element created over the app's lifetime).
  int _nextViewId = 1;

  int allocateViewId() => _nextViewId++;
}

/// The render object behind [WatchPlatformView]: registers the view with the
/// engine over FFI, reserves the slot in layout, tags its semantics node with
/// the view id, and paints the view's place in the scene. On a compositor-
/// capable engine that is a [PlatformViewLayer] at the slot (the engine
/// composites the native view from the layer tree); on older engines it is
/// nothing (the overlay is positioned from semantics) or — in the underlay
/// layer — the transparent hole the native view shows through. Not exported:
/// apps interact with it only via [WatchPlatformView].
class RenderWatchPlatformView extends RenderBox {
  /// Creates the render object and registers the view with the engine.
  RenderWatchPlatformView(
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

  /// Last size reported to the engine, to skip redundant FFI on relayouts.
  Size _reportedSize = Size.zero;

  /// Whether the engine composites the native view from the layer tree, in
  /// which case this box paints a [PlatformViewLayer] and nothing else.
  /// Fixed for the life of the process (the bindings cache the answer), so
  /// the compositing getters below never change value on a live object.
  bool get _composited => _PlatformViewHost.instance.isComposited;

  /// Whether this render object punches the transparent hole (legacy engines
  /// only): in the underlay layer, and only when the engine actually honors
  /// it — under an old engine the view degrades to overlay, and a hole
  /// beneath nothing would just expose the window background.
  bool get _punchesHole =>
      !_composited &&
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
    // Re-create in place: the engine updates type/params/layer for this id
    // and preserves the published geometry. The semantics update re-publishes
    // this node so a legacy engine's next walk re-associates the slot
    // promptly.
    _PlatformViewHost.instance.bindings.platformViewCreate(
        _viewId, _viewType, _params,
        belowFrame: layer == WatchPlatformViewLayer.belowFlutter);
    markNeedsSemanticsUpdate();
    if (layerChanged) {
      markNeedsPaint(); // legacy engines: the hole appears or fills in
    }
  }

  @override
  void dispose() {
    _PlatformViewHost.instance.bindings.platformViewDispose(_viewId);
    super.dispose();
  }

  @override
  bool get sizedByParent => true;

  // Composited mode mirrors the framework's PlatformViewRenderBox: the paint
  // always adds a layer, and the box gets its own layer so the platform view
  // sits at a stable place in the tree across repaints of its neighbours.
  @override
  bool get alwaysNeedsCompositing => _composited;

  @override
  bool get isRepaintBoundary => _composited;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void performLayout() {
    // Report the full layout size so a legacy engine publishes UNCLIPPED
    // rects: the framework clips a semantics node's rect to the viewport,
    // which would make a half-scrolled-off view shrink toward the screen
    // edge instead of sliding past it; with the true size the engine maps
    // (0,0,w,h) through the (unclipped) node transform instead. Layout —
    // not paint — is the right hook: it runs whenever the size can change
    // and never during plain scrolling. Harmless under the compositor, which
    // takes the geometry from the layer tree.
    if (size != _reportedSize) {
      _reportedSize = size;
      _PlatformViewHost.instance.bindings
          .platformViewSetSize(_viewId, size.width, size.height);
    }
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    // Touch ownership is decided on the native side (the host routes a
    // touch-down to the native view or to Flutter by the layer and, under
    // the compositor, by what Flutter painted above the view). Staying
    // transparent here lets a wrapping GestureDetector (or content behind)
    // own the touches Flutter does receive, which is how belowFlutter
    // interaction is handled in Dart. Off-watch / under an old engine the
    // slot is empty anyway.
    return false;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_composited) {
      // The engine composites the native view from this layer: its position
      // in the tree is the view's place in paint order, and the ancestor
      // clips/opacity/transforms apply to it.
      context.addLayer(PlatformViewLayer(rect: offset & size, viewId: _viewId));
      return;
    }
    // Legacy engines. Overlay layer: nothing — the slot stays transparent and
    // the native overlay covers it. Underlay layer: clear the rect to
    // transparent so the native view UNDER the frame shows through; content
    // painted after this widget draws over the hole (and thus over the
    // native view). Either way, positioning rides the semantics tree, not
    // paint.
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
    // Tagging the node with the view id is how the engine associates this
    // box with the native view: the accessibility bridge reads it, and a
    // legacy engine positions the native overlay from it.
    config
      ..isSemanticBoundary = true
      ..platformViewId = _viewId;
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(IntProperty('viewId', _viewId))
      ..add(StringProperty('viewType', _viewType))
      ..add(EnumProperty<WatchPlatformViewLayer>('layer', _layer))
      ..add(FlagProperty('composited',
          value: _composited, ifTrue: 'composited', ifFalse: 'legacy'));
  }
}
