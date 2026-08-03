// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Contract tests for the watchOS accessibility (VoiceOver) overlay in the
// FlutterWatchOS host module. All the semantics — which nodes become elements,
// how label/value/hint read, which traits apply, which actions dispatch — live
// in the ENGINE (WatchOSAccessibilityCore, unit-tested in the engine repo);
// the host is a pure mirror that places an invisible SwiftUI view per
// engine-published element and carries the accessibility modifiers, because
// SwiftUI is the only accessibility API watchOS offers.
//
// These guard the host invariants that behaviour depends on: that the mirror
// stays a mirror (no policy re-growing here), that every element actually
// carries its label/value/hint/traits/actions, and that text fields and
// platform views are not double-exposed.

import '../src/common.dart';
import '../src/host_sources.dart';

void main() {
  final String runner = readHostSource('FlutterRunner.swift');
  final String view = readHostSource('FlutterHostView.swift');
  final String a11y = readHostSource('WatchAccessibility.swift');
  final String bridge = readHostSource('flutter_watchos_host.h');

  group('watchOS accessibility C ABI (flutter_watchos_host.h)', () {
    test('declares the element struct and the full bridge ABI', () {
      expect(bridge, contains('FlutterWatchOSA11yElement'));
      for (final symbol in <String>[
        'FlutterWatchOSA11yCopyElements',
        'FlutterWatchOSA11yGeneration',
        'FlutterWatchOSA11ySetChangeCallback',
        'FlutterWatchOSA11yGetLabel',
        'FlutterWatchOSA11yGetValue',
        'FlutterWatchOSA11yGetHint',
        'FlutterWatchOSA11yGetIdentifier',
        'FlutterWatchOSA11yGetCustomActionLabel',
        'FlutterWatchOSA11yFocusGained',
        'FlutterWatchOSA11yFocusLost',
        'FlutterWatchOSA11yPerformAction',
        'FlutterWatchOSA11yPerformCustomAction',
      ]) {
        expect(bridge, contains(symbol));
      }
    });

    test('carries the traits and actions the host has to map', () {
      for (final trait in <String>[
        'kFlutterWatchOSA11yTraitButton',
        'kFlutterWatchOSA11yTraitHeader',
        'kFlutterWatchOSA11yTraitLink',
        'kFlutterWatchOSA11yTraitImage',
        'kFlutterWatchOSA11yTraitSelected',
        'kFlutterWatchOSA11yTraitStaticText',
        'kFlutterWatchOSA11yTraitUpdatesFrequently',
        'kFlutterWatchOSA11yTraitNotEnabled',
        'kFlutterWatchOSA11yTraitAdjustable',
        'kFlutterWatchOSA11yTraitTextField',
        'kFlutterWatchOSA11yTraitToggle',
        'kFlutterWatchOSA11yTraitKeyboardKey',
      ]) {
        expect(bridge, contains(trait));
      }
      for (final action in <String>[
        'kFlutterWatchOSA11yActionTap',
        'kFlutterWatchOSA11yActionLongPress',
        'kFlutterWatchOSA11yActionScrollUp',
        'kFlutterWatchOSA11yActionScrollDown',
        'kFlutterWatchOSA11yActionIncrease',
        'kFlutterWatchOSA11yActionDecrease',
        'kFlutterWatchOSA11yActionDismiss',
      ]) {
        expect(bridge, contains(action));
      }
    });

    test('the element struct keeps the fields the overlay needs', () {
      // sort_priority pins VoiceOver's reading order to Flutter's traversal
      // order; `hidden` marks a scrolled-off element (focusing it makes the
      // engine scroll it into view); `enabled` becomes SwiftUI's .disabled.
      for (final field in <String>[
        'int32_t node_id;',
        'uint32_t traits;',
        'int32_t actions;',
        'int32_t custom_action_count;',
        'double sort_priority;',
        'uint64_t content_version;',
        'bool hidden;',
        'bool enabled;',
      ]) {
        expect(bridge, contains(field));
      }
    });
  });

  group('watchOS accessibility — the host stays a mirror', () {
    test('starts the mirror after the engine is running', () {
      expect(runner, contains('WatchAccessibility.startMirroring()'));
    });

    test('re-copies on the engine change callback, gated by generation', () {
      expect(a11y, contains('FlutterWatchOSA11ySetChangeCallback'));
      expect(a11y, contains('FlutterWatchOSA11yCopyElements'));
      expect(a11y, contains('FlutterWatchOSA11yGeneration'));
      expect(a11y, contains('generation == lastGeneration'));
    });

    test('holds no policy about what is accessible', () {
      // Focusability, label/value composition, trait derivation, and action
      // validation are all engine-side so they reach EXISTING apps with the
      // next engine, and so they stay identical to the iOS bridge.
      expect(a11y, isNot(contains('isFocusable')));
      expect(a11y, isNot(contains('tooltip')));
      expect(a11y, isNot(contains('scopesRoute')));
      expect(a11y, isNot(contains('hasImplicitScrolling')));
    });

    test('converts engine rects into SwiftUI points', () {
      expect(a11y, contains('WatchContentScale.toDisplay'));
    });

    test('re-reads element strings only when the engine says they changed', () {
      // A scroll republishes every element every frame with new rects and
      // identical strings. Without the content-version cache the mirror
      // crossed the ABI four times per element per frame and allocated a
      // Swift String for each — measured as almost the whole cost of the
      // bridge.
      expect(a11y, contains('hit.version == element.content_version'));
      expect(a11y, contains('stringCache'));
      // Equality drives SwiftUI rebuilds; the version stands in for the
      // strings so a moving element does not re-compare five of them.
      expect(a11y, contains('a.contentVersion == b.contentVersion'));
      expect(a11y, isNot(contains('a.label == b.label')));
    });
  });

  group('watchOS accessibility — the elements VoiceOver reads', () {
    test('each element carries its label, value, hint and identifier', () {
      expect(a11y, contains('.accessibilityLabel(element.label)'));
      expect(a11y, contains('.accessibilityValue(element.value)'));
      expect(a11y, contains('.accessibilityHint(element.hint)'));
      expect(a11y, contains('.accessibilityIdentifier(element.identifier)'));
    });

    test('traits map onto SwiftUI, and disabled becomes .disabled', () {
      expect(a11y, contains('.accessibilityAddTraits(element.swiftUITraits)'));
      // SwiftUI has no notEnabled trait; a disabled Flutter control has to
      // read as "dimmed" the way a disabled native control does.
      expect(a11y, contains('.disabled(!element.isEnabled)'));
    });

    test('reading order follows Flutter traversal order, not geometry', () {
      // Every element is absolutely positioned, so without an explicit
      // priority SwiftUI would order them geometrically.
      expect(a11y, contains('.accessibilitySortPriority(element.sortPriority)'));
    });

    test('focus is reported back so Flutter can scroll and track it', () {
      expect(a11y, contains('.accessibilityFocused('));
      expect(a11y, contains('focusGained(element.id)'));
      expect(a11y, contains('focusLost(element.id)'));
    });

    test('actions are attached only when the node offers them', () {
      // An unconditional action would advertise a control the app does not
      // have — VoiceOver would offer "activate" on a plain label.
      expect(a11y, contains('if element.offers(kFlutterWatchOSA11yActionTap)'));
      expect(a11y, contains('accessibilityAdjustableAction'));
      expect(a11y, contains('accessibilityScrollAction'));
      expect(a11y, contains('accessibilityAction(.escape)'));
      expect(a11y, contains('performCustomAction'));
    });
  });

  group('watchOS accessibility — no double exposure', () {
    test('text fields are named on their proxy, not given a second element',
        () {
      // The text-input overlay already places a real native TextField there;
      // a synthesized element on top would shadow it, and the proxy alone
      // would read as an anonymous "text field".
      expect(a11y, contains(r'elements.filter { !$0.isTextField }'));
      expect(view, contains('accessibility.placedElements'));
      expect(view, contains('A11yTextFieldSemantics'));
    });

    test('the frame image is never an accessibility element', () {
      // `Image(decorative:)` is what keeps VoiceOver from announcing the whole
      // Flutter UI as one picture.
      expect(view, contains('Image(decorative: frame'));
    });
  });
}
