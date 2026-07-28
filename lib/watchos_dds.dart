// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io' show InternetAddress, InternetAddressType, SocketException;

import 'package:flutter_tools/src/base/dds.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:meta/meta.dart';

/// Resolves a hostname to its addresses. Injected so tests don't hit DNS.
typedef HostResolver = Future<List<InternetAddress>> Function(String host);

/// A [DartDevelopmentService] that binds on the same address family as the
/// app's Dart VM Service instead of trusting `--ipv6`.
///
/// An Apple Watch is always wirelessly paired, and is usually reachable only
/// over IPv6 (a `.coredevice.local` name or a raw IPv6 address). flutter_tools
/// picks the DDS bind address from `DebuggingOptions.ipv6` — false unless the
/// user passes `--ipv6` — while the DDS process picks its own family by
/// resolving the *remote* VM service host. When those disagree DDS rejects the
/// bind address it was handed:
///
///     Bad state: Invalid argument(s): serviceUri 'http://127.0.0.1:0'
///     is not an IPv6 address.
///
/// which aborts `run`, `attach`, and `drive` on a physical watch. Deriving the
/// flag the same way DDS does keeps the two in agreement.
class WatchosDartDevelopmentService extends DartDevelopmentService {
  // The base class keeps its logger private, so hold our own reference for the
  // trace below rather than forwarding a super parameter.
  // ignore: use_super_parameters
  WatchosDartDevelopmentService({required Logger logger, HostResolver? resolveHost})
    : _logger = logger,
      _resolveHost = resolveHost ?? InternetAddress.lookup,
      super(logger: logger);

  final Logger _logger;
  final HostResolver _resolveHost;

  @override
  Future<void> startDartDevelopmentService(
    Uri vmServiceUri, {
    String? appName,
    int? ddsPort,
    bool? disableServiceAuthCodes,
    bool? ipv6,
    bool enableDevTools = true,
    bool cacheStartupProfile = false,
    String? google3WorkspaceRoot,
    Uri? devToolsServerAddress,
  }) async {
    return super.startDartDevelopmentService(
      vmServiceUri,
      appName: appName,
      ddsPort: ddsPort,
      disableServiceAuthCodes: disableServiceAuthCodes,
      ipv6: await shouldBindIpv6(vmServiceUri, ipv6: ipv6),
      enableDevTools: enableDevTools,
      cacheStartupProfile: cacheStartupProfile,
      google3WorkspaceRoot: google3WorkspaceRoot,
      devToolsServerAddress: devToolsServerAddress,
    );
  }

  /// The address family DDS should bind on for [vmServiceUri].
  ///
  /// Honours an explicit `--ipv6`, and otherwise upgrades to IPv6 when the
  /// watch's VM service host has no IPv4 address — which is what the DDS
  /// process itself concludes from the same host.
  @visibleForTesting
  Future<bool> shouldBindIpv6(Uri vmServiceUri, {bool? ipv6}) async {
    if (ipv6 ?? false) {
      return true;
    }
    if (await hostHasIpv4Address(vmServiceUri.host, _resolveHost)) {
      return false;
    }
    _logger.printTrace(
      'The Dart VM Service host "${vmServiceUri.host}" has no IPv4 address; '
      'binding DDS on IPv6 loopback so it can reach the watch.',
    );
    return true;
  }
}

/// Whether [host] is, or resolves to, an IPv4 address.
///
/// Mirrors the check the DDS entrypoint runs on the remote VM service URI, so
/// [WatchosDartDevelopmentService] reaches the same conclusion DDS will.
/// Returns true when [host] cannot be resolved at all: the family is then a
/// guess either way, and DDS reports the real failure with a better message.
@visibleForTesting
Future<bool> hostHasIpv4Address(String host, HostResolver resolveHost) async {
  final InternetAddress? literal = InternetAddress.tryParse(host);
  if (literal != null) {
    return literal.type == InternetAddressType.IPv4;
  }
  // A scoped IPv6 literal (`fe80::1%en0`) doesn't parse, and no hostname
  // contains a colon.
  if (host.contains(':')) {
    return false;
  }
  try {
    final List<InternetAddress> addresses = await resolveHost(host);
    return addresses.any((InternetAddress address) => address.type == InternetAddressType.IPv4);
  } on SocketException {
    return true;
  }
}
