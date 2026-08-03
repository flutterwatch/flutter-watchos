// The watchOS accessibility overlay — the host half of the bridge whose engine
// half is documented in flutter_watchos_accessibility.h.
//
// The Flutter UI reaches the screen as one software-rendered image, which
// VoiceOver sees as a single decorative picture, and watchOS offers no UIKit
// accessibility-element API (every element property of UIAccessibility is
// API_UNAVAILABLE(watchos)). SwiftUI's accessibility modifiers ARE supported,
// so the bridge does what the text-input and platform-view overlays already do:
// the engine publishes a flat list of elements — rect, label, value, hint,
// traits, actions — and this file places one invisible SwiftUI view per element
// at its rect, carrying those modifiers. Assistive technology then reads and
// drives the Flutter UI as if the elements were native views, and everything the
// user does comes back as a SemanticsAction.
//
// Elements are placed whenever semantics are on, never only under VoiceOver:
// Switch Control, AssistiveTouch, the Accessibility Inspector and XCUITest all
// navigate the same tree with VoiceOver off, and watchOS exposes no way to
// detect them (every UIAccessibilityIs*Running query is unavailable there), so
// a gate would exclude them permanently. This matches the iOS shell, which
// builds its element tree whenever semantics are enabled.
#if !arch(arm64_32)
import Foundation
import CoreGraphics
import SwiftUI

import FlutterWatchOSHostC

/// One accessibility element, positioned in SwiftUI points. A pure mirror of
/// the engine's element list — this type holds no policy, only what to say and
/// what can be done.
struct WatchA11yElement: Identifiable, Equatable {
    let id: Int32
    let rect: CGRect
    let label: String
    let value: String
    let hint: String
    let identifier: String
    let traits: UInt32
    let actions: Int32
    let customActions: [String]
    /// Descending: pins VoiceOver's reading order to Flutter's traversal
    /// order. Without it SwiftUI orders these absolutely-positioned overlays
    /// geometrically, which scrambles anything that is not a plain top-to-
    /// bottom column.
    let sortPriority: Double
    let isEnabled: Bool
    /// Moves only when the strings above change. Rects move every frame while
    /// the user scrolls, so this is what lets the mirror keep the strings it
    /// already has instead of re-reading four of them per element per frame.
    let contentVersion: UInt64

    // Equality drives whether SwiftUI is asked to rebuild. Comparing
    // contentVersion instead of the five string fields is exactly equivalent —
    // it moves if and only if one of them did — and avoids a pile of string
    // compares on the main thread every frame.
    static func == (a: WatchA11yElement, b: WatchA11yElement) -> Bool {
        a.id == b.id && a.rect == b.rect && a.traits == b.traits
            && a.actions == b.actions && a.sortPriority == b.sortPriority
            && a.isEnabled == b.isEnabled && a.contentVersion == b.contentVersion
    }

    // The C constants import as `Int`; the conversion is kept here rather
    // than at every call site.
    func offers(_ action: Int) -> Bool { actions & Int32(action) != 0 }
    func has(trait: Int) -> Bool { traits & UInt32(trait) != 0 }

    /// A Flutter text field. The host places no element for these — the
    /// text-input overlay already puts a real native field there — so this is
    /// the one trait the view layer has to ask about by name.
    var isTextField: Bool { has(trait: kFlutterWatchOSA11yTraitTextField) }

    /// The SwiftUI traits for this element. `notEnabled` and `adjustable` have
    /// no SwiftUI trait: the first is applied as `.disabled`, the second as an
    /// adjustable action.
    var swiftUITraits: AccessibilityTraits {
        var result = AccessibilityTraits()
        let mapping: [(Int, AccessibilityTraits)] = [
            (kFlutterWatchOSA11yTraitButton, .isButton),
            (kFlutterWatchOSA11yTraitHeader, .isHeader),
            (kFlutterWatchOSA11yTraitLink, .isLink),
            (kFlutterWatchOSA11yTraitImage, .isImage),
            (kFlutterWatchOSA11yTraitSelected, .isSelected),
            (kFlutterWatchOSA11yTraitStaticText, .isStaticText),
            (kFlutterWatchOSA11yTraitUpdatesFrequently, .updatesFrequently),
            (kFlutterWatchOSA11yTraitToggle, .isToggle),
            (kFlutterWatchOSA11yTraitKeyboardKey, .isKeyboardKey),
        ]
        for (trait, swiftUITrait) in mapping where has(trait: trait) {
            result.formUnion(swiftUITrait)
        }
        return result
    }
}

/// Thin, app-independent adapter for watchOS accessibility — identical for
/// every app. It mirrors the engine's element list and forwards focus and
/// actions; it holds no app logic and makes no decisions about what is
/// accessible.
final class WatchAccessibility: ObservableObject {
    static let shared = WatchAccessibility()

    /// The elements to place, kept in sync with the engine via the change
    /// callback registered in `start()`.
    @Published var elements: [WatchA11yElement] = []

    /// Generation last copied from the engine; unchanged means skip the copy.
    private var lastGeneration: UInt64 = 0

    /// Strings already read for a node, keyed by node id and tagged with the
    /// engine's content version. A scroll republishes every element every
    /// frame with new rects but identical strings, so without this the mirror
    /// crossed the ABI four times per element per frame and allocated a Swift
    /// String for each — measured as almost the entire cost of the bridge.
    private struct CachedStrings {
        let version: UInt64
        let label: String
        let value: String
        let hint: String
        let identifier: String
        let customActions: [String]
    }
    private var stringCache: [Int32: CachedStrings] = [:]

    fileprivate func start() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        FlutterWatchOSA11ySetChangeCallback({ context in
            guard let context else { return }
            let me = Unmanaged<WatchAccessibility>.fromOpaque(context)
                .takeUnretainedValue()
            DispatchQueue.main.async { me.reload() }
        }, ctx)
        reload()
    }

    /// Pull the current element list from the engine. Main thread.
    private func reload() {
        let generation = FlutterWatchOSA11yGeneration()
        if generation != 0 && generation == lastGeneration { return }
        lastGeneration = generation
        let count = Int(FlutterWatchOSA11yCopyElements(nil, 0))
        var buffer = [FlutterWatchOSA11yElement](
            repeating: FlutterWatchOSA11yElement(), count: max(count, 0))
        let written = buffer.withUnsafeMutableBufferPointer { ptr in
            Int(FlutterWatchOSA11yCopyElements(ptr.baseAddress, Int32(ptr.count)))
        }
        var cache: [Int32: CachedStrings] = [:]
        cache.reserveCapacity(written)
        let next = buffer.prefix(written).map { element -> WatchA11yElement in
            let id = element.node_id
            // Re-read the strings only when the engine says they changed.
            let strings: CachedStrings
            if let hit = stringCache[id], hit.version == element.content_version {
                strings = hit
            } else {
                strings = CachedStrings(
                    version: element.content_version,
                    label: String(cString: FlutterWatchOSA11yGetLabel(id)),
                    value: String(cString: FlutterWatchOSA11yGetValue(id)),
                    hint: String(cString: FlutterWatchOSA11yGetHint(id)),
                    identifier: String(cString: FlutterWatchOSA11yGetIdentifier(id)),
                    customActions: (0..<element.custom_action_count).map { index in
                        String(cString: FlutterWatchOSA11yGetCustomActionLabel(
                            id, index))
                    })
            }
            cache[id] = strings
            return WatchA11yElement(
                id: id,
                // Engine rects are logical points; overlays place in SwiftUI
                // points (they differ under FlutterWatchOSContentScale).
                rect: WatchContentScale.toDisplay(
                    CGRect(x: element.x, y: element.y,
                           width: element.width, height: element.height)),
                label: strings.label,
                value: strings.value,
                hint: strings.hint,
                identifier: strings.identifier,
                traits: element.traits,
                actions: element.actions,
                customActions: strings.customActions,
                sortPriority: element.sort_priority,
                isEnabled: element.enabled,
                contentVersion: element.content_version)
        }
        // Rebuilt from the live set, so vanished nodes do not accumulate.
        stringCache = cache
        if next != elements { elements = next }
    }

    // The handlers are pure pass-throughs to the engine, which validates every
    // action against the node that is actually in the tree.
    func focusGained(_ id: Int32) { FlutterWatchOSA11yFocusGained(id) }
    func focusLost(_ id: Int32) { FlutterWatchOSA11yFocusLost(id) }
    @discardableResult
    func perform(_ action: Int, on id: Int32) -> Bool {
        FlutterWatchOSA11yPerformAction(id, Int32(action))
    }
    @discardableResult
    func performCustomAction(_ index: Int, on id: Int32) -> Bool {
        FlutterWatchOSA11yPerformCustomAction(id, Int32(index))
    }

    /// The elements the host places itself: everything except the text fields,
    /// which VoiceOver reaches through the text-input overlay's native proxy.
    var placedElements: [WatchA11yElement] {
        elements.filter { !$0.isTextField }
    }

    /// The element for a semantics node, when one is published. Used by the
    /// text-input overlay to name its proxy field.
    func element(for nodeId: Int32) -> WatchA11yElement? {
        elements.first { $0.id == nodeId }
    }

    /// Called by FlutterRunner once the engine is up.
    static func startMirroring() { shared.start() }
}

/// Names a text-input proxy from its Flutter semantics node. VoiceOver reads
/// the native field itself — it is a real TextField — so all it is missing is
/// what the field is FOR, which only the Flutter side knows. A nil element
/// (VoiceOver off, or an engine that predates the bridge) leaves the field
/// exactly as it was.
struct A11yTextFieldSemantics: ViewModifier {
    let element: WatchA11yElement?

    func body(content: Content) -> some View {
        if let element {
            content
                .accessibilityLabel(element.label)
                .accessibilityValue(element.value)
                .accessibilityHint(element.hint)
                .accessibilitySortPriority(element.sortPriority)
        } else {
            content
        }
    }
}

/// The invisible SwiftUI view that represents one Flutter semantics node to
/// VoiceOver. It draws nothing — the pixels are already in the frame image
/// underneath — and exists purely to carry the accessibility modifiers at the
/// right rect.
struct WatchA11yElementView: View {
    let element: WatchA11yElement
    @AccessibilityFocusState private var isFocused: Bool

    var body: some View {
        Color.clear
            .frame(width: max(element.rect.width, 1),
                   height: max(element.rect.height, 1))
            .contentShape(Rectangle())
            .accessibilityElement()
            .accessibilityLabel(element.label)
            .accessibilityValue(element.value)
            .accessibilityHint(element.hint)
            .accessibilityIdentifier(element.identifier)
            .accessibilityAddTraits(element.swiftUITraits)
            .accessibilityFocused($isFocused)
            // Focus is what tells Flutter which node the user is on — whatever
            // is driving it, screen reader or switch. The framework needs it
            // for its own a11y focus tracking, and an element the framework
            // culled (scrolled off) is scrolled back into view by the engine
            // when it is focused.
            .onChange(of: isFocused) { _, focused in
                if focused {
                    WatchAccessibility.shared.focusGained(element.id)
                } else {
                    WatchAccessibility.shared.focusLost(element.id)
                }
            }
            .modifier(A11yOptionalActions(element: element))
            // A disabled Flutter control reads as "dimmed", exactly as a
            // disabled native control does; SwiftUI has no notEnabled trait.
            .disabled(!element.isEnabled)
            .accessibilitySortPriority(element.sortPriority)
            .position(x: element.rect.midX, y: element.rect.midY)
    }
}

/// The actions that only some elements offer. Split into a modifier because
/// SwiftUI's accessibility actions are attached unconditionally — a
/// `.accessibilityAdjustableAction` on a node with no increase/decrease would
/// advertise a control the app does not have.
private struct A11yOptionalActions: ViewModifier {
    let element: WatchA11yElement

    func body(content: Content) -> some View {
        content
            .modifier(A11yActivate(element: element))
            .modifier(A11yAdjustable(element: element))
            .modifier(A11yNamedActions(element: element))
            .modifier(A11yScroll(element: element))
            .modifier(A11yDismiss(element: element))
            .modifier(A11yCustomActions(element: element))
    }
}

/// Activation — VoiceOver's double-tap. Attached only when the node offers a
/// tap, so a plain label is not announced as activatable.
private struct A11yActivate: ViewModifier {
    let element: WatchA11yElement

    func body(content: Content) -> some View {
        if element.offers(kFlutterWatchOSA11yActionTap) {
            content.accessibilityAction {
                WatchAccessibility.shared.perform(
                    kFlutterWatchOSA11yActionTap, on: element.id)
            }
        } else {
            content
        }
    }
}

/// Dismissible content (a sheet, a snackbar) — VoiceOver's escape gesture,
/// the same mapping the iOS bridge makes with accessibilityPerformEscape.
private struct A11yDismiss: ViewModifier {
    let element: WatchA11yElement

    func body(content: Content) -> some View {
        if element.offers(kFlutterWatchOSA11yActionDismiss) {
            content.accessibilityAction(.escape) {
                WatchAccessibility.shared.perform(
                    kFlutterWatchOSA11yActionDismiss, on: element.id)
            }
        } else {
            content
        }
    }
}

/// Sliders and steppers: VoiceOver's swipe up/down becomes increase/decrease.
private struct A11yAdjustable: ViewModifier {
    let element: WatchA11yElement

    func body(content: Content) -> some View {
        if element.offers(kFlutterWatchOSA11yActionIncrease)
            || element.offers(kFlutterWatchOSA11yActionDecrease) {
            content.accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    WatchAccessibility.shared.perform(
                        kFlutterWatchOSA11yActionIncrease, on: element.id)
                case .decrement:
                    WatchAccessibility.shared.perform(
                        kFlutterWatchOSA11yActionDecrease, on: element.id)
                @unknown default:
                    break
                }
            }
        } else {
            content
        }
    }
}

/// The standard Flutter actions VoiceOver has no gesture for. They go into the
/// actions rotor under a name, which is how a UIKit app surfaces the same ones.
private struct A11yNamedActions: ViewModifier {
    let element: WatchA11yElement

    // Deliberately the wording VoiceOver itself uses for these on iOS, so a
    // user hears the same phrase in a Flutter watch app as anywhere else.
    private static let named: [(action: Int, name: LocalizedStringKey)] = [
        (kFlutterWatchOSA11yActionLongPress, "Long Press"),
        (kFlutterWatchOSA11yActionExpand, "Expand"),
        (kFlutterWatchOSA11yActionCollapse, "Collapse"),
    ]

    func body(content: Content) -> some View {
        Self.named.reduce(AnyView(content)) { view, entry in
            guard element.offers(entry.action) else { return view }
            return AnyView(view.accessibilityAction(named: entry.name) {
                WatchAccessibility.shared.perform(entry.action, on: element.id)
            })
        }
    }
}

/// Scrollables: VoiceOver's three-finger scroll on the element.
private struct A11yScroll: ViewModifier {
    let element: WatchA11yElement

    func body(content: Content) -> some View {
        if element.offers(kFlutterWatchOSA11yActionScrollUp)
            || element.offers(kFlutterWatchOSA11yActionScrollDown)
            || element.offers(kFlutterWatchOSA11yActionScrollLeft)
            || element.offers(kFlutterWatchOSA11yActionScrollRight) {
            content.accessibilityScrollAction { edge in
                // A scroll toward an edge moves the content the other way,
                // which is the direction Flutter's action names.
                let action: Int
                switch edge {
                case .top: action = kFlutterWatchOSA11yActionScrollDown
                case .bottom: action = kFlutterWatchOSA11yActionScrollUp
                case .leading: action = kFlutterWatchOSA11yActionScrollRight
                case .trailing: action = kFlutterWatchOSA11yActionScrollLeft
                }
                WatchAccessibility.shared.perform(action, on: element.id)
            }
        } else {
            content
        }
    }
}

/// `CustomSemanticsAction`s, in the actions rotor under their own labels.
private struct A11yCustomActions: ViewModifier {
    let element: WatchA11yElement

    func body(content: Content) -> some View {
        // ForEach cannot build modifiers, and the list is short (an app that
        // attaches more than a handful is already unusable under VoiceOver),
        // so they are folded on one at a time.
        element.customActions.enumerated().reduce(AnyView(content)) { view, entry in
            let (index, label) = entry
            return AnyView(view.accessibilityAction(named: Text(label)) {
                WatchAccessibility.shared.performCustomAction(index, on: element.id)
            })
        }
    }
}
#endif  // !arch(arm64_32)
