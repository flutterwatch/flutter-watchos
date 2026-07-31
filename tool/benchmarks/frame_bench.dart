// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// A drop-in frame-timing probe for measuring a watchOS app on real hardware.
//
// Copy this file into your app's `lib/` and call [installFrameBench] from
// `main()`:
//
// ```dart
// void main() {
//   WidgetsFlutterBinding.ensureInitialized();
//   installFrameBench();
//   runApp(const MyApp());
// }
// ```
//
// It prints one line per window and a running total, which `flutter-watchos
// logs` (or `devicectl … --console`) picks up:
//
// ```
// BENCH window 7  n=120  fps=60.0 duty=0.61 OK  build p50=0.42 p90=0.50  raster p50=9.69 p90=11.61
// BENCH TOTAL windows=7 n=840  build p50=0.44 … raster p50=9.66 p90=11.96 p99=13.50
// ```
//
// Everything is aggregated in-process. Do not read these numbers over a live
// DevTools connection on a watch: streaming a timeline puts compression and
// polling work on the same small CPU and inflates exactly what you are
// measuring. Run it, then read the log.
//
// See doc/benchmarking.md for how to interpret the output, and why a
// Simulator number is not a device number.

import 'dart:ui' show FramePhase;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Frames per reported window (~2s at 60fps).
///
/// Short on purpose. A watch dims its display a few seconds after the wrist
/// drops and the frame rate collapses, so a window has to fit inside one
/// wrist-raise to be usable at all.
const int kWindowFrames = 120;

/// Frames dropped at the start of every window.
///
/// The first frames after a display wake are not representative, and windows
/// restart after each report, so this re-warms rather than warming once.
const int kWarmupFrames = 30;

/// A window arriving at this rate is healthy whatever its duty cycle.
const double kHealthyFps = 45.0;

/// Fraction of the frame interval that must be accounted for by real build +
/// raster work for a *slow* window to count.
const double kHealthyDuty = 0.5;

/// Starts collecting frame timings. Safe to call once, early in `main()`.
void installFrameBench() {
  final _FrameStats stats = _FrameStats();
  SchedulerBinding.instance.addTimingsCallback((List<FrameTiming> timings) {
    for (final FrameTiming timing in timings) {
      stats.add(timing);
    }
  });
}

class _FrameStats {
  final List<double> _build = <double>[];
  final List<double> _raster = <double>[];

  // Frames from windows that ran at full rate, pooled across the run. Dimmed
  // windows are thrown away rather than averaged in, so a run only has to
  // catch a few seconds of real rendering to produce a usable number.
  final List<double> _healthyBuild = <double>[];
  final List<double> _healthyRaster = <double>[];

  int _seen = 0;
  int _window = 0;
  int _healthyWindows = 0;
  int? _firstVsyncUs;
  int _lastRasterUs = 0;

  void add(FrameTiming timing) {
    _seen++;
    if (_seen <= kWarmupFrames) {
      return;
    }
    _firstVsyncUs ??= timing.timestampInMicroseconds(FramePhase.vsyncStart);
    _lastRasterUs = timing.timestampInMicroseconds(FramePhase.rasterFinish);
    _build.add(timing.buildDuration.inMicroseconds / 1000.0);
    _raster.add(timing.rasterDuration.inMicroseconds / 1000.0);
    if (_build.length >= kWindowFrames) {
      _report();
    }
  }

  void _report() {
    _window++;
    final int spanUs = _lastRasterUs - (_firstVsyncUs ?? _lastRasterUs);
    final double fps =
        spanUs > 0 ? _build.length / (spanUs / 1000000.0) : double.nan;
    _build.sort();
    _raster.sort();

    // Frame rate alone cannot tell "the display dimmed" from "this app is too
    // heavy for 60fps" — both are slow. What separates them is where the time
    // went. A dimmed window is mostly idle: ~1fps with a few ms of work in
    // each frame. A shader-bound window is saturated: 13fps with ~78ms of work
    // per frame, which is a real measurement and must not be discarded. So the
    // second test is whether the work accounts for the interval.
    //
    // Both halves are load-bearing. Keying on frame rate alone throws away
    // every window of a genuinely slow app; keying on duty alone throws away
    // every window of a fast one, because an app comfortably inside its budget
    // is idle most of the frame by definition.
    final double intervalMs = fps > 0 ? 1000.0 / fps : double.infinity;
    final double workMs = _percentile(_build, 50) + _percentile(_raster, 50);
    final double duty = intervalMs > 0 ? workMs / intervalMs : 0.0;
    final bool healthy = fps >= kHealthyFps || duty >= kHealthyDuty;

    if (healthy) {
      _healthyWindows++;
      _healthyBuild.addAll(_build);
      _healthyRaster.addAll(_raster);
    }

    debugPrint('BENCH window $_window  n=${_build.length}  '
        'fps=${fps.toStringAsFixed(1)} duty=${duty.toStringAsFixed(2)} '
        '${healthy ? "OK" : "DEGRADED"}  '
        'build p50=${_fmt(_build, 50)} p90=${_fmt(_build, 90)}  '
        'raster p50=${_fmt(_raster, 50)} p90=${_fmt(_raster, 90)}');

    if (healthy) {
      final List<double> build = List<double>.of(_healthyBuild)..sort();
      final List<double> raster = List<double>.of(_healthyRaster)..sort();
      debugPrint('BENCH TOTAL windows=$_healthyWindows n=${build.length}  '
          'build p50=${_fmt(build, 50)} p90=${_fmt(build, 90)} '
          'p99=${_fmt(build, 99)}  '
          'raster p50=${_fmt(raster, 50)} p90=${_fmt(raster, 90)} '
          'p99=${_fmt(raster, 99)}');
    }

    _build.clear();
    _raster.clear();
    _firstVsyncUs = null;
    _seen = 0;
  }

  /// [sorted] must already be sorted ascending.
  double _percentile(List<double> sorted, int percent) {
    if (sorted.isEmpty) {
      return 0;
    }
    return sorted[((sorted.length - 1) * percent / 100).round()];
  }

  String _fmt(List<double> sorted, int percent) =>
      _percentile(sorted, percent).toStringAsFixed(2);
}
