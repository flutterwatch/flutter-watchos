// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/os.dart';
import 'package:flutter_watchos/watchos_device_discovery.dart';
import 'package:flutter_watchos/watchos_doctor.dart';

import '../src/common.dart';
import '../src/fakes.dart';

void main() {
  late WatchosDeviceDiscovery discovery;

  setUp(() {
    final workflow = WatchosWorkflow(
      operatingSystemUtils: FakeOperatingSystemUtils(hostPlatform: HostPlatform.darwin_arm64),
    );
    discovery = WatchosDeviceDiscovery(watchosWorkflow: workflow, logger: BufferLogger.test());
  });

  testWithoutContext('supportsPlatform reflects workflow capability', () {
    expect(discovery.supportsPlatform, isTrue);
    expect(discovery.canListAnything, isTrue);
  });

  testWithoutContext('wellKnownIds is empty', () {
    expect(discovery.wellKnownIds, isEmpty);
  });

  testWithoutContext('getDiagnostics returns empty list', () async {
    expect(await discovery.getDiagnostics(), isEmpty);
  });
}
