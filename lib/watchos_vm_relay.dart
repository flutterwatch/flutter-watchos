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
// has to be plain HTTP request/response. Measurements:
// docs/watchos-vm-service-transport.md.
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
    Timer? timer = Timer(timeout, () {
      if (!waiter.isCompleted) {
        _waiter = null;
        waiter.complete();
      }
    });
    await waiter.future;
    timer.cancel();
    timer = null;
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
  }) : _logTrace = logTrace,
       port = _bridgeServer.port,
       tunnelPort = _tunnelServer.port;

  final HttpServer _bridgeServer;
  final ServerSocket _tunnelServer;
  final void Function(String) _logTrace;

  /// Port the bridge endpoints listen on, on every interface — the watch
  /// reaches the Mac by LAN address, so loopback-only would be unreachable.
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
  }) async {
    final HttpServer bridgeServer = await HttpServer.bind(InternetAddress.anyIPv4, port);
    ServerSocket tunnelServer;
    try {
      tunnelServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, tunnelPort);
    } on Object {
      await bridgeServer.close(force: true);
      rethrow;
    }
    final relay = WatchosVmRelay._(bridgeServer, tunnelServer, logTrace: logTrace);
    unawaited(relay._serveBridge());
    relay._serveTunnel();
    return relay;
  }

  /// The URI to hand flutter_tools. To everything on the Mac this is the VM
  /// Service: DDS, DevTools and `flutter attach` connect to it unchanged.
  Uri get vmServiceUri => Uri.parse('http://127.0.0.1:$tunnelPort/');

  /// The URI the watch bridge dials, reachable from the device.
  Uri bridgeUri(String macAddress) => Uri.parse('http://$macAddress:$port');

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
    await for (final HttpRequest request in _bridgeServer) {
      // Deliberately not awaited. A poll is held open for up to
      // `kBridgePollTimeout`, so handling requests one at a time would make a
      // push wait behind the very poll it is racing — every VM Service reply
      // would be delayed until the poll timed out, and the tunnel would appear
      // to work only at 20-second granularity.
      unawaited(_handleGuarded(request));
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
    switch (request.uri.path) {
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

  Future<void> _handleBridgePush(HttpRequest request) async {
    final String body = await _readPushBody(request);
    // Everything below the await is synchronous, so concurrent handlers cannot
    // interleave the reassembly bookkeeping.
    final int? seq = int.tryParse(request.headers.value(kPushSeqHeader) ?? '');
    if (seq == null) {
      _applyPushBody(body);
    } else {
      final String? epoch = request.headers.value(kPushEpochHeader);
      if (epoch != _pushEpoch) {
        _pushEpoch = epoch;
        _nextPushSeq = 0;
        _pendingPushBodies.clear();
      }
      if (seq < _nextPushSeq) {
        // Already applied — a retransmit. Applying it again would replay bytes
        // into the middle of the stream.
        _logTrace('relay: ignoring duplicate push seq $seq');
      } else {
        _pendingPushBodies[seq] = body;
        while (_pendingPushBodies.containsKey(_nextPushSeq)) {
          _applyPushBody(_pendingPushBodies.remove(_nextPushSeq)!);
          _nextPushSeq++;
        }
        if (_pendingPushBodies.length > 4) {
          // Usually a straggler: one slow request can be overtaken by many,
          // since the bridge caps *concurrent* pushes, not how far ahead the
          // sequence may run (measured — seq 430 held 5 later bodies and then
          // arrived; the session carried on unharmed). If the gap never
          // closes, the push was lost and the bridge logs "stream is now
          // broken".
          _logTrace(
            'relay: waiting for push seq $_nextPushSeq with '
            '${_pendingPushBodies.length} later bodies held — a push is late '
            'or lost',
          );
        }
      }
    }
    await _respondJson(request, <String, Object?>{'ok': true});
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
  /// Returns an empty string if the body cannot be inflated. That drops the
  /// batch, which breaks the connection it belonged to — but a half-decoded
  /// byte stream would corrupt the VM Service protocol silently, and a dead
  /// connection at least announces itself.
  Future<String> _readPushBody(HttpRequest request) async {
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
      return '';
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

/// Picks the Mac address the watch should dial.
///
/// The watch reaches the Mac over the LAN (proxied via the paired iPhone), so
/// loopback is useless here. Prefers a private IPv4 address on an ordinary
/// interface and skips link-local and loopback.
Future<String?> resolveMacLanAddress({
  Future<List<NetworkInterface>> Function()? listInterfaces,
}) async {
  final List<NetworkInterface> interfaces =
      await (listInterfaces?.call() ??
          NetworkInterface.list(type: InternetAddressType.IPv4));
  String? best;
  for (final interface in interfaces) {
    for (final InternetAddress address in interface.addresses) {
      if (address.isLoopback || address.isLinkLocal) {
        continue;
      }
      // A bridge interface is what Internet Sharing hands the watch's network,
      // so prefer it; otherwise take the first usable address.
      if (interface.name.startsWith('bridge')) {
        return address.address;
      }
      best ??= address.address;
    }
  }
  return best;
}
