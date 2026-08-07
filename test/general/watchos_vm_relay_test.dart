// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

    testWithoutContext('prefers a private LAN address over a VPN tunnel', () async {
      // A VPN's utun address is routable but the watch cannot reach it, and
      // the failure looks exactly like the app never starting. Interface order
      // from the OS is not something to rely on either way.
      final String? address = await resolveMacLanAddress(
        listInterfaces: () async => <NetworkInterface>[
          _FakeInterface('utun4', <String>['100.83.2.7']),
          _FakeInterface('en0', <String>['192.168.1.24']),
        ],
      );
      expect(address, '192.168.1.24');
    });

    testWithoutContext('recognises all three private ranges', () async {
      for (final candidate in <String>['10.0.0.5', '172.16.4.1', '172.31.9.9']) {
        expect(
          await resolveMacLanAddress(
            listInterfaces: () async => <NetworkInterface>[
              _FakeInterface('utun4', <String>['100.83.2.7']),
              _FakeInterface('en0', <String>[candidate]),
            ],
          ),
          candidate,
        );
      }
      // 172.32 is outside the RFC 1918 block, so it must not outrank the VPN.
      expect(
        await resolveMacLanAddress(
          listInterfaces: () async => <NetworkInterface>[
            _FakeInterface('utun4', <String>['100.83.2.7']),
            _FakeInterface('en0', <String>['172.32.0.1']),
          ],
        ),
        '100.83.2.7',
      );
    });

    testWithoutContext('prefers an iPhone tether over any other LAN', () async {
      // The watch's traffic arrives from the paired iPhone, so the phone is
      // the hop that has to reach us. Tethered, it shares the 172.20.10.0/28
      // hotspot subnet with this Mac; the wired LAN it has never heard of.
      final String? address = await resolveMacLanAddress(
        listInterfaces: () async => <NetworkInterface>[
          _FakeInterface('en9', <String>['10.107.71.31']),
          _FakeInterface('en8', <String>['172.20.10.2']),
        ],
      );
      expect(address, '172.20.10.2');
    });

    testWithoutContext('tether preference does not depend on interface order', () async {
      final String? address = await resolveMacLanAddress(
        listInterfaces: () async => <NetworkInterface>[
          _FakeInterface('en8', <String>['172.20.10.2']),
          _FakeInterface('en9', <String>['10.107.71.31']),
        ],
      );
      expect(address, '172.20.10.2');
    });

    testWithoutContext('a bridge still outranks a tether', () async {
      // Internet Sharing means the watch's network is one this Mac hands out,
      // which is more certain than a route through the phone.
      final String? address = await resolveMacLanAddress(
        listInterfaces: () async => <NetworkInterface>[
          _FakeInterface('en8', <String>['172.20.10.2']),
          _FakeInterface('bridge100', <String>['192.168.2.1']),
        ],
      );
      expect(address, '192.168.2.1');
    });

    testWithoutContext('addresses just outside the hotspot block are ordinary', () async {
      // 172.20.10.0/28 stops at .15; .16 is somebody's ordinary LAN and must
      // not be mistaken for a tether.
      final String? address = await resolveMacLanAddress(
        listInterfaces: () async => <NetworkInterface>[
          _FakeInterface('en9', <String>['172.20.10.16']),
          _FakeInterface('en8', <String>['172.20.10.14']),
        ],
      );
      expect(address, '172.20.10.14');
    });

    testWithoutContext('an override wins over everything, including a bridge', () async {
      // The escape hatch for a layout the ordering cannot infer: there is no
      // way to ask which of our addresses the paired iPhone can actually see.
      final String? address = await resolveMacLanAddress(
        override: '10.107.71.31',
        listInterfaces: () async => <NetworkInterface>[
          _FakeInterface('bridge100', <String>['192.168.2.1']),
          _FakeInterface('en8', <String>['172.20.10.2']),
        ],
      );
      expect(address, '10.107.71.31');
    });

    testWithoutContext('an empty override is ignored rather than obeyed', () async {
      // An unset environment variable reads as '' in some shells; that must
      // not blank out the relay address.
      final String? address = await resolveMacLanAddress(
        override: '',
        listInterfaces: () async => <NetworkInterface>[
          _FakeInterface('en0', <String>['192.168.1.24']),
        ],
      );
      expect(address, '192.168.1.24');
    });

    testWithoutContext('still returns a public address when that is all there is', () async {
      final String? address = await resolveMacLanAddress(
        listInterfaces: () async => <NetworkInterface>[
          _FakeInterface('en0', <String>['203.0.113.9']),
        ],
      );
      expect(address, '203.0.113.9');
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
      final HttpClientResponse response = await _get(relay.port, relay.pathFor(RelayPaths.bridgeHello));
      expect(response.statusCode, 200);
      await relay.bridgeReady;
      expect(relay.bridgeConnected, isTrue);
    });

    testWithoutContext('a poll also counts as the bridge checking in', () async {
      unawaited(_get(relay.port, relay.pathFor(RelayPaths.bridgePoll)));
      await relay.bridgeReady;
      expect(relay.bridgeConnected, isTrue);
    });

    testWithoutContext('an unknown path 404s rather than hanging the bridge', () async {
      final HttpClientResponse response = await _get(relay.port, relay.pathFor('/nope'));
      expect(response.statusCode, 404);
    });

    testWithoutContext('the tunnel listens on loopback only', () async {
      // Binding the tunnel on every interface would expose a debug channel into
      // the developer's machine to the whole LAN.
      expect(relay.vmServiceUri.host, '127.0.0.1');
      expect(relay.vmServiceUri.port, relay.tunnelPort);
      expect(relay.tunnelPort, isNot(relay.port));
    });

    // The bridge endpoints *cannot* be loopback-only — the watch dials the
    // Mac's LAN address — so the token is the only thing between a live debug
    // session and the local network. The app is launched with
    // `--disable-service-auth-codes`, so without this the relay would be
    // strictly weaker than the VM Service posture it stands in for.
    testWithoutContext('rejects a request with no token', () async {
      expect(
        (await _get(relay.port, RelayPaths.bridgeHello)).statusCode,
        404,
      );
      expect(
        (await _get(relay.port, RelayPaths.bridgePoll)).statusCode,
        404,
      );
    });

    testWithoutContext('rejects a request with the wrong token', () async {
      final HttpClientResponse response = await _get(
        relay.port,
        '/${'0' * 32}${RelayPaths.bridgeHello}',
      );
      expect(response.statusCode, 404);
    });

    testWithoutContext('an unauthenticated caller cannot mark the bridge connected', () async {
      // Not merely a 404: reaching `_markBridgeConnected` would make `run`
      // hand out a VM Service URI with nothing behind it.
      await _get(relay.port, RelayPaths.bridgeHello);
      await _get(relay.port, RelayPaths.bridgePoll);
      expect(relay.bridgeConnected, isFalse);
    });

    testWithoutContext('an unauthenticated caller cannot inject a frame', () async {
      final Socket client = await Socket.connect(InternetAddress.loopbackIPv4, relay.tunnelPort);
      addTearDown(client.destroy);
      final received = <int>[];
      client.listen(received.addAll);

      final client2 = HttpClient();
      addTearDown(() => client2.close(force: true));
      final HttpClientRequest request = await client2.postUrl(
        Uri.parse('http://127.0.0.1:${relay.port}${RelayPaths.bridgePush}'),
      );
      request.write(TunnelFrame(1, TunnelFrameKind.data, utf8.encode('spoofed')).encode());
      final HttpClientResponse response = await request.close();
      await response.drain<void>();

      expect(response.statusCode, 404);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(received, isEmpty);
    });

    testWithoutContext('the bridge URI carries the token, so the watch needs no auth code', () async {
      final Uri uri = relay.bridgeUri('192.168.2.1');
      expect(uri.path, '/${relay.token}');
      // The Swift bridge appends its endpoint to this; the result must be what
      // the relay serves.
      expect('${uri.path}${RelayPaths.bridgePoll}', relay.pathFor(RelayPaths.bridgePoll));
    });

    testWithoutContext('mints a fresh token per run', () async {
      expect(relay.token, hasLength(32));
      expect(generateRelayToken(), isNot(generateRelayToken()));
    });
  });

  // The link is the binding constraint on this transport (38-80 KB/s measured
  // on device), so the watch compresses what it sends. These pin the contract
  // the Swift side encodes against — a mismatch here corrupts the byte stream
  // rather than failing loudly, so it is worth testing both directions.
  group('WatchosVmRelay compression', () {
    late WatchosVmRelay relay;
    final traces = <String>[];

    setUp(() async {
      traces.clear();
      relay = await WatchosVmRelay.start(logTrace: traces.add);
    });

    tearDown(() async {
      await relay.dispose();
    });

    testWithoutContext('inflates a raw-deflate push body', () async {
      final Socket client = await Socket.connect(InternetAddress.loopbackIPv4, relay.tunnelPort);
      addTearDown(client.destroy);
      final received = <int>[];
      client.listen(received.addAll);

      // Long enough that the watch would really have compressed it.
      final Uint8List payload = utf8.encode('x' * 4096);
      final String frame = TunnelFrame(1, TunnelFrameKind.data, payload).encode();
      await _pushBytes(
        relay,
        ZLibCodec(raw: true).encode(utf8.encode(frame)),
        contentEncoding: kRawDeflateEncoding,
      );

      await _until(() => received.length >= payload.length);
      expect(received, payload);
    });

    testWithoutContext('still accepts an uncompressed push body', () async {
      // The watch sends plain when compression would not help, so the
      // uncompressed path has to keep working.
      final Socket client = await Socket.connect(InternetAddress.loopbackIPv4, relay.tunnelPort);
      addTearDown(client.destroy);
      final received = <int>[];
      client.listen(received.addAll);

      final Uint8List payload = utf8.encode('hello');
      await _pushRaw(relay, TunnelFrame(1, TunnelFrameKind.data, payload).encode());

      await _until(() => received.length >= payload.length);
      expect(received, payload);
    });

    testWithoutContext('a corrupt compressed body kills the connection it belonged to', () async {
      // Claims to be deflate but is not. Half-decoding it would corrupt the VM
      // Service stream silently, so the batch is dropped whole — and because
      // those bytes are simply gone, carrying on would splice the stream back
      // together minus a chunk. The connection has to die so flutter_tools
      // reports a lost connection instead of unexplained silence.
      final Socket client = await Socket.connect(InternetAddress.loopbackIPv4, relay.tunnelPort);
      addTearDown(client.destroy);
      final done = Completer<void>();
      client.listen((_) {}, onDone: done.complete, onError: (Object _) => done.complete());

      await _pushBytes(
        relay,
        utf8.encode('definitely not deflate'),
        contentEncoding: kRawDeflateEncoding,
      );

      await done.future.timeout(const Duration(seconds: 5));
      expect(traces.join('\n'), contains('could not inflate'));
      expect(traces.join('\n'), contains('dropping 1 tunnel connection'));
    });

    testWithoutContext('the relay keeps serving after a corrupt body', () async {
      final Socket doomed = await Socket.connect(InternetAddress.loopbackIPv4, relay.tunnelPort);
      addTearDown(doomed.destroy);
      doomed.listen((_) {}, onError: (Object _) {});
      await _pushBytes(
        relay,
        utf8.encode('definitely not deflate'),
        contentEncoding: kRawDeflateEncoding,
      );
      await _until(() => traces.join('\n').contains('could not inflate'));

      // A fresh connection gets a new id and must work normally.
      final Socket client = await Socket.connect(InternetAddress.loopbackIPv4, relay.tunnelPort);
      addTearDown(client.destroy);
      final received = <int>[];
      client.listen(received.addAll);

      final Uint8List payload = utf8.encode('still here');
      await _pushRaw(relay, TunnelFrame(2, TunnelFrameKind.data, payload).encode());
      await _until(() => received.length >= payload.length);
      expect(received, payload);
    });

    testWithoutContext('applies pipelined pushes in sequence order, not arrival order', () async {
      // The bridge keeps several pushes in flight and URLSession may deliver
      // them in any order; the relay must restore byte order or the VM Service
      // protocol is silently corrupted.
      final Socket client = await Socket.connect(InternetAddress.loopbackIPv4, relay.tunnelPort);
      addTearDown(client.destroy);
      final received = <int>[];
      client.listen(received.addAll);

      final Uint8List first = utf8.encode('FIRST');
      final Uint8List second = utf8.encode('SECOND');
      // Deliver seq 1 before seq 0: nothing may reach the client yet.
      await _pushBytes(
        relay,
        utf8.encode(TunnelFrame(1, TunnelFrameKind.data, second).encode()),
        seq: 1,
        epoch: 'e1',
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(received, isEmpty, reason: 'seq 1 must wait for seq 0');

      await _pushBytes(
        relay,
        utf8.encode(TunnelFrame(1, TunnelFrameKind.data, first).encode()),
        seq: 0,
        epoch: 'e1',
      );
      await _until(() => received.length >= first.length + second.length);
      expect(utf8.decode(received), 'FIRSTSECOND');
    });

    testWithoutContext('a new epoch resets the sequence', () async {
      // A relaunched app restarts its counter at 0. Keying on the old epoch
      // would make its first push look like a duplicate and stall the new
      // stream forever.
      final Socket client = await Socket.connect(InternetAddress.loopbackIPv4, relay.tunnelPort);
      addTearDown(client.destroy);
      final received = <int>[];
      client.listen(received.addAll);

      await _pushBytes(
        relay,
        utf8.encode(TunnelFrame(1, TunnelFrameKind.data, utf8.encode('old')).encode()),
        seq: 0,
        epoch: 'e1',
      );
      await _until(() => utf8.decode(received) == 'old');

      await _pushBytes(
        relay,
        utf8.encode(TunnelFrame(1, TunnelFrameKind.data, utf8.encode('new')).encode()),
        seq: 0,
        epoch: 'e2',
      );
      await _until(() => utf8.decode(received) == 'oldnew');
    });

    testWithoutContext('ignores a retransmitted sequence rather than replaying it', () async {
      final Socket client = await Socket.connect(InternetAddress.loopbackIPv4, relay.tunnelPort);
      addTearDown(client.destroy);
      final received = <int>[];
      client.listen(received.addAll);

      final List<int> body = utf8.encode(
        TunnelFrame(1, TunnelFrameKind.data, utf8.encode('once')).encode(),
      );
      await _pushBytes(relay, body, seq: 0, epoch: 'e1');
      await _pushBytes(relay, body, seq: 0, epoch: 'e1');
      // A later frame proves the duplicate was skipped, not merely delayed.
      await _pushBytes(
        relay,
        utf8.encode(TunnelFrame(1, TunnelFrameKind.data, utf8.encode('!')).encode()),
        seq: 1,
        epoch: 'e1',
      );
      await _until(() => utf8.decode(received).endsWith('!'));
      expect(utf8.decode(received), 'once!');
    });

    testWithoutContext('gives up on a push that never arrives instead of wedging', () async {
      // A push that fails past the bridge's retries leaves a permanent hole in
      // the sequence. Holding later bodies forever means the relay accumulates
      // them at wire rate while the user sees an indefinite hang; the watchdog
      // turns that into a reported lost connection.
      final WatchosVmRelay gapRelay = await WatchosVmRelay.start(
        logTrace: traces.add,
        pushGapTimeout: const Duration(milliseconds: 200),
      );
      addTearDown(gapRelay.dispose);

      final Socket client = await Socket.connect(
        InternetAddress.loopbackIPv4,
        gapRelay.tunnelPort,
      );
      addTearDown(client.destroy);
      final done = Completer<void>();
      client.listen((_) {}, onDone: done.complete, onError: (Object _) => done.complete());

      // seq 0 never comes.
      await _pushBytes(
        gapRelay,
        utf8.encode(TunnelFrame(1, TunnelFrameKind.data, utf8.encode('later')).encode()),
        seq: 1,
        epoch: 'e1',
      );

      await done.future.timeout(const Duration(seconds: 5));
      expect(traces.join('\n'), contains('push seq 0 never arrived'));

      // And the relay resynchronises past the hole rather than staying stuck:
      // a new connection with a following sequence still works.
      final Socket fresh = await Socket.connect(
        InternetAddress.loopbackIPv4,
        gapRelay.tunnelPort,
      );
      addTearDown(fresh.destroy);
      final received = <int>[];
      fresh.listen(received.addAll);
      await _pushBytes(
        gapRelay,
        utf8.encode(TunnelFrame(2, TunnelFrameKind.data, utf8.encode('ok')).encode()),
        seq: 2,
        epoch: 'e1',
      );
      await _until(() => utf8.decode(received) == 'ok');
    });

    testWithoutContext('a straggler that arrives in time does not trip the watchdog', () async {
      // Default gap timeout: the straggler must land well inside it.
      final WatchosVmRelay gapRelay = await WatchosVmRelay.start(logTrace: traces.add);
      addTearDown(gapRelay.dispose);

      final Socket client = await Socket.connect(
        InternetAddress.loopbackIPv4,
        gapRelay.tunnelPort,
      );
      addTearDown(client.destroy);
      final received = <int>[];
      client.listen(received.addAll);

      await _pushBytes(
        gapRelay,
        utf8.encode(TunnelFrame(1, TunnelFrameKind.data, utf8.encode('B')).encode()),
        seq: 1,
        epoch: 'e1',
      );
      await _pushBytes(
        gapRelay,
        utf8.encode(TunnelFrame(1, TunnelFrameKind.data, utf8.encode('A')).encode()),
        seq: 0,
        epoch: 'e1',
      );
      await _until(() => utf8.decode(received) == 'AB');
      expect(traces.join('\n'), isNot(contains('never arrived')));
    });

    testWithoutContext('gzips a poll response when the caller accepts it', () async {
      final Socket client = await Socket.connect(InternetAddress.loopbackIPv4, relay.tunnelPort);
      addTearDown(client.destroy);
      // Well past kMinCompressBytes, and repetitive so it really shrinks.
      client.add(utf8.encode('y' * 8192));
      await client.flush();

      final http = HttpClient()..autoUncompress = false;
      addTearDown(() => http.close(force: true));
      final HttpClientRequest request = await http.getUrl(
        Uri.parse('http://127.0.0.1:${relay.port}${relay.pathFor(RelayPaths.bridgePoll)}'),
      );
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'gzip');
      final HttpClientResponse response = await request.close();
      final List<int> body = await response.fold<List<int>>(<int>[], (a, b) => a..addAll(b));

      expect(response.headers.value(HttpHeaders.contentEncodingHeader), 'gzip');
      // Decodable, and genuinely smaller than what it stands for.
      final String decoded = utf8.decode(gzip.decode(body));
      expect(decoded, contains('frames'));
      expect(body.length, lessThan(decoded.length));
    });

    testWithoutContext('leaves a poll response plain when gzip is not accepted', () async {
      // Queue a frame first: an empty queue holds the poll open for
      // kBridgePollTimeout, which would add 20s to the suite for no coverage.
      final Socket client = await Socket.connect(InternetAddress.loopbackIPv4, relay.tunnelPort);
      addTearDown(client.destroy);
      client.add(utf8.encode('z' * 1024));
      await client.flush();

      final http = HttpClient()..autoUncompress = false;
      addTearDown(() => http.close(force: true));
      final HttpClientRequest request = await http.getUrl(
        Uri.parse('http://127.0.0.1:${relay.port}${relay.pathFor(RelayPaths.bridgePoll)}'),
      );
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final HttpClientResponse response = await request.close();
      await response.drain<void>();

      expect(response.headers.value(HttpHeaders.contentEncodingHeader), isNull);
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
      bridge = _FakeBridge(relay: relay, vmPort: vmService.port)..start();
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
        await _pushRaw(relay, TunnelFrame(1, TunnelFrameKind.data, List<int>.filled(64 * 1024, 65)).encode());
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
  _FakeBridge({required this.relay, required this.vmPort});

  final WatchosVmRelay relay;
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
          Uri.parse('http://127.0.0.1:${relay.port}${relay.pathFor(RelayPaths.bridgePoll)}'),
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

  int _pushSeq = 0;

  /// Serialised: frames must reach the relay in the order they were produced.
  /// Carries the pipeline headers the Swift bridge sends, so the relay's
  /// reassembly path is what these tests exercise.
  void _push(String frame) {
    _pushChain = _pushChain.then((_) async {
      if (!_running) {
        return;
      }
      try {
        final HttpClientRequest request = await _client.postUrl(
          Uri.parse('http://127.0.0.1:${relay.port}${relay.pathFor(RelayPaths.bridgePush)}'),
        );
        request.headers.set(kPushSeqHeader, '${_pushSeq++}');
        request.headers.set(kPushEpochHeader, 'fake-bridge');
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
Future<void> _pushRaw(WatchosVmRelay relay, String frame) async {
  final client = HttpClient();
  try {
    final HttpClientRequest request = await client.postUrl(
      Uri.parse('http://127.0.0.1:${relay.port}${relay.pathFor(RelayPaths.bridgePush)}'),
    );
    request.write(frame);
    final HttpClientResponse response = await request.close();
    await response.drain<void>();
  } finally {
    client.close();
  }
}

/// Posts a raw body to the push endpoint, optionally claiming an encoding
/// and/or a pipeline position.
Future<void> _pushBytes(
  WatchosVmRelay relay,
  List<int> body, {
  String? contentEncoding,
  int? seq,
  String? epoch,
}) async {
  final client = HttpClient();
  try {
    final HttpClientRequest request = await client.postUrl(
      Uri.parse('http://127.0.0.1:${relay.port}${relay.pathFor(RelayPaths.bridgePush)}'),
    );
    if (contentEncoding != null) {
      request.headers.set(HttpHeaders.contentEncodingHeader, contentEncoding);
    }
    if (seq != null) {
      request.headers.set(kPushSeqHeader, '$seq');
    }
    if (epoch != null) {
      request.headers.set(kPushEpochHeader, epoch);
    }
    request.add(body);
    final HttpClientResponse response = await request.close();
    await response.drain<void>();
  } finally {
    client.close();
  }
}

/// Polls [condition] until it holds, or fails the test after [timeout].
///
/// The tunnel is asynchronous end to end, so an assertion straight after a
/// push races the delivery it is checking.
Future<void> _until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within ${timeout.inSeconds}s');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
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
