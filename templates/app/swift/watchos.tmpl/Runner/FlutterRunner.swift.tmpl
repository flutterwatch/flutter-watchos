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
            // Release/AOT build: the Dart snapshots live in App.framework.
            guard let app = dlopen("\(bundle)/Frameworks/App.framework/App", RTLD_NOW) else {
                NSLog("AOT engine but App.framework missing: %@", String(cString: dlerror()))
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

    // MARK: - Digital Crown input & Haptics Channel

    func sendCrownDelta(_ delta: Double) {
        guard let engine else { return }
        let messageStr = String(format: "%f", delta)
        guard let messageData = messageStr.data(using: .utf8) else { return }
        
        messageData.withUnsafeBytes { rawBufferPointer in
            guard let baseAddress = rawBufferPointer.baseAddress else { return }
            let messageBytes = baseAddress.assumingMemoryBound(to: UInt8.self)
            
            "crown_channel".withCString { channelCString in
                var platformMessage = FlutterPlatformMessage()
                platformMessage.struct_size = MemoryLayout<FlutterPlatformMessage>.size
                platformMessage.channel = channelCString
                platformMessage.message = messageBytes
                platformMessage.message_size = messageData.count
                platformMessage.response_handle = nil
                
                FlutterEngineSendPlatformMessage(engine, &platformMessage)
            }
        }
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
