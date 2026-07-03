// 32-bit watches (Series 4–8 / SE) are unsupported; the Flutter host is
// compiled out for that slice and an info screen is shown instead (see App.swift).
#if !arch(arm64_32)
import Foundation
import CoreGraphics
import WatchKit

/// One native text-field overlay, positioned in SwiftUI points. App.swift
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
                rect: CGRect(x: f.x, y: f.y, width: f.width, height: f.height),
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

    private(set) var pixelRatio: Double = WKInterfaceDevice.current().screenScale
    private(set) var sizePoints: CGSize = WKInterfaceDevice.current().screenBounds.size
    private var started = false

    func start() {
        guard !started else { return }
        started = true

        // Play the crown detent click when requested (on the main thread,
        // where crown deltas arrive).
        FlutterWatchOSCrownSetTickCallback({ _ in
            WKInterfaceDevice.current().play(.click)
        }, nil)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let running = FlutterWatchOSHostRun(
            Bundle.main.bundlePath,
            sizePoints.width,
            sizePoints.height,
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
    }

    /// Forward one touch sample (logical points, straight from SwiftUI).
    func touch(at location: CGPoint, ended: Bool) {
        FlutterWatchOSHostTouch(location.x, location.y, ended)
    }

    /// Forward one Digital Crown sample: the change in the SwiftUI
    /// crown-rotation binding since the previous sample.
    func sendCrownDelta(_ delta: Double) {
        FlutterWatchOSCrownDelta(delta)
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
