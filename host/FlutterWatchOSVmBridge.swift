import Foundation

/// Watch-side half of the VM Service tunnel.
///
/// The Mac cannot dial into a watch app: watchOS refuses third-party apps
/// direct sockets to a raw IP:port. It does allow `URLSession`, brokered
/// through a system daemon, and that path reaches the Mac (proxied via the
/// paired iPhone). `URLSessionWebSocketTask` does *not* survive that path, so
/// the watch↔Mac hop is plain HTTP request/response.
///
///   flutter_tools ──TCP──▶ CLI relay ──HTTP long-poll──▶ this ──TCP──▶ VM Service
///
/// Loopback *is* a direct socket the sandbox permits, so the VM Service side is
/// an ordinary BSD socket. Nothing here parses the VM Service protocol: this is
/// a byte pump, and flutter_tools and the Dart VM do the HTTP upgrade and
/// WebSocket framing end to end.
///
/// This deliberately does not use `URLSessionWebSocketTask` on the loopback
/// leg. That was the previous design and it could not connect to the app's own
/// VM Service — ~200 consecutive "Could not connect to the server" against an
/// endpoint that was demonstrably listening and that a raw socket reaches
/// first try. See docs/watchos-vm-service-transport.md.
///
/// The CLI activates this by launching the app with
/// `FLUTTER_WATCHOS_RELAY_URL` and `FLUTTER_WATCHOS_VM_PORT` set. With neither
/// present — every normal run — nothing here starts.
@objc public final class FlutterWatchOSVmBridge: NSObject {
    private static let relayURLKey = "FLUTTER_WATCHOS_RELAY_URL"
    private static let vmPortKey = "FLUTTER_WATCHOS_VM_PORT"

    /// Starts the bridge if the CLI asked for it. Safe to call unconditionally.
    @objc public static func startIfConfigured() {
        let environment = ProcessInfo.processInfo.environment
        guard let relay = environment[relayURLKey],
              let relayURL = URL(string: relay),
              let portText = environment[vmPortKey],
              let port = UInt16(portText)
        else {
            return
        }
        let bridge = FlutterWatchOSVmBridge(relayURL: relayURL, vmServicePort: port)
        shared = bridge
        bridge.start()
    }

    /// Held so the bridge outlives `startIfConfigured`.
    private static var shared: FlutterWatchOSVmBridge?

    private let relayURL: URL
    private let vmServicePort: UInt16
    /// A poll is held open by the relay, and waiting through a blip on the
    /// phone-proxied path is what we want.
    private let session: URLSession
    private var running = false

    /// Live tunnel connections, keyed by the relay's connection id.
    private let connectionsLock = NSLock()
    private var connections: [Int: VmSocket] = [:]

    /// Outbound frames, batched so a burst of stream events costs one POST
    /// rather than one per event.
    private let pendingLock = NSLock()
    private var pending: [String] = []
    /// Exactly one push may be in flight at a time — see `flushToRelay`.
    private var flushInFlight = false

    init(relayURL: URL, vmServicePort: UInt16) {
        self.relayURL = relayURL
        self.vmServicePort = vmServicePort
        // Ephemeral, because the default configuration caches responses to
        // disk. Every poll response and push here is single-use tunnel traffic,
        // so caching it is pure cost — measured, a 14.7MB profile fetch filled
        // the app's cache storage and set watchOS purging it mid-session
        // ("Cache storage usage still exceeds limit after cache shrinking").
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // A poll is held open by the relay; it must not be cut short.
        configuration.timeoutIntervalForRequest = 60
        configuration.waitsForConnectivity = true
        self.session = URLSession(configuration: configuration)
        super.init()
    }

    private func start() {
        guard !running else { return }
        running = true
        NSLog("[flutter-watchos] vm bridge starting, relay=%@ vmPort=%d",
              relayURL.absoluteString, Int(vmServicePort))
        announce()
        poll()
    }

    // MARK: - Relay side (HTTP)

    private func relayRequest(path: String, method: String) -> URLRequest {
        var request = URLRequest(url: relayURL.appendingPathComponent(path))
        request.httpMethod = method
        return request
    }

    /// Tells the relay the app is up, so `run` can stop waiting.
    private func announce() {
        let task = session.dataTask(with: relayRequest(path: "bridge/hello", method: "GET")) { _, _, error in
            if let error {
                NSLog("[flutter-watchos] vm bridge hello failed: %@", error.localizedDescription)
            }
        }
        task.resume()
    }

    /// Long-polls the relay for Mac→watch frames, forever.
    ///
    /// Re-arms itself on every outcome, including failure: a dropped poll is
    /// normal when the phone-proxied path hiccups, and giving up would strand
    /// the session with no way back.
    private func poll() {
        guard running else { return }
        let task = session.dataTask(with: relayRequest(path: "bridge/poll", method: "GET")) { [weak self] data, _, error in
            guard let self, self.running else { return }
            if let error {
                NSLog("[flutter-watchos] vm bridge poll failed: %@", error.localizedDescription)
                self.repoll(afterSeconds: 1)
                return
            }
            if let data,
               let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let frames = payload["frames"] as? [String] {
                for line in frames {
                    self.applyFrameFromRelay(line)
                }
            }
            self.repoll(afterSeconds: 0)
        }
        task.resume()
    }

    private func repoll(afterSeconds delay: Double) {
        guard running else { return }
        if delay <= 0 {
            poll()
        } else {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.poll()
            }
        }
    }

    private func applyFrameFromRelay(_ line: String) {
        guard let frame = TunnelFrame(line: line) else {
            NSLog("[flutter-watchos] vm bridge dropping malformed frame")
            return
        }
        switch frame.kind {
        case .open:
            openConnection(id: frame.connectionId)
        case .data:
            guard let socket = connection(for: frame.connectionId) else {
                // Silently dropping a frame here corrupts the byte stream, and
                // the symptom (a VM Service that never answers) looks nothing
                // like the cause. Benign only when it races a close.
                NSLog("[flutter-watchos] vm bridge no connection %d for %d-byte data frame",
                      frame.connectionId, frame.payload.count)
                return
            }
            socket.write(frame.payload)
        case .close:
            closeConnection(id: frame.connectionId, notifyRelay: false)
        }
    }

    /// Largest batch of frames to put in one POST. Big enough that a bulk reply
    /// (a CPU profile is megabytes) is not paid for one round trip per 32KB
    /// read, small enough that a single request stays bounded.
    private static let maxPushBytes = 512 * 1024

    /// Queues a frame for the Mac.
    private func enqueueForRelay(_ frame: String) {
        pendingLock.lock()
        pending.append(frame)
        let shouldStart = !flushInFlight
        if shouldStart {
            flushInFlight = true
        }
        pendingLock.unlock()

        if shouldStart {
            flushToRelay()
        }
    }

    /// Posts the queued frames, then re-posts whatever accumulated meanwhile.
    ///
    /// Strictly one request in flight at a time. This is a byte stream, so
    /// order is not negotiable, and `URLSession` gives no ordering guarantee
    /// between concurrent tasks — two overlapping pushes could be delivered
    /// back to front and silently corrupt the stream.
    ///
    /// Serialising also fixes throughput rather than costing it: everything the
    /// VM Service produces while a request is in flight coalesces into the next
    /// one, so a bulk reply self-tunes into a few large POSTs instead of
    /// hundreds of small ones over a phone-proxied link.
    private func flushToRelay() {
        pendingLock.lock()
        var batch: [String] = []
        var bytes = 0
        while !pending.isEmpty, bytes < Self.maxPushBytes {
            let frame = pending.removeFirst()
            bytes += frame.utf8.count + 1
            batch.append(frame)
        }
        if batch.isEmpty {
            flushInFlight = false
            pendingLock.unlock()
            return
        }
        pendingLock.unlock()

        // Newline-delimited: frames are base64 with a numeric header, so the
        // relay can split them again unambiguously.
        let body = batch.joined(separator: "\n")
        var request = relayRequest(path: "bridge/push", method: "POST")
        request.httpBody = body.data(using: .utf8)
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        session.dataTask(with: request) { [weak self] _, _, error in
            guard let self else { return }
            if let error {
                // The frames are gone. Losing bytes mid-stream is unrecoverable
                // for the connection, so say so plainly rather than let it look
                // like a hang.
                NSLog("[flutter-watchos] vm bridge push failed, stream is now broken: %@",
                      error.localizedDescription)
            }
            guard self.running else { return }
            self.flushToRelay()
        }.resume()
    }

    // MARK: - VM Service side (loopback TCP)

    private func connection(for id: Int) -> VmSocket? {
        connectionsLock.lock()
        defer { connectionsLock.unlock() }
        return connections[id]
    }

    private func openConnection(id: Int) {
        connectionsLock.lock()
        let existing = connections[id]
        connectionsLock.unlock()
        if existing != nil {
            NSLog("[flutter-watchos] vm bridge ignoring duplicate open for %d", id)
            return
        }

        let socket = VmSocket(
            id: id,
            port: vmServicePort,
            onBytes: { [weak self] data in
                self?.enqueueForRelay(TunnelFrame(connectionId: id, kind: .data, payload: data).encoded())
            },
            onClosed: { [weak self] in
                self?.closeConnection(id: id, notifyRelay: true)
            }
        )
        connectionsLock.lock()
        connections[id] = socket
        connectionsLock.unlock()
        socket.start()
    }

    private func closeConnection(id: Int, notifyRelay: Bool) {
        connectionsLock.lock()
        let socket = connections.removeValue(forKey: id)
        connectionsLock.unlock()
        guard let socket else { return }
        socket.close()
        if notifyRelay, running {
            enqueueForRelay(TunnelFrame(connectionId: id, kind: .close, payload: Data()).encoded())
        }
    }
}

// MARK: - Frame

/// `<connection-id>:<kind>:<base64 payload>`. Mirrors `TunnelFrame` in
/// lib/watchos_vm_relay.dart; the two must stay in step.
private struct TunnelFrame {
    enum Kind: String {
        case open = "o"
        case data = "d"
        case close = "c"
    }

    let connectionId: Int
    let kind: Kind
    let payload: Data

    init(connectionId: Int, kind: Kind, payload: Data) {
        self.connectionId = connectionId
        self.kind = kind
        self.payload = payload
    }

    /// Parses one frame, or returns nil if the line is malformed. Tolerant by
    /// design: a corrupt frame should cost one message, not the session.
    init?(line: String) {
        let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3,
              let id = Int(parts[0]),
              let kind = Kind(rawValue: String(parts[1]))
        else {
            return nil
        }
        let encoded = String(parts[2])
        if encoded.isEmpty {
            self.init(connectionId: id, kind: kind, payload: Data())
            return
        }
        guard let decoded = Data(base64Encoded: encoded) else {
            return nil
        }
        self.init(connectionId: id, kind: kind, payload: decoded)
    }

    func encoded() -> String {
        let body = payload.isEmpty ? "" : payload.base64EncodedString()
        return "\(connectionId):\(kind.rawValue):\(body)"
    }
}

// MARK: - Loopback socket

/// One raw TCP connection to the app's own VM Service.
///
/// Deliberately plain BSD sockets rather than `Network.framework`: this is the
/// one API family measured to work from a watchOS app to loopback, and there is
/// no protocol here worth a higher-level abstraction — it moves bytes.
private final class VmSocket {
    private let id: Int
    private let port: UInt16
    private let onBytes: (Data) -> Void
    private let onClosed: () -> Void

    /// Serialises connect and writes, so a write can never be applied before
    /// the connect it depends on and frames keep their relay order.
    private let queue: DispatchQueue
    private var fd: Int32 = -1
    private var closed = false
    private let stateLock = NSLock()
    /// One-shot markers: enough to prove each leg moved bytes, without logging
    /// every frame of a megabyte transfer.
    private var loggedFirstWrite = false
    private var loggedFirstRead = false

    init(id: Int, port: UInt16, onBytes: @escaping (Data) -> Void, onClosed: @escaping () -> Void) {
        self.id = id
        self.port = port
        self.onBytes = onBytes
        self.onClosed = onClosed
        self.queue = DispatchQueue(label: "dev.flutterwatch.vmbridge.conn\(id)")
    }

    func start() {
        queue.async { [weak self] in
            self?.connectWithRetry()
        }
    }

    /// The VM Service may not be listening the instant flutter_tools connects —
    /// the bridge starts before `FlutterWatchOSHostRun()`. Retry briefly rather
    /// than losing the session to a startup race.
    private func connectWithRetry() {
        let deadline = Date().addingTimeInterval(15)
        var attempt = 0
        while !isClosed() {
            attempt += 1
            if connectOnce() {
                NSLog("[flutter-watchos] vm bridge connection %d attached to VM Service (attempt %d)",
                      id, attempt)
                startReadLoop()
                return
            }
            if Date() >= deadline {
                break
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        if !isClosed() {
            NSLog("[flutter-watchos] vm bridge connection %d could not reach the VM Service on port %d",
                  id, Int(port))
            onClosed()
        }
    }

    private func connectOnce() -> Bool {
        let handle = socket(AF_INET, SOCK_STREAM, 0)
        guard handle >= 0 else { return false }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(handle, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(handle)
            return false
        }

        // The VM Service protocol is request/response over small frames; Nagle
        // would add a round trip of latency to every one of them.
        var on: Int32 = 1
        setsockopt(handle, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
        // Without this a write to a closed socket kills the whole app with
        // SIGPIPE rather than returning EPIPE.
        setsockopt(handle, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        stateLock.lock()
        fd = handle
        let alreadyClosed = closed
        stateLock.unlock()

        if alreadyClosed {
            Darwin.close(handle)
            return false
        }
        return true
    }

    /// Blocking reads on a dedicated thread. At most a couple of connections
    /// exist at a time, so a thread each is cheaper to reason about than an
    /// event-source state machine.
    private func startReadLoop() {
        Thread { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 32 * 1024)
            while !self.isClosed() {
                let handle = self.currentFd()
                guard handle >= 0 else { break }
                let count = read(handle, &buffer, buffer.count)
                if count > 0 {
                    if !self.loggedFirstRead {
                        self.loggedFirstRead = true
                        NSLog("[flutter-watchos] vm bridge connection %d: first read ok (%d bytes)",
                              self.id, count)
                    }
                    self.onBytes(Data(buffer[0..<count]))
                    continue
                }
                if count < 0 && errno == EINTR {
                    continue
                }
                break
            }
            if !self.isClosed() {
                NSLog("[flutter-watchos] vm bridge connection %d: VM Service closed", self.id)
                self.onClosed()
            }
        }.start()
    }

    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let handle = self.currentFd()
            guard handle >= 0 else {
                NSLog("[flutter-watchos] vm bridge connection %d: dropping write, not connected", self.id)
                return
            }
            var sent = 0
            // Captured rather than read after the fact: `errno` is per-thread
            // but any call below (including NSLog) can clobber it, and without
            // the cause a short write is undiagnosable — "short write (0/367)"
            // says nothing about whether the peer hung up or the buffer filled.
            var failure: Int32 = 0
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress else { return }
                while sent < data.count {
                    let written = send(handle, base.advanced(by: sent), data.count - sent, 0)
                    if written > 0 {
                        sent += written
                        continue
                    }
                    if written < 0 && errno == EINTR {
                        continue
                    }
                    // No EAGAIN case on purpose: the socket is blocking with no
                    // SO_SNDTIMEO, so send() cannot return it. Retrying on it
                    // would spin if anyone ever adds a send timeout.
                    failure = written < 0 ? errno : 0
                    break
                }
            }
            if sent < data.count {
                let reason = failure == 0 ? "peer closed" : String(cString: strerror(failure))
                NSLog("[flutter-watchos] vm bridge connection %d: short write (%d/%d), errno=%d (%@)",
                      self.id, sent, data.count, failure, reason)
                self.onClosed()
                return
            }
            if !self.loggedFirstWrite {
                self.loggedFirstWrite = true
                NSLog("[flutter-watchos] vm bridge connection %d: first write ok (%d bytes)",
                      self.id, sent)
            }
        }
    }

    func close() {
        stateLock.lock()
        let alreadyClosed = closed
        closed = true
        let handle = fd
        fd = -1
        stateLock.unlock()
        guard !alreadyClosed, handle >= 0 else { return }
        // Wakes the blocked read so the loop can notice and exit.
        shutdown(handle, SHUT_RDWR)
        Darwin.close(handle)
    }

    private func isClosed() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return closed
    }

    private func currentFd() -> Int32 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return fd
    }
}
