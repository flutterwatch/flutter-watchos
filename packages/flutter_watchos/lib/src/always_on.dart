// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'watchos_ffi_bindings.dart';
import 'watchos_info_platform.dart' as platform;

/// The watchOS **Always-On** display state — whether the wrist is down and the
/// system is showing the app dimmed rather than blanking the screen.
///
/// Always On is enabled by default for every app (watchOS 8+), and the watch
/// host keeps the last rendered frame on screen, so a Flutter app already stays
/// visible with the wrist lowered. What this API adds is the ability to *react*
/// to it, which the watchOS Human Interface Guidelines expect:
///
/// * stop animations, tickers, and timers — they burn battery for a display
///   nobody is looking at,
/// * hide anything private, since the screen is visible to bystanders,
/// * drop bright, large fills of colour in favour of a darker, sparser layout.
///
/// Read it once:
///
/// ```dart
/// if (WatchAlwaysOn.isActive) { /* wrist is down */ }
/// ```
///
/// …or rebuild on every change with [WatchAlwaysOnBuilder]:
///
/// ```dart
/// WatchAlwaysOnBuilder(
///   builder: (context, alwaysOn, _) => alwaysOn
///       ? const _DimmedFace()     // static, dark, no private data
///       : const _LiveFace(),      // the full UI
/// )
/// ```
///
/// ## Relationship to app lifecycle
///
/// The app-lifecycle channel is not a substitute for this: watchOS also
/// resigns active for a notification banner or Control Center, so
/// `AppLifecycleState.inactive` cannot distinguish "wrist down" from "something
/// is covering the app". The state here comes from SwiftUI's
/// `\.isLuminanceReduced`, which means exactly the former.
///
/// The two do travel together, though — dimming and resigning active happen at
/// the same moment, in no guaranteed order. That has one practical
/// consequence: **do not read [isActive] from inside your own
/// `didChangeAppLifecycleState`.** At that instant the host may not have
/// reported yet, so a one-shot read can see the pre-transition value. Listen to
/// [state] (or use [WatchAlwaysOnBuilder]) and let it settle instead:
///
/// ```dart
/// // Wrong — races the host, may read the old value:
/// void didChangeAppLifecycleState(AppLifecycleState s) {
///   if (WatchAlwaysOn.isActive) pauseAnimation();
/// }
///
/// // Right — fires once the state is known, both entering and leaving:
/// WatchAlwaysOn.state.addListener(() {
///   WatchAlwaysOn.state.value ? pauseAnimation() : resumeAnimation();
/// });
/// ```
///
/// Registering [state] does not interfere with your own lifecycle observers;
/// they keep receiving every state as usual.
///
/// An app that would rather blank than dim opts out in its `Info.plist` with
/// `WKSupportsAlwaysOnDisplay` = `false`; [isActive] then never becomes true.
///
/// On non-watchOS platforms [isActive] reads `false` and [state] never changes,
/// so this is safe in cross-platform code.
abstract final class WatchAlwaysOn {
  static WatchOSNativeBindings? _bindings;

  static WatchOSNativeBindings get _native => _bindings ??= platform.isWatch
      ? WatchOSNativeBindings()
      : WatchOSNativeBindings.forTesting();

  /// Test seam: inject fake bindings and drop any listened-to state.
  @visibleForTesting
  static set bindingsOverride(WatchOSNativeBindings? bindings) {
    _state?.dispose();
    _state = null;
    _bindings = bindings;
  }

  /// Whether the display is dimmed right now (the wrist is down).
  static bool get isActive => _native.alwaysOnActive;

  /// Whether the running watch host reports Always-On state at all.
  ///
  /// False off-watch, and false for an app built by a CLI whose host module
  /// predates this bridge — there [isActive] stays `false` because nothing is
  /// reporting, not because the display is lit. Apps that adapt their layout
  /// don't need this; apps that want to *tell the user* the feature is
  /// unavailable do.
  static bool get isSupported => _native.alwaysOnSupported;

  static _AlwaysOnNotifier? _state;

  /// The Always-On state as a listenable, for apps that react outside the
  /// widget tree (pausing a controller, cancelling a timer). Prefer
  /// [WatchAlwaysOnBuilder] inside `build`.
  ///
  /// The listenable is shared and lives for the process; listeners must be
  /// removed when their owner is disposed, as with any long-lived listenable.
  static ValueListenable<bool> get state => _state ??= _AlwaysOnNotifier();
}

/// Tracks [WatchAlwaysOn.isActive] and notifies on change.
///
/// The native flag is written by the watch host and cannot wake Dart on its
/// own, so this samples it — but only when the state could plausibly change.
/// Reading the flag on the lifecycle event alone would be cheaper but racy:
/// the resign-active notification and the SwiftUI environment update are not
/// ordered with respect to each other, so a lifecycle-only read can miss the
/// transition by a few milliseconds and then stay stale until the *next*
/// lifecycle change — potentially minutes.
///
/// **Both edges race**, and they race the same way. Lowering the wrist pairs
/// resign-active with the dimming; raising it pairs become-active with the
/// brightening — and in each pair the order is not guaranteed. So every
/// lifecycle change, in either direction, opens a short burst of fast samples.
/// The burst is what actually closes the race, and it deliberately lands in the
/// moment right after the lifecycle event, while the app is still being
/// scheduled normally: once watchOS has settled into the Always-On state it
/// keeps the app running but is free to fire its timers less often, and after
/// about two minutes frontmost apps drop to the background entirely.
///
/// After the burst a slow trickle continues while the app is away from
/// `resumed` (a watchOS that dims noticeably later than it resigns active) or
/// while the state reads dimmed. That second condition is deliberate
/// asymmetry: a stuck `false` costs an app one missed dimming, while a stuck
/// `true` leaves it showing its degraded Always-On layout on a lit screen
/// indefinitely. Sampling until dimmed goes away makes that unrecoverable case
/// self-heal.
class _AlwaysOnNotifier extends ValueNotifier<bool> with WidgetsBindingObserver {
  _AlwaysOnNotifier() : super(WatchAlwaysOn.isActive) {
    WidgetsFlutterBinding.ensureInitialized().addObserver(this);
    _lifecycle = WidgetsBinding.instance.lifecycleState;
    _reschedule();
  }

  /// Sample spacing during the burst that follows a lifecycle change…
  static const Duration _fastInterval = Duration(milliseconds: 250);

  /// …how many samples that burst is (12 × 250ms = 3s)…
  static const int _burstSamples = 12;

  /// …and the backstop spacing afterwards.
  static const Duration _slowInterval = Duration(seconds: 1);

  AppLifecycleState? _lifecycle;

  /// Samples left in the current burst. Counted rather than timed: a
  /// wall-clock deadline would be invisible to the very timers that drive the
  /// sampling, so it could not be tested — and a burst whose length no test
  /// can observe is a burst nobody can show still works.
  ///
  /// Zero at construction, so merely touching [WatchAlwaysOn.state] never
  /// opens a burst — off watchOS, where lifecycle changes may never arrive,
  /// that would leave timers running for nothing.
  int _burstLeft = 0;
  Timer? _timer;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    _burstLeft = _burstSamples;
    // Read immediately: when the host wins the race this is already correct and
    // the burst finds nothing to do.
    _sync();
    _reschedule();
  }

  void _sync() => value = WatchAlwaysOn.isActive;

  /// Arms the next sample, or none at all.
  void _reschedule() {
    _timer?.cancel();
    _timer = null;
    final Duration? delay = _nextDelay();
    if (delay == null) return;
    _timer = Timer(delay, () {
      _sync();
      _reschedule();
    });
  }

  /// When to sample next — null to stop. Consumes one burst sample.
  ///
  /// Stopping requires all three: an exhausted burst, a known-`resumed` app,
  /// and a lit display. An unknown lifecycle (null — nothing reported yet, and
  /// the normal case off watchOS) never trickles on its own.
  Duration? _nextDelay() {
    if (_burstLeft > 0) {
      _burstLeft--;
      return _fastInterval;
    }
    if (value) return _slowInterval;
    if (_lifecycle != null && _lifecycle != AppLifecycleState.resumed) {
      return _slowInterval;
    }
    return null;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

/// Rebuilds when the watch enters or leaves the dimmed Always-On state.
///
/// ```dart
/// WatchAlwaysOnBuilder(
///   builder: (context, alwaysOn, child) => alwaysOn
///       ? const Text('—')
///       : LiveHeartRate(child: child),
///   child: const HeartIcon(),   // built once, reused across both branches
/// )
/// ```
///
/// Off watchOS `alwaysOn` is always `false`, so a cross-platform widget tree
/// simply always takes the lit branch.
class WatchAlwaysOnBuilder extends StatelessWidget {
  /// Creates a builder driven by [WatchAlwaysOn.state].
  const WatchAlwaysOnBuilder({super.key, required this.builder, this.child});

  /// Called with the current Always-On state whenever it changes.
  final Widget Function(BuildContext context, bool alwaysOn, Widget? child)
      builder;

  /// An optional subtree that does not depend on the state, built once and
  /// passed back to [builder].
  final Widget? child;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: WatchAlwaysOn.state,
        builder: builder,
        child: child,
      );
}
