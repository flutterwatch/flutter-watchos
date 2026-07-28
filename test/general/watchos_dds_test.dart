// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io' show InternetAddress, SocketException;

import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_watchos/watchos_dds.dart';
import 'package:flutter_watchos/watchos_device.dart';

import '../src/common.dart';

void main() {
  // DDS picks its bind family by resolving the *remote* VM service host, while
  // flutter_tools picks it from `--ipv6`. When a wirelessly-paired watch is
  // reachable only over IPv6 the two disagree and DDS rejects the bind address
  // with "serviceUri 'http://127.0.0.1:0' is not an IPv6 address", killing
  // `run`/`attach`/`drive` on a physical watch.
  group('WatchosDartDevelopmentService.shouldBindIpv6', () {
    WatchosDartDevelopmentService serviceResolving(Map<String, List<String>> dns) {
      return WatchosDartDevelopmentService(
        logger: BufferLogger.test(),
        resolveHost: (String host) async {
          final List<String>? addresses = dns[host];
          if (addresses == null) {
            throw const SocketException('Failed host lookup');
          }
          return addresses.map(InternetAddress.new).toList();
        },
      );
    }

    testWithoutContext('binds IPv6 for a host that only resolves to IPv6', () async {
      final WatchosDartDevelopmentService service = serviceResolving(<String, List<String>>{
        'my-watch.coredevice.local': <String>['fd12:3456::1'],
      });
      expect(
        await service.shouldBindIpv6(Uri.parse('http://my-watch.coredevice.local:53421/')),
        isTrue,
      );
    });

    testWithoutContext('binds IPv4 for a host that resolves to IPv4', () async {
      final WatchosDartDevelopmentService service = serviceResolving(<String, List<String>>{
        'my-watch.local': <String>['fd12:3456::1', '192.168.1.42'],
      });
      expect(await service.shouldBindIpv6(Uri.parse('http://my-watch.local:53421/')), isFalse);
    });

    testWithoutContext('reads an IP literal without a DNS lookup', () async {
      final WatchosDartDevelopmentService service = serviceResolving(
        const <String, List<String>>{},
      );
      expect(await service.shouldBindIpv6(Uri.parse('http://192.168.1.42:53421/')), isFalse);
      expect(await service.shouldBindIpv6(Uri.parse('http://[fd12:3456::1]:53421/')), isTrue);
    });

    testWithoutContext('treats a scoped IPv6 literal as IPv6', () async {
      // `fe80::1%en0` doesn't parse as an InternetAddress, and would otherwise
      // fall through to a DNS lookup that cannot succeed.
      final WatchosDartDevelopmentService service = serviceResolving(
        const <String, List<String>>{},
      );
      expect(await service.shouldBindIpv6(Uri.parse('http://[fe80::1%25en0]:53421/')), isTrue);
    });

    testWithoutContext('honours an explicit --ipv6 for an IPv4 host', () async {
      final WatchosDartDevelopmentService service = serviceResolving(
        const <String, List<String>>{},
      );
      expect(
        await service.shouldBindIpv6(Uri.parse('http://192.168.1.42:53421/'), ipv6: true),
        isTrue,
      );
    });

    testWithoutContext('leaves the default alone when the host cannot be resolved', () async {
      // DDS reports the unresolvable host with a better message than we could.
      final WatchosDartDevelopmentService service = serviceResolving(
        const <String, List<String>>{},
      );
      expect(await service.shouldBindIpv6(Uri.parse('http://nonexistent.invalid:1/')), isFalse);
    });
  });

  group('hostHasIpv4Address', () {
    testWithoutContext('is true when any resolved address is IPv4', () async {
      Future<List<InternetAddress>> resolve(String host) async => <InternetAddress>[
        InternetAddress('fd00::1'),
        InternetAddress('10.0.0.5'),
      ];
      expect(await hostHasIpv4Address('watch.local', resolve), isTrue);
    });

    testWithoutContext('is false when every resolved address is IPv6', () async {
      Future<List<InternetAddress>> resolve(String host) async => <InternetAddress>[
        InternetAddress('fd00::1'),
      ];
      expect(await hostHasIpv4Address('watch.local', resolve), isFalse);
    });
  });

  group('WatchosDevice.dds', () {
    testWithoutContext('uses the watchOS DDS so the bind family follows the device', () {
      final device = WatchosDevice(
        'physical-watch-id',
        name: 'My Watch',
        logger: BufferLogger.test(),
        isSimulator: false,
      );
      expect(device.dds, isA<WatchosDartDevelopmentService>());
    });
  });
}
