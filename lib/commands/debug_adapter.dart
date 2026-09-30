// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/commands/debug_adapter.dart';

import 'port_help.dart';

/// `debug-adapter`: stock's command, whose `--dds-port` help says "random
/// unused port" ([UnusedPortHelp]).
class WatchosDebugAdapterCommand extends DebugAdapterCommand with UnusedPortHelp {
  /// The `debug-adapter` command; hidden unless [verboseHelp], as in stock.
  WatchosDebugAdapterCommand({super.verboseHelp});
}
