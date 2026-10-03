// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Pins the `xcodebuild` command line of the watch app build. The
// architecture rule is the part that matters most: a device build must leave
// `ARCHS` to Xcode's Standard Architectures, which build the arm64_32 slice
// the App Store requires below watchOS 27.0, while the Simulator is
// arm64-only.

import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_watchos/build_targets/application.dart';
import 'package:flutter_watchos/watchos_build_info.dart';

import '../src/common.dart';

const _simulatorDebug = WatchosBuildInfo(BuildInfo.debug, targetArch: 'arm64', simulator: true);
const _deviceRelease = WatchosBuildInfo(BuildInfo.release, targetArch: 'arm64');
const _deviceProfile = WatchosBuildInfo(BuildInfo.profile, targetArch: 'arm64');

void main() {
  testWithoutContext('a device build passes no ARCHS', () {
    for (final buildInfo in <WatchosBuildInfo>[_deviceRelease, _deviceProfile]) {
      final List<String> args = watchosXcodebuildArgs(
        buildInfo: buildInfo,
        hasWorkspace: false,
        symroot: '/app/build/watchos',
      );
      expect(args.where((String arg) => arg.startsWith('ARCHS')), isEmpty);
    }
  });

  testWithoutContext('a Simulator build passes ARCHS=arm64', () {
    final List<String> args = watchosXcodebuildArgs(
      buildInfo: _simulatorDebug,
      hasWorkspace: false,
      symroot: '/app/build/watchos',
    );
    expect(args.where((String arg) => arg.startsWith('ARCHS')), <String>['ARCHS=arm64']);
  });

  testWithoutContext('the Simulator argv in full', () {
    expect(
      watchosXcodebuildArgs(
        buildInfo: _simulatorDebug,
        hasWorkspace: false,
        symroot: '/app/build/watchos',
        // A Simulator build is never signed; stray values must not leak in.
        signingArgs: const <String>['DEVELOPMENT_TEAM=ABCDE12345'],
        authenticationArgs: const <String>['-authenticationKeyID', 'KEY'],
      ),
      <String>[
        'xcodebuild',
        '-project',
        'Runner.xcodeproj',
        '-scheme',
        'Runner',
        '-configuration',
        'Debug',
        '-sdk',
        'watchsimulator',
        '-destination',
        'generic/platform=watchOS Simulator',
        'SYMROOT=/app/build/watchos',
        'COMPILER_INDEX_STORE_ENABLE=NO',
        'ARCHS=arm64',
        'build',
      ],
    );
  });

  testWithoutContext('the device argv in full', () {
    expect(
      watchosXcodebuildArgs(
        buildInfo: _deviceRelease,
        hasWorkspace: true,
        symroot: '/app/build/watchos',
        signingArgs: const <String>['DEVELOPMENT_TEAM=ABCDE12345', 'CODE_SIGN_STYLE=Automatic'],
        authenticationArgs: const <String>['-authenticationKeyID', 'KEY'],
      ),
      <String>[
        'xcodebuild',
        '-workspace',
        'Runner.xcworkspace',
        '-scheme',
        'Runner',
        '-configuration',
        'Release',
        '-sdk',
        'watchos',
        '-destination',
        'generic/platform=watchOS',
        'SYMROOT=/app/build/watchos',
        'COMPILER_INDEX_STORE_ENABLE=NO',
        'DEVELOPMENT_TEAM=ABCDE12345',
        'CODE_SIGN_STYLE=Automatic',
        '-allowProvisioningUpdates',
        '-authenticationKeyID',
        'KEY',
        'build',
      ],
    );
  });

  testWithoutContext('profile builds the Release configuration', () {
    final List<String> args = watchosXcodebuildArgs(
      buildInfo: _deviceProfile,
      hasWorkspace: false,
      symroot: '/app/build/watchos',
    );
    expect(args[args.indexOf('-configuration') + 1], 'Release');
  });
}
