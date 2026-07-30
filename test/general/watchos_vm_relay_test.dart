// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_watchos/watchos_vm_relay.dart';

import '../src/common.dart';

void main() {
  group('TunnelFrame', () {
    testWithoutContext('round-trips a payload', () {
      const frame = TunnelFrame(7, TunnelFrameKind.data, <int>[0, 1, 250, 255]);
      expect(TunnelFrame.decode(frame.encode()), frame);
    });

    testWithoutContext('round-trips a control frame with no payload', () {
      const frame = TunnelFrame.control(3, TunnelFrameKind.open);
      expect(frame.encode(), '3:o:');
      expect(TunnelFrame.decode('3:o:'), frame);
    });

    testWithoutContext('encodes payloads that would break a line-based split', () {
      // Newlines are the batch separator; base64 must keep them out of the wire
      // format or one frame would be read as several.
      final frame = TunnelFrame(1, TunnelFrameKind.data, utf8.encode('a\nb:c\n'));
      expect(frame.encode(), isNot(contains('\n')));
      expect(TunnelFrame.decode(frame.encode())!.payload, utf8.encode('a\nb:c\n'));
    });

    testWithoutContext('rejects malformed lines rather than throwing', () {
      expect(TunnelFrame.decode(''), isNull);
      expect(TunnelFrame.decode('nope'), isNull);
      expect(TunnelFrame.decode('1:d'), isNull, reason: 'missing payload field');
      expect(TunnelFrame.decode('x:d:'), isNull, reason: 'non-numeric id');
      expect(TunnelFrame.decode('1:z:'), isNull, reason: 'unknown kind');
      expect(TunnelFrame.decode('1:d:!!!not base64!!!'), isNull);
    });
  });

  group('RelayQueue', () {
    testWithoutContext('drains what is buffered without waiting', () async {
      final queue = RelayQueue()
        ..add('one')
        ..add('two');
      expect(await queue.drainWhenReady(const Duration(seconds: 10)), <String>['one', 'two']);
      expect(queue.length, 0);
    });

    testWithoutContext('wakes as soon as a frame arrives mid-wait', () async {
      final queue = RelayQueue();
      final Future<List<String>> pending = queue.drainWhenReady(const Duration(seconds: 10));
      queue.add('late');
      // Must return on the frame, not on the 10s timeout.
      expect(await pending, <String>['late']);
    });

    testWithoutContext('returns empty on timeout rather than hanging', () async {
      final queue = RelayQueue();
      expect(await queue.drainWhenReady(const Duration(milliseconds: 20)), isEmpty);
    });

    testWithoutContext('close releases a waiter', () async {
      final queue = RelayQueue();
      final Future<List<String>> pending = queue.drainWhenReady(const Duration(seconds: 30));
      queue.close();
      expect(await pending, isEmpty);
    });
  });

  group('push body framing', () {
    testWithoutContext('splits batched frames on newlines', () {
      expect(WatchosVmRelay.splitPushBody('1:d:AAE=\n2:c:\n'), <String>['1:d:AAE=', '2:c:']);
    });

    testWithoutContext('ignores blank lines and stray whitespace', () {
      expect(WatchosVmRelay.splitPushBody('\n\n  1:d:AAE=  \n\n'), <String>['1:d:AAE=']);
      expect(WatchosVmRelay.splitPushBody(''), isEmpty);
    });
  });

  group('resolveMacLanAddress', () {
    testWithoutContext('prefers a bridge interface, which is what the watch is on', () async {
      final String? address = await resolveMacLanAddress(
        listInterfaces: () async => <NetworkInterface>[
          _FakeInterface('en9', <String>['10.107.71.31']),
          _FakeInterface('bridge100', <String>['192.168.2.1']),
        ],
      );
      expect(address, '192.168.2.1');
    });

    testWithoutContext('falls back to any routable address', () async {
      final String? address = await resolveMacLanAddress(
        listInterfaces: () async => <NetworkInterface>[
          _FakeInterface('en9', <String>['10.107.71.31']),
        ],
      );
      expect(address, '10.107.71.31');
    });

    testWithoutContext('skips link-local, which the watch cannot use', () async {
      final String? address = await resolveMacLanAddress(
        listInterfaces: () async => <NetworkInterface>[
          _FakeInterface('en1', <String>['169.254.10.1']),
          _FakeInterface('en2', <String>['192.168.8.20']),
        ],
      );
      expect(address, '192.168.8.20');
    });

    testWithoutContext('returns null when nothing is routable', () async {
      final String? address = await resolveMacLanAddress(
        listInterfaces: () async => <NetworkInterface>[
          _FakeInterface('en1', <String>['169.254.10.1']),
        ],
      );
      expect(address, isNull);
    });
  });

  group('WatchosVmRelay bridge endpoints', () {
    late WatchosVmRelay relay;

    setUp(() async {
      relay = await WatchosVmRelay.start(logTrace: (String _) {});
    });

    tearDown(() async {
      await relay.dispose();
    });

    testWithoutContext('bridgeReady completes when the bridge says hello', () async {
      expect(relay.bridgeConnected, isFalse);
      final HttpClientResponse response = await _get(relay.port, RelayPaths.bridgeHello);
      expect(response.statusCode, 200);
      await relay.bridgeReady;
      expect(relay.bridgeConnected, isTrue);
    });

    testWithoutContext('a poll also counts as the bridge checking in', () async {
      unawaited(_get(relay.port, RelayPaths.bridgePoll));
      await relay.bridgeReady;
      expect(relay.bridgeConnected, isTrue);
    });

    testWithoutContext('an unknown path 404s rather than hanging the bridge', () async {
      final HttpClientResponse response = await _get(relay.port, '/nope');
      expect(response.statusCode, 404);
    });

    testWithoutContext('the tunnel listens on loopback only', () async {
      // Binding the tunnel on every interface would expose a debug channel into
      // the developer's machine to the whole LAN.
      expect(relay.vmServiceUri.host, '127.0.0.1');
      expect(relay.vmServiceUri.port, relay.tunnelPort);
      expect(relay.tunnelPort, isNot(relay.port));
    });
  });

  // The point of the byte tunnel is that neither end parses the VM Service
  // protocol. These tests prove it by running a *real* WebSocket server as the
  // stand-in VM Service and a real WebSocket client as the stand-in
  // flutter_tools: if any hop mangled the framing or the HTTP upgrade, the
  // handshake would not complete at all.
  group('WatchosVmRelay tunnel end to end', () {
    late WatchosVmRelay relay;
    late _FakeVmService vmService;
    late _FakeBridge bridge;
    final traces = <String>[];

    setUp(() async {
      traces.clear();
      vmService = await _FakeVmService.start();
      relay = await WatchosVmRelay.start(logTrace: traces.add);
      bridge = _FakeBridge(relayPort: relay.port, vmPort: vmService.port)..start();
      await relay.bridgeReady;
    });

    tearDown(() async {
      await bridge.dispose();
      await relay.dispose();
      await vmService.dispose();
    });

    testWithoutContext('a WebSocket handshake completes through the tunnel', () async {
      final WebSocket client = await WebSocket.connect('ws://127.0.0.1:${relay.tunnelPort}/ws');
      addTearDown(() async => client.close());
      expect(client.readyState, WebSocket.open);
    });

    testWithoutContext('carries a request to the VM Service and the reply back', () async {
      final WebSocket client = await WebSocket.connect('ws://127.0.0.1:${relay.tunnelPort}/ws');
      addTearDown(() async => client.close());
      final Future<dynamic> reply = client.first;

      client.add('{"method":"getVM"}');
      expect(await reply, 'echo:{"method":"getVM"}');
      expect(vmService.received, <String>['{"method":"getVM"}']);
    });

    testWithoutContext('carries a payload larger than one read buffer intact', () async {
      // 256KB crosses the bridge's 32KB read buffer many times over; a framing
      // bug here would show up as truncation or interleaving rather than an
      // outright failure.
      final String big = 'x' * (256 * 1024);
      final WebSocket client = await WebSocket.connect('ws://127.0.0.1:${relay.tunnelPort}/ws');
      addTearDown(() async => client.close());
      final Future<dynamic> reply = client.first;

      client.add(big);
      expect(await reply, 'echo:$big');
    });

    testWithoutContext('keeps two concurrent connections separate', () async {
      final WebSocket first = await WebSocket.connect('ws://127.0.0.1:${relay.tunnelPort}/ws');
      final WebSocket second = await WebSocket.connect('ws://127.0.0.1:${relay.tunnelPort}/ws');
      addTearDown(() async {
        await first.close();
        await second.close();
      });
      final Future<dynamic> firstReply = first.first;
      final Future<dynamic> secondReply = second.first;

      first.add('one');
      second.add('two');

      expect(await firstReply, 'echo:one');
      expect(await secondReply, 'echo:two');
    });

    testWithoutContext('a client hanging up closes its VM Service connection', () async {
      final WebSocket client = await WebSocket.connect('ws://127.0.0.1:${relay.tunnelPort}/ws');
      expect(await vmService.connectionCount(1), 1);

      await client.close();
      // The close has to travel client → relay → bridge → VM Service.
      expect(await vmService.connectionCount(0), 0);
    });

    testWithoutContext('survives the client vanishing mid-reply', () async {
      // `Socket.add` reports write failures asynchronously. Unhandled, they
      // reach the root zone and kill `flutter run` outright — which is exactly
      // what happened on device when a client gave up while the watch was still
      // pushing a large reply.
      final WebSocket client = await WebSocket.connect('ws://127.0.0.1:${relay.tunnelPort}/ws');
      client.add('start');
      await vmService.connectionCount(1);

      // Rip the client away without a close handshake, then keep pushing at it.
      final Socket raw = await Socket.connect(InternetAddress.loopbackIPv4, relay.tunnelPort);
      raw.destroy();
      await client.close();
      for (var i = 0; i < 50; i++) {
        await _pushRaw(relay.port, TunnelFrame(1, TunnelFrameKind.data, List<int>.filled(64 * 1024, 65)).encode());
      }

      // The relay must still be serving: a fresh connection has to work.
      final WebSocket fresh = await WebSocket.connect('ws://127.0.0.1:${relay.tunnelPort}/ws');
      addTearDown(() async => fresh.close());
      final Future<dynamic> reply = fresh.first;
      fresh.add('still alive');
      expect(await reply, 'echo:still alive');
    });

    testWithoutContext('the VM Service going away closes the client', () async {
      final WebSocket client = await WebSocket.connect('ws://127.0.0.1:${relay.tunnelPort}/ws');
      final Future<void> done = client.listen(null).asFuture<void>();

      await vmService.dropConnections();
      // Must complete rather than hang: flutter_tools needs to see the drop.
      await done.timeout(const Duration(seconds: 5));
    });
  });
}

/// Stands in for the Dart VM Service: a real WebSocket server that echoes.
class _FakeVmService {
  _FakeVmService._(this._server);

  final HttpServer _server;
  final List<WebSocket> _sockets = <WebSocket>[];

  /// Text frames received, in order.
  final List<String> received = <String>[];

  int get port => _server.port;

  static Future<_FakeVmService> start() async {
    final HttpServer server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final service = _FakeVmService._(server);
    unawaited(service._serve());
    return service;
  }

  Future<void> _serve() async {
    await for (final HttpRequest request in _server) {
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        continue;
      }
      final WebSocket socket = await WebSocketTransformer.upgrade(request);
      _sockets.add(socket);
      socket.listen(
        (dynamic message) {
          received.add(message as String);
          socket.add('echo:$message');
        },
        onDone: () => _sockets.remove(socket),
        onError: (Object _) => _sockets.remove(socket),
      );
    }
  }

  /// Waits for the live connection count to reach [expected], then returns it.
  /// Polls because the close has several hops to travel.
  Future<int> connectionCount(int expected) async {
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 5));
    while (_sockets.length != expected && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return _sockets.length;
  }

  Future<void> dropConnections() async {
    for (final WebSocket socket in _sockets.toList(growable: false)) {
      await socket.close();
    }
  }

  Future<void> dispose() async {
    await dropConnections();
    await _server.close(force: true);
  }
}

/// Stands in for the Swift bridge on the watch, over the same HTTP contract.
///
/// A second implementation of the wire format is the point: it keeps the
/// relay's half of the contract honest without a device in the loop.
class _FakeBridge {
  _FakeBridge({required this.relayPort, required this.vmPort});

  final int relayPort;
  final int vmPort;

  final HttpClient _client = HttpClient();
  final Map<int, Socket> _sockets = <int, Socket>{};
  bool _running = true;
  Future<void> _pushChain = Future<void>.value();

  void start() {
    unawaited(_pollLoop());
  }

  Future<void> _pollLoop() async {
    while (_running) {
      try {
        final HttpClientRequest request = await _client.getUrl(
          Uri.parse('http://127.0.0.1:$relayPort${RelayPaths.bridgePoll}'),
        );
        final HttpClientResponse response = await request.close();
        final body = jsonDecode(await utf8.decodeStream(response)) as Map<String, Object?>;
        for (final String line in (body['frames']! as List<Object?>).cast<String>()) {
          await _apply(line);
        }
      } on Object {
        if (!_running) {
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }
  }

  Future<void> _apply(String line) async {
    final TunnelFrame? frame = TunnelFrame.decode(line);
    if (frame == null) {
      return;
    }
    switch (frame.kind) {
      case TunnelFrameKind.open:
        final Socket socket = await Socket.connect(InternetAddress.loopbackIPv4, vmPort);
        _sockets[frame.connectionId] = socket;
        socket.listen(
          (List<int> data) =>
              _push(TunnelFrame(frame.connectionId, TunnelFrameKind.data, data).encode()),
          onDone: () {
            if (_sockets.remove(frame.connectionId) != null) {
              _push(TunnelFrame.control(frame.connectionId, TunnelFrameKind.close).encode());
            }
          },
          onError: (Object _) {},
        );
      case TunnelFrameKind.data:
        _sockets[frame.connectionId]?.add(frame.payload);
      case TunnelFrameKind.close:
        final Socket? socket = _sockets.remove(frame.connectionId);
        socket?.destroy();
    }
  }

  /// Serialised: frames must reach the relay in the order they were produced.
  void _push(String frame) {
    _pushChain = _pushChain.then((_) async {
      if (!_running) {
        return;
      }
      try {
        final HttpClientRequest request = await _client.postUrl(
          Uri.parse('http://127.0.0.1:$relayPort${RelayPaths.bridgePush}'),
        );
        request.write(frame);
        final HttpClientResponse response = await request.close();
        await response.drain<void>();
      } on Object {
        // Matches the Swift bridge: a dropped push is logged, not fatal.
      }
    });
  }

  Future<void> dispose() async {
    _running = false;
    for (final Socket socket in _sockets.values.toList(growable: false)) {
      socket.destroy();
    }
    _sockets.clear();
    _client.close(force: true);
  }
}

/// Posts one frame to the relay as the bridge would.
Future<void> _pushRaw(int port, String frame) async {
  final client = HttpClient();
  try {
    final HttpClientRequest request = await client.postUrl(
      Uri.parse('http://127.0.0.1:$port${RelayPaths.bridgePush}'),
    );
    request.write(frame);
    final HttpClientResponse response = await request.close();
    await response.drain<void>();
  } finally {
    client.close();
  }
}

Future<HttpClientResponse> _get(int port, String path) async {
  final client = HttpClient();
  try {
    final HttpClientRequest request = await client.getUrl(
      Uri.parse('http://127.0.0.1:$port$path'),
    );
    return await request.close();
  } finally {
    client.close();
  }
}

class _FakeInterface implements NetworkInterface {
  _FakeInterface(this.name, List<String> addresses)
    : addresses = addresses.map(InternetAddress.new).toList();

  @override
  final String name;

  @override
  final List<InternetAddress> addresses;

  @override
  int get index => 0;
}
