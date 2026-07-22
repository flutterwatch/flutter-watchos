// The FlutterWatchOS host module — generic glue around the Flutter engine,
// identical for every app. The flutter-watchos CLI compiles this module at
// build time and stages it into the app's `watchos/Flutter/` directory; the
// app's own `App.swift` only does `import FlutterWatchOS` and shows
// `FlutterHostView()`.
//
// 32-bit watches (Series 4–8 / SE) are unsupported; the Flutter host is
// compiled out for that slice and the app shows an info screen instead (see
// the app template's App.swift).
#if !arch(arm64_32)
import Foundation
import CoreGraphics
import SwiftUI
import WatchKit

import FlutterWatchOSHostC

/// One native text-field overlay, positioned in SwiftUI points. FlutterHostView
/// places an invisible proxy over each so the first tap on a Flutter TextField
/// raises the system keyboard (masked when `isObscured`).
struct WatchProxyField: Identifiable, Equatable {
    let id: Int32
    let rect: CGRect
    let isObscured: Bool
}

/// Thin, app-independent adapter for watchOS text input — identical for every
/// app. It keeps the native proxy fields in sync and forwards focus and edits;
/// it holds no app logic.
final class WatchTextInput: ObservableObject {
    static let shared = WatchTextInput()

    /// The fields to overlay, kept in sync with the engine via the change
    /// callback registered in `start()`.
    @Published var fields: [WatchProxyField] = []

    /// Generation last copied from the engine; an unchanged generation means
    /// nothing changed since the previous copy, so `reload()` skips the work.
    private var lastGeneration: UInt64 = 0

    fileprivate func start() {
        // The engine invokes this (on its platform thread) whenever the field
        // list or any field's text changes; hop to main and refresh.
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        FlutterWatchOSTextInputSetChangeCallback({ context in
            guard let context else { return }
            let me = Unmanaged<WatchTextInput>.fromOpaque(context)
                .takeUnretainedValue()
            DispatchQueue.main.async { me.reload() }
        }, ctx)
        reload()
    }

    /// Pull the current field list from the engine. Main thread.
    private func reload() {
        let generation = FlutterWatchOSTextInputGeneration()
        if generation != 0 && generation == lastGeneration { return }
        lastGeneration = generation
        let count = Int(FlutterWatchOSTextInputCopyFields(nil, 0))
        var buffer = [FlutterWatchOSProxyField](
            repeating: FlutterWatchOSProxyField(), count: max(count, 0))
        let written = buffer.withUnsafeMutableBufferPointer { ptr in
            Int(FlutterWatchOSTextInputCopyFields(ptr.baseAddress, Int32(ptr.count)))
        }
        let next = buffer.prefix(written).map { f in
            WatchProxyField(
                id: f.node_id,
                // Engine rects are logical points; overlays place in SwiftUI
                // points (they differ under FlutterWatchOSContentScale).
                rect: WatchContentScale.toDisplay(
                    CGRect(x: f.x, y: f.y, width: f.width, height: f.height)),
                isObscured: f.obscured)
        }
        if next != fields { fields = next }
    }

    // The proxy bindings/handlers are pure pass-throughs to the engine.
    func text(for id: Int32) -> String {
        String(cString: FlutterWatchOSTextInputGetText(id))
    }
    func setText(_ text: String, for id: Int32) {
        FlutterWatchOSTextInputSetText(id, text)
    }
    func beginEditing(_ id: Int32) { FlutterWatchOSTextInputBeginEditing(id) }
    /// Keyboard Done: the engine delivers TextInputAction.done (onSubmitted
    /// fires; the framework unfocuses the field and closes the connection).
    func submitEditing() { FlutterWatchOSTextInputSubmitEditing() }
    func endEditing() { FlutterWatchOSTextInputEndEditing() }
}

/// One platform view, positioned in SwiftUI points. FlutterHostView renders the
/// native view registered for `viewType` at `rect` — above the frame image
/// (classic overlay) or, when `belowFrame`, under it (the Flutter scene has a
/// transparent hole there, so Flutter content can draw on top of the view).
struct WatchPlatformViewSlot: Identifiable, Equatable {
    let id: Int64
    let viewType: String
    let params: String
    let rect: CGRect
    let visible: Bool
    let belowFrame: Bool
}

/// The app's native platform-view factories, keyed by the `viewType` used by
/// the Dart `WatchPlatformView` widget (package:flutter_watchos). Register in
/// the App initializer, BEFORE the Flutter host appears:
///
///     WatchPlatformViewRegistry.register("my-gauge") { params in
///         AnyView(MyGaugeView(params: params))
///     }
///
/// `params` is the widget's `creationParams` string (by convention JSON). A
/// `viewType` with no registered factory renders nothing.
public enum WatchPlatformViewRegistry {
    private static var factories: [String: (String) -> AnyView] = [:]

    /// Registers (or replaces) the factory for a view type. Main thread.
    public static func register(_ viewType: String,
                                factory: @escaping (String) -> AnyView) {
        factories[viewType] = factory
    }

    /// Builds the native view for a slot; nil when the type is unregistered.
    static func view(for viewType: String, params: String) -> AnyView? {
        factories[viewType].map { $0(params) }
    }
}

/// C entry point through which PLUGINS register platform-view factories.
///
/// A federated watchOS plugin can ship SwiftUI view sources (`watchos/**.swift`
/// next to its FFI classes); the CLI compiles them into the app and the
/// plugin's Dart `registerWith()` triggers registration, which lands here.
/// Plugin code resolves this symbol via `dlsym` — never a compile-time import —
/// so a plugin built for a newer CLI still links against an app created by an
/// older one (its views just don't appear, matching
/// `WatchPlatformView.isSupported` semantics).
///
/// `factory` receives (viewType, creationParams) as C strings and returns a
/// RETAINED object conforming to SwiftUI's `View` (nil to render nothing).
/// The registration itself hops to the main thread, where the registry lives.
@_cdecl("FlutterWatchOSPlatformViewRegisterNativeFactory")
public func FlutterWatchOSPlatformViewRegisterNativeFactory(
    _ viewType: UnsafePointer<CChar>?,
    _ factory: (@convention(c) (
        UnsafePointer<CChar>?, UnsafePointer<CChar>?
    ) -> UnsafeMutableRawPointer?)?
) {
    guard let viewType, let factory else { return }
    let type = String(cString: viewType)
    DispatchQueue.main.async {
        WatchPlatformViewRegistry.register(type) { params in
            let raw = type.withCString { t in
                params.withCString { p in factory(t, p) }
            }
            guard let raw else { return AnyView(EmptyView()) }
            let object = Unmanaged<AnyObject>.fromOpaque(raw).takeRetainedValue()
            guard let view = object as? any View else { return AnyView(EmptyView()) }
            func erase(_ v: some View) -> AnyView { AnyView(v) }
            return erase(view)
        }
    }
}

/// Thin, app-independent adapter for watchOS platform views — a pure mirror
/// of the engine-published slot list, exactly like WatchTextInput above. All
/// geometry (scroll tracking, culling, hot-restart cleanup) is engine-side.
final class WatchPlatformViews: ObservableObject {
    static let shared = WatchPlatformViews()

    /// The platform views to overlay, kept in sync with the engine via the
    /// change callback registered in `start()`.
    @Published var slots: [WatchPlatformViewSlot] = []

    /// Generation last copied from the engine; unchanged means skip the copy.
    private var lastGeneration: UInt64 = 0

    fileprivate func start() {
        // The engine invokes this (on the thread that mutated the registry)
        // whenever a view is created/disposed or a rect changes; hop to main
        // and refresh.
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        FlutterWatchOSPlatformViewsSetChangeCallback({ context in
            guard let context else { return }
            let me = Unmanaged<WatchPlatformViews>.fromOpaque(context)
                .takeUnretainedValue()
            DispatchQueue.main.async { me.reload() }
        }, ctx)
        reload()
    }

    /// Pull the current slot list from the engine. Main thread.
    private func reload() {
        let generation = FlutterWatchOSPlatformViewsGeneration()
        if generation != 0 && generation == lastGeneration { return }
        lastGeneration = generation
        let count = Int(FlutterWatchOSPlatformViewsCopy(nil, 0))
        var buffer = [FlutterWatchOSPlatformViewSlot](
            repeating: FlutterWatchOSPlatformViewSlot(), count: max(count, 0))
        let written = buffer.withUnsafeMutableBufferPointer { ptr in
            Int(FlutterWatchOSPlatformViewsCopy(ptr.baseAddress, Int32(ptr.count)))
        }
        let next = buffer.prefix(written).map { s in
            WatchPlatformViewSlot(
                id: s.view_id,
                viewType: String(cString: FlutterWatchOSPlatformViewGetType(s.view_id)),
                params: String(cString: FlutterWatchOSPlatformViewGetParams(s.view_id)),
                // Engine rects are logical points; overlays place in SwiftUI
                // points (they differ under FlutterWatchOSContentScale).
                rect: WatchContentScale.toDisplay(
                    CGRect(x: s.x, y: s.y, width: s.width, height: s.height)),
                visible: s.visible,
                belowFrame: FlutterWatchOSPlatformViewGetBelowFrame(s.view_id))
        }
        if next != slots { slots = next }
    }
}

/// Content scale: how large the app's LOGICAL coordinate space is relative
/// to the watch screen. `1.0` (the default) maps one Flutter logical pixel
/// to one SwiftUI point. Smaller values lay the app out in a proportionally
/// LARGER logical space rendered smaller — same layout ratio, smaller
/// components — which lets phone-designed UIs (e.g. a plugin's upstream
/// example app) fit the watch screen without touching their Dart code.
///
/// Set it in the app's Info.plist:
///
///     <key>FlutterWatchOSContentScale</key>
///     <real>0.6</real>
///
/// Physical sharpness is unchanged (the rendered pixel count is identical);
/// only the logical density changes. Touches, the Digital Crown, and the
/// native overlays (text input, platform views) are converted automatically.
enum WatchContentScale {
    /// Parsed once; clamped to a sane range (below ~0.3 text is unreadable).
    static let value: Double = {
        guard let number = Bundle.main.object(
            forInfoDictionaryKey: "FlutterWatchOSContentScale") as? NSNumber
        else { return 1.0 }
        return min(max(number.doubleValue, 0.3), 1.0)
    }()

    /// Engine-published logical rect → SwiftUI points, for overlay placement.
    static func toDisplay(_ rect: CGRect) -> CGRect {
        guard value != 1.0 else { return rect }
        return CGRect(x: rect.origin.x * value,
                      y: rect.origin.y * value,
                      width: rect.size.width * value,
                      height: rect.size.height * value)
    }
}

/// Generic glue around the Flutter engine — identical for every app. It starts
/// the engine, forwards touch and Digital Crown input, displays the frames the
/// engine produces, and plays the crown detent haptic on request.
final class FlutterRunner: ObservableObject {
    static let shared = FlutterRunner()

    /// The latest Flutter frame, rendered by the engine.
    @Published var frame: CGImage?

    /// Whether the app asked (via WatchStatusBar in package:flutter_watchos)
    /// for the system status bar — the clock — to be hidden. Default: visible,
    /// per the watchOS HIG. Mirrored from the plugin's C flag on each frame,
    /// so a Dart-side toggle applies with the next rendered frame. Apps that
    /// don't link the package never leave the system default.
    @Published var statusBarHidden = false

    /// dlsym-resolved so an app without package:flutter_watchos still builds.
    /// RTLD_DEFAULT is the special -2 handle.
    private static let statusBarHiddenFn: (@convention(c) () -> Bool)? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                              "flutter_watchos_status_bar_hidden") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) () -> Bool).self)
    }()

    /// Likewise dlsym-resolved: nil when the app doesn't link
    /// package:flutter_watchos, or links a version predating WatchAlwaysOn.
    private static let setAlwaysOnFn: (@convention(c) (Bool) -> Void)? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                              "flutter_watchos_set_always_on_active") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) (Bool) -> Void).self)
    }()

    /// Display geometry (SwiftUI points) — what the frame image is framed to.
    private(set) var sizePoints: CGSize = WKInterfaceDevice.current().screenBounds.size

    /// What the ENGINE runs at: the logical space grows by 1/contentScale and
    /// the pixel ratio shrinks by contentScale, so the physical pixel count
    /// (logical × ratio) is exactly the screen's either way.
    private(set) var pixelRatio: Double =
        WKInterfaceDevice.current().screenScale * WatchContentScale.value
    private var flutterSize: CGSize {
        CGSize(width: sizePoints.width / WatchContentScale.value,
               height: sizePoints.height / WatchContentScale.value)
    }

    private var started = false

    func start() {
        guard !started else { return }
        started = true

        // Keep the plugin-view registration entry point alive under
        // -dead_strip: plugin code reaches it only via dlsym at runtime, which
        // the linker cannot see, so it needs one visible reference.
        _ = FlutterWatchOSPlatformViewRegisterNativeFactory

        // Play the crown detent click when requested (on the main thread,
        // where crown deltas arrive).
        FlutterWatchOSCrownSetTickCallback({ _ in
            WKInterfaceDevice.current().play(.click)
        }, nil)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let running = FlutterWatchOSHostRun(
            Bundle.main.bundlePath,
            flutterSize.width,
            flutterSize.height,
            pixelRatio,
            { context, image in
                // Hop to the main thread to publish the frame.
                guard let context, let image else { return }
                let runner = Unmanaged<FlutterRunner>.fromOpaque(context)
                    .takeUnretainedValue()
                DispatchQueue.main.async { runner.publish(image) }
            },
            ctx)
        guard running else {
            NSLog("FlutterWatchOSHostRun failed")
            return
        }
        WatchTextInput.shared.start()
        WatchPlatformViews.shared.start()
    }

    /// Forward one touch sample (SwiftUI points → engine logical points).
    func touch(at location: CGPoint, ended: Bool) {
        FlutterWatchOSHostTouch(location.x / WatchContentScale.value,
                                location.y / WatchContentScale.value,
                                ended)
    }

    /// Forward one Digital Crown sample: the change in the SwiftUI
    /// crown-rotation binding since the previous sample. Scaled into logical
    /// points so the physical scroll feel is identical at any content scale.
    func sendCrownDelta(_ delta: Double) {
        FlutterWatchOSCrownDelta(delta / WatchContentScale.value)
    }

    /// Report the Always-On (reduced-luminance) state to Dart, where
    /// `WatchAlwaysOn` reads it. Called from FlutterHostView whenever SwiftUI's
    /// `\.isLuminanceReduced` changes AND once when the view first appears —
    /// the startup report is what lets Dart tell "the display is lit" apart
    /// from "this host is too old to report", so it must not be skipped.
    ///
    /// SwiftUI is the only public source for this state: WatchKit's app-state
    /// notifications say the app resigned active, which also happens for a
    /// notification banner or Control Center.
    func reportAlwaysOn(_ active: Bool) {
        Self.setAlwaysOnFn?(active)
    }

    /// Main thread: publish the frame and mirror the plugin's status-bar
    /// request alongside it (a cheap flag read; publishes only on change).
    private func publish(_ image: CGImage) {
        frame = image
        if let hiddenFn = Self.statusBarHiddenFn {
            let hidden = hiddenFn()
            if hidden != statusBarHidden { statusBarHidden = hidden }
        }
    }
}
#endif  // !arch(arm64_32)
