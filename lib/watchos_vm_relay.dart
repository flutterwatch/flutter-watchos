// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Mac-side half of the watchOS VM Service tunnel.
//
// A watch app cannot be reached over the network: watchOS refuses third-party
// apps direct sockets to a raw IP:port (`dart:io` and `NWConnection` both get
// ENETDOWN). What it does allow is `URLSession`, brokered through a system
// daemon, and that path reaches the Mac — proxied via the paired iPhone.
// `URLSessionWebSocketTask` does *not* survive that path, so the watch↔Mac hop
// has to be plain HTTP request/response.
//
//   flutter_tools ──TCP──▶ this relay ──HTTP long-poll──▶ bridge ──TCP──▶ VM Service
//
// Both ends of the tunnel are raw byte streams and *nothing in the middle
// parses the VM Service protocol*: flutter_tools and the Dart VM perform the
// HTTP upgrade and WebSocket framing end to end, exactly as they would over a
// direct connection. That is the whole point of the design — the relay cannot
// mis-frame a message it never looks at, and features that arrive in a future
// Dart SDK work without changes here.
//
// The earlier revision terminated WebSocket on both ends. It failed on device:
// `URLSessionWebSocketTask` could not connect even to the app's own loopback
// VM Service. Bytes over a raw socket connect there fine, so the fix is to stop
// speaking the protocol at all.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:meta/meta.dart';

/// Picks the port the Dart VM Service is pinned to on the watch.
///
/// The in-app bridge cannot discover the port the VM chose, so the CLI fixes it
/// at launch with `--vm-service-port` and hands the same value to the bridge.
///
/// Deliberately random per run rather than a constant: a watch app that outlives
/// an unclean `run` keeps its port bound, and a fixed choice would then leave
/// every later run with no VM Service at all — silently, because the bind
/// failure never reaches the console. Measured: a stale instance held 45460
/// while a manual launch on 45470 came up first try.
int pickDeviceVmServicePort({math.Random? random}) {
  const low = 45000;
  const high = 46000;
  return low + (random ?? math.Random()).nextInt(high - low);
}

/// How long a bridge poll is held open before returning empty. Long enough to
/// keep request overhead negligible, short enough to stay well inside any
/// intermediary's idle timeout.
const Duration kBridgePollTimeout = Duration(seconds: 20);

/// `Content-Encoding` the bridge uses for a compressed push body.
///
/// Deliberately not `deflate`: that token means zlib-wrapped data (RFC 1950)
/// to most HTTP stacks, and watchOS's `COMPRESSION_ZLIB` emits bare RFC 1951.
/// Must match `rawDeflateEncoding` in host/FlutterWatchOSVmBridge.swift.
const String kRawDeflateEncoding = 'x-raw-deflate';

/// Below this, framing overhead outweighs any saving, so send it plain.
const int kMinCompressBytes = 256;

/// Header carrying a push body's position in the bridge's byte stream.
///
/// The bridge keeps several pushes in flight to hide the phone-proxied path's
/// round-trip time, and `URLSession` gives no ordering guarantee between
/// concurrent tasks — so the relay reassembles bodies in sequence order
/// instead of arrival order. Absent header means an unpipelined sender (the
/// bridge before this protocol, or a test); those bodies apply immediately.
const String kPushSeqHeader = 'x-relay-seq';

/// Header naming the bridge instance a push's sequence belongs to.
///
/// A relaunched app restarts its counter at 0; without this, its first push
/// would look like a duplicate of a sequence the relay has already applied and
/// the new stream would stall forever.
const String kPushEpochHeader = 'x-relay-epoch';

/// Raw DEFLATE (RFC 1951), matching what the watch produces.
final ZLibCodec _rawInflate = ZLibCodec(raw: true);

/// Generates the secret path prefix guarding the bridge endpoints.
///
/// The bridge endpoints have to listen on every interface — the watch reaches
/// the Mac by LAN address, so loopback would be unreachable — which puts an
/// unauthenticated door into a live debug session on the local network. Anyone
/// who could reach it could POST frames straight into flutter_tools, or drain
/// the poll queue and starve the real bridge. Worse, the app is launched with
/// `--disable-service-auth-codes`, so this would be strictly weaker than the
/// stock VM Service posture it stands in for.
///
/// 128 bits from a cryptographic source, minted per run and never written to
/// disk. It travels to the watch inside `FLUTTER_WATCHOS_RELAY_URL`, so the
/// bridge needs no code for it — it simply dials the URL it was handed.
String generateRelayToken({math.Random? random}) {
  final math.Random source = random ?? math.Random.secure();
  return List<int>.generate(16, (_) => source.nextInt(256))
      .map((int byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
}

/// What a tunnel frame does to the connection it names.
enum TunnelFrameKind {
  /// Mac→watch only: flutter_tools opened a connection; dial the VM Service.
  open('o'),

  /// Bytes to hand to the far end of this connection, verbatim.
  data('d'),

  /// The far end went away; tear the other side down.
  close('c');

  const TunnelFrameKind(this.code);

  /// One-character wire tag.
  final String code;

  static TunnelFrameKind? fromCode(String code) {
    for (final TunnelFrameKind kind in TunnelFrameKind.values) {
      if (kind.code == code) {
        return kind;
      }
    }
    return null;
  }
}

/// One unit of the tunnel: `<connection-id>:<kind>:<base64 payload>`.
///
/// Text rather than binary so a batch is newline-delimited and the whole hop
/// stays trivially debuggable with `curl`. Base64 costs a third more bytes on a
/// link that carries a few hundred KB per session — not worth optimising, and
/// the framing bugs it rules out are exactly the ones that are painful to find
/// through a phone-proxied HTTP hop.
@immutable
class TunnelFrame {
  const TunnelFrame(this.connectionId, this.kind, this.payload);

  /// A frame carrying no payload.
  const TunnelFrame.control(this.connectionId, this.kind) : payload = const <int>[];

  final int connectionId;
  final TunnelFrameKind kind;
  final List<int> payload;

  String encode() {
    final String encodedPayload = payload.isEmpty ? '' : base64.encode(payload);
    return '$connectionId:${kind.code}:$encodedPayload';
  }

  /// Parses one frame, or returns null if [line] is malformed.
  ///
  /// Tolerant by design: a corrupted frame should cost one message, not the
  /// session, and the far end is a different language runtime.
  static TunnelFrame? decode(String line) {
    final int firstColon = line.indexOf(':');
    if (firstColon <= 0) {
      return null;
    }
    final int secondColon = line.indexOf(':', firstColon + 1);
    if (secondColon < 0) {
      return null;
    }
    final int? id = int.tryParse(line.substring(0, firstColon));
    if (id == null) {
      return null;
    }
    final TunnelFrameKind? kind = TunnelFrameKind.fromCode(
      line.substring(firstColon + 1, secondColon),
    );
    if (kind == null) {
      return null;
    }
    final String encodedPayload = line.substring(secondColon + 1);
    if (encodedPayload.isEmpty) {
      return TunnelFrame.control(id, kind);
    }
    try {
      return TunnelFrame(id, kind, base64.decode(encodedPayload));
    } on FormatException {
      return null;
    }
  }

  @override
  bool operator ==(Object other) {
    return other is TunnelFrame &&
        other.connectionId == connectionId &&
        other.kind == kind &&
        _sameBytes(other.payload, payload);
  }

  @override
  int get hashCode => Object.hash(connectionId, kind, payload.length);

  @override
  String toString() => 'TunnelFrame($connectionId, ${kind.code}, ${payload.length}B)';

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }
}

/// One direction of the pipe: frames waiting to be handed to whoever asks
/// next, plus a way to wait for the queue to become non-empty.
///
/// Split out from the server so the queueing rules — which are the part with
/// actual edge cases — can be tested without sockets.
@visibleForTesting
class RelayQueue {
  final Queue<String> _pending = Queue<String>();
  Completer<void>? _waiter;

  /// Frames currently buffered.
  int get length => _pending.length;

  /// Adds [message] and wakes any waiter.
  void add(String message) {
    _pending.add(message);
    final Completer<void>? waiter = _waiter;
    if (waiter != null && !waiter.isCompleted) {
      _waiter = null;
      waiter.complete();
    }
  }

  /// Takes everything buffered, leaving the queue empty.
  List<String> drain() {
    final List<String> messages = _pending.toList(growable: false);
    _pending.clear();
    return messages;
  }

  /// Drains immediately if anything is buffered, otherwise waits up to
  /// [timeout] for the first frame. Returns an empty list on timeout.
  ///
  /// The wait is what makes long-polling cheap: the watch keeps one request
  /// open rather than asking repeatedly.
  Future<List<String>> drainWhenReady(Duration timeout) async {
    if (_pending.isNotEmpty) {
      return drain();
    }
    final waiter = Completer<void>();
    _waiter = waiter;
    final timer = Timer(timeout, () {
      if (!waiter.isCompleted) {
        // Only clear the slot if it is still ours. A later waiter may have
        // taken it, and unregistering that one would leave `add` with nobody
        // to wake — the frames would then sit until its own timeout fired.
        if (identical(_waiter, waiter)) {
          _waiter = null;
        }
        waiter.complete();
      }
    });
    await waiter.future;
    timer.cancel();
    return drain();
  }

  /// Drops buffered frames and releases any waiter.
  void close() {
    _pending.clear();
    final Completer<void>? waiter = _waiter;
    _waiter = null;
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete();
    }
  }
}

/// Relay endpoints, kept in one place so the Swift bridge and the tests cannot
/// drift apart silently.
///
/// These are suffixes: every request is served under the run's secret token
/// prefix (see [generateRelayToken]), which [WatchosVmRelay.pathFor] applies.
class RelayPaths {
  /// Bridge long-polls here for frames headed to the watch.
  static const String bridgePoll = '/bridge/poll';

  /// Bridge posts frames from the VM Service here.
  static const String bridgePush = '/bridge/push';

  /// Bridge announces itself here; also a health check.
  static const String bridgeHello = '/bridge/hello';
}

/// The Mac-side relay: a TCP listener for flutter_tools, and an HTTP endpoint
/// the watch bridge dials out to.
class WatchosVmRelay {
  WatchosVmRelay._(
    this._bridgeServer,
    this._tunnelServer, {
    required void Function(String) logTrace,
    required this.token,
    required Duration pushGapTimeout,
  }) : _logTrace = logTrace,
       _pushGapTimeout = pushGapTimeout,
       port = _bridgeServer.port,
       tunnelPort = _tunnelServer.port;

  final HttpServer _bridgeServer;
  final ServerSocket _tunnelServer;
  final void Function(String) _logTrace;

  /// Secret prefix every bridge request must carry. See [generateRelayToken]
  /// for why the endpoints cannot simply be bound to loopback instead.
  final String token;

  /// Port the bridge endpoints listen on, on every interface — the watch
  /// reaches the Mac by LAN address, so loopback-only would be unreachable.
  /// Unauthenticated callers get a 404 and change no state; see [token].
  final int port;

  /// Port flutter_tools connects to. Loopback only: nothing off this Mac has
  /// any business talking to the tunnel.
  final int tunnelPort;

  /// Mac→watch frames, waiting for the bridge to collect them.
  final RelayQueue _toWatch = RelayQueue();

  /// Live flutter_tools connections, by tunnel connection id.
  final Map<int, Socket> _connections = <int, Socket>{};
  int _nextConnectionId = 1;

  /// Bytes moved, so a slow tunnel can be told apart from a stalled one.
  ///
  /// Without this the trace log shows only connection open/close, and a
  /// DevTools session that is crawling looks exactly like one that has hung —
  /// which cost a debugging session to exactly that ambiguity.
  int _bytesToWatch = 0;
  int _bytesFromWatch = 0;
  int _lastReportedToWatch = 0;
  int _lastReportedFromWatch = 0;
  Timer? _throughputTimer;

  /// Bytes actually carried over HTTP from the watch, before inflating.
  ///
  /// Tracked separately from [_bytesFromWatch] (which counts VM Service
  /// payload) so the log can show what compression is buying. The link is the
  /// binding constraint on this transport, so the ratio is the number worth
  /// watching when it regresses.
  int _wireBytesFromWatch = 0;
  int _lastReportedWireFromWatch = 0;

  /// How often to report throughput while a connection is open.
  static const Duration _throughputInterval = Duration(seconds: 10);

  void _startThroughputReporting() {
    _throughputTimer ??= Timer.periodic(_throughputInterval, (Timer _) {
      if (_connections.isEmpty) {
        _stopThroughputReporting();
        return;
      }
      final int up = _bytesToWatch - _lastReportedToWatch;
      final int down = _bytesFromWatch - _lastReportedFromWatch;
      final int wireDown = _wireBytesFromWatch - _lastReportedWireFromWatch;
      _lastReportedToWatch = _bytesToWatch;
      _lastReportedFromWatch = _bytesFromWatch;
      _lastReportedWireFromWatch = _wireBytesFromWatch;
      final int seconds = _throughputInterval.inSeconds;
      if (up == 0 && down == 0) {
        _logTrace(
          'relay: ${_connections.length} connection(s) open but NO traffic for '
          '${seconds}s — the tunnel is stalled, not merely slow',
        );
      } else {
        // Two rates on purpose: the payload rate is what DevTools experiences,
        // the wire rate is what the link is actually spending.
        final ratio = (wireDown > 0 && down > 0)
            ? ', ${(down / wireDown).toStringAsFixed(1)}x compression'
            : '';
        _logTrace(
          'relay: ${(up / seconds / 1024).toStringAsFixed(1)} KB/s to watch, '
          '${(down / seconds / 1024).toStringAsFixed(1)} KB/s from watch '
          '(${(wireDown / seconds / 1024).toStringAsFixed(1)} KB/s on the wire'
          '$ratio) '
          '(${_connections.length} connection(s))',
        );
      }
    });
  }

  void _stopThroughputReporting() {
    _throughputTimer?.cancel();
    _throughputTimer = null;
  }

  /// Whether the watch bridge has checked in.
  bool get bridgeConnected => _bridgeConnected;
  bool _bridgeConnected = false;

  final _bridgeArrived = Completer<void>();
  bool _disposed = false;

  /// Completes once the watch bridge makes contact. Lets `run` wait for the
  /// app to come up rather than handing out a URI nothing is behind yet.
  Future<void> get bridgeReady => _bridgeArrived.future;

  static Future<WatchosVmRelay> start({
    required void Function(String) logTrace,
    int port = 0,
    int tunnelPort = 0,
    String? token,
    Duration pushGapTimeout = _defaultPushGapTimeout,
  }) async {
    final HttpServer bridgeServer = await HttpServer.bind(InternetAddress.anyIPv4, port);
    ServerSocket tunnelServer;
    try {
      tunnelServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, tunnelPort);
    } on Object {
      await bridgeServer.close(force: true);
      rethrow;
    }
    final relay = WatchosVmRelay._(
      bridgeServer,
      tunnelServer,
      logTrace: logTrace,
      token: token ?? generateRelayToken(),
      pushGapTimeout: pushGapTimeout,
    );
    unawaited(relay._serveBridge());
    relay._serveTunnel();
    return relay;
  }

  /// The URI to hand flutter_tools. To everything on the Mac this is the VM
  /// Service: DDS, DevTools and `flutter attach` connect to it unchanged.
  Uri get vmServiceUri => Uri.parse('http://127.0.0.1:$tunnelPort/');

  /// The served path for one of [RelayPaths], under this run's token.
  String pathFor(String endpoint) => '/$token$endpoint';

  /// The URI the watch bridge dials, reachable from the device.
  ///
  /// The token rides in the path, so the bridge appends its endpoint to this
  /// and needs no notion of authentication at all.
  Uri bridgeUri(String macAddress) => Uri.parse('http://$macAddress:$port/$token');

  // MARK: - flutter_tools side (raw TCP)

  void _serveTunnel() {
    _tunnelServer.listen(
      _acceptTunnelConnection,
      onError: (Object e) => _logTrace('relay: tunnel listener error: $e'),
    );
  }

  void _acceptTunnelConnection(Socket socket) {
    final int id = _nextConnectionId++;
    _connections[id] = socket;
    // The VM Service protocol is request/response over small frames; Nagle
    // would add a round trip of latency to every one of them.
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
    } on Object {
      // Best-effort; not worth failing the connection over.
    }
    _logTrace('relay: tunnel connection $id opened');
    _startThroughputReporting();
    _toWatch.add(TunnelFrame.control(id, TunnelFrameKind.open).encode());
    // `Socket.add` reports failures asynchronously, not by throwing: a write to
    // a peer that has hung up surfaces here, and with nothing listening it
    // reaches the root zone and takes the whole `run` down. Measured — a client
    // that gave up mid-reply killed flutter_tools with a Broken pipe.
    unawaited(
      socket.done.then<void>(
        (_) => _teardownConnection(id, notifyBridge: true, reason: 'client closed'),
        onError: (Object e) =>
            _teardownConnection(id, notifyBridge: true, reason: 'client write failed: $e'),
      ),
    );
    socket.listen(
      (Uint8List data) {
        _bytesToWatch += data.length;
        _toWatch.add(TunnelFrame(id, TunnelFrameKind.data, data).encode());
      },
      onDone: () => _teardownConnection(id, notifyBridge: true, reason: 'client closed'),
      onError: (Object e) =>
          _teardownConnection(id, notifyBridge: true, reason: 'client error: $e'),
      cancelOnError: true,
    );
  }

  void _teardownConnection(int id, {required bool notifyBridge, required String reason}) {
    final Socket? socket = _connections.remove(id);
    if (socket == null) {
      return;
    }
    _logTrace('relay: tunnel connection $id closed ($reason)');
    if (notifyBridge && !_disposed) {
      _toWatch.add(TunnelFrame.control(id, TunnelFrameKind.close).encode());
    }
    try {
      socket.destroy();
    } on Object {
      // Already gone.
    }
  }

  // MARK: - watch side (HTTP)

  Future<void> _serveBridge() async {
    // Nothing awaits this future, so an error escaping here would reach the
    // root zone and take the whole `run` down — the same way an unhandled
    // `Socket.add` failure did. A dead listener is bad; killing the tool
    // because of one is worse.
    try {
      await for (final HttpRequest request in _bridgeServer) {
        // Deliberately not awaited. A poll is held open for up to
        // `kBridgePollTimeout`, so handling requests one at a time would make a
        // push wait behind the very poll it is racing — every VM Service reply
        // would be delayed until the poll timed out, and the tunnel would appear
        // to work only at 20-second granularity.
        unawaited(_handleGuarded(request));
      }
    } on Object catch (e) {
      if (!_disposed) {
        _logTrace('relay: bridge listener stopped: $e');
      }
    }
  }

  Future<void> _handleGuarded(HttpRequest request) async {
    try {
      await _handle(request);
    } on Object catch (e) {
      _logTrace('relay: request ${request.uri.path} failed: $e');
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } on Object {
        // Response already gone; nothing useful to do.
      }
    }
  }

  Future<void> _handle(HttpRequest request) async {
    // Authenticate before touching any state. A caller without the token must
    // not be able to mark the bridge connected, drain the poll queue, or push
    // a frame — all three are reachable from the LAN otherwise.
    final prefix = '/$token';
    final String path = request.uri.path;
    if (!path.startsWith('$prefix/')) {
      await _rejectUnauthenticated(request);
      return;
    }
    switch (path.substring(prefix.length)) {
      case RelayPaths.bridgeHello:
        _markBridgeConnected();
        _logTrace(
          'relay: bridge checked in from ${request.connectionInfo?.remoteAddress.address}',
        );
        await _respondJson(request, <String, Object?>{'ok': true});
      case RelayPaths.bridgePoll:
        await _handleBridgePoll(request);
      case RelayPaths.bridgePush:
        await _handleBridgePush(request);
      default:
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
    }
  }

  /// Whether an unauthenticated request has already been logged.
  ///
  /// A scanner can generate these faster than the trace log is worth reading,
  /// and the first one carries all the information: either the watch is dialling
  /// a stale URL, or something else on the network found the port.
  bool _loggedRejection = false;

  Future<void> _rejectUnauthenticated(HttpRequest request) async {
    if (!_loggedRejection) {
      _loggedRejection = true;
      _logTrace(
        'relay: rejected a request without the run token from '
        '${request.connectionInfo?.remoteAddress.address} '
        '(further rejections are not logged)',
      );
    }
    // 404 rather than 401: an unauthenticated caller learns nothing about
    // whether anything is served here.
    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }

  void _markBridgeConnected() {
    _bridgeConnected = true;
    if (!_bridgeArrived.isCompleted) {
      _bridgeArrived.complete();
    }
  }

  Future<void> _handleBridgePoll(HttpRequest request) async {
    _markBridgeConnected();
    final List<String> frames = await _toWatch.drainWhenReady(kBridgePollTimeout);
    await _respondJson(request, <String, Object?>{'frames': frames});
  }

  /// Sequence-reassembly state for pipelined pushes. Epoch-scoped: a new
  /// bridge instance restarts both.
  String? _pushEpoch;
  int _nextPushSeq = 0;
  final Map<int, String> _pendingPushBodies = <int, String>{};

  /// How long to hold later push bodies waiting for a missing one before
  /// giving up on the stream.
  ///
  /// A straggler is normal — the bridge caps *concurrent* pushes, not how far
  /// ahead the sequence may run (measured: seq 430 held 5 later bodies and
  /// then arrived, and the session carried on unharmed). So this is generous
  /// on purpose; it is here for the push that never arrives, which used to
  /// wedge the relay forever while the bridge logged one line and the user saw
  /// an indefinite hang.
  static const Duration _defaultPushGapTimeout = Duration(seconds: 30);
  final Duration _pushGapTimeout;
  Timer? _pushGapTimer;

  Future<void> _handleBridgePush(HttpRequest request) async {
    final String? body = await _readPushBody(request);
    // Everything below the await is synchronous, so concurrent handlers cannot
    // interleave the reassembly bookkeeping.
    if (body == null) {
      // The bytes this batch stood for are gone. Continuing would splice the
      // stream back together minus a chunk, which desynchronises the VM
      // Service framing downstream and shows up as unexplained silence. Kill
      // the connections instead, so flutter_tools reports a lost connection.
      _breakTunnel('a push body could not be inflated');
    }
    final int? seq = int.tryParse(request.headers.value(kPushSeqHeader) ?? '');
    if (seq == null) {
      _applyPushBody(body ?? '');
    } else {
      final String? epoch = request.headers.value(kPushEpochHeader);
      if (epoch != _pushEpoch) {
        _pushEpoch = epoch;
        _nextPushSeq = 0;
        _pendingPushBodies.clear();
      }
      if (seq < _nextPushSeq) {
        // Already applied — a retransmit, which the bridge sends when a push
        // fails in transit. Applying it again would replay bytes into the
        // middle of the stream, so acknowledge and drop it.
        _logTrace('relay: ignoring duplicate push seq $seq');
      } else {
        // An undecodable body still occupies its sequence slot: dropping the
        // slot too would hold every later push forever.
        _pendingPushBodies[seq] = body ?? '';
        while (_pendingPushBodies.containsKey(_nextPushSeq)) {
          _applyPushBody(_pendingPushBodies.remove(_nextPushSeq)!);
          _nextPushSeq++;
        }
        _updatePushGapWatchdog();
      }
    }
    await _respondJson(request, <String, Object?>{'ok': true});
  }

  /// Arms or disarms the watchdog that gives up on a missing push.
  void _updatePushGapWatchdog() {
    if (_pendingPushBodies.isEmpty) {
      _pushGapTimer?.cancel();
      _pushGapTimer = null;
      return;
    }
    if (_pendingPushBodies.length > 4) {
      _logTrace(
        'relay: waiting for push seq $_nextPushSeq with '
        '${_pendingPushBodies.length} later bodies held — a push is late or lost',
      );
    }
    // Deliberately not restarted while a gap persists: the deadline is on the
    // missing sequence, not on the traffic still flowing past it.
    _pushGapTimer ??= Timer(_pushGapTimeout, _abandonPushGap);
  }

  void _abandonPushGap() {
    _pushGapTimer = null;
    if (_pendingPushBodies.isEmpty) {
      return;
    }
    final int missing = _nextPushSeq;
    final int held = _pendingPushBodies.length;
    // Resynchronise past the hole so the relay is usable again if the bridge
    // keeps going, then tear the connections down — the byte stream they were
    // carrying is missing a chunk and cannot be trusted.
    _nextPushSeq = _pendingPushBodies.keys.reduce(math.max) + 1;
    _pendingPushBodies.clear();
    _breakTunnel(
      'push seq $missing never arrived after ${_pushGapTimeout.inSeconds}s '
      '($held later bodies discarded)',
    );
  }

  /// Tears down every live tunnel connection, because the byte stream feeding
  /// them has lost data and is no longer coherent.
  void _breakTunnel(String reason) {
    if (_connections.isEmpty) {
      _logTrace('relay: $reason');
      return;
    }
    _logTrace('relay: $reason — dropping ${_connections.length} tunnel connection(s)');
    for (final int id in _connections.keys.toList(growable: false)) {
      _teardownConnection(id, notifyBridge: true, reason: reason);
    }
  }

  void _applyPushBody(String body) {
    for (final String line in splitPushBody(body)) {
      final TunnelFrame? frame = TunnelFrame.decode(line);
      if (frame == null) {
        _logTrace('relay: dropping malformed frame from watch');
        continue;
      }
      _applyFrameFromWatch(frame);
    }
  }

  void _applyFrameFromWatch(TunnelFrame frame) {
    final Socket? socket = _connections[frame.connectionId];
    if (socket == null) {
      // Raced with the client hanging up. Dropping is correct: there is no
      // longer anyone the bytes belong to.
      return;
    }
    switch (frame.kind) {
      case TunnelFrameKind.data:
        try {
          _bytesFromWatch += frame.payload.length;
          socket.add(frame.payload);
        } on Object catch (e) {
          // Only catches the synchronous "already destroyed" case; a genuine
          // write failure arrives via `socket.done` above.
          _teardownConnection(frame.connectionId, notifyBridge: true, reason: 'write failed: $e');
        }
      case TunnelFrameKind.close:
        _teardownConnection(frame.connectionId, notifyBridge: false, reason: 'VM Service closed');
      case TunnelFrameKind.open:
        // Only the Mac opens connections; the watch never should.
        _logTrace('relay: ignoring unexpected open frame from watch');
    }
  }

  /// Reads a push body, inflating it when the bridge compressed it.
  ///
  /// Returns null if the body cannot be inflated. The caller drops the whole
  /// batch and kills the tunnel: a half-decoded byte stream would corrupt the
  /// VM Service protocol silently, whereas a dead connection announces itself.
  Future<String?> _readPushBody(HttpRequest request) async {
    final builder = BytesBuilder(copy: false);
    await request.forEach(builder.add);
    final Uint8List raw = builder.takeBytes();
    _wireBytesFromWatch += raw.length;
    final String? encoding = request.headers
        .value(HttpHeaders.contentEncodingHeader)
        ?.trim()
        .toLowerCase();
    if (encoding != kRawDeflateEncoding) {
      return utf8.decode(raw, allowMalformed: true);
    }
    try {
      return utf8.decode(_rawInflate.decode(raw), allowMalformed: true);
    } on Object catch (e) {
      _logTrace('relay: could not inflate a ${raw.length}-byte push body ($e)');
      return null;
    }
  }

  /// The bridge batches frames into one POST, newline delimited. Frames are
  /// base64 payloads with a numeric header, so a bare `\n` split is
  /// unambiguous.
  @visibleForTesting
  static List<String> splitPushBody(String body) {
    return body
        .split('\n')
        .map((String line) => line.trim())
        .where((String line) => line.isNotEmpty)
        .toList(growable: false);
  }

  Future<void> _respondJson(HttpRequest request, Map<String, Object?> payload) async {
    final Uint8List body = utf8.encode(jsonEncode(payload));
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json;

    // `URLSession` advertises gzip and inflates it transparently, so the watch
    // side needs no code for this direction — it just sees a smaller response.
    // Mac→watch is the quieter direction, but a poll response carrying a bulk
    // write is exactly when it is worth having.
    final bool acceptsGzip =
        request.headers.value(HttpHeaders.acceptEncodingHeader)?.toLowerCase().contains('gzip') ??
        false;
    if (acceptsGzip && body.length >= kMinCompressBytes) {
      final List<int> compressed = gzip.encode(body);
      // Compression can inflate incompressible input; never send the larger one.
      if (compressed.length < body.length) {
        request.response.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
        request.response.add(compressed);
        await request.response.close();
        return;
      }
    }
    request.response.add(body);
    await request.response.close();
  }

  /// Shuts the relay down; safe to call more than once.
  Future<void> dispose() async {
    _disposed = true;
    _stopThroughputReporting();
    _pushGapTimer?.cancel();
    _pushGapTimer = null;
    _logTrace(
      'relay: moved ${(_bytesToWatch / 1024).toStringAsFixed(1)} KB to watch, '
      '${(_bytesFromWatch / 1024).toStringAsFixed(1)} KB from watch',
    );
    _toWatch.close();
    for (final int id in _connections.keys.toList(growable: false)) {
      _teardownConnection(id, notifyBridge: false, reason: 'relay shutting down');
    }
    await _tunnelServer.close();
    await _bridgeServer.close(force: true);
  }
}

/// The four octets of a dotted-quad IPv4 address, or null if [address] is not
/// one.
List<int>? _parseIPv4(String address) {
  final List<String> parts = address.split('.');
  if (parts.length != 4) {
    return null;
  }
  final octets = <int>[];
  for (final part in parts) {
    final int? octet = int.tryParse(part);
    if (octet == null || octet < 0 || octet > 255) {
      return null;
    }
    octets.add(octet);
  }
  return octets;
}

/// Whether [address] is in one of the RFC 1918 private IPv4 ranges.
bool _isPrivateIPv4(String address) {
  final List<int>? octets = _parseIPv4(address);
  if (octets == null) {
    return false;
  }
  return octets[0] == 10 ||
      (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) ||
      (octets[0] == 192 && octets[1] == 168);
}

/// Whether [address] is on Apple's Personal Hotspot subnet, `172.20.10.0/28`,
/// which puts the iPhone itself on `.1` and tethered clients on `.2`–`.14`.
///
/// An address here means this Mac is tethered to an iPhone, over USB or Wi-Fi.
bool _isIPhoneHotspotIPv4(String address) {
  final List<int>? octets = _parseIPv4(address);
  return octets != null &&
      octets[0] == 172 &&
      octets[1] == 20 &&
      octets[2] == 10 &&
      octets[3] < 16;
}

/// Picks the Mac address the watch should dial.
///
/// The watch reaches the Mac over the LAN (proxied via the paired iPhone), so
/// loopback is useless here, and so is anything that only routes somewhere
/// else. In preference order:
///
/// 1. [override], when set — the last word for a network we cannot infer.
/// 2. A `bridge*` interface — that is what Internet Sharing hands the watch's
///    network, so if one exists it is certainly the right side of the Mac.
/// 3. An iPhone Personal Hotspot address (`172.20.10.0/28`). The watch's
///    traffic arrives *from* the paired iPhone, so that phone is the one hop
///    that has to reach us — and while tethered it is on this subnet with us.
///    That outranks an ordinary LAN address on purpose: a Mac that is tethered
///    *and* on wired Ethernet has two private addresses, and the phone can
///    only route to one of them.
/// 4. Any other private (RFC 1918) address, which is what an ordinary Wi-Fi
///    LAN looks like. Preferring it keeps a VPN tunnel's address from winning
///    purely on `NetworkInterface.list` ordering — the watch cannot route to
///    that, and the failure looks like the app never starting.
/// 5. Anything else routable, as a last resort.
///
/// Loopback and link-local are skipped outright.
///
/// Ordering is all this can do: there is no way to ask which of our addresses
/// the paired iPhone can see. On a multi-homed Mac whose layout defeats the
/// order above, [override] is the escape hatch.
Future<String?> resolveMacLanAddress({
  Future<List<NetworkInterface>> Function()? listInterfaces,
  String? override,
}) async {
  if (override != null && override.isNotEmpty) {
    return override;
  }
  final List<NetworkInterface> interfaces =
      await (listInterfaces?.call() ??
          NetworkInterface.list(type: InternetAddressType.IPv4));
  String? tethered;
  String? private;
  String? routable;
  for (final interface in interfaces) {
    for (final InternetAddress address in interface.addresses) {
      if (address.isLoopback || address.isLinkLocal) {
        continue;
      }
      if (interface.name.startsWith('bridge')) {
        return address.address;
      }
      if (_isIPhoneHotspotIPv4(address.address)) {
        tethered ??= address.address;
      } else if (_isPrivateIPv4(address.address)) {
        private ??= address.address;
      } else {
        routable ??= address.address;
      }
    }
  }
  return tethered ?? private ?? routable;
}
