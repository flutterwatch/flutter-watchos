// 32-bit watches (Series 4–8 / SE) are unsupported; the Flutter host is
// compiled out for that slice and an info screen is shown instead (see App.swift).
#if !arch(arm64_32)
import Foundation
import CoreGraphics
import WatchKit

/// Hosts a Flutter engine instance via the embedder C API using software
/// rendering. Frames arrive as raw pixel buffers and are published as
/// CGImages for SwiftUI to display.
final class FlutterRunner: ObservableObject {
    static let shared = FlutterRunner()

    @Published var frame: CGImage?

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
    // `delta`s (≈0.01–1 per frame) while a fast flick delivers huge ones (up to
    // ~440). So scroll distance is mapped directly from `delta`; a separate
    // velocity multiplier double-counted speed and flung the list thousands of
    // points past its end. Behaviours reproduced:
    //   1. ACCELERATION — emergent from the delta magnitude itself: slow = tiny
    //      deltas = precise aiming; fast flick = large deltas = far travel.
    //   2. INERTIA — crown motion is forwarded as a trackpad PAN/ZOOM gesture, so
    //      Flutter's BouncingScrollPhysics runs real ballistic momentum on
    //      gesture-end (plus the rubber-band at the edges). Long flings come from
    //      that momentum, NOT one giant input step — which is why each sample is
    //      tanh soft-saturated (crownMaxPointsPerEvent) so a hard flick (or the
    //      simulator's inertial-scroll bursts) can't teleport the list. Pan/zoom
    //      carries no hover pointer, so no widget-highlight flicker.
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
    /// inertial-scroll bursts (which delivered single 15,000-point steps).
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

    /// Forwards one Digital Crown sample to Flutter. `delta` is the change in the
    /// SwiftUI crown-rotation binding since the previous sample; it already grows
    /// with turn speed, so distance is mapped from it directly and soft-saturated.
    func sendCrownDelta(_ delta: Double) {
        guard let engine, delta != 0 else { return }

        // Raw/exclusive crown mode: a Dart app (via WatchCrown) is consuming the
        // crown directly, so push the rotation to it and skip scroll + detent.
        if flutter_watchos_crown_mode() != 0 {
            flutter_watchos_crown_push_delta(delta)
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
        if channel == "haptics_channel" {
            if let typeStr = String(data: data, encoding: .utf8) {
                let hapticType: WKHapticType
                switch typeStr {
                case "click": hapticType = .click
                case "success": hapticType = .success
                case "failure": hapticType = .failure
                case "retry": hapticType = .retry
                case "start": hapticType = .start
                case "stop": hapticType = .stop
                default: hapticType = .click
                }
                DispatchQueue.main.async {
                    WKInterfaceDevice.current().play(hapticType)
                }
            }
        }
        
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
        DispatchQueue.main.async { self.frame = image }
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
