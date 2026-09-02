// The FlutterWatchOS host view — the whole Flutter UI as one SwiftUI view,
// identical for every app. The app template's `App.swift` shows it:
//
//     WindowGroup { FlutterHostView() }
//
// 32-bit watches (Series 4–8 / SE) are unsupported; this file is compiled out
// for that slice (the app template shows its own fallback screen instead).
#if !arch(arm64_32)
import SwiftUI

/// Displays the running Flutter app: the engine-rendered frames plus the
/// native overlays that ride them (text-input proxies, platform views) and
/// the input plumbing (touches, Digital Crown).
///
/// While the engine boots — around 600 ms on a watch — the view shows a launch
/// placeholder and fades it out once Flutter's first frame is on screen. See
/// `init(splashScreen:)`.
public struct FlutterHostView<Splash: View>: View {
    @ObservedObject var runner = FlutterRunner.shared
    // The engine publishes the text-field rects; this is a pure mirror of them.
    @ObservedObject var textInput = WatchTextInput.shared
    // Likewise for platform-view slots (rects + view types).
    @ObservedObject var platformViews = WatchPlatformViews.shared
    // And for the accessibility elements.
    @ObservedObject var accessibility = WatchAccessibility.shared
    // Always-On: true while the wrist is down and watchOS is showing the app
    // dimmed. Readable only here — it is a SwiftUI environment value, with no
    // WatchKit equivalent — so the host forwards it to Dart (WatchAlwaysOn).
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @State private var crownValue: Double = 0.0
    @FocusState private var isFocused: Bool
    // Which text-field proxy (by semantics node id) currently holds focus.
    @FocusState private var focusedField: Int32?
    // Per-gesture cache of the frame drag's ownership decision (nil = no
    // active drag). See the simultaneousGesture below.
    @State private var dragOwnedByNative: Bool?
    /// Drives the placeholder's removal. Separate from
    /// `runner.displayingFlutterUI` so the fade can be opened explicitly with
    /// `withAnimation`: the flag flips inside the display-tick update that
    /// also publishes the first frame, and an implicit `.animation(_:value:)`
    /// does not reliably animate across that transaction — measured as a hard
    /// cut on device-shaped content rather than a fade.
    @State private var splashVisible = true
    /// Held over the screen until the engine's first frame lands.
    private let splashScreen: Splash

    /// Shows `splashScreen` from launch and cross-fades it away once Flutter
    /// has drawn its first frame — the watchOS shape of
    /// `FlutterViewController.splashScreenView` on iOS.
    ///
    ///     FlutterHostView { MyLaunchScreen() }
    ///
    /// Pass `EmptyView()` to opt out and let the app come up on bare black.
    public init(@ViewBuilder splashScreen: () -> Splash) {
        self.splashScreen = splashScreen()
    }

    public var body: some View {
        GeometryReader { _ in
            Group {
                if let frame = runner.frame {
                    Image(decorative: frame, scale: runner.pixelRatio)
                        .resizable()
                        .frame(width: runner.sizePoints.width, height: runner.sizePoints.height)
                } else {
                    // Nothing rendered yet. The launch placeholder at the
                    // bottom of this chain covers the gap; this is only the
                    // ground beneath it.
                    Color.black
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // MUST be simultaneous, not exclusive: on real hardware an
            // exclusive zero-distance drag wins the gesture arena against the
            // internal gestures of overlaid native controls (a SwiftUI Toggle
            // stopped responding mid-screen on a physical watch; fine on the
            // simulator, where taps carry no micro-movement). Simultaneity
            // means this gesture also sees touches that belong to the native
            // side — `nativeOwnsTouch` drops them so Flutter content behind a
            // slot never ghost-fires and a tapped proxy field is not
            // immediately unfocused.
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        // Decide ownership ONCE per gesture, at touch-down.
                        // Slot rects move while Flutter scrolls; re-checking
                        // against live rects can flip the answer mid-drag and
                        // strand Flutter with a pointer that never ends.
                        let owned = dragOwnedByNative ?? {
                            let o = nativeOwnsTouch(at: value.startLocation)
                            dragOwnedByNative = o
                            return o
                        }()
                        if owned { return }
                        runner.touch(at: value.location, ended: false)
                    }
                    .onEnded { value in
                        let owned = dragOwnedByNative
                            ?? nativeOwnsTouch(at: value.startLocation)
                        dragOwnedByNative = nil
                        if owned { return }
                        runner.touch(at: value.location, ended: true)
                        // The tap landed outside every native overlay and proxy
                        // field. For a tap (small drag distance), drop focus:
                        // clear SwiftUI focus AND tell the engine to unfocus.
                        // The watchOS keyboard often clears `focusedField`
                        // itself when it closes, leaving the Flutter field
                        // still focused with nothing to clear it; the explicit
                        // `endEditing()` (idempotent) covers that. Scrolls/pans
                        // (large translation) leave focus alone.
                        let dragDistance = hypot(value.translation.width,
                                                 value.translation.height)
                        if dragDistance < 8 {
                            focusedField = nil
                            textInput.endEditing()
                        }
                    }
            )
            .focusable()
            .focused($isFocused)
            .digitalCrownRotation(
                $crownValue,
                from: -10000.0,
                through: 10000.0,
                by: 0.05,
                sensitivity: .high,
                isContinuous: true,
                // Must stay false with this fine `by:` step: the system crown
                // haptic fires once per detent and, at by:0.05, floods the
                // Taptic Engine and stutters the scroll on real hardware. The
                // detent click is played by the runner instead (see
                // FlutterWatchOSCrownSetTickCallback).
                isHapticFeedbackEnabled: false
            )
            .onChange(of: crownValue) { oldValue, newValue in
                runner.sendCrownDelta(newValue - oldValue)
            }
            // Platform views (underlay layer). Slots whose widget chose
            // `layer: .belowFlutter` sit UNDER the frame image; the Flutter
            // scene keeps a transparent hole at their rect (the frame CGImage
            // carries alpha), so Flutter content painted above the widget —
            // dialogs, snackbars, badges — draws ON TOP of the native view.
            // Touches never reach an underlay view (the frame image above
            // owns them; interaction is handled in Dart), so hit-testing is
            // disabled outright to keep routing deterministic.
            .background {
                platformViewGroup(platformViews.slots.filter(\.belowFrame))
                    .allowsHitTesting(false)
            }
            // Platform views (overlay layer, the default). The native view
            // registered for each slot's viewType is overlaid on the Flutter
            // frame at the rect the engine publishes (tracking
            // scroll/animation via semantics). Overlay views sit ABOVE all
            // Flutter content and consume touches inside their rect; the
            // text-input proxies (next overlay) stay above them.
            .overlay {
                platformViewGroup(platformViews.slots.filter { !$0.belowFrame })
            }
            // Text entry. A near-transparent native field is overlaid on each
            // Flutter text field (`textInput.fields`). Because it is present
            // from the start, the user's first tap lands on it → the system
            // keyboard opens immediately (masked for `obscured` fields),
            // pre-filled with the field's current value.
            .overlay {
                ForEach(textInput.fields) { field in
                    // Each proxy binds to its own field value, so two fields
                    // can't mix data. SecureField for obscured fields, TextField
                    // otherwise.
                    let textBinding = Binding(
                        get: { textInput.text(for: field.id) },
                        set: { textInput.setText($0, for: field.id) }
                    )
                    proxy(isObscured: field.isObscured, text: textBinding)
                        .focused($focusedField, equals: field.id)
                        .submitLabel(.done)
                        // Keyboard Done. IMPORTANT: @FocusState never fires on
                        // watchOS, so `focusedField` is nil here and the
                        // onChange path below never runs — the submit must be
                        // sent to the engine directly. (The nil-set stays for a
                        // future watchOS where FocusState works; endEditing
                        // after submitEditing is a no-op.)
                        .onSubmit {
                            textInput.submitEditing()
                            focusedField = nil
                        }
                        // Make the proxy effectively invisible while keeping it
                        // tappable AND keyboard-raising. watchOS will NOT present the
                        // keyboard for a field it considers hidden — `.opacity(0)`,
                        // `.hidden()`, `.mask`, `.colorMultiply` all focus the field
                        // but suppress the keyboard. A *near-zero* opacity (0.02) is
                        // still "visible" to the system (keyboard works) yet renders
                        // the faint system fill at 2% — invisible in practice over the
                        // Flutter field. `.foregroundStyle/.tint(.clear)` additionally
                        // clear the text + cursor. `contentShape` keeps the full rect
                        // tappable regardless of opacity (opacity doesn't affect hit
                        // testing).
                        .textFieldStyle(.plain)
                        .foregroundStyle(.clear)
                        .tint(.clear)
                        .opacity(0.02)
                        // The frame must match the engine's field rect exactly, or
                        // the native tap area would be larger than the visible
                        // Flutter field.
                        .frame(width: field.rect.width, height: field.rect.height)
                        .contentShape(Rectangle())
                        .position(x: field.rect.midX, y: field.rect.midY)
                        // VoiceOver already handles the proxy natively — it is
                        // a real TextField — but it was created with an empty
                        // label, so it would read as an anonymous "text field".
                        // Name it from the Flutter node's own semantics; the
                        // accessibility overlay below deliberately does NOT
                        // synthesize an element for text fields, so this is the
                        // one thing VoiceOver finds there.
                        .modifier(A11yTextFieldSemantics(
                            element: accessibility.element(for: field.id)))
                }
            }
            // Accessibility. One invisible element per Flutter
            // semantics node, at the rect the engine publishes — the whole
            // reason assistive technology can read a Flutter watch app at all,
            // since the UI itself reaches the screen as a single decorative
            // image.
            // Above the platform views (their native content is accessible on
            // its own and the engine publishes no element over it) and above
            // the proxy fields, so element order matches what is drawn.
            //
            // Placed whenever semantics are on, not only under VoiceOver —
            // Switch Control, the Accessibility Inspector and XCUITest read the
            // same tree, and watchOS cannot report that they are running.
            .overlay {
                ForEach(accessibility.placedElements) { element in
                    WatchA11yElementView(element: element)
                }
                // These views exist only to carry semantics — VoiceOver
                // reaches them through the accessibility tree, never through
                // hit testing. Without this they would cover the whole screen
                // and swallow direct touches meant for the Flutter frame.
                .allowsHitTesting(false)
            }
            .onChange(of: focusedField) { _, newValue in
                if let id = newValue {
                    textInput.beginEditing(id)
                } else {
                    textInput.endEditing()
                }
            }
        }
        .ignoresSafeArea()
        // The engine's frame clock. Must be attached wherever the Flutter
        // surface is on screen; see EngineVsyncClock for why it looks like
        // nothing.
        .background { EngineVsyncClock() }
        // Safe area. The Flutter surface is deliberately full-bleed (above),
        // but Dart still has to KNOW which edges the system occupies — the
        // clock at the top and the display's own curvature all round — or
        // `SafeArea` insets by nothing and content sits under the clock.
        //
        // This overlay exists only to measure. It must stay OUTSIDE the
        // `.ignoresSafeArea()` above: a GeometryReader that ignores the safe
        // area reports all zeros, and one inside a ScrollView reports zero
        // top/bottom (the scroll view turns the safe area into a content
        // inset). Both were measured on the Simulator — either mistake ships
        // the exact bug this fixes, silently.
        //
        // `Color.clear` in an overlay is still hit-testable, hence
        // `allowsHitTesting(false)`; and an overlay never affects the layout
        // of the view it covers, so the frame image and the gesture
        // coordinate space are untouched.
        .overlay {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { runner.reportSafeArea(proxy.safeAreaInsets) }
                    .onChange(of: proxy.safeAreaInsets) { _, insets in
                        runner.reportSafeArea(insets)
                    }
            }
            .allowsHitTesting(false)
        }
        // Launch placeholder. Flutter's rendering is asynchronous — the engine
        // reaches its first frame around 600 ms after launch — so something has
        // to hold the screen until then or the app comes up empty. This is the
        // watchOS shape of `FlutterViewController.splashScreenView` on iOS:
        // shown from launch, faded out over 0.2 s (iOS uses the same duration)
        // once the first frame is on screen, then removed from the hierarchy.
        //
        // `FlutterHostView()` defaults to black — what watchOS itself draws
        // behind the app icon while launching — so the handover from the system
        // launch screen to Flutter is invisible. watchOS has no launch
        // storyboard, so there is nothing to load a default from the way
        // `loadDefaultSplashScreenView` does from `UILaunchStoryboardName`.
        //
        // Gated on `displayingFlutterUI`, never on `runner.frame`: see the
        // property's own note for why the frame image cannot serve here.
        .overlay {
            ZStack {
                if splashVisible {
                    splashScreen
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                }
            }
            // Full-bleed like the Flutter surface itself: a launch screen
            // inset by the clock and the display curvature would not line up
            // with the frame it hands over to.
            .ignoresSafeArea()
            // A splash that covers the screen must not eat the first tap on
            // the live app during the fade.
            .allowsHitTesting(false)
        }
        .onChange(of: runner.displayingFlutterUI, initial: true) { _, displaying in
            guard displaying, splashVisible else { return }
            withAnimation(.easeOut(duration: 0.2)) { splashVisible = false }
        }
        // System time visibility. Default: VISIBLE (the watchOS HIG
        // expectation). Apps opt into hiding it from Dart via
        // `WatchStatusBar.hidden = true` (package:flutter_watchos) — e.g. for
        // games or full-bleed UIs; there is no system API to reposition the
        // clock, so a custom placement means hiding it and drawing your own.
        .modifier(SystemTimeHidden(hidden: runner.statusBarHidden))
        // Always-On. With the wrist lowered watchOS keeps the frontmost app on
        // screen at reduced luminance, and dims this view's frame image for us,
        // so nothing has to change for the app to stay visible. What Dart can't
        // see on its own is that it HAPPENED: this environment value is the only
        // public signal, and it exists solely inside SwiftUI. Report it so
        // `WatchAlwaysOn` can pause animations and hide private content, per the
        // watchOS HIG.
        //
        // `initial: true` matters twice over: it seeds the state for an app
        // launched straight into the dimmed state (raise-to-wake off, a
        // complication tap), and the report itself is how Dart learns this host
        // reports at all (WatchAlwaysOn.isSupported).
        .onChange(of: isLuminanceReduced, initial: true) { _, reduced in
            runner.reportAlwaysOn(reduced)
        }
        .onAppear {
            FlutterRunner.shared.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isFocused = true
            }
        }
    }

    /// Whether a touch beginning at `point` belongs to the native side: a
    /// visible overlay platform view (native controls own their taps) or a
    /// text-input proxy (the field handles focus itself — ending editing here
    /// would close the keyboard the tap just opened). Underlay platform views
    /// are NOT native-owned: they sit below the frame and their interaction
    /// is handled in Dart.
    private func nativeOwnsTouch(at point: CGPoint) -> Bool {
        if platformViews.slots.contains(where: { slot in
            slot.visible && !slot.belowFrame && slot.rect.contains(point)
        }) {
            return true
        }
        return textInput.fields.contains { $0.rect.contains(point) }
    }

    /// The native views for a group of platform-view slots, each positioned
    /// at its engine-published rect (shared by the underlay and overlay
    /// layers above). An invisible slot (culled: scrolled out, covered by a
    /// route) is hidden with opacity, NOT removed from the hierarchy —
    /// removal would destroy the native view's @State (a toggle would reset
    /// while a dialog is open); the registry contract is "keep the native
    /// view alive but hidden".
    @ViewBuilder
    private func platformViewGroup(_ slots: [WatchPlatformViewSlot]) -> some View {
        ForEach(slots) { slot in
            if let native = WatchPlatformViewRegistry.view(
                   for: slot.viewType, params: slot.params) {
                native
                    // The frame must match the widget's slot exactly; clipped
                    // so an oversized native view cannot spill over
                    // surrounding Flutter content.
                    .frame(width: slot.rect.width, height: slot.rect.height)
                    .clipped()
                    // The WHOLE slot is a native hit surface (the documented
                    // contract), including any transparent parts of the view.
                    .contentShape(Rectangle())
                    .position(x: slot.rect.midX, y: slot.rect.midY)
                    .opacity(slot.visible ? 1 : 0)
                    .allowsHitTesting(slot.visible)
            }
        }
    }

    /// The native input control for a field — SecureField (masked) when obscured,
    /// otherwise a plain TextField — bound to that field's engine-owned state.
    @ViewBuilder
    private func proxy(isObscured: Bool, text: Binding<String>) -> some View {
        if isObscured {
            SecureField("", text: text)
        } else {
            TextField("", text: text)
        }
    }
}

extension FlutterHostView where Splash == Color {
    /// The host view with the default launch placeholder: plain black, which
    /// is what watchOS draws behind the app icon while the app launches, so
    /// nothing visibly changes until Flutter's first frame arrives.
    ///
    ///     WindowGroup { FlutterHostView() }
    public init() {
        self.init { Color.black }
    }
}

/// Gives the engine the display's own clock.
///
/// watchOS has no `CADisplayLink` (`API_UNAVAILABLE(watchos)`, checked in the
/// SDK header, not assumed), so without this the engine has no way to know when
/// the panel refreshes and falls back to `VsyncWaiterFallback`: a phase fixed
/// at engine boot, then a posted task every 1/60 s forever. That grid and the
/// panel's are unrelated clocks that drift against each other, so finished
/// frames are handed to the compositor at a walking offset from the display's
/// latch point.
///
/// Measured on a Series 10 before this existed: frame delivery p99 of 21.4 ms
/// against native's 17.2 ms, worst case two whole refresh periods — while
/// raster needed 2.3 ms of a 16.67 ms budget. Judder with 13 ms of headroom,
/// which no amount of faster rasterizing would have fixed.
///
/// `TimelineView(.animation)` is the one display-synced schedule SwiftUI vends
/// on this platform, and it is a good one: 300 consecutive entries measured
/// 16.665 ms p50 / 17.22 ms p99.
///
/// Two deliberate choices:
///
///  * **`Color.clear` inside a `.background`.** The tick IS the payload —
///    nothing is drawn. Wrapping the frame image (let alone the whole host
///    view, with its platform-view, proxy-field and accessibility overlays) in
///    the TimelineView would re-evaluate all of it sixty times a second for no
///    visual result.
///  * **`onChange` rather than calling from `body`.** One call per schedule
///    entry, with no reliance on how often SwiftUI chooses to evaluate a view
///    body. (The engine tolerates extra calls — a tick with no frame pending
///    is a no-op — but relying on that would be relying on luck.)
///
/// In Always-On the schedule drops to a low frequency by itself and the engine
/// simply produces fewer frames, which is exactly right for a screen nobody is
/// looking at.
private struct EngineVsyncClock: View {
    var body: some View {
        TimelineView(.animation) { context in
            Color.clear
                .onChange(of: context.date) { _, _ in
                    // Present first, then ask. Show the frame that is ready
                    // for THIS refresh, then let the engine start the next —
                    // the other order would hand the engine a head start it
                    // cannot use and delay the picture by a refresh.
                    //
                    // Both go through the runner, like every other engine call
                    // this file makes: the C module is imported by
                    // FlutterRunner, and a Swift import is per-FILE, not
                    // per-module, so calling the symbol here would not compile.
                    FlutterRunner.shared.presentLatestFrame()
                    FlutterRunner.shared.notifyVsync()
                }
        }
        .allowsHitTesting(false)
    }
}

/// Hides the system status bar (the clock) only when the app asked for it.
/// watchOS has no public API for this; `_statusBarHidden()` is SwiftUI SPI,
/// so it is applied ONLY on explicit opt-in (`WatchStatusBar.hidden = true`)
/// — the default path never touches it and keeps the time visible.
private struct SystemTimeHidden: ViewModifier {
    let hidden: Bool
    func body(content: Content) -> some View {
        if hidden {
            content._statusBarHidden()
        } else {
            content
        }
    }
}
#endif  // !arch(arm64_32)
