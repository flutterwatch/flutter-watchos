// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Contract tests for native Digital Crown scrolling: the host's hidden
// ScrollView (host/WatchCrownProxy.swift, host/FlutterHostView.swift) and the
// runtime the CLI compiles into every app (runtime/lib/). The behaviour runs
// on a watch or the Simulator and is covered there and by the runtime's own
// widget tests; these guard the SwiftUI details it was measured to depend on,
// each of which silently stopped the crown or cost it its native feel when
// it was different.

import 'dart:io' as io;

import '../src/common.dart';
import '../src/host_sources.dart';

void main() {
  final String proxy = readHostSource('WatchCrownProxy.swift');
  final String view = readHostSource('FlutterHostView.swift');
  final String runner = readHostSource('FlutterRunner.swift');
  final String runtime = io.File(
    cliRootPath('runtime/lib/watchos_crown_runtime.dart'),
  ).readAsStringSync();
  final String package = io.File(
    cliRootPath('packages/flutter_watchos/lib/src/crown_scroll.dart'),
  ).readAsStringSync();

  /// The body of the Swift type [name] in [source], up to the next top-level
  /// declaration.
  String swiftType(String source, String name) {
    final int start = source.indexOf(name);
    if (start < 0) {
      throw StateError('$name not found');
    }
    final int end = source.indexOf('\nprivate ', start + name.length);
    return source.substring(start, end < 0 ? source.length : end);
  }

  /// [source] without its `//` comments, so a comment that explains a rule
  /// does not read as breaking it.
  String code(String source) =>
      source.split('\n').map((String line) => line.replaceFirst(RegExp(r'//.*'), '')).join('\n');

  group('the hidden crown ScrollView', () {
    late final String scroll = swiftType(view, 'private struct CrownProxyScroll');

    test('is a ScrollView that takes crown focus without .focusable()', () {
      // `.focusable()` on a ScrollView hands the crown to a wrapper and the
      // scroll never moves (watchOS 26.5 Simulator).
      expect(scroll, contains('ScrollView(.vertical)'));
      expect(scroll, contains('.focused(focus)'));
      expect(code(scroll), isNot(contains('.focusable(')));
    });

    test('sits behind the frame and is never hit tested', () {
      // The crown layer is a background of the host view (the frame is
      // opaque over it), and its proxy case never takes a touch.
      final int layer = view.indexOf('// The Digital Crown. Its consumer sits behind the frame');
      expect(layer, isNonNegative);
      final int background = view.indexOf('.background {', layer);
      final int route = view.indexOf('switch crownModel.route {', background);
      expect(background, greaterThan(layer));
      expect(route, greaterThan(background));
      expect(view.substring(background, route).trim(), '.background {');
      final String proxyCase = view.substring(route, view.indexOf('case .binding:', route));
      expect(proxyCase, contains('CrownProxyScroll('));
      expect(proxyCase, contains('.allowsHitTesting(false)'));
      expect(proxyCase, contains('.frame(height: config.viewportPoints)'));
    });

    test('is shaped in equal rows that sum to the content height', () {
      // A lazy stack estimates rows it has not laid out from those it has;
      // a shorter last row left the crown resting past Flutter's end.
      expect(scroll, contains('config.contentPoints / Double(rows)'));
      expect(scroll, contains('LazyVStack(spacing: 0)'));
      // An endless or huge scrollable cannot ask for unbounded rows.
      expect(scroll, contains('min(100_000,'));
    });

    test('is in points, the scrollable in logical pixels', () {
      // FlutterWatchOSContentScale: one logical pixel is `scale` points.
      expect(proxy, contains('scale: WatchContentScale.value'));
      expect(
        proxy,
        contains('func pixels(atOrigin origin: Double) -> Double { minExtent + origin / scale }'),
      );
      expect(
        proxy,
        contains('func origin(atPixels pixels: Double) -> Double { (pixels - minExtent) * scale }'),
      );
    });

    test('follows Flutter on the next main-queue turn', () {
      // Set inside the view update, a new position does not stop a glide.
      final String follow = scroll.substring(scroll.indexOf('private func followFlutter()'));
      expect(follow, contains('DispatchQueue.main.async'));
      expect(follow, contains('position.scrollTo(y: target)'));
      expect(follow, contains('guard stop || !model.crownActive'));
    });

    test('wakes the display clock on every move and phase', () {
      expect(RegExp(r'FlutterDisplayClock\.shared\.wake\(\)').allMatches(scroll), hasLength(2));
    });

    test('shows the system crown indicator, flashed for touch scrolls', () {
      expect(scroll, contains('.scrollIndicatorsFlash(trigger: follow.indicatorFlash)'));
      // An app may hide it: WatchCrownScroll(scrollIndicator: false).
      expect(scroll, contains('.scrollIndicators(config.showsIndicator ? .automatic : .hidden)'));
      expect(code(scroll), isNot(contains('.scrollIndicators(.hidden)')));
    });

    test('rests on whole pages or items when the scrollable snaps', () {
      // A page view or a wheel: the native view settles on rows of its pitch,
      // as a native paged scroll view or picker does with the crown.
      expect(
        scroll,
        contains('.scrollTargetBehavior(CrownSnapBehavior(pitch: config.snaps ? config.rowPoints : 0))'),
      );
      final String snap = swiftType(view, 'private struct CrownSnapBehavior');
      expect(snap, contains('ScrollTargetBehavior'));
      expect(snap, contains('guard pitch > 0 else { return }'));
      expect(snap, contains('.rounded() * pitch'));
    });

    test('anchors a turn where the last follow landed', () {
      expect(scroll, contains('model.viewMoved(to: origin)'));
      expect(proxy, contains('if syncHold > 0 && !crownActive {'));
    });
  });

  group('the host view stays off the per-frame path', () {
    test('only the crown view observes what changes every frame', () {
      // FlutterHostView observes CrownProxyModel; its body must not run on
      // every frame of a touch scroll (see FlutterFrameStore).
      final String model = proxy.substring(proxy.indexOf('final class CrownProxyModel'));
      final Iterable<String> published = RegExp(
        r'@Published[^\n]*var (\w+)',
      ).allMatches(model).map((Match m) => m.group(1)!);
      expect(published.toSet(), <String>{'route', 'config'});
      final String follow = proxy.substring(
        proxy.indexOf('final class CrownProxyFollow'),
        proxy.indexOf('final class CrownProxyModel'),
      );
      expect(follow, contains('var request'));
      expect(follow, contains('var indicatorFlash'));
      expect(
        swiftType(view, 'private struct CrownProxyScroll'),
        contains('@ObservedObject private var follow = CrownProxyFollow.shared'),
      );
    });

    test('rejects a description that is not finite', () {
      expect(proxy, contains(r'allSatisfy { $0.isFinite }'));
    });

    test('closes an open turn when the crown goes elsewhere', () {
      final int change = proxy.indexOf('if nextRoute != route {');
      final String block = proxy.substring(change, proxy.indexOf('guard route == .proxy', change));
      expect(block, contains('phase: 0'));
      expect(block, contains('origin = nil'));
    });

    test('gives crown focus back after the keyboard', () {
      final int field = view.indexOf('textInput.endEditing()');
      expect(view.indexOf('case .proxy: crownProxyFocused = true', field), greaterThan(field));
      // The focus change above never fires on watchOS: Done and a tap
      // outside give the focus back themselves.
      final int submit = view.indexOf('textInput.submitEditing()');
      expect(view.indexOf('restoreCrownFocus()', submit), greaterThan(submit));
      expect(
        RegExp(r'textInput\.endEditing\(\)\s*restoreCrownFocus\(\)').hasMatch(view),
        isTrue,
      );
      final String restore = view.substring(view.indexOf('private func restoreCrownFocus()'));
      expect(restore, contains(r'case .proxy: focusSoon($crownProxyFocused)'));
      expect(restore, contains(r'case .binding: focusSoon($isFocused)'));
    });
  });

  group('crown routing', () {
    test('only one crown consumer exists at a time', () {
      // A second consumer next to the native view, even unfocused and silent,
      // cost it its haptics on a Series 10.
      expect(view, contains('case .proxy:'));
      expect(view, contains('case .binding:'));
      expect(view, contains('case .none:'));
      expect(RegExp(r'\.digitalCrownRotation\(').allMatches(view), hasLength(1));
      expect(swiftType(view, 'private struct CrownBinding'), contains('.digitalCrownRotation('));
    });

    test('only the raw crown goes to the engine binding', () {
      // Native scrolling is the only crown scrolling: no switch, key or
      // fallback leads back to the engine's scroll model.
      expect(proxy, contains('"flutter_watchos_crown_mode"'));
      expect(proxy, contains('nextRoute = .binding'));
      expect(RegExp(r'nextRoute = \.binding').allMatches(proxy), hasLength(1));
      for (final source in <String>[proxy, view, runner]) {
        expect(source, isNot(contains('FLUTTER_WATCHOS_CROWN_SCROLL')));
        expect(source, isNot(contains('FlutterWatchOSCrownScroll"')));
      }
    });

    test('the runner hands the crown its position before each frame', () {
      final int tick = runner.indexOf('CrownProxyModel.shared.tick()');
      final int vsync = runner.indexOf('FlutterWatchOSHostNotifyVsync()', tick);
      expect(tick, isNonNegative);
      expect(vsync, greaterThan(tick));
    });
  });

  group('runtime <-> host', () {
    test('every C entry point the runtime looks up is exported by the host', () {
      final Iterable<String> looked = RegExp(
        r"'(FlutterWatchOSCrownProxy\w+)'",
      ).allMatches(runtime).map((Match m) => m.group(1)!);
      expect(looked.toSet(), hasLength(3));
      for (final symbol in looked) {
        expect(proxy, contains('@_cdecl("$symbol")'), reason: symbol);
      }
    });

    test('a crown turn reports where it starts before it moves', () {
      final int start = proxy.indexOf('phase: 2)');
      final int move = proxy.indexOf('phase: 1)', start);
      expect(start, isNonNegative);
      expect(move, greaterThan(start));
      expect(runtime, contains('if (phase == 2)'));
    });

    test('following Flutter closes an open crown turn', () {
      // Without the rest report, a runtime that yielded to a finger waits for
      // a rest that never comes and the next turn finds the crown dead.
      final int accepted = proxy.indexOf('if stop || !crownActive {');
      final int rest = proxy.indexOf(
        'bridge.report(config.pixels(atOrigin: origin), phase: 0)',
        accepted,
      );
      final int hold = proxy.indexOf('syncHold = max(syncHold, 3)', accepted);
      expect(accepted, isNonNegative);
      expect(rest, greaterThan(accepted));
      expect(hold, greaterThan(accepted));
      expect(runtime, contains('_fingerDown(position)'));
    });

    test('the runtime and the host agree on the description', () {
      expect(runtime, contains('Void Function(Int32, Double, Double, Double, Double, Int32, Int32)'));
      expect(proxy, contains('_ maxExtent: Double, _ rowExtent: Double, _ indicator: Int32,'));
      expect(proxy, contains('_ snaps: Int32'));
    });

    test("the mark's options are the ones the runtime reads", () {
      for (final key in <String>["'enabled'", "'scrollIndicator'"]) {
        expect(package, contains(key));
        expect(runtime, contains('data[$key]'));
      }
    });

    test("WatchCrownScroll's mark is the one the runtime looks for", () {
      String mark(String source, String name) =>
          RegExp("$name = '([^']+)'").firstMatch(source)!.group(1)!;
      expect(mark(package, '_crownScrollMarker'), mark(runtime, 'crownScrollMarker'));
    });
  });
}
