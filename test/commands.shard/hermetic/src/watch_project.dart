// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// A watch project and watch targets for the launch-command tests.
library;

import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_watchos/watchos_device.dart';

/// The id of [watchSimulator].
const String kSimulatorId = '4F1C2B7E-0000-4000-8000-00000000A11E';

/// The id of [physicalWatch].
const String kWatchId = '00008310-000A1B2C3D4E5F60';

/// A booted watch Simulator.
WatchosDevice watchSimulator() => WatchosDevice(
  kSimulatorId,
  name: 'Apple Watch Series 11 (46mm)',
  logger: BufferLogger.test(),
  isSimulator: true,
  osVersion: '26.5',
);

/// A paired physical watch.
WatchosDevice physicalWatch() => WatchosDevice(
  kWatchId,
  name: "Someone's Apple Watch",
  logger: BufferLogger.test(),
  isSimulator: false,
  osVersion: '26.5',
);

/// Writes a watch app at `/project` in [fileSystem] and makes it the
/// current directory: a pubspec, `lib/main.dart`, a driver test and an empty
/// `watchos/` folder, which is what makes watch targets supported.
void writeWatchProject(FileSystem fileSystem) {
  final Directory project = fileSystem.directory('/project')..createSync();
  project.childFile('pubspec.yaml').writeAsStringSync('name: my_app\n');
  project.childDirectory('lib').childFile('main.dart').createSync(recursive: true);
  project.childDirectory('test_driver').childFile('main_test.dart').createSync(recursive: true);
  project.childDirectory('watchos').createSync();
  fileSystem.currentDirectory = project;
}
