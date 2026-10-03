// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// The app's own language version may be older than this file needs.
// @dart = 3.9

// Native Digital Crown scrolling, compiled into every watch app.
//
// The flutter-watchos CLI copies this file next to the app's generated plugin
// registrant, which calls [install] before `main`; the app needs no code and
// no package for it. The host keeps a hidden native ScrollView behind the
// Flutter frame that owns the crown, shaped like the scrollable this runtime
// picks (host/WatchCrownProxy.swift). watchOS scrolls that view with its own
// acceleration, momentum, detent haptics and edge spring; the host reports
// where it is once per display refresh, and the runtime shows exactly that
// position. When the content moves by other means (a finger, the app), the
// runtime tells the host, so the crown always continues from there.
//
// The scrollable is the one a native watch app would give the crown: among
// the vertical scrollables on screen, the frontmost that covers at least 40% of
// the screen, else the largest. Scrollables an app marks with
// `WatchCrownScroll` (package:flutter_watchos) are tried first, and ones with
// something to scroll before ones without. A NestedScrollView is driven as
// one scrollable, through its own drag, so its header collapses first.
//
// For a scrollable with the platform's default physics, the runtime also
// gives a released finger the native edge: the spring a native scroll view
// returns with after a stretch or a fling into its end.

import 'dart:async';
import 'dart:ffi' hide Size;

import 'package:flutter/gestures.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// The key of the `MetaData` map `WatchCrownScroll` (package:flutter_watchos)
/// puts above the scrollables it covers: `{crownScrollMarker: true,
/// 'enabled': bool, 'scrollIndicator': bool}`. `enabled` false keeps the
/// crown off them; `scrollIndicator` false hides watchOS's scroll indicator.
const String crownScrollMarker = 'flutter_watchos.crownScroll';

/// What a `WatchCrownScroll` above a scrollable asks for.
class _Mark {
  const _Mark({required this.enabled, required this.indicator});

  final bool enabled;
  final bool indicator;

  static _Mark? of(Widget widget) {
    if (widget is! MetaData) {
      return null;
    }
    final Object? data = widget.metaData;
    if (data is! Map || data[crownScrollMarker] != true) {
      return null;
    }
    return _Mark(
      enabled: data['enabled'] != false,
      indicator: data['scrollIndicator'] != false,
    );
  }
}

/// Starts native crown scrolling. Called by the plugin registrant before
/// `main`, in every isolate that runs it, and a no-op wherever it cannot run:
/// a background isolate, or a host without the native crown.
void install() {
  try {
    if (_installed || RootIsolateToken.instance == null) {
      return;
    }
    final CrownHost? host = FfiCrownHost.open();
    if (host == null) {
      return;
    }
    _installed = true;
    // A hot restart leaves the old isolate's listener with the host; drop it
    // before anything can call it.
    host.setListener(null);
    CrownRuntime(host).start();
  } catch (_) {
    // The crown must never take the app down.
  }
}

/// The registrant can run again in the same isolate (an app calling
/// `DartPluginRegistrant.ensureInitialized()`); one runtime per isolate.
bool _installed = false;

/// The host's half of the crown, behind an interface so tests can stand in.
abstract class CrownHost {
  /// Describes the scrollable to mirror, in its logical pixels; null
  /// withdraws it.
  void configure(CrownDescription? description);

  /// Reports a position the crown did not cause. [stop]: a finger took over
  /// from the crown, so the native view stops gliding.
  void sync(double pixels, {bool stop = false});

  /// Receives the native view's position and phase (1 moving, 0 at rest, 2
  /// where a crown turn starts from); null stops receiving.
  void setListener(void Function(double pixels, int phase)? listener);
}

/// What the host needs to shape its native view.
@immutable
class CrownDescription {
  /// Describes a scrollable.
  const CrownDescription({
    required this.viewport,
    required this.minExtent,
    required this.maxExtent,
    required this.rowExtent,
    this.indicator = true,
    this.snaps = false,
  });

  /// The viewport's main-axis extent.
  final double viewport;

  /// The scrollable's minimum scroll extent.
  final double minExtent;

  /// The scrollable's maximum scroll extent.
  final double maxExtent;

  /// The scrollable's row pitch, so the native view's rows match it.
  final double rowExtent;

  /// Whether watchOS shows its scroll indicator for it.
  final bool indicator;

  /// Whether the scrollable comes to rest on whole rows of [rowExtent] (a
  /// page view, a wheel), so the native view snaps to them as it settles.
  final bool snaps;

  @override
  bool operator ==(Object other) =>
      other is CrownDescription &&
      other.viewport == viewport &&
      other.minExtent == minExtent &&
      other.maxExtent == maxExtent &&
      other.rowExtent == rowExtent &&
      other.indicator == indicator &&
      other.snaps == snaps;

  @override
  int get hashCode =>
      Object.hash(viewport, minExtent, maxExtent, rowExtent, indicator, snaps);
}

typedef _ListenerNative = Void Function(Double pixels, Int32 phase);

/// [CrownHost] over the host module's C entry points
/// (`FlutterWatchOSCrownProxy*`, host/WatchCrownProxy.swift).
class FfiCrownHost implements CrownHost {
  FfiCrownHost._(DynamicLibrary lib)
    : _configure = lib
          .lookupFunction<
            Void Function(Int32, Double, Double, Double, Double, Int32, Int32),
            void Function(int, double, double, double, double, int, int)
          >('FlutterWatchOSCrownProxyConfigure'),
      _sync = lib
          .lookupFunction<
            Void Function(Double, Int32),
            void Function(double, int)
          >('FlutterWatchOSCrownProxySync'),
      _setListener = lib
          .lookupFunction<
            Void Function(Pointer<NativeFunction<_ListenerNative>>),
            void Function(Pointer<NativeFunction<_ListenerNative>>)
          >('FlutterWatchOSCrownProxySetListener');

  /// The host in this process, or null when it has no native crown (another
  /// platform, or an older host).
  static FfiCrownHost? open() {
    try {
      return FfiCrownHost._(DynamicLibrary.process());
    } on ArgumentError {
      return null;
    }
  }

  final void Function(int, double, double, double, double, int, int) _configure;
  final void Function(double, int) _sync;
  final void Function(Pointer<NativeFunction<_ListenerNative>>) _setListener;
  NativeCallable<_ListenerNative>? _callable;

  @override
  void configure(CrownDescription? description) {
    if (description == null) {
      _configure(0, 0, 0, 0, 0, 1, 0);
    } else {
      _configure(
        1,
        description.viewport,
        description.minExtent,
        description.maxExtent,
        description.rowExtent,
        description.indicator ? 1 : 0,
        description.snaps ? 1 : 0,
      );
    }
  }

  @override
  void sync(double pixels, {bool stop = false}) => _sync(pixels, stop ? 1 : 0);

  @override
  void setListener(void Function(double pixels, int phase)? listener) {
    _setListener(nullptr);
    _callable?.close();
    _callable = null;
    if (listener == null) {
      return;
    }
    final NativeCallable<_ListenerNative> callable =
        NativeCallable<_ListenerNative>.listener(listener);
    _callable = callable;
    _setListener(callable.nativeFunction);
  }
}

/// UIKit's rubber-band constant and a native scroll view's edge spring, as
/// measured on a Series 10 (see `WatchScrollPhysics` in
/// package:flutter_watchos, which applies them to a finger drag as well).
const double _edgeFrequency = 11.0;
const SpringDescription _edgeSpring = SpringDescription(
  mass: 1,
  stiffness: _edgeFrequency * _edgeFrequency,
  damping: 2 * _edgeFrequency,
);

/// The native release of a scroll position moving at [velocity], or null
/// when the platform's own fling already is the native one (it stays in
/// range: the platform's friction is UIKit's).
///
/// Out of range, the edge spring runs `e^(-ωt)·(x0 + v·t)` from the stretch
/// `x0`: in spring terms an initial velocity of `v − ω·x0`. A fling that
/// reaches an edge crosses it into the same spring.
Simulation? nativeBallisticSimulation(
  ScrollMetrics position,
  double velocity,
  Tolerance tolerance, {
  bool fingerRelease = true,
}) {
  final double x = position.pixels;
  double v = velocity;
  final bool outOfRange =
      x < position.minScrollExtent || x > position.maxScrollExtent;
  if (fingerRelease) {
    if (x < position.minScrollExtent) {
      v -= _edgeFrequency * (x - position.minScrollExtent);
    } else if (x > position.maxScrollExtent) {
      v -= _edgeFrequency * (x - position.maxScrollExtent);
    }
  } else if (!outOfRange) {
    // Not a release, in range: the platform's friction is UIKit's already.
    final double end = FrictionSimulation(0.135, x, velocity).finalX;
    if (end >= position.minScrollExtent && end <= position.maxScrollExtent) {
      return null;
    }
  }
  final Simulation simulation = BouncingScrollSimulation(
    spring: _edgeSpring,
    position: x,
    velocity: v,
    leadingExtent: position.minScrollExtent,
    trailingExtent: position.maxScrollExtent,
    tolerance: tolerance,
  );
  // A native release moves in the first frame after the finger lifts; a
  // ballistic's first frame shows where it starts. A flick runs a frame
  // ahead to match. (A still finger has nothing to lead.)
  return fingerRelease && velocity != 0
      ? _LeadSimulation(simulation, 1 / 60)
      : simulation;
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

/// Picks the scrollable the crown drives and drives it from the host.
class CrownRuntime {
  /// A runtime talking to [host]. [scanInterval] is how many frames pass
  /// between looks for the scrollable.
  CrownRuntime(this._host, {this.scanInterval = 10});

  final CrownHost _host;

  /// Frames between looks for the scrollable.
  final int scanInterval;

  WidgetsBinding? _binding;
  int _frame = 0;

  ScrollableState? _scrollable;
  ScrollPosition? _position;
  CrownDescription? _described;

  _CrownDriveActivity? _activity;

  /// The NestedScrollView whose outer scrollable [_scrollable] is: its header
  /// and body scroll as one, through its own drag (its positions are not
  /// single-context ones that can be set directly).
  NestedScrollViewState? _nested;

  /// The NestedScrollView's body positions, listened to beside the outer one.
  ScrollController? _nestedInner;

  /// The drag a crown turn feeds a NestedScrollView.
  Drag? _nestedDrag;

  /// The report the NestedScrollView's drag last took.
  double? _nestedLast;

  /// Whether the crown is moving the content now.
  bool get _driving => _activity != null || _nestedDrag != null;

  /// What the host's reports are corrected by while the scrollable's extent
  /// changes in the middle of a turn: the native view keeps its offset from
  /// the top of its content, so a new minimum (rows loaded above) or, for a
  /// reversed list, a new maximum would otherwise shift every later report.
  /// Back to zero whenever the native view is put on the content.
  double _shift = 0;

  /// The crown was driving when something else took the position over (a
  /// finger, or the app). The native view may still glide; its reports are
  /// not the user's any more and are ignored until it rests.
  bool _yielded = false;

  /// True while the runtime ends a drive itself, which is not a takeover.
  bool _endingDrive = false;

  /// Where the native view is, as far as the runtime knows: the position it
  /// last reported (a turn's start included), or the one it was last asked
  /// to follow.
  double? _native;

  /// Content position minus native position when the crown took over: zero
  /// from rest; during a Flutter fling the native view follows a frame
  /// behind, so a crown turned mid-fling starts that far back. Shown on top
  /// of the native position and blended out, so the takeover neither jumps
  /// nor leaves the edges misaligned.
  double _takeoverOffset = 0;

  /// Per-frame share of [_takeoverOffset] kept (about 0.2 s to blend out).
  static const double _takeoverDecay = 0.8;

  BallisticScrollActivity? _seenBallistic;

  /// The position's activity at the previous frame, to tell a finger's
  /// release from any other ballistic.
  ScrollActivity? _lastActivity;

  bool _detached = false;

  /// The scrollable the crown drives now, if any.
  @visibleForTesting
  ScrollableState? get scrollable => _scrollable;

  /// Waits for the app's binding, then attaches to it: right after `main`
  /// returns when `main` creates it synchronously (`runApp`), else as soon as
  /// it exists.
  void start() {
    Timer.run(() {
      final WidgetsBinding? binding = _bindingOrNull();
      if (binding != null) {
        attach(binding);
        return;
      }
      Timer.periodic(const Duration(milliseconds: 50), (Timer timer) {
        final WidgetsBinding? binding = _bindingOrNull();
        if (binding != null) {
          timer.cancel();
          attach(binding);
        } else if (timer.tick > 600) {
          timer.cancel();
        }
      });
    });
  }

  static WidgetsBinding? _bindingOrNull() {
    try {
      return WidgetsBinding.instance;
    } catch (_) {
      return null;
    }
  }

  /// Starts following [binding]'s frames.
  void attach(WidgetsBinding binding) {
    _binding = binding;
    _host.setListener(onNativePosition);
    binding.addPersistentFrameCallback(_onFrame);
    // A finger's release starts its ballistic as the pointer goes up,
    // outside any frame; adopting it right there lets the native release
    // move in the very next frame, as a native one does.
    binding.pointerRouter.addGlobalRoute(_onPointer);
    // The scrollable is found during a frame. If the app has drawn already
    // and gone idle, ask for one, or the crown has nothing to drive until
    // something else redraws (on a watch: until the first touch).
    if (binding.rootElement != null) {
      binding.scheduleFrame();
    }
  }

  /// Stops driving and following frames (a frame callback cannot be
  /// removed, so it stays registered and does nothing).
  @visibleForTesting
  void detach() {
    _detached = true;
    _binding?.pointerRouter.removeGlobalRoute(_onPointer);
    _select(null);
    _host.setListener(null);
  }

  void _onPointer(PointerEvent event) {
    if (_detached ||
        (event is! PointerUpEvent && event is! PointerCancelEvent)) {
      return;
    }
    try {
      _adoptBallistic();
    } catch (_) {
      // Never break input over the crown.
    }
  }

  void _onFrame(Duration timestamp) {
    if (_detached) {
      return;
    }
    try {
      _frame++;
      final ScrollableState? current = _scrollable;
      if (current != null &&
          (!current.mounted || !identical(current.position, _position))) {
        _select(null);
        _scanSoon = true;
      } else if (current != null && _visibleArea(current) == 0) {
        // Off the screen (another tab, a page over it) or no longer
        // scrollable, even in the middle of a crown turn: let go of it at
        // once. Releasing it ends the drive and the host's view with it, so
        // the rest of the turn cannot scroll a list nobody sees.
        _select(null);
        _scanSoon = true;
      }
      // The full look (a walk of the element tree) runs every few frames,
      // and at once when the scrollable is gone; not in the middle of a
      // crown turn on a scrollable still on screen. Also on the last frame of
      // a burst (a page or dialog transition just ended), so the crown never
      // waits a scan interval to leave a list that a new route covers.
      if (!_driving &&
          (_scanSoon ||
              _frame % scanInterval == 0 ||
              !(_binding?.hasScheduledFrame ?? true))) {
        _scanSoon = false;
        final _Candidate? found = _findCandidate();
        _select(found?.state, indicator: found?.indicator ?? true);
      }
      _describe();
      _adoptBallistic();
    } catch (_) {
      // Never break a frame over the crown.
    }
  }

  /// Look for the scrollable at the next frame instead of waiting for the
  /// periodic scan.
  bool _scanSoon = true;

  /// The scrollable a native watch app would give the crown: among those
  /// marked by `WatchCrownScroll` if any, else among all, the frontmost
  /// vertical scrollable that fills at least 40% of the screen, else the
  /// largest one showing.
  @visibleForTesting
  ScrollableState? findScrollable() => _findCandidate()?.state;

  _Candidate? _findCandidate() {
    final Element? root = _binding?.rootElement;
    if (root == null) {
      return null;
    }
    final List<_Candidate> candidates = <_Candidate>[];
    // The overlays (navigators) the walk is inside, outermost first.
    final List<Element> overlays = <Element>[];
    void visit(Element element, _Mark? inherited) {
      final Widget widget = element.widget;
      _Mark? mark = _Mark.of(widget) ?? inherited;
      if (widget is ModalBarrier &&
          overlays.isNotEmpty &&
          TickerMode.getValuesNotifier(element).value.enabled) {
        // Every route puts a barrier over the ones below it in its
        // navigator: what came before it there is under a page, a dialog or
        // a sheet, and a native watch app's crown does not reach that
        // either. A nested navigator's barrier covers only its own routes.
        final Element overlay = overlays.last;
        candidates.removeWhere(
          (_Candidate candidate) => candidate.overlays.contains(overlay),
        );
      }
      if (element is StatefulElement && element.state is ScrollableState) {
        final ScrollableState state = element.state as ScrollableState;
        if (axisDirectionToAxis(state.axisDirection) == Axis.vertical &&
            (mark?.enabled ?? true)) {
          final double area = _visibleArea(state);
          if (area > 0) {
            candidates.add(
              _Candidate(
                state,
                marked: mark != null,
                indicator:
                    (mark?.indicator ?? true) && !_hasOwnScrollbar(state),
                area: area,
                overlays: List<Element>.of(overlays),
                preferred: _scrolls(state) && !_isIdleTextField(state),
              ),
            );
          }
          // A mark chooses the outermost vertical scrollable under it only;
          // one that keeps the crown off covers everything under it.
          if (mark?.enabled ?? false) {
            mark = null;
          }
        }
      }
      final bool isOverlay =
          element is StatefulElement && element.state is OverlayState;
      if (isOverlay) {
        overlays.add(element);
      }
      element.visitChildElements((Element child) => visit(child, mark));
      if (isOverlay) {
        overlays.removeLast();
      }
    }

    visit(root, null);
    // Marked scrollables first. A mark can cover a whole app (every page's
    // list then counts as marked), so the same rule picks among them.
    final List<_Candidate> marked = candidates
        .where((_Candidate candidate) => candidate.marked)
        .toList();
    return _pick(marked.isNotEmpty ? marked : candidates);
  }

  /// Among the candidates with something to scroll (and not a text field
  /// nobody is typing in), else among all: the frontmost that fills at least
  /// 40% of the screen, else the largest.
  _Candidate? _pick(List<_Candidate> candidates) {
    final List<_Candidate> preferred = candidates
        .where((_Candidate candidate) => candidate.preferred)
        .toList();
    return _pickAmong(preferred.isNotEmpty ? preferred : candidates);
  }

  _Candidate? _pickAmong(List<_Candidate> candidates) {
    if (candidates.isEmpty) {
      return null;
    }
    final double screen = _screenArea();
    for (final _Candidate candidate in candidates.reversed) {
      if (candidate.area >= 0.4 * screen) {
        return candidate;
      }
    }
    _Candidate best = candidates.first;
    for (final _Candidate candidate in candidates) {
      if (candidate.area >= best.area) {
        best = candidate;
      }
    }
    return best;
  }

  double _screenArea() {
    final Size? size = _binding?.renderViews.firstOrNull?.size;
    return size == null ? 0 : size.width * size.height;
  }

  /// How much of [state]'s viewport shows on screen, or 0 when it does not
  /// take the crown: hidden (a covered route), unlaid, or not scrollable by
  /// the user.
  double _visibleArea(ScrollableState state) {
    if (!state.mounted ||
        !TickerMode.getValuesNotifier(state.context).value.enabled) {
      return 0;
    }
    final ScrollPosition position = state.position;
    // A NestedScrollView is driven through its outer scrollable; any other
    // position the runtime cannot set (its body's, another kind) would hold
    // the crown and do nothing with it.
    final bool nested = _nestedOf(state) != null;
    if ((position is! ScrollPositionWithSingleContext && !nested) ||
        !position.hasContentDimensions ||
        !position.hasViewportDimension ||
        !position.hasPixels ||
        (!nested && !position.physics.shouldAcceptUserOffset(position))) {
      return 0;
    }
    final RenderObject? box = state.context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) {
      return 0;
    }
    // Drawn in the last frame? The viewport is a repaint boundary, and its
    // layer is in the scene only when something painted it. That covers
    // every way a scrollable can be laid out yet not shown: an IndexedStack's
    // other children, Offstage, a transparent Opacity, a page scrolled out of
    // a PageView, a route under an opaque one.
    final RenderObject? viewport = _viewportOf(box);
    if (viewport != null) {
      // ignore: invalid_use_of_protected_member
      final ContainerLayer? layer = viewport.layer;
      if (layer == null || !layer.attached) {
        return 0;
      }
    }
    // The same from above, for a scrollable without a viewport of its own.
    RenderObject child = box;
    for (
      RenderObject? parent = child.parent;
      parent != null;
      parent = parent.parent
    ) {
      if (!parent.paintsChild(child)) {
        return 0;
      }
      child = parent;
    }
    final Size? screen = _binding?.renderViews.firstOrNull?.size;
    if (screen == null) {
      return 0;
    }
    final Rect rect = MatrixUtils.transformRect(
      box.getTransformTo(null),
      Offset.zero & box.size,
    );
    final Rect shown = rect.intersect(Offset.zero & screen);
    if (shown.isEmpty) {
      return 0;
    }
    return shown.width * shown.height;
  }

  /// The NestedScrollView whose outer scrollable [state] is, if it is one.
  static NestedScrollViewState? _nestedOf(ScrollableState state) {
    if (state.position is ScrollPositionWithSingleContext) {
      return null;
    }
    final NestedScrollViewState? nested = state.context
        .findAncestorStateOfType<NestedScrollViewState>();
    if (nested == null) {
      return null;
    }
    try {
      return identical(nested.outerController.position, state.position)
          ? nested
          : null;
    } catch (_) {
      return null;
    }
  }

  /// Whether [state] has a range to scroll (an endless one counts).
  static bool _scrolls(ScrollableState state) {
    final NestedScrollViewState? nested = _nestedOf(state);
    if (nested != null) {
      final ScrollPosition? inner = _nestedBody(nested);
      final ScrollPosition outer = state.position;
      return outer.maxScrollExtent > outer.minScrollExtent ||
          (inner != null &&
              inner.hasContentDimensions &&
              inner.maxScrollExtent > inner.minScrollExtent);
    }
    final ScrollPosition position = state.position;
    return position.maxScrollExtent > position.minScrollExtent ||
        !position.maxScrollExtent.isFinite;
  }

  /// Whether [state] is a text field's own scrollable while nobody types in
  /// it: the page around it should take the crown first.
  static bool _isIdleTextField(ScrollableState state) {
    final EditableTextState? field = state.context
        .findAncestorStateOfType<EditableTextState>();
    return field != null && !field.widget.focusNode.hasFocus;
  }

  /// Whether the app wraps [state] in a scrollbar of its own (a Flutter
  /// Scrollbar or CupertinoScrollbar): watchOS's indicator would be a second.
  static bool _hasOwnScrollbar(ScrollableState state) {
    bool found = false;
    state.context.visitAncestorElements((Element element) {
      if (element is StatefulElement) {
        if (element.state is RawScrollbarState) {
          found = true;
          return false;
        }
        if (element.state is ScrollableState) {
          return false;
        }
      }
      return true;
    });
    return found;
  }

  /// The NestedScrollView body's position the crown moves: the one on screen
  /// (a TabBarView body keeps others alive), else the first.
  static ScrollPosition? _nestedBody(NestedScrollViewState nested) {
    final Iterable<ScrollPosition> positions = nested.innerController.positions;
    ScrollPosition? first;
    for (final ScrollPosition position in positions) {
      first ??= position;
      final RenderObject? box = position.context.notificationContext
          ?.findRenderObject();
      final RenderObject? viewport = box == null ? null : _viewportOf(box);
      // ignore: invalid_use_of_protected_member
      if (viewport != null && (viewport.layer?.attached ?? false)) {
        return position;
      }
    }
    return first;
  }

  /// Whether watchOS shows its scroll indicator for the scrollable driven
  /// now (`WatchCrownScroll(scrollIndicator: false)` hides it).
  bool _indicator = true;

  /// The viewport under a scrollable's render object (its first repaint
  /// boundary), within a few levels.
  static RenderObject? _viewportOf(RenderObject root) {
    RenderObject? found;
    void visit(RenderObject child, int depth) {
      if (found != null || depth > 8) {
        return;
      }
      if (child is RenderAbstractViewport) {
        found = child;
        return;
      }
      child.visitChildren((RenderObject next) => visit(next, depth + 1));
    }

    visit(root, 0);
    return found;
  }

  void _select(ScrollableState? next, {bool indicator = true}) {
    if (identical(next, _scrollable)) {
      if (indicator != _indicator) {
        _indicator = indicator;
        _described = null;
        _describe();
      }
      return;
    }
    _indicator = indicator;
    final ScrollPosition? old = _position;
    final bool wasDriving = _activity != null;
    _activity = null;
    final Drag? nestedDrag = _nestedDrag;
    _nestedDrag = null;
    if (old != null) {
      // The old scrollable may be gone already, its position disposed.
      try {
        old.removeListener(_onPosition);
        _nestedInner?.removeListener(_onPosition);
        if (wasDriving && old is ScrollPositionWithSingleContext) {
          old.goIdle();
        }
        if (nestedDrag != null) {
          _endingDrive = true;
          try {
            nestedDrag.end(DragEndDetails(primaryVelocity: 0));
          } finally {
            _endingDrive = false;
          }
        }
      } catch (_) {
        // Nothing left to release.
      }
    }
    _nested = null;
    _nestedInner = null;
    _nestedLast = null;
    _shift = 0;
    _yielded = false;
    _takeoverOffset = 0;
    _native = null;
    _windowAnchor = null;
    _seenBallistic = null;
    _lastActivity = null;
    _scrollable = next;
    _position = next?.position;
    _described = null;
    if (next == null) {
      _host.configure(null);
      return;
    }
    _position!.addListener(_onPosition);
    final NestedScrollViewState? nested = _nestedOf(next);
    if (nested != null) {
      _nested = nested;
      _nestedInner = nested.innerController..addListener(_onPosition);
    }
    _describe();
    // Stop whatever the native view was doing for the previous scrollable.
    _sync(_contentPixels(), stop: true);
  }

  /// Where the content is, in the host's terms before mirroring: the
  /// position's pixels, or a NestedScrollView's header and body together.
  double _contentPixels() {
    final ScrollPosition position = _position!;
    final NestedScrollViewState? nested = _nested;
    if (nested == null) {
      return position.pixels;
    }
    final ScrollPosition? body = _nestedBody(nested);
    return position.pixels + (body != null && body.hasPixels ? body.pixels : 0);
  }

  /// How far an endless scrollable's window reaches either side of where it
  /// was described: far beyond one crown turn, so the native view never
  /// meets the window's edge while the crown turns.
  static const double _window = 100000;

  /// The point an endless scrollable's window is centred on.
  double? _windowAnchor;

  void _describe() {
    final ScrollableState? scrollable = _scrollable;
    final ScrollPosition? position = _position;
    if (scrollable == null ||
        position == null ||
        !position.hasContentDimensions ||
        !position.hasViewportDimension ||
        !position.hasPixels) {
      return;
    }
    // An endless list (no item count, a looping wheel) has no finite range
    // to mirror; the host gets a window around the content instead, moved
    // when the content has travelled far into it and the crown is idle.
    final bool endless =
        !position.minScrollExtent.isFinite ||
        !position.maxScrollExtent.isFinite;
    final double? anchor = _windowAnchor;
    if (!endless) {
      _windowAnchor = null;
    } else if (anchor == null ||
        (_activity == null && (position.pixels - anchor).abs() > _window / 2)) {
      _windowAnchor = position.pixels;
    }
    double minExtent = position.minScrollExtent.isFinite
        ? position.minScrollExtent
        : _windowAnchor! - _window;
    double maxExtent = position.maxScrollExtent.isFinite
        ? position.maxScrollExtent
        : _windowAnchor! + _window;
    final NestedScrollViewState? nested = _nested;
    // A NestedScrollView's rows are its body's.
    ScrollableState rows = scrollable;
    if (nested != null) {
      // Header and body scroll as one: their ranges add up.
      final ScrollPosition? body = _nestedBody(nested);
      if (body != null && body.hasContentDimensions) {
        minExtent += body.minScrollExtent;
        maxExtent += body.maxScrollExtent;
      }
      final ScrollContext? bodyContext = body?.context;
      if (bodyContext is ScrollableState) {
        rows = bodyContext;
      }
    }
    final double? snapPitch = _snapPitch(position);
    final CrownDescription? described = _described;
    if (described != null &&
        described.viewport == position.viewportDimension &&
        described.minExtent == minExtent &&
        described.maxExtent == maxExtent &&
        described.indicator == _indicator &&
        described.snaps == (snapPitch != null)) {
      return;
    }
    final CrownDescription next = CrownDescription(
      viewport: position.viewportDimension,
      minExtent: minExtent,
      maxExtent: maxExtent,
      rowExtent: snapPitch ?? _rowExtent(rows) ?? described?.rowExtent ?? 44,
      indicator: _indicator,
      snaps: snapPitch != null,
    );
    if (described != null && _driving) {
      // The extent changed under a turn. The native view keeps its offset
      // from the top of its content, so its next reports would land the
      // change away from the content: count it into the shift until rest.
      _shift += _reversed
          ? described.maxExtent - maxExtent
          : described.minExtent - minExtent;
    }
    _described = next;
    _host.configure(next);
    if (described != null &&
        !_driving &&
        (_reversed || described.minExtent != minExtent)) {
      // The host's coordinates moved under the content (a reversed list's
      // end, or an endless list's window): put the native view back on it.
      _sync(_contentPixels());
    }
  }

  /// The pitch a scrollable comes to rest on, when its physics snap: a page
  /// view's page, a wheel's item. Null for free scrolling.
  static double? _snapPitch(ScrollPosition position) {
    for (
      ScrollPhysics? layer = position.physics;
      layer != null;
      layer = layer.parent
    ) {
      if (layer is PageScrollPhysics) {
        return position is PageMetrics
            ? position.viewportDimension *
                  (position as PageMetrics).viewportFraction
            : position.viewportDimension;
      }
      if (layer is FixedExtentScrollPhysics && position is FixedExtentMetrics) {
        final double? extent = _wheelExtentOf(position);
        if (extent != null) {
          return extent;
        }
      }
    }
    return null;
  }

  static double? _wheelExtentOf(ScrollPosition position) {
    final RenderObject? box = position.context.notificationContext
        ?.findRenderObject();
    RenderListWheelViewport? wheel;
    void visit(RenderObject child) {
      if (wheel != null) {
        return;
      }
      if (child is RenderListWheelViewport) {
        wheel = child;
        return;
      }
      child.visitChildren(visit);
    }

    if (box is RenderListWheelViewport) {
      return box.itemExtent;
    }
    box?.visitChildren(visit);
    return wheel?.itemExtent;
  }

  /// A reversed scrollable (a chat list) grows upwards; the native view
  /// always grows downwards, so its coordinates are mirrored.
  bool get _reversed => _scrollable?.axisDirection == AxisDirection.up;

  /// The scrollable's pixels in the host's coordinates (mirrored for a
  /// reversed list).
  double _toHost(double pixels) {
    final CrownDescription? described = _described;
    if (described == null || !_reversed) {
      return pixels;
    }
    return described.minExtent + described.maxExtent - pixels;
  }

  /// A host report in the scrollable's pixels: the mirror back, and the shift
  /// an extent change in the middle of the turn left.
  double _fromHost(double report) => _toHost(report) + _shift;

  /// The scrollable's row pitch: exact for a fixed-extent list, else the
  /// median distance from one laid-out row to the next. Only the
  /// scrollable's own rows count: not those of a scrollable nested in it (a
  /// carousel), nor of a sliver laid out on the other axis.
  static double? _rowExtent(ScrollableState scrollable) {
    final RenderObject? root = scrollable.context.findRenderObject();
    if (root == null) {
      return null;
    }
    final RenderObject? own = _viewportOf(root);
    RenderSliverMultiBoxAdaptor? list;
    double? wheelExtent;
    void visit(RenderObject child) {
      if (list != null || wheelExtent != null) {
        return;
      }
      if (child is RenderListWheelViewport) {
        wheelExtent = child.itemExtent;
        return;
      }
      if (child is RenderAbstractViewport && !identical(child, own)) {
        return;
      }
      if (child is RenderSliver && child.constraints.axis != Axis.vertical) {
        return;
      }
      if (child is RenderSliverMultiBoxAdaptor) {
        list = child;
        return;
      }
      child.visitChildren(visit);
    }

    root.visitChildren(visit);
    if (wheelExtent != null) {
      return wheelExtent;
    }
    final RenderSliverMultiBoxAdaptor? found = list;
    if (found == null) {
      return null;
    }
    if (found is RenderSliverFixedExtentBoxAdaptor &&
        found.itemExtent != null) {
      return found.itemExtent;
    }
    // The pitch, from one row's start to the next (spacing and separators
    // included), else the row height.
    final List<double> pitches = <double>[];
    final List<double> heights = <double>[];
    double? previous;
    for (
      RenderBox? child = found.firstChild;
      child != null;
      child = found.childAfter(child)
    ) {
      final ParentData? data = child.parentData;
      final double? offset = data is SliverMultiBoxAdaptorParentData
          ? data.layoutOffset
          : null;
      if (offset != null && previous != null && offset > previous) {
        pitches.add(offset - previous);
      }
      previous = offset;
      if (child.hasSize && child.size.height > 0) {
        heights.add(child.size.height);
      }
    }
    final List<double> source = pitches.isNotEmpty ? pitches : heights;
    if (source.isEmpty) {
      return null;
    }
    source.sort();
    return source[source.length ~/ 2];
  }

  /// The content moved. Unless the crown moved it, the host follows.
  void _onPosition() {
    final ScrollPosition? position = _position;
    if (_driving || position == null || !position.hasPixels) {
      return;
    }
    _sync(_contentPixels());
  }

  void _sync(double pixels, {bool stop = false}) {
    _native = pixels;
    _nestedLast = pixels;
    // The native view lands on the content: nothing left to correct.
    _shift = 0;
    _host.sync(_toHost(pixels), stop: stop);
  }

  /// The host's report, at [pixels] in the scrollable's own pixels: the
  /// native view moved (phase 1), came to rest (phase 0), or is where a crown
  /// turn starts from (phase 2, just before the turn's first move).
  @visibleForTesting
  void onNativePosition(double hostPixels, int phase) {
    if (_detached) {
      return;
    }
    if (phase == 2 && _activity == null) {
      // A turn starts: make sure it drives what is on screen now (a route
      // may have covered the list since the last look).
      final _Candidate? candidate = _findCandidate();
      final ScrollableState? found = candidate?.state;
      if (!identical(found, _scrollable)) {
        _select(found, indicator: candidate?.indicator ?? true);
        // This turn moves a view shaped like the old scrollable: sit it out;
        // its rest brings the view to the new one.
        _yielded = found != null;
        return;
      }
    }
    if (_nested != null) {
      _onNestedPosition(hostPixels, phase);
      return;
    }
    final ScrollPosition? position = _position;
    if (position is! ScrollPositionWithSingleContext || !position.hasPixels) {
      return;
    }
    final double pixels = _fromHost(hostPixels);
    if (phase == 2) {
      // A new turn: whatever the native view did before is over.
      _native = pixels;
      _yielded = false;
      return;
    }
    if (phase == 1) {
      if (_yielded || (_activity == null && _fingerDown(position))) {
        // The rest of a glide a finger stopped, or a turn while a finger
        // holds the content: the finger wins.
        _native = pixels;
        return;
      }
      _CrownDriveActivity? activity = _activity;
      if (activity == null) {
        // The crown's first step is the native view's move from where it
        // was; anything more is how far it trailed the content.
        _takeoverOffset = position.pixels - (_native ?? position.pixels);
        activity = _CrownDriveActivity(position, onEnd: _onDriveEnded);
        _activity = activity;
        position.beginActivity(activity);
      } else {
        _takeoverOffset *= _takeoverDecay;
      }
      if (_takeoverOffset.abs() < 0.25) {
        _takeoverOffset = 0;
      }
      _native = pixels;
      final double from = position.pixels;
      position.setPixels(pixels + _takeoverOffset);
      final double moved = position.pixels - from;
      activity.track(moved);
      if (moved != 0) {
        // As a drag does: listeners that hide a bar while the user scrolls
        // down react to the crown too.
        // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
        position.updateUserScrollDirection(
          moved > 0 ? ScrollDirection.reverse : ScrollDirection.forward,
        );
      }
    } else if (_yielded) {
      _yielded = false;
      // The native view stopped where the takeover began; bring it to where
      // the content is now.
      _sync(position.pixels);
    } else if (_activity != null) {
      final double offset = _takeoverOffset;
      _takeoverOffset = 0;
      _native = pixels;
      position.setPixels(pixels + offset);
      if (offset != 0 || _shift != 0) {
        // A short turn ended before the takeover blended out, or the extent
        // changed under the turn: the native view comes to the content, not
        // the other way round.
        _sync(position.pixels);
      }
      // The native view settles on its own, edge spring included, so at rest
      // it is in range and a bouncing scrollable has nothing left to animate
      // (no ballistic replays the spring). A snapping scrollable (a wheel)
      // still snaps, and content a leftover takeover offset left past an
      // edge springs back.
      _endingDrive = true;
      try {
        position.goBallistic(0);
      } finally {
        _endingDrive = false;
      }
    }
  }

  /// A host report for a NestedScrollView: each move goes into a drag of its
  /// own, which collapses the header before the body scrolls, as a finger's
  /// drag does; the rest ends the drag, which lets the header snap.
  void _onNestedPosition(double pixels, int phase) {
    final ScrollPosition? outer = _position;
    if (outer == null || !outer.hasPixels) {
      return;
    }
    if (phase == 2) {
      _nestedLast = pixels;
      _yielded = false;
      return;
    }
    if (phase == 1) {
      final double last = _nestedLast ?? pixels;
      _nestedLast = pixels;
      if (_yielded || (_nestedDrag == null && _fingerDown(outer))) {
        return;
      }
      final double delta = pixels - last;
      if (delta == 0) {
        return;
      }
      final Drag drag = _nestedDrag ??= outer.drag(
        DragStartDetails(),
        _onNestedDragEnded,
      );
      drag.update(
        DragUpdateDetails(
          globalPosition: Offset.zero,
          delta: Offset(0, -delta),
          primaryDelta: -delta,
        ),
      );
      return;
    }
    if (_yielded) {
      _yielded = false;
      _sync(_contentPixels());
      return;
    }
    final Drag? drag = _nestedDrag;
    _nestedDrag = null;
    if (drag != null) {
      _endingDrive = true;
      try {
        drag.end(DragEndDetails(primaryVelocity: 0));
      } finally {
        _endingDrive = false;
      }
    }
    // The body clamps at its ends where the native view stretched: the
    // native view comes to the content.
    _sync(_contentPixels());
  }

  /// The NestedScrollView's crown drag ended without the runtime ending it:
  /// a finger (or the app) took the content over.
  void _onNestedDragEnded() {
    if (_endingDrive || _nestedDrag == null) {
      return;
    }
    _nestedDrag = null;
    _yielded = true;
    _sync(_contentPixels(), stop: true);
  }

  /// Whether a finger is on the content (holding or dragging it).
  static bool _fingerDown(ScrollPosition position) {
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    final ScrollActivity? activity = position.activity;
    return activity is DragScrollActivity || activity is HoldScrollActivity;
  }

  void _onDriveEnded(_CrownDriveActivity ended) {
    if (!identical(_activity, ended)) {
      return;
    }
    _activity = null;
    if (_endingDrive) {
      return;
    }
    // Replaced while the crown drove: a finger touched down (on a native
    // scroll view that stops the crown's glide) or the app scrolled.
    _yielded = true;
    final ScrollPosition? position = _position;
    if (position != null && position.hasPixels) {
      _sync(position.pixels, stop: true);
    }
  }

  /// Gives a released finger the native edge on a scrollable with the
  /// platform's default physics: catches the platform's ballistic in the
  /// frame it starts, before it has moved anything, and runs the native one
  /// instead when the edge is involved.
  void _adoptBallistic() {
    final ScrollPosition? position = _position;
    if (position is! ScrollPositionWithSingleContext) {
      return;
    }
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    final ScrollActivity? activity = position.activity;
    final ScrollActivity? before = _lastActivity;
    _lastActivity = activity;
    if (activity is! BallisticScrollActivity ||
        activity is _NativeBallisticActivity ||
        identical(activity, _seenBallistic)) {
      return;
    }
    _seenBallistic = activity;
    if (!isPlatformBounce(position.physics)) {
      return;
    }
    // A finger let go: its velocity starts the native release. Any other
    // ballistic (new dimensions mid-spring) carries on with the content's
    // own velocity.
    final bool released =
        before is DragScrollActivity || before is HoldScrollActivity;
    final Simulation? simulation = nativeBallisticSimulation(
      position,
      activity.velocity,
      position.physics.toleranceFor(position),
      fingerRelease: released,
    );
    if (simulation == null) {
      return;
    }
    position.beginActivity(
      _NativeBallisticActivity(
        position,
        simulation,
        position.context.vsync,
        activity.shouldIgnorePointer,
      ),
    );
  }

  /// Whether [physics] is the platform's default: iOS bouncing at the normal
  /// rate, possibly wrapped by the framework's always-scrollable and
  /// range-maintaining layers. An app's own physics are left alone.
  @visibleForTesting
  static bool isPlatformBounce(ScrollPhysics physics) {
    bool bounce = false;
    for (ScrollPhysics? layer = physics; layer != null; layer = layer.parent) {
      final Type type = layer.runtimeType;
      if (type == BouncingScrollPhysics &&
          (layer as BouncingScrollPhysics).decelerationRate ==
              ScrollDecelerationRate.normal) {
        bounce = true;
      } else if (type != AlwaysScrollableScrollPhysics &&
          type != RangeMaintainingScrollPhysics) {
        return false;
      }
    }
    return bounce;
  }
}

class _Candidate {
  _Candidate(
    this.state, {
    required this.marked,
    required this.indicator,
    required this.area,
    required this.overlays,
    required this.preferred,
  });

  final ScrollableState state;
  final bool marked;
  final bool indicator;
  final double area;
  final List<Element> overlays;

  /// Has something to scroll and is not an idle text field's own scrollable.
  final bool preferred;
}

/// Holds a position while the native view drives it: the position follows
/// the reports one to one, overscroll included, and the scrollable's own
/// physics stay out of the way until the native view rests.
class _CrownDriveActivity extends ScrollActivity {
  _CrownDriveActivity(super.delegate, {required this.onEnd});

  final void Function(_CrownDriveActivity activity) onEnd;

  final Stopwatch _clock = Stopwatch()..start();
  double _velocity = 0;

  /// Records one report's move, for [velocity].
  void track(double moved) {
    final double seconds = _clock.elapsedMicroseconds / 1e6;
    _clock.reset();
    if (seconds > 0 && seconds < 0.2) {
      _velocity = moved / seconds;
    } else {
      _velocity = 0;
    }
  }

  @override
  void dispose() {
    onEnd(this);
    super.dispose();
  }

  /// As in any scroll in motion, a touch stops the scroll and does not reach
  /// the row under it (a native scroll view does the same).
  @override
  bool get shouldIgnorePointer => true;

  @override
  bool get isScrolling => true;

  /// How fast the crown moves the content, so that images can defer loading
  /// while it flies past (`ScrollPosition.recommendDeferredLoading`).
  @override
  double get velocity => _velocity;
}

/// The native release, told apart from the platform's.
class _NativeBallisticActivity extends BallisticScrollActivity {
  _NativeBallisticActivity(
    super.delegate,
    super.simulation,
    super.vsync,
    super.shouldIgnorePointer,
  );
}
