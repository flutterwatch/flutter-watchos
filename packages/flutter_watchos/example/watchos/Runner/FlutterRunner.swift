// 32-bit watches (Series 4–8 / SE) are unsupported; the Flutter host is
// compiled out for that slice and an info screen is shown instead (see App.swift).
#if !arch(arm64_32)
import Foundation
import CoreGraphics
import WatchKit

/// One Flutter text field to overlay, published by the engine in SwiftUI points.
/// App.swift places an invisible native proxy over each so the FIRST tap on a
/// field raises the system keyboard (masked for `obscured`). The engine computes
/// these from the semantics tree internally — the host does no geometry.
struct WatchProxyField: Identifiable, Equatable {
    let id: Int32
    let rect: CGRect
    let isObscured: Bool
}

/// Thin, app-independent adapter over the engine's exported text-input C ABI.
/// Holds NO logic: it mirrors the engine's published proxy-field list into a
/// `@Published` array for SwiftUI and forwards focus/edits straight to the
/// engine. All semantics math, per-field state, the `flutter/textinput`
/// protocol, and `obscureText` handling live in the engine dylib
/// (shell/platform/embedder/watchos/). This object is identical for every app.
final class WatchTextInput: ObservableObject {
    static let shared = WatchTextInput()

    /// The fields to overlay, kept in sync with the engine via the change
    /// callback registered in `start()`.
    @Published var fields: [WatchProxyField] = []

    /// Generation last copied from the engine; an unchanged generation means
    /// nothing changed since the previous copy, so `reload()` skips the work.
    private var lastGeneration: UInt64 = 0

    fileprivate func start(pixelRatio: Double) {
        FlutterWatchOSTextInputSetPixelRatio(pixelRatio)
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

/// Hosts a Flutter engine instance via the embedder C API using software
/// rendering. Frames arrive as raw pixel buffers and are published as
/// CGImages for SwiftUI to display.
final class FlutterRunner: ObservableObject {
    static let shared = FlutterRunner()

    @Published var frame: CGImage?

    /// Whether the app asked (via WatchStatusBar in package:flutter_watchos)
    /// for the system status bar — the clock — to be hidden. Default: visible,
    /// per the watchOS HIG. Mirrored from the plugin's C flag on each frame,
    /// so a Dart-side toggle applies with the next rendered frame. Apps that
    /// don't link the package never leave the system default.
    @Published var statusBarHidden = false

    /// dlsym-resolved so an app without package:flutter_watchos still builds
    /// (same pattern as the crown bridge below). RTLD_DEFAULT is handle -2.
    private static let statusBarHiddenFn: (@convention(c) () -> Bool)? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                              "flutter_watchos_status_bar_hidden") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) () -> Bool).self)
    }()

    private var engine: FlutterEngine?
    private(set) var pixelRatio: Double = WKInterfaceDevice.current().screenScale
    private(set) var sizePoints: CGSize = WKInterfaceDevice.current().screenBounds.size

    // Snapshot buffers must outlive the engine.
    private var vmSnapshotData: UnsafeMutableRawPointer?
    private var vmSnapshotSize = 0
    private var isolateSnapshotData: UnsafeMutableRawPointer?
    private var isolateSnapshotSize = 0

    func start() {
        guard engine == nil else { return }
        let bundle = Bundle.main.bundlePath

        var rendererConfig = FlutterRendererConfig()
        rendererConfig.type = kSoftware
        rendererConfig.software.struct_size = MemoryLayout<FlutterSoftwareRendererConfig>.size
        rendererConfig.software.surface_present_callback = { userData, allocation, rowBytes, height in
            guard let userData, let allocation else { return false }
            let runner = Unmanaged<FlutterRunner>.fromOpaque(userData).takeUnretainedValue()
            runner.publishFrame(allocation: allocation, rowBytes: rowBytes, height: height)
            return true
        }

        var args = FlutterProjectArgs()
        args.struct_size = MemoryLayout<FlutterProjectArgs>.size
        let assetsPath = strdup("\(bundle)/flutter_assets")
        let icuPath = strdup("\(bundle)/icudtl.dat")
        args.assets_path = UnsafePointer(assetsPath)
        args.icu_data_path = UnsafePointer(icuPath)

        args.platform_message_callback = { platformMessage, userData in
            guard let platformMessage, let userData else { return }
            let runner = Unmanaged<FlutterRunner>.fromOpaque(userData).takeUnretainedValue()

            let channelName = String(cString: platformMessage.pointee.channel)
            let messageSize = platformMessage.pointee.message_size

            var data = Data()
            if let messageBytes = platformMessage.pointee.message, messageSize > 0 {
                data = Data(bytes: messageBytes, count: messageSize)
            }

            runner.handlePlatformMessage(channel: channelName, data: data, responseHandle: platformMessage.pointee.response_handle)
        }

        if FlutterEngineRunsAOTCompiledDartCode() {
            // Release/profile (AOT) build: the Dart snapshots live in the AOT
            // library. The CLI packages it as a bare `Frameworks/App.dylib`
            // (install_name @rpath/App.dylib); a framework-wrapped
            // `App.framework/App` is also accepted, in case a release/App Store
            // submission step repackages it as a framework. Try both.
            let appCandidates = [
                "\(bundle)/Frameworks/App.dylib",
                "\(bundle)/Frameworks/App.framework/App",
            ]
            guard let app = appCandidates.lazy.compactMap({ dlopen($0, RTLD_NOW) }).first else {
                NSLog("AOT engine but App library missing: %@", String(cString: dlerror()))
                return
            }
            func sym(_ name: String) -> UnsafePointer<UInt8>? {
                dlsym(app, name).map { UnsafeRawPointer($0).assumingMemoryBound(to: UInt8.self) }
            }
            args.vm_snapshot_data = sym("kDartVmSnapshotData")
            args.vm_snapshot_instructions = sym("kDartVmSnapshotInstructions")
            args.isolate_snapshot_data = sym("kDartIsolateSnapshotData")
            args.isolate_snapshot_instructions = sym("kDartIsolateSnapshotInstructions")
        } else if let vm = loadBlob("vm_isolate_snapshot.bin"), let iso = loadBlob("isolate_snapshot.bin") {
            // JIT mode: hand the engine its core VM/isolate snapshots explicitly.
            (vmSnapshotData, vmSnapshotSize) = vm
            (isolateSnapshotData, isolateSnapshotSize) = iso
            args.vm_snapshot_data = UnsafePointer(vmSnapshotData!.assumingMemoryBound(to: UInt8.self))
            args.vm_snapshot_data_size = vmSnapshotSize
            args.isolate_snapshot_data = UnsafePointer(isolateSnapshotData!.assumingMemoryBound(to: UInt8.self))
            args.isolate_snapshot_data_size = isolateSnapshotSize
        }

        args.log_message_callback = { tag, message, _ in
            let t = tag.flatMap { String(cString: $0) } ?? ""
            let m = message.flatMap { String(cString: $0) } ?? ""
            NSLog("[flutter:%@] %@", t, m)
        }

        let userData = Unmanaged.passUnretained(self).toOpaque()
        let result = FlutterEngineRun(1 /* FLUTTER_ENGINE_VERSION */, &rendererConfig, &args, userData, &engine)
        NSLog("FlutterEngineRun -> %d", result.rawValue)
        guard result == kSuccess else { return }

        sendWindowMetrics()
        // Turn on the semantics tree so the engine can locate text fields (the
        // engine ingests semantics internally to publish the proxy rects). No
        // host-side semantics callback is needed.
        FlutterEngineUpdateSemanticsEnabled(engine, true)
        // Hand the engine the device pixel ratio + change callback so it can
        // publish proxy-field rects in SwiftUI points.
        WatchTextInput.shared.start(pixelRatio: pixelRatio)
    }

    private func sendWindowMetrics() {
        var event = FlutterWindowMetricsEvent()
        event.struct_size = MemoryLayout<FlutterWindowMetricsEvent>.size
        event.width = Int(sizePoints.width * pixelRatio)
        event.height = Int(sizePoints.height * pixelRatio)
        event.pixel_ratio = pixelRatio
        FlutterEngineSendWindowMetricsEvent(engine, &event)
    }

    // MARK: - Touch input

    private var touchDown = false

    func touch(at location: CGPoint, ended: Bool) {
        guard let engine else { return }
        var event = FlutterPointerEvent()
        event.struct_size = MemoryLayout<FlutterPointerEvent>.size
        event.x = location.x * pixelRatio
        event.y = location.y * pixelRatio
        event.timestamp = Int(FlutterEngineGetCurrentTime() / 1000)
        event.device_kind = kFlutterPointerDeviceKindTouch
        if ended {
            event.phase = kUp
            touchDown = false
        } else if !touchDown {
            event.phase = kDown
            touchDown = true
        } else {
            event.phase = kMove
        }
        FlutterEngineSendPointerEvent(engine, &event, 1)
    }

    // MARK: - Digital Crown input
    //
    // Reproduces native watchOS crown scrolling. See docs/digital-crown-scroll.md
    // for the full investigation, including the captured-input calibration that
    // produced this model. Key finding from logging real crown input: the SwiftUI
    // crown signal ALREADY scales with turn speed — a slow turn delivers tiny
    // `delta`s while a fast flick delivers huge ones — so scroll distance is
    // mapped directly from `delta`; a separate velocity multiplier double-counted
    // speed and flung the list thousands of points past its end. Behaviours:
    //   1. ACCELERATION — emergent from the delta magnitude itself: slow = tiny
    //      deltas = precise aiming; fast flick = large deltas = far travel.
    //   2. INERTIA — crown motion is forwarded as a trackpad PAN/ZOOM gesture, so
    //      Flutter's BouncingScrollPhysics runs real ballistic momentum on
    //      gesture-end (plus the rubber-band). Long flings come from that momentum,
    //      NOT one giant input step — each sample is tanh soft-saturated
    //      (crownMaxPointsPerEvent) so a hard flick (or the simulator's inertial
    //      bursts) can't teleport the list. Pan/zoom carries no hover, no flicker.
    //   3. DETENT CLICK — a WKHapticType.click per crownHapticTickPoints of
    //      travel, rate-limited by crownMinTickInterval. We play it ourselves
    //      rather than via the modifier's `isHapticFeedbackEnabled`, because that
    //      fires once per `by:` detent and at by:0.05 a fast turn crosses hundreds
    //      per frame → the Taptic Engine backs up and STUTTERS the scroll on real
    //      hardware. (.directionUp/.directionDown are navigation cues, not the
    //      detent — they sound wrong; .click is the closest detent feel.)
    //   4. EDGE BUMP — the end-of-content haptic is played Flutter-side from an
    //      OverscrollNotification (WatchCrownScroll in package:flutter_watchos).

    // -- Tunables (calibrated from captured sim input; see the doc) -----------
    /// Logical points scrolled per crown unit, before soft-saturation. The crown
    /// delta already encodes turn speed, so this maps it directly.
    private let crownPointsPerUnit: Double = 5.0
    /// Soft cap (logical points) on the scroll applied per crown sample, via
    /// tanh. One sample can never move the list past this; long-distance travel
    /// comes from Flutter's fling momentum. Tames hard flicks and the simulator's
    /// inertial-scroll bursts.
    private let crownMaxPointsPerEvent: Double = 120.0
    /// Play a detent click every this many logical points of scroll (0 = off).
    /// We play the haptic ourselves instead of via the modifier's
    /// `isHapticFeedbackEnabled` because that fires per `by:` step and floods the
    /// Taptic Engine on a fast turn (stutter). This is distance-gated AND
    /// time-gated (crownMinTickInterval), so it stays a clean detent cadence.
    private let crownHapticTickPoints: Double = 22.0
    /// Hard floor on the time between detent clicks — the anti-flood guarantee.
    /// Even a violent flick can't play clicks faster than this (≈22/sec at 0.045).
    private let crownMinTickInterval: Double = 0.045
    /// Idle gap with no rotation that ends the gesture so Flutter flings.
    private let crownIdleEndSeconds: Double = 0.05
    /// Set true to log raw crown delta/points for calibration.
    private let crownDebugLogging = false
    // -------------------------------------------------------------------------

    /// True while a crown-driven pan/zoom gesture is in flight.
    private var crownPanActive = false
    /// Accumulated pan offset (physical px) since the current gesture started.
    private var crownPanY: Double = 0
    /// Logical points scrolled since the last detent tick.
    private var crownPointsSinceTick: Double = 0
    /// Engine-clock time (ns) of the last detent click, for rate-limiting.
    private var crownLastTickNanos: UInt64 = 0
    /// Fires once the crown stops to end the gesture, letting Flutter's scroll
    /// physics apply the momentum/settle that makes it feel native.
    private var crownIdleTimer: Timer?

    // Raw Digital Crown bridge, resolved at runtime via dlsym so an app that
    // does NOT link the flutter_watchos package still builds and runs — the
    // crown just stays in scroll mode. When the package IS present it exports
    // these C symbols (dlsym-visible, used by its own FFI), so raw mode is
    // picked up with no extra wiring. RTLD_DEFAULT is the special -2 handle.
    private static let crownModeFn: (@convention(c) () -> Int32)? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                              "flutter_watchos_crown_mode") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) () -> Int32).self)
    }()
    private static let crownPushFn: (@convention(c) (Double) -> Void)? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                              "flutter_watchos_crown_push_delta") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) (Double) -> Void).self)
    }()

    /// Forwards one Digital Crown sample to Flutter. `delta` is the change in the
    /// SwiftUI crown-rotation binding since the previous sample; it already grows
    /// with turn speed, so distance is mapped from it directly and soft-saturated.
    func sendCrownDelta(_ delta: Double) {
        guard let engine, delta != 0 else { return }

        // Raw/exclusive crown mode: a Dart app (via WatchCrown) is consuming the
        // crown directly, so push the rotation to it and skip scroll + detent.
        if let crownMode = Self.crownModeFn, crownMode() != 0 {
            Self.crownPushFn?(delta)
            return
        }

        let cx = sizePoints.width * pixelRatio / 2
        let cy = sizePoints.height * pixelRatio / 2

        // Map delta→points directly (it already encodes speed), then tanh
        // soft-saturate so no single sample teleports the list — distance on a
        // fast flick comes from Flutter's fling momentum, not a giant single step.
        let raw = delta * crownPointsPerUnit
        let points = crownMaxPointsPerEvent * tanh(raw / crownMaxPointsPerEvent)
        let pixels = points * pixelRatio

        if crownDebugLogging {
            NSLog("crown delta=%.4f raw=%.1f pts=%.1f", delta, raw, points)
        }

        if !crownPanActive {
            crownPanActive = true
            crownPanY = 0
            crownPointsSinceTick = 0
            sendPanZoom(phase: kPanZoomStart, x: cx, y: cy)
        }

        // Crown forward (positive delta) scrolls down the list — content moves up,
        // i.e. a negative pan in Flutter's coordinate space.
        crownPanY -= pixels
        sendPanZoom(phase: kPanZoomUpdate, x: cx, y: cy)

        // Detent click: one .click every crownHapticTickPoints of travel, but
        // never faster than crownMinTickInterval (the anti-flood floor that keeps
        // the Taptic Engine from backing up and stuttering the scroll).
        if crownHapticTickPoints > 0 {
            crownPointsSinceTick += abs(points)
            if crownPointsSinceTick >= crownHapticTickPoints {
                crownPointsSinceTick = 0
                let now = FlutterEngineGetCurrentTime()
                let sinceLast = Double(now &- crownLastTickNanos) / 1_000_000_000.0
                if crownLastTickNanos == 0 || sinceLast >= crownMinTickInterval {
                    crownLastTickNanos = now
                    WKInterfaceDevice.current().play(.click)
                }
            }
        }

        // Restart the idle timer; when the crown stops, end the gesture so Flutter
        // applies momentum from the tracked pan velocity. .common mode keeps it
        // firing while the crown's tracking run-loop mode is active.
        crownIdleTimer?.invalidate()
        let timer = Timer(timeInterval: crownIdleEndSeconds, repeats: false) { [weak self] _ in
            self?.endCrownPan()
        }
        RunLoop.main.add(timer, forMode: .common)
        crownIdleTimer = timer
    }

    private func endCrownPan() {
        guard crownPanActive else { return }
        crownPanActive = false
        crownPointsSinceTick = 0
        sendPanZoom(phase: kPanZoomEnd,
                    x: sizePoints.width * pixelRatio / 2,
                    y: sizePoints.height * pixelRatio / 2)
    }

    private func sendPanZoom(phase: FlutterPointerPhase, x: Double, y: Double) {
        guard let engine else { return }
        var event = FlutterPointerEvent()
        event.struct_size = MemoryLayout<FlutterPointerEvent>.size
        event.timestamp = Int(FlutterEngineGetCurrentTime() / 1000)
        event.phase = phase
        event.device_kind = kFlutterPointerDeviceKindTrackpad
        event.device = 1  // distinct pointer id from touch (device 0)
        event.x = x
        event.y = y
        event.pan_x = 0
        event.pan_y = crownPanY
        event.scale = 1.0
        event.rotation = 0
        FlutterEngineSendPointerEvent(engine, &event, 1)
    }

    private func handlePlatformMessage(channel: String, data: Data, responseHandle: OpaquePointer?) {
        // NOTE: `flutter/textinput` is intercepted INSIDE the engine
        // (shell/platform/embedder/watchos/) and never reaches this callback.
        // Haptics, device info, crown, and status bar all go over FFI
        // (package:flutter_watchos), not platform channels, so no channels are
        // handled here. Always answer so Dart-side futures complete.
        if let responseHandle {
            FlutterEngineSendPlatformMessageResponse(engine, responseHandle, nil, 0)
        }
    }

    // MARK: - Frames

    private func publishFrame(allocation: UnsafeRawPointer, rowBytes: Int, height: Int) {
        let width = rowBytes / 4
        guard width > 0, height > 0,
              let data = CFDataCreate(nil, allocation.assumingMemoryBound(to: UInt8.self), rowBytes * height),
              let provider = CGDataProvider(data: data) else { return }
        // The embedder software surface hands us RGBA8888 premultiplied.
        let bitmapInfo = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue |
                                                 CGImageAlphaInfo.premultipliedLast.rawValue)
        let image = CGImage(width: width,
                            height: height,
                            bitsPerComponent: 8,
                            bitsPerPixel: 32,
                            bytesPerRow: rowBytes,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: bitmapInfo,
                            provider: provider,
                            decode: nil,
                            shouldInterpolate: false,
                            intent: .defaultIntent)
        DispatchQueue.main.async {
            self.frame = image
            // Mirror the plugin's status-bar request alongside the frame (a
            // cheap flag read; publishes only on change).
            if let hiddenFn = Self.statusBarHiddenFn {
                let hidden = hiddenFn()
                if hidden != self.statusBarHidden { self.statusBarHidden = hidden }
            }
        }
    }

    private func loadBlob(_ name: String) -> (UnsafeMutableRawPointer, Int)? {
        let path = "\(Bundle.main.bundlePath)/\(name)"
        guard let data = FileManager.default.contents(atPath: path) else {
            NSLog("snapshot blob missing: %@ (relying on engine-embedded snapshot)", name)
            return nil
        }
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: data.count, alignment: 16)
        data.withUnsafeBytes { ptr.copyMemory(from: $0.baseAddress!, byteCount: data.count) }
        return (ptr, data.count)
    }
}
#endif  // !arch(arm64_32)
