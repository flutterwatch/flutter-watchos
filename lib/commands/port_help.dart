// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/runner/flutter_command.dart';

/// Rewords stock's port help to say that a port of 0 finds a "random unused
/// port", or a "random unused host port".
///
/// Stock's `--dds-port`, `--host-vmservice-port` and `--vm-service-port`
/// help names that port with a word this tool does not print. The help shows
/// through [usage], for `-h` and `help <command>`; a usage error prints only
/// its message, never the usage. Only the text changes: the options and
/// their parsing are stock's.
mixin UnusedPortHelp on FlutterCommand {
  @override
  String get usage => rewordStockPortHelp(super.usage);
}

/// [text] with the word between "random" and "port" (or "host port") in
/// stock's port help replaced by "unused", wherever the help wraps between
/// the words.
String rewordStockPortHelp(String text) => text.replaceAllMapped(
  RegExp(r'random(\s+)(?!host\b)[a-z]+(\s+)(host\s+)?port'),
  (Match match) => 'random${match[1]}unused${match[2]}${match[3] ?? ''}port',
);
