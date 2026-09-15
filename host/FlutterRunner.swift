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
import SceneKit
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

    /// `slots` split by layer, computed once per change rather than filtered
    /// on every evaluation of the host view's body.
    private(set) var underlaySlots: [WatchPlatformViewSlot] = []
    private(set) var overlaySlots: [WatchPlatformViewSlot] = []

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
        if next != slots {
            // The derived lists first: the `slots` assignment is what SwiftUI
            // observes, and the body it schedules reads these.
            underlaySlots = next.filter(\.belowFrame)
            overlaySlots = next.filter { !$0.belowFrame }
            slots = next
        }
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
/// The display's rounded-corner radius, and what it costs to stay clear of it.
///
/// watchOS exposes no corner-radius API — `WKInterfaceGroup.setCornerRadius`
/// is a view's radius, not the screen's — and `ContainerRelativeShape`
/// resolves to a plain rectangle at the top level, so there is nothing to read
/// at runtime. These are Apple's own numbers, from the `DeviceCornerRadius`
/// key in each simulator device type's `capabilities.plist`, in points.
///
/// Keyed by logical screen size because that is what a running app can
/// actually observe. A formula would not do: 187x223 has a 44pt radius while
/// the LARGER 198x242 has 42.5pt — newer displays are rounder, not bigger.
enum WatchDisplayCorner {
    private static let radiusByScreenSize: [String: Double] = [
        "162x197": 28,     // SE 40mm, Series 4-6 40mm
        "176x215": 38.5,   // Series 7-9 41mm
        "184x224": 34,     // SE 44mm, Series 4-6 44mm
        "187x223": 44,     // Series 10/11 42mm
        "198x242": 42.5,   // Series 7-9 45mm
        "205x251": 54,     // Ultra, Ultra 2
        "208x248": 50,     // Series 10/11 46mm
        "211x257": 57,     // Ultra 3
    ]

    /// Radius in points for this watch, or nil on a model that shipped after
    /// this table. Unknown means unknown: the caller keeps watchOS's own
    /// insets rather than guessing, because a wrong guess clips content.
    static let radius: Double? = {
        let b = WKInterfaceDevice.current().screenBounds
        return radiusByScreenSize["\(Int(b.width.rounded()))x\(Int(b.height.rounded()))"]
    }()

    /// The smallest UNIFORM inset that keeps an axis-aligned rectangle clear
    /// of the corner arc.
    ///
    /// The arc's centre sits at (r, r) from the corner, so an inset rectangle
    /// whose corner is at (d, d) stays inside while √2·(r − d) ≤ r — that is,
    /// d ≥ r(1 − 1/√2) ≈ 0.293r. On Ultra 3 that is 17pt against watchOS's own
    /// 56.5pt top inset.
    ///
    /// It has to be uniform. Dropping the top to 17 while leaving the sides at
    /// watchOS's 2pt puts the content corner at (2, 17), which is 68pt from
    /// the arc centre against a 57pt radius — outside the display, clipped.
    static var uniformInset: Double? {
        guard let r = radius else { return nil }
        return (r * (1 - 1 / 2.0.squareRoot())).rounded(.up)
    }
}

/// Which safe area the app wants reported to Dart, from `Info.plist`:
///
///     <key>FlutterWatchOSSafeArea</key>
///     <string>corners</string>
///
/// `platform` (the default) reports watchOS's own `safeAreaInsets`. Those keep
/// content clear of the system clock as well as the corners, and they do it by
/// pushing a full-width rectangle entirely below the corner arc — on Ultra 3,
/// 56.5pt off the top and 40pt off the bottom, leaving 62% of the display.
///
/// `corners` reports the uniform corner inset instead: 17pt all round on Ultra
/// 3, which is 73% of the display. It is a TRADE, not a free win — the usable
/// area grows by about a fifth while the usable WIDTH shrinks from 207pt to
/// 177pt, and content may sit under the system clock, which the system draws
/// over the app. Worth it for a layout that is not a full-width scrolling
/// list; wrong for one that is.
enum WatchSafeAreaMode {
    static let usesCornerInset: Bool = {
        let value = Bundle.main.object(
            forInfoDictionaryKey: "FlutterWatchOSSafeArea") as? String
        return value?.lowercased() == "corners"
    }()
}

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

/// How the engine's frames reach the screen. EXPERIMENTAL opt-in, off by
/// default:
///
///     <key>FlutterWatchOSPresent</key>
///     <string>texture</string>
///
/// (`FLUTTER_WATCHOS_PRESENT=texture` in the environment does the same for a
/// `run`, so an app can be compared without editing its Info.plist.)
///
/// `image` (the default) shows each frame as a CGImage in a SwiftUI `Image`:
/// the engine reads its Metal render target back through a shared buffer and
/// CoreAnimation uploads the bitmap again on the way to the screen. `texture`
/// hands the render target ITSELF to the host, which samples it on the GPU
/// through the one public route watchOS has for that — a SceneKit material
/// shown by SwiftUI's `SceneView` — so no pixel is copied between rasterising
/// and scanout. In a frame with platform views that is the bottom layer, on an
/// engine with `FlutterWatchOSHostSetTextureLayersCallback`; content above a
/// native view stays an image, and an older engine sends the whole frame as
/// images. See `FlutterTexturePresenter`.
///
/// It is an experiment: SceneKit is soft-deprecated since 2025 (maintenance
/// only, though it remains the only 3D framework on watchOS), a SceneKit
/// render pass has a cost of its own, and none of it has been through App
/// Review. Measured on a Series 10, a frame
/// without platform views rasterises in about a third of the time it takes on
/// the image path. Measure before shipping an app with it.
enum WatchPresentMode: Equatable {
    case image
    case texture

    static let current: WatchPresentMode = {
        let raw = ProcessInfo.processInfo.environment["FLUTTER_WATCHOS_PRESENT"]
            ?? Bundle.main.object(forInfoDictionaryKey: "FlutterWatchOSPresent") as? String
        switch raw?.lowercased() {
        case "texture", "scenekit": return .texture
        default: return .image
        }
    }()
}

/// One frame delivered as the engine's own render target (`WatchPresentMode
/// .texture`): the `id<MTLTexture>`, typed as `AnyObject` because the watchOS
/// SDK declares no Metal, and the lease that gives it back to the engine.
struct FlutterTextureFrame {
    let texture: AnyObject
    let lease: UnsafeMutableRawPointer
}

/// Shows the engine's render target on the GPU, without a copy.
///
/// A SceneKit scene of exactly one thing: an orthographic camera looking at a
/// screen-sized plane whose material samples the engine's texture with a
/// constant lighting model (no lights, no shading, the texel is the pixel).
/// SwiftUI's `SceneView` draws it — the one public view on watchOS that can
/// put an `MTLTexture` on screen; there is no `CAMetalLayer`, no `SCNView`
/// or `SCNRenderer`, and an `SK3DNode` inside a `SpriteView` renders nothing
/// here (measured: a SpriteKit sprite beside it draws, the SceneKit content
/// does not).
///
/// Only a frame's BOTTOM layer is shown this way. `SceneView` is opaque on
/// watchOS (a clear scene background renders black, measured), so Flutter
/// content above a platform view, which must let the view show through, stays
/// an image. Blending extra SceneViews for those layers composited correctly
/// but flashed white while scrolling fast on a Series 10, and was reverted.
///
/// Frames arrive through `present`, on the display tick like the image path.
/// The two most recent leases are kept: SceneKit's own render of the previous
/// frame may still be reading that texture when the next one lands, and the
/// engine draws into a slot again the moment its lease comes back.
final class FlutterTexturePresenter {
    static let shared = FlutterTexturePresenter()

    /// What `FlutterTextureFrameView` shows, and the camera it shows it from.
    let scene = SCNScene()
    let cameraNode = SCNNode()

    private let material = SCNMaterial()
    /// Newest last; never more than two.
    private var held: [FlutterTextureLease] = []

    private init() {
        let size = WKInterfaceDevice.current().screenBounds.size
        scene.background.contents = UIColor.black

        material.lightingModel = .constant
        material.isDoubleSided = true
        material.diffuse.minificationFilter = .linear
        material.diffuse.magnificationFilter = .linear
        material.diffuse.mipFilter = .none
        material.diffuse.wrapS = .clamp
        material.diffuse.wrapT = .clamp
        // No `contentsTransform`: SceneKit maps a Metal texture the way it
        // maps an image, first row at the top of the plane (measured — a
        // vertical flip here shows the app upside down).

        let plane = SCNPlane(width: size.width, height: size.height)
        plane.materials = [material]
        scene.rootNode.addChildNode(SCNNode(geometry: plane))

        // Orthographic: `orthographicScale` is half the visible height in
        // scene units, so a plane of the view's size fills it exactly.
        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.orthographicScale = Double(size.height) / 2
        camera.zNear = 1
        camera.zFar = 100
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 10)
        scene.rootNode.addChildNode(cameraNode)
    }

    /// Main thread: show this texture from SceneKit's next render. The view
    /// does not render continuously; a changed material is what makes it draw.
    func present(texture: AnyObject, lease: FlutterTextureLease) {
        material.diffuse.contents = texture
        held.append(lease)
        while held.count > 2 {
            held.removeFirst()
        }
    }

    /// Main thread: the older engine's single-texture frame.
    func present(_ frame: FlutterTextureFrame) {
        present(texture: frame.texture,
                lease: FlutterTextureLease(frame.lease, release: FlutterRunner.releaseTexture))
    }
}

/// One frame's claim on the engine's render targets. Handing it back (when
/// the last reference goes) is what lets the engine draw into them again.
final class FlutterTextureLease {
    private let lease: UnsafeMutableRawPointer
    private let release: (UnsafeMutableRawPointer) -> Void

    init(_ lease: UnsafeMutableRawPointer, release: @escaping (UnsafeMutableRawPointer) -> Void) {
        self.lease = lease
        self.release = release
    }

    deinit { release(lease) }
}

/// One layer of a composited frame, in SwiftUI points: Flutter content as an
/// image, or a platform view with the geometry the layer tree gave it. The
/// engine hands the host a frame as an ordered list of these, bottom first;
/// see `FlutterWatchOSLayersCallback` in the C header.
struct FlutterFrameLayer: Identifiable {
    /// Stable across frames for a platform view (`pv<id>`), so SwiftUI keeps
    /// the native view — and its state — as it moves through the stack;
    /// positional for Flutter content (`f<index>`).
    let id: String
    /// Flutter content; nil for a platform view, and for Flutter content
    /// delivered as a texture (`isTexture`).
    let image: CGImage?
    /// The bottom Flutter layer when the presenter draws it from the engine's
    /// render target (`WatchPresentMode.texture`) instead of an image.
    var isTexture = false
    /// Where the image carries pixels; outside is transparent (Flutter only).
    let paintedRects: [CGRect]
    let viewId: Int64
    let rect: CGRect
    let opacity: Double
    let clip: CGRect?
    let clipRadius: CGFloat

    var isPlatformView: Bool { image == nil && !isTexture }

    /// Whether `other` shows the same thing in the same place. A texture
    /// layer's pixels are not part of that: the presenter swaps the texture
    /// under the view, so a frame that changed nothing else needs no SwiftUI
    /// update. An image is a new object every frame, so image layers always do.
    func sameShape(as other: FlutterFrameLayer) -> Bool {
        id == other.id && isTexture == other.isTexture
            && image === other.image
            && paintedRects == other.paintedRects && viewId == other.viewId
            && rect == other.rect && opacity == other.opacity
            && clip == other.clip && clipRadius == other.clipRadius
    }

    static func flutter(index: Int, image: CGImage?, painted: [CGRect], size: CGSize) -> FlutterFrameLayer {
        FlutterFrameLayer(id: "f\(index)", image: image, isTexture: image == nil,
                          paintedRects: painted, viewId: 0,
                          rect: CGRect(origin: .zero, size: size), opacity: 1, clip: nil, clipRadius: 0)
    }
}

/// The engine's latest frame, and nothing else — kept apart from the rest of
/// the runner's state on purpose.
///
/// SwiftUI re-evaluates every view that observes an object whenever ANY of
/// that object's published properties changes. The frame changes sixty times
/// a second, so publishing it from `FlutterRunner` — which `FlutterHostView`
/// observes for its rarely-changing status-bar flag — re-ran the whole host
/// body on every refresh: the text-field proxies, the platform-view slots
/// (re-invoking their factories) and the accessibility elements were all
/// rebuilt for a picture that only `FlutterFrameView` shows. With the frame
/// here, that one leaf view is the only observer, and the overlays are
/// evaluated when their own mirrors change.
final class FlutterFrameStore: ObservableObject {
    static let shared = FlutterFrameStore()

    /// The latest frame, bottom layer first. One Flutter layer when the app
    /// shows no platform view (and always, on an engine that predates
    /// composited frames).
    @Published fileprivate(set) var layers: [FlutterFrameLayer] = []

    /// Where each platform view was last placed, by id — what a view that is
    /// not in the current frame is kept alive at (hidden) so it comes back
    /// at the right size without a layout jump.
    fileprivate(set) var lastRects: [Int64: CGRect] = [:]
}

/// Whether the host's display tick runs, kept apart from the runner for the
/// same reason as `FlutterFrameStore`: only `EngineVsyncClock` observes it.
///
/// The tick used to run every refresh for as long as the app was on screen,
/// waking the app sixty times a second to find, on a still screen, nothing to
/// present and no frame asked for. iOS stops its CADisplayLink in that case;
/// this is the watchOS shape of it. After `idleTicksBeforePause` refreshes with
/// no frame to show and no request from the engine, the tick pauses. It
/// resumes the moment the engine asks for a frame (the vsync request
/// callback) or a frame lands, so the first frame after a pause is at most one
/// refresh late, the same as a display link being restarted.
///
/// Only an engine with `FlutterWatchOSHostSetVsyncRequestCallback` can wake
/// the tick; on an older one it never pauses. `FLUTTER_WATCHOS_DISPLAY_CLOCK`
/// set to `continuous` keeps it running, for A/B measurements.
final class FlutterDisplayClock: ObservableObject {
    static let shared = FlutterDisplayClock()

    /// About half a second: long enough that an animation's gaps between
    /// frames never pause it, short enough to be over before anyone notices.
    static let idleTicksBeforePause = 30

    @Published private(set) var paused = false

    /// Set once the engine's request callback is registered (main thread).
    var canPause = false

    private var idleTicks = 0
    private var requested = false
    private let lock = NSLock()

    /// Any thread: the engine asked for a frame, or one is ready to present.
    func wake() {
        lock.lock()
        requested = true
        lock.unlock()
        if Thread.isMainThread {
            resume()
        } else {
            DispatchQueue.main.async { self.resume() }
        }
    }

    /// Main thread, once per tick, after presenting and servicing the engine.
    /// `presented`: a frame reached the screen on this tick.
    func didTick(presented: Bool) {
        lock.lock()
        let active = requested || presented
        requested = false
        lock.unlock()
        if active {
            idleTicks = 0
            return
        }
        idleTicks += 1
        if canPause && !paused && idleTicks >= Self.idleTicksBeforePause {
            paused = true
        }
    }

    private func resume() {
        idleTicks = 0
        if paused {
            paused = false
        }
    }
}

/// Opt-in CPU accounting for measurements on a watch, where no profiler reads
/// another process's CPU time: with `FLUTTER_WATCHOS_CPU_LOG` set to a number
/// of seconds, logs this process's user+system CPU time over each such window.
/// Off by default; the timer that samples would itself wake the app.
enum FlutterCPULog {
    static func startIfConfigured() {
        guard let raw = ProcessInfo.processInfo.environment["FLUTTER_WATCHOS_CPU_LOG"],
              let seconds = Double(raw), seconds >= 1 else { return }
        var last = cpuSeconds()
        Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { _ in
            let now = cpuSeconds()
            NSLog("FlutterWatchOS: cpu %.1f%% over %.0f s (clock %@)",
                  (now - last) / seconds * 100, seconds,
                  FlutterDisplayClock.shared.paused ? "paused" : "running")
            last = now
        }
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func secs(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return secs(usage.ru_utime) + secs(usage.ru_stime)
    }
}

/// Generic glue around the Flutter engine — identical for every app. It starts
/// the engine, forwards touch and Digital Crown input, displays the frames the
/// engine produces, and plays the crown detent haptic on request.
final class FlutterRunner: ObservableObject {
    static let shared = FlutterRunner()

    /// True once Flutter's first frame is ON SCREEN — what the launch
    /// placeholder waits on before it comes down. The watchOS spelling of
    /// `FlutterViewController.displayingFlutterUI` on iOS.
    ///
    /// Set from `publish`, i.e. from the frame reaching SwiftUI, and NOT from
    /// the engine's `FlutterWatchOSHostSetFirstFrameCallback`. That ABI exists
    /// for this exact job and the host deliberately does not use it yet:
    ///
    ///  * Its premise does not hold on this engine. It was added because "on
    ///    the Metal path frames go straight to the drawable, so the CGImage
    ///    frame callback never fires" — but Impeller here renders to an
    ///    MTLTexture that the engine reads back into a shared MTLBuffer and
    ///    presents through the same CGImage callback as software. Zero-copy
    ///    compositing is a later rung. Both renderers publish frames today.
    ///  * It fires too early. It is armed with
    ///    `FlutterEngineSetNextFrameCallback`, which reports RASTERISATION;
    ///    the pixels reach SwiftUI a display tick or more later. Taking the
    ///    placeholder down then fades it out over black and lets the content
    ///    pop in behind it — measured on a watch simulator as a single-sample
    ///    cut where publishing gives a clean six-sample fade.
    ///
    /// When a zero-copy present path does land, the host that owns the layer
    /// knows when it has presented and should set this there.
    ///
    /// One-way — it never returns to false, so the placeholder cannot come
    /// back once the app is up.
    @Published private(set) var displayingFlutterUI = false

    /// The newest frame the engine has finished, waiting for a display tick.
    /// Written on the raster thread, read on the main thread, hence the lock —
    /// one pointer swap per frame, uncontended in practice.
    private var stashed: [FlutterFrameLayer]?
    /// The same for `WatchPresentMode.texture`. Both can be in use: the
    /// software fallback keeps producing images whatever the mode.
    private var stashedTexture: FlutterTextureFrame?
    /// The same for whole frames as textures (`presentsTextureLayers`).
    private var stashedTextureLayers: TextureLayersFrame?
    private struct TextureLayersFrame {
        let layers: [FlutterFrameLayer]
        let texture: AnyObject?
        let lease: FlutterTextureLease
    }
    private let stashLock = NSLock()

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

    /// The EXPERIMENTAL texture-delivery ABI (`WatchPresentMode.texture`),
    /// dlsym-resolved so this host still links against an engine that predates
    /// it — in which case the mode silently stays `image`.
    typealias TextureFrameCallback = @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
    ) -> Void
    private static let setTextureFrameCallbackFn:
        (@convention(c) (TextureFrameCallback?, UnsafeMutableRawPointer?) -> Void)? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                              "FlutterWatchOSHostSetTextureFrameCallback") else { return nil }
        return unsafeBitCast(
            sym, to: (@convention(c) (TextureFrameCallback?, UnsafeMutableRawPointer?) -> Void).self)
    }()
    private static let releaseFrameTextureFn:
        (@convention(c) (UnsafeMutableRawPointer?) -> Void)? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                              "FlutterWatchOSHostReleaseFrameTexture") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) (UnsafeMutableRawPointer?) -> Void).self)
    }()

    /// Whether the texture present path is on: asked for AND the engine has it.
    static let presentsTextures: Bool =
        WatchPresentMode.current == .texture
        && ((setTextureFrameCallbackFn != nil && releaseFrameTextureFn != nil)
            || presentsTextureLayers)

    /// Every frame with its bottom layer as a texture, platform views
    /// included: the texture twin of the layers callback. Same dlsym rule;
    /// without it an engine that has only the single-texture callback sends
    /// frames with platform views as images.
    typealias TextureLayersCallback = @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<FlutterWatchOSLayer>?,
        UnsafePointer<UnsafeMutableRawPointer?>?, Int32, UnsafeMutableRawPointer?
    ) -> Void
    private static let setTextureLayersCallbackFn:
        (@convention(c) (TextureLayersCallback?, UnsafeMutableRawPointer?) -> Void)? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                              "FlutterWatchOSHostSetTextureLayersCallback") else { return nil }
        return unsafeBitCast(
            sym, to: (@convention(c) (TextureLayersCallback?, UnsafeMutableRawPointer?) -> Void).self)
    }()
    private static let releaseFrameTexturesFn:
        (@convention(c) (UnsafeMutableRawPointer?) -> Void)? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                              "FlutterWatchOSHostReleaseFrameTextures") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) (UnsafeMutableRawPointer?) -> Void).self)
    }()

    static let presentsTextureLayers: Bool =
        WatchPresentMode.current == .texture
        && setTextureLayersCallbackFn != nil && releaseFrameTexturesFn != nil
        && setLayersCallbackFn != nil && hitTestFn != nil

    /// The engine announces each vsync request, so the display tick can pause
    /// while nothing is asked for (see `FlutterDisplayClock`).
    typealias VsyncRequestCallback = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private static let setVsyncRequestCallbackFn:
        (@convention(c) (VsyncRequestCallback?, UnsafeMutableRawPointer?) -> Void)? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                              "FlutterWatchOSHostSetVsyncRequestCallback") else { return nil }
        return unsafeBitCast(
            sym, to: (@convention(c) (VsyncRequestCallback?, UnsafeMutableRawPointer?) -> Void).self)
    }()

    /// Composited frames (see `FlutterFrameLayer`): the engine delivers each
    /// frame as a layer list with the platform views placed by the layer
    /// tree, and answers which view a touch belongs to. dlsym-resolved so
    /// this host still links against an engine that predates it — that
    /// engine sends single images and publishes view rects through the
    /// registry, and the host places them itself (`WatchPlatformViews`).
    typealias LayersCallback = @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<FlutterWatchOSLayer>?, Int32
    ) -> Void
    private static let setLayersCallbackFn:
        (@convention(c) (LayersCallback?, UnsafeMutableRawPointer?) -> Void)? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                              "FlutterWatchOSHostSetLayersCallback") else { return nil }
        return unsafeBitCast(
            sym, to: (@convention(c) (LayersCallback?, UnsafeMutableRawPointer?) -> Void).self)
    }()
    private static let hitTestFn: (@convention(c) (Double, Double) -> Int64)? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                              "FlutterWatchOSHostHitTest") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) (Double, Double) -> Int64).self)
    }()

    /// True when the engine composites platform views from the layer tree.
    static let compositesLayers: Bool = setLayersCallbackFn != nil && hitTestFn != nil

    /// The platform view that owns a touch at `location` (SwiftUI points),
    /// or nil when Flutter does — the engine judges it against the newest
    /// frame: the topmost layer under the point decides, and transparent
    /// Flutter pixels are looked through. Only meaningful when
    /// `compositesLayers`; the legacy host decides from the registry rects.
    func platformView(owningTouchAt location: CGPoint) -> Int64? {
        guard let hitTest = Self.hitTestFn else { return nil }
        let id = hitTest(location.x / WatchContentScale.value,
                         location.y / WatchContentScale.value)
        return id == 0 ? nil : id
    }

    /// Give a texture frame back to the engine. Any thread.
    static func releaseTexture(_ lease: UnsafeMutableRawPointer) {
        releaseFrameTextureFn?(lease)
    }

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

        // Bridge the Dart VM Service out to the CLI's relay, when the CLI asked
        // for it at launch. No-op otherwise, so ordinary runs are unaffected.
        FlutterWatchOSVmBridge.startIfConfigured()

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
        if let setVsyncRequest = Self.setVsyncRequestCallbackFn,
           ProcessInfo.processInfo.environment["FLUTTER_WATCHOS_DISPLAY_CLOCK"] != "continuous" {
            // Registered before Run so the first request already wakes the tick.
            setVsyncRequest({ _ in FlutterDisplayClock.shared.wake() }, nil)
            FlutterDisplayClock.shared.canPause = true
        }
        FlutterCPULog.startIfConfigured()
        if Self.compositesLayers {
            // Registered before Run so the very first frame comes this way.
            Self.setLayersCallbackFn?({ context, layers, count in
                guard let context, let layers, count > 0 else { return }
                let runner = Unmanaged<FlutterRunner>.fromOpaque(context)
                    .takeUnretainedValue()
                runner.stash(layers: UnsafeBufferPointer(start: layers, count: Int(count)))
            }, ctx)
        }
        if Self.presentsTextureLayers {
            // Registered before Run so the very first frame comes this way.
            Self.setTextureLayersCallbackFn?({ context, layers, textures, count, lease in
                guard let context, let lease else { return }
                let claim = FlutterTextureLease(lease) { FlutterRunner.releaseFrameTexturesFn?($0) }
                guard let layers, let textures, count > 0 else { return }
                let runner = Unmanaged<FlutterRunner>.fromOpaque(context)
                    .takeUnretainedValue()
                runner.stash(layers: UnsafeBufferPointer(start: layers, count: Int(count)),
                             textures: UnsafeBufferPointer(start: textures, count: Int(count)),
                             lease: claim)
            }, ctx)
            NSLog("FlutterWatchOS: presenting the bottom layer as a texture, platform views included (experimental)")
        } else if Self.presentsTextures {
            // Registered before Run so the very first frame comes this way.
            Self.setTextureFrameCallbackFn?({ context, texture, lease in
                guard let context, let texture, let lease else { return }
                let runner = Unmanaged<FlutterRunner>.fromOpaque(context)
                    .takeUnretainedValue()
                // Unretained: the engine's lease is what keeps the texture
                // alive, and the material takes its own reference when shown.
                let object = Unmanaged<AnyObject>.fromOpaque(texture).takeUnretainedValue()
                runner.stash(FlutterTextureFrame(texture: object, lease: lease))
            }, ctx)
            NSLog("FlutterWatchOS: presenting textures (experimental)")
        } else if WatchPresentMode.current == .texture {
            NSLog("FlutterWatchOS: texture present requested but this engine has no texture delivery; using images")
        }
        let running = FlutterWatchOSHostRun(
            Bundle.main.bundlePath,
            flutterSize.width,
            flutterSize.height,
            pixelRatio,
            { context, image in
                // Park the frame; the next display tick publishes it. See
                // `presentLatestFrame`.
                guard let context, let image else { return }
                let runner = Unmanaged<FlutterRunner>.fromOpaque(context)
                    .takeUnretainedValue()
                runner.stash(image)
            },
            ctx)
        guard running else {
            NSLog("FlutterWatchOSHostRun failed")
            return
        }

        WatchTextInput.shared.start()
        WatchPlatformViews.shared.start()
        WatchAccessibility.startMirroring()
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

    /// One display refresh, from `EngineVsyncClock`'s display-synced tick.
    ///
    /// The engine renders a frame only if it asked for one, so a tick with
    /// nothing pending costs a call and returns. Without this the engine has
    /// no display clock at all on watchOS (`CADisplayLink` is
    /// `API_UNAVAILABLE`) and falls back to a free-running 60 Hz timer whose
    /// phase drifts against the panel's — judder even with the frame budget
    /// half empty.
    func notifyVsync() {
        FlutterWatchOSHostNotifyVsync()
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

    /// Forward the watch's safe area to the engine, which turns it into
    /// `MediaQuery.padding` — the value `SafeArea` insets by. The engine
    /// stashes it if this lands before `start()`, so ordering does not matter.
    ///
    /// Divided by the content scale for the same reason touches are: the
    /// engine runs in a logical space of `points / contentScale` and
    /// multiplies back by `pixelRatio` (screenScale × contentScale), so an
    /// undivided inset would be scaled twice.
    ///
    /// `leading`/`trailing` map to left/right, which is exact under LTR. Every
    /// watch measured reports the two sides equal (2pt), so RTL sees the same
    /// rectangle either way.
    func reportSafeArea(_ insets: EdgeInsets) {
        let scale = WatchContentScale.value

        // `corners` mode: report only what the display's curvature costs, and
        // let content sit under the clock. See WatchSafeAreaMode for the trade
        // this makes, and WatchDisplayCorner for the geometry. A model this
        // build has no radius for keeps watchOS's own insets — guessing one
        // would clip content, which is the failure this whole path prevents.
        if WatchSafeAreaMode.usesCornerInset, let inset = WatchDisplayCorner.uniformInset {
            let d = inset / scale
            FlutterWatchOSHostSetSafeAreaInsets(d, d, d, d)
            return
        }

        FlutterWatchOSHostSetSafeAreaInsets(insets.top / scale,
                                            insets.trailing / scale,
                                            insets.bottom / scale,
                                            insets.leading / scale)
    }

    /// Raster thread: hold the newest frame until a display tick collects it.
    ///
    /// Retaining is what the `+0` borrow in the callback contract requires, and
    /// assigning to this property is what does it — the engine releases its own
    /// reference as soon as the callback returns.
    ///
    /// Replacing rather than queueing is deliberate. If the engine ever
    /// produced two frames inside one refresh, showing the older one first
    /// would add latency to display a picture that is already stale.
    func stash(_ image: CGImage) {
        stash(frame: [.flutter(index: 0, image: image, painted: [], size: sizePoints)])
    }

    /// The composited twin: a whole frame's layers, converted from the C
    /// structs (whose memory is valid only during the callback) into values.
    /// Same thread and same replacement rule as above.
    func stash(layers: UnsafeBufferPointer<FlutterWatchOSLayer>) {
        stash(frame: Self.frameLayers(layers, textured: false, size: sizePoints))
    }

    /// GPU completion thread: a frame with its bottom layer as a texture and
    /// any layers above platform views as images. The texture is unretained
    /// here — the lease keeps it alive, and the material takes its own
    /// reference when shown; the images are retained by the layer values. A
    /// frame the tick never collected is dropped with its lease, which gives
    /// it straight back to the engine.
    func stash(layers: UnsafeBufferPointer<FlutterWatchOSLayer>,
               textures: UnsafeBufferPointer<UnsafeMutableRawPointer?>,
               lease: FlutterTextureLease) {
        let frame = Self.frameLayers(layers, textured: true, size: sizePoints)
        let texture = textures.lazy.compactMap { $0 }.first
            .map { Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() }
        stashLock.lock()
        let overtaken = stashedTextureLayers
        stashedTextureLayers = TextureLayersFrame(layers: frame, texture: texture, lease: lease)
        stashLock.unlock()
        FlutterDisplayClock.shared.wake()
        _ = overtaken  // released here, outside the lock
    }

    /// The C layers of one frame as values; their memory is valid only during
    /// the callback. `textured`: a Flutter layer without an image is the one
    /// delivered as a texture.
    private static func frameLayers(_ layers: UnsafeBufferPointer<FlutterWatchOSLayer>,
                                    textured: Bool, size sizePoints: CGSize) -> [FlutterFrameLayer] {
        var frame: [FlutterFrameLayer] = []
        frame.reserveCapacity(layers.count)
        for (index, layer) in layers.enumerated() {
            if layer.type == kFlutterWatchOSLayerFlutter {
                let image = layer.image?.takeUnretainedValue()
                if image == nil && !textured { continue }
                var painted: [CGRect] = []
                if let region = layer.region, layer.region_count > 0 {
                    for r in 0..<Int(layer.region_count) {
                        let q = region + r * 4
                        painted.append(WatchContentScale.toDisplay(
                            CGRect(x: q[0], y: q[1], width: q[2], height: q[3])))
                    }
                }
                frame.append(.flutter(index: index, image: image, painted: painted, size: sizePoints))
            } else {
                // Engine geometry is logical points; the host places in
                // SwiftUI points (they differ under FlutterWatchOSContentScale).
                let rect = WatchContentScale.toDisplay(
                    CGRect(x: layer.x, y: layer.y, width: layer.width, height: layer.height))
                let clip = layer.has_clip
                    ? WatchContentScale.toDisplay(CGRect(
                        x: layer.clip_x, y: layer.clip_y,
                        width: layer.clip_width, height: layer.clip_height))
                    : nil
                frame.append(FlutterFrameLayer(
                    id: "pv\(layer.view_id)", image: nil, paintedRects: [],
                    viewId: layer.view_id, rect: rect, opacity: layer.opacity,
                    clip: clip, clipRadius: CGFloat(layer.clip_radius * WatchContentScale.value)))
            }
        }
        return frame
    }

    private func stash(frame: [FlutterFrameLayer]) {
        stashLock.lock()
        stashed = frame
        stashLock.unlock()
        FlutterDisplayClock.shared.wake()
    }

    /// GPU completion thread: the texture twin of the above. A frame the tick
    /// never collected goes straight back to the engine — holding it would
    /// starve the ring for a picture that is already stale.
    func stash(_ frame: FlutterTextureFrame) {
        stashLock.lock()
        let overtaken = stashedTexture
        stashedTexture = frame
        stashLock.unlock()
        if let overtaken { Self.releaseTexture(overtaken.lease) }
        FlutterDisplayClock.shared.wake()
    }

    /// Main thread, once per display refresh: show the newest finished frame.
    ///
    /// This is the second half of giving the engine the display's clock, and
    /// without it the first half does not reach the screen. Frames used to go
    /// `DispatchQueue.main.async { publish(image) }` straight from the raster
    /// thread, landing at an arbitrary point in the run loop; the `@Published`
    /// write then invalidated the view, and SwiftUI drew it on whichever render
    /// pass came next. A frame finishing just after SwiftUI committed waited a
    /// whole refresh, and because the raster clock and the display clock drift
    /// against each other, which frames wait walks slowly through the sequence.
    ///
    /// Measured: fixing only the production clock moved the app's own frame
    /// intervals (p99 22.2 ms -> 19.1 ms on the simulator) while what reached
    /// the screen did not improve at all — 14.1% of captured frames stepped
    /// more than 1.5x the median before, 16.8% after. Producing on time is not
    /// the same as presenting on time.
    ///
    /// Invalidating from the display tick means the ensuing SwiftUI render pass
    /// is the one for the refresh in progress, not an arbitrary later one.
    /// Returns whether a frame was presented, which keeps the display tick
    /// running (see `FlutterDisplayClock`).
    @discardableResult
    func presentLatestFrame() -> Bool {
        stashLock.lock()
        let image = stashed
        let texture = stashedTexture
        let textureLayers = stashedTextureLayers
        stashed = nil
        stashedTexture = nil
        stashedTextureLayers = nil
        stashLock.unlock()
        let presented = image != nil || texture != nil || textureLayers != nil
        if let texture {
            FlutterTexturePresenter.shared.present(texture)
            // A single texture means no platform view and nothing above the
            // bottom layer: images left from an earlier frame would cover it.
            if !FlutterFrameStore.shared.layers.isEmpty {
                FlutterFrameStore.shared.layers = []
            }
            didPublish()
        }
        if let textureLayers {
            if let texture = textureLayers.texture {
                FlutterTexturePresenter.shared.present(texture: texture, lease: textureLayers.lease)
            }
            let store = FlutterFrameStore.shared
            for layer in textureLayers.layers where layer.isPlatformView {
                store.lastRects[layer.viewId] = layer.rect
            }
            let current = store.layers
            let same = current.count == textureLayers.layers.count
                && zip(current, textureLayers.layers).allSatisfy { $0.sameShape(as: $1) }
            if !same {
                store.layers = textureLayers.layers
            }
            didPublish()
        }
        if let image {
            let store = FlutterFrameStore.shared
            for layer in image where layer.isPlatformView {
                store.lastRects[layer.viewId] = layer.rect
            }
            store.layers = image
            didPublish()
        }
        return presented
    }

    /// Main thread, after a frame reached SwiftUI (image) or the presenter
    /// (texture): mirror the plugin's status-bar request alongside it (a cheap
    /// flag read; publishes only on change).
    private func didPublish() {
        // The placeholder's cue: this is the moment Flutter's pixels reach
        // SwiftUI, so the cross-fade has something to reveal. See
        // `displayingFlutterUI` for why the engine's earlier signal is not it.
        if !displayingFlutterUI {
            displayingFlutterUI = true
        }
        if let hiddenFn = Self.statusBarHiddenFn {
            let hidden = hiddenFn()
            if hidden != statusBarHidden { statusBarHidden = hidden }
        }
    }
}
#endif  // !arch(arm64_32)
