// Native Digital Crown scrolling: the host half.
//
// A Flutter app on the watch is one rendered image, so nothing in it can own
// the crown the way a native scroll view does. The host therefore keeps a real
// SwiftUI ScrollView behind the frame (FlutterHostView's crown proxy) shaped
// like the Flutter scrollable the crown should drive: as tall as its scroll
// range plus one screen, in rows of its row pitch. The crown scrolls that
// view, and watchOS applies everything it applies to any native scroll view:
// the acceleration curve, the momentum after a flick, the detent haptics, the
// spring at either end and the crown scroll indicator. Once per display
// refresh the host hands the view's position to Dart, which shows exactly
// that position.
//
// The Dart half is the crown runtime the CLI compiles into every app
// (`runtime/lib/watchos_crown_runtime.dart`), so no app code is needed. It
// picks the scrollable, describes it here, drives it from the reports, and
// tells the host when the content moved by other means (a finger, the app),
// so the crown always continues from where the content is.
//
// This is the only way the crown scrolls; there is no switch back to the
// engine's scroll model. The engine binding (a `.digitalCrownRotation`
// feeding `FlutterWatchOSCrownDelta`) serves one case: the app reads the raw
// crown (`WatchCrown` in package:flutter_watchos switches
// `flutter_watchos_crown_mode` to raw), and a game wants the rotation itself,
// not a scroll view's momentum.
#if !arch(arm64_32)
import Foundation
import SwiftUI

/// Where crown rotation goes right now.
enum WatchCrownRoute: Equatable {
    /// The hidden native ScrollView (the runtime described a scrollable).
    case proxy
    /// The `.digitalCrownRotation` binding into the engine: the app reads
    /// the raw crown.
    case binding
    /// Nowhere: nothing to scroll (or the runtime has not registered yet),
    /// and a native screen with nothing to scroll gives the crown no haptics
    /// either.
    case none
}

// MARK: - The C ABI the crown runtime calls

/// What Dart writes and the main thread reads, behind one lock held only to
/// copy a few scalars.
final class CrownProxyBridge: @unchecked Sendable {
    static let shared = CrownProxyBridge()

    typealias Listener = @convention(c) (Double, Int32) -> Void

    struct Description: Equatable {
        var viewport: Double
        var minExtent: Double
        var maxExtent: Double
        var rowExtent: Double
        var showsIndicator: Bool
        var snaps: Bool
    }

    private let lock = NSLock()
    private var generation: Int32 = 0
    private var description: Description?
    private var syncGeneration: Int32 = 0
    private var syncPixels = 0.0
    private var syncStop = false
    private var listener: Listener?
    private var runtimeAttached = false

    func configure(_ description: Description?) {
        lock.lock(); defer { lock.unlock() }
        self.description = description
        generation &+= 1
    }

    func readDescription() -> (Int32, Description?) {
        lock.lock(); defer { lock.unlock() }
        return (generation, description)
    }

    func sync(_ pixels: Double, stop: Bool) {
        lock.lock(); defer { lock.unlock() }
        syncPixels = pixels
        if stop { syncStop = true }
        syncGeneration &+= 1
    }

    /// The latest position Dart reported and whether a stop was asked for
    /// since the last read (reading clears it).
    func readSync() -> (Int32, Double, Bool) {
        lock.lock(); defer { lock.unlock() }
        let result = (syncGeneration, syncPixels, syncStop)
        syncStop = false
        return result
    }

    func setListener(_ listener: Listener?) {
        lock.lock(); defer { lock.unlock() }
        self.listener = listener
        // Cleared by a runtime starting over (a hot restart): until it
        // registers again, nothing drives the content.
        runtimeAttached = listener != nil
    }

    var isRuntimeAttached: Bool {
        lock.lock(); defer { lock.unlock() }
        return runtimeAttached
    }

    func report(_ pixels: Double, phase: Int32) {
        lock.lock()
        let listener = self.listener
        lock.unlock()
        listener?(pixels, phase)
    }
}

/// Describes the scrollable the crown should drive, in its logical pixels;
/// `active` 0 withdraws it. `indicator` 0 hides watchOS's scroll indicator
/// (`WatchCrownScroll(scrollIndicator: false)`). `snaps` 1: the scrollable
/// rests on whole rows of `rowExtent` (a page view, a wheel), so the native
/// view settles on them too.
@_cdecl("FlutterWatchOSCrownProxyConfigure")
public func FlutterWatchOSCrownProxyConfigure(
    _ active: Int32, _ viewport: Double, _ minExtent: Double,
    _ maxExtent: Double, _ rowExtent: Double, _ indicator: Int32,
    _ snaps: Int32
) {
    // A scrollable without finite extents (an endless list) is described by
    // the runtime as a finite window; anything else here is not a shape a
    // view can take.
    let finite = [viewport, minExtent, maxExtent, rowExtent].allSatisfy { $0.isFinite }
    CrownProxyBridge.shared.configure(
        active != 0 && finite && viewport > 0 && maxExtent >= minExtent
            ? .init(viewport: viewport, minExtent: minExtent,
                    maxExtent: maxExtent, rowExtent: rowExtent,
                    showsIndicator: indicator != 0, snaps: snaps != 0)
            : nil)
    FlutterDisplayClock.shared.wake()
}

/// The scrollable moved without the crown. `stop` 1: a finger took over from
/// the crown, so the native view stops where the content is even mid-glide.
@_cdecl("FlutterWatchOSCrownProxySync")
public func FlutterWatchOSCrownProxySync(_ pixels: Double, _ stop: Int32) {
    CrownProxyBridge.shared.sync(pixels, stop: stop != 0)
    FlutterDisplayClock.shared.wake()
}

/// Registers (NULL clears) the function the host calls with the native view's
/// position, in the scrollable's pixels, and its phase: 1 while the crown
/// moves it, 0 once it rests, and 2 for where a crown turn starts from (sent
/// just before the turn's first 1). A `NativeCallable.listener`, so any
/// thread.
@_cdecl("FlutterWatchOSCrownProxySetListener")
public func FlutterWatchOSCrownProxySetListener(
    _ listener: (@convention(c) (Double, Int32) -> Void)?
) {
    CrownProxyBridge.shared.setListener(listener)
    FlutterDisplayClock.shared.wake()
}

// MARK: - The main-thread model

/// What the crown view follows, published apart from CrownProxyModel: it
/// changes on every frame of a touch scroll, and only the crown view may
/// re-evaluate that often (FlutterHostView observes the model, and its body
/// must not run per frame; see FlutterFrameStore).
final class CrownProxyFollow: ObservableObject {
    static let shared = CrownProxyFollow()

    /// Bumped when Flutter moved without the crown; the view follows.
    @Published fileprivate(set) var request = 0
    /// Bumped when such a move actually moves the view: on a native scroll
    /// view a touch scroll shows the scroll indicator.
    @Published fileprivate(set) var indicatorFlash = 0
}

/// The state FlutterHostView's crown proxy is built from, and the per-refresh
/// exchange with the runtime. Main thread only.
final class CrownProxyModel: ObservableObject {
    static let shared = CrownProxyModel()

    /// The driven scrollable, in Flutter's logical pixels, and the hidden
    /// view's shape in SwiftUI points: one logical pixel is `scale` points
    /// (FlutterWatchOSContentScale), so the crown moves the content as far on
    /// screen as it moves a native view.
    struct Config: Equatable {
        var viewport: Double
        var minExtent: Double
        var maxExtent: Double
        var rowExtent: Double
        var scale: Double
        var showsIndicator: Bool
        /// The scrollable rests on whole rows (a page view, a wheel).
        var snaps: Bool

        /// The scroll range plus one screen, in points.
        var contentPoints: Double { max(viewport, maxExtent - minExtent + viewport) * scale }
        var viewportPoints: Double { viewport * scale }
        var rowPoints: Double { rowExtent * scale }

        /// The scrollable's pixels at the view's `origin` (points), and back.
        func pixels(atOrigin origin: Double) -> Double { minExtent + origin / scale }
        func origin(atPixels pixels: Double) -> Double { (pixels - minExtent) * scale }
    }

    @Published private(set) var route: WatchCrownRoute = .none
    @Published private(set) var config: Config?
    private(set) var syncPixels = 0.0

    /// Written by the view: where it is, whether it rests, whether the crown
    /// is turning it.
    var origin: Double?
    var scrollIdle = true
    var crownActive = false
    /// Set with a sync that must land even mid-glide; the follow consumes it.
    var syncStop = false
    /// Ticks to ignore movement after a follow (it lands a frame later).
    var syncHold = 0

    private var lastTickOrigin: Double?
    private var reportedPhase: Int32 = 0

    /// The view moved. A move while a follow is held out and the crown is not
    /// turning is the follow landing: where a crown turn would start from,
    /// not part of one. Recording it here, as it lands, keeps a turn started
    /// during a Flutter fling from counting the last follow as its own first
    /// step (the content would jump a frame of the fling ahead).
    func viewMoved(to origin: Double) {
        self.origin = origin
        if syncHold > 0 && !crownActive {
            lastTickOrigin = origin
        }
    }
    private var generation: Int32 = -1
    private var syncGeneration: Int32 = -1

    private typealias ModeFn = @convention(c) () -> Int32
    /// package:flutter_watchos's raw crown switch, when the app links it.
    private static let crownModeFn: ModeFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "flutter_watchos_crown_mode")
        else { return nil }
        return unsafeBitCast(sym, to: ModeFn.self)
    }()

    /// One display refresh, before the engine starts its frame: take the
    /// runtime's description and position, decide the route, and report the
    /// native view's position.
    func tick() {
        let bridge = CrownProxyBridge.shared
        let (gen, description) = bridge.readDescription()
        if gen != generation {
            generation = gen
            let next = description.map {
                Config(viewport: $0.viewport, minExtent: $0.minExtent,
                       maxExtent: $0.maxExtent, rowExtent: $0.rowExtent > 1 ? $0.rowExtent : 44,
                       scale: WatchContentScale.value,
                       showsIndicator: $0.showsIndicator, snaps: $0.snaps)
            }
            if next != config {
                if next == nil || config == nil { origin = nil; lastTickOrigin = nil }
                config = next
            }
        }

        let raw = (Self.crownModeFn?() ?? 0) != 0
        let nextRoute: WatchCrownRoute
        if raw {
            nextRoute = .binding
        } else if bridge.isRuntimeAttached, config != nil {
            nextRoute = .proxy
        } else {
            nextRoute = .none
        }
        if nextRoute != route {
            // A turn still open when the crown goes elsewhere (the app took
            // the raw crown mid-glide) is over: say so, or the runtime holds
            // the content in a drive that never ends.
            if route == .proxy, reportedPhase == 1, let config, let origin {
                bridge.report(config.pixels(atOrigin: origin), phase: 0)
            }
            route = nextRoute
            crownActive = false
            reportedPhase = 0
            // The proxy view is created afresh on entering .proxy; nothing the
            // old one reported holds for it.
            origin = nil
            lastTickOrigin = nil
            syncHold = 0
        }
        guard route == .proxy, let config else { return }

        let (syncGen, pixels, stop) = bridge.readSync()
        if syncGen != syncGeneration {
            syncGeneration = syncGen
            if stop || !crownActive {
                if stop {
                    crownActive = false
                    syncStop = true
                }
                // The view now follows Flutter, so a turn still open is over:
                // say so, or the runtime keeps waiting for its rest and the
                // next turn finds the crown dead.
                if reportedPhase == 1, let origin {
                    bridge.report(config.pixels(atOrigin: origin), phase: 0)
                    reportedPhase = 0
                }
                // Held from now, not from when the view gets to it: the
                // follow lands a turn later, and the glide it stops must not
                // read as the crown meanwhile.
                syncHold = max(syncHold, 3)
                syncPixels = pixels
                let follow = CrownProxyFollow.shared
                follow.request &+= 1
                if let origin, abs(config.origin(atPixels: pixels) - origin) > 0.25 {
                    follow.indicatorFlash &+= 1
                }
            }
        }

        // Only the crown moves the view (touches never reach it), apart from
        // the follows, which are held out.
        if syncHold > 0 {
            syncHold -= 1
            lastTickOrigin = origin
        } else if let origin {
            let pixels = config.pixels(atOrigin: origin)
            if lastTickOrigin == nil {
                // Where a new view starts out: not a move.
                lastTickOrigin = origin
            } else if let start = lastTickOrigin, origin != start {
                if reportedPhase == 0 {
                    // Where this turn starts from: where the last follow left
                    // the view. Following a Flutter fling, that trails the
                    // content by a frame or two; the runtime needs it to take
                    // over without a jump.
                    bridge.report(config.pixels(atOrigin: start), phase: 2)
                }
                lastTickOrigin = origin
                bridge.report(pixels, phase: 1)
                reportedPhase = 1
            } else if reportedPhase == 1 && scrollIdle {
                bridge.report(pixels, phase: 0)
                reportedPhase = 0
            }
        }
    }
}
#endif
