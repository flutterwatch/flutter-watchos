// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_watchos/watchos_build_info.dart';

import '../src/common.dart';

void main() {
  testWithoutContext('sdkName is watchsimulator for simulator builds', () {
    const buildInfo = WatchosBuildInfo(BuildInfo.debug, targetArch: 'arm64', simulator: true);
    expect(buildInfo.sdkName, equals('watchsimulator'));
  });

  testWithoutContext('sdkName is watchos for device builds', () {
    const buildInfo = WatchosBuildInfo(BuildInfo.debug, targetArch: 'arm64');
    expect(buildInfo.sdkName, equals('watchos'));
  });

  testWithoutContext('destination is the watchOS Simulator destination', () {
    const buildInfo = WatchosBuildInfo(BuildInfo.debug, targetArch: 'arm64', simulator: true);
    expect(buildInfo.destination, equals('generic/platform=watchOS Simulator'));
  });

  testWithoutContext('destination is the watchOS device destination', () {
    const buildInfo = WatchosBuildInfo(BuildInfo.release, targetArch: 'arm64');
    expect(buildInfo.destination, equals('generic/platform=watchOS'));
  });

  testWithoutContext('defaults to non-simulator (device)', () {
    const buildInfo = WatchosBuildInfo(BuildInfo.debug, targetArch: 'arm64');
    expect(buildInfo.simulator, isFalse);
    expect(buildInfo.sdkName, equals('watchos'));
  });
}
