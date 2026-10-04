// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/commands/debug_adapter.dart';
import 'package:flutter_tools/src/debug_adapters/server.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/runner/flutter_command.dart';

import 'port_help.dart';

/// `debug-adapter`: stock's command, except that a session starts
/// flutter-watchos instead of stock `flutter`.
///
/// Stock's adapter runs `<Cache.flutterRoot>/bin/flutter` for a `launch` or
/// `attach` request that names no `customTool`, which here is the pinned SDK
/// without the watch. This command puts `bin/flutter-watchos` of this clone
/// into such a request ([WatchosDapToolTransformer]); a request's own
/// `customTool` is kept. Its `--dds-port` help says "random unused port"
/// ([UnusedPortHelp]).
class WatchosDebugAdapterCommand extends DebugAdapterCommand with UnusedPortHelp {
  /// The `debug-adapter` command; hidden unless [verboseHelp], as in stock.
  ///
  /// [toolPath] is the tool a session starts; it defaults to
  /// `bin/flutter-watchos` next to the pinned SDK, which `main` sets as
  /// [Cache.flutterRoot].
  WatchosDebugAdapterCommand({super.verboseHelp, String? toolPath}) : _toolPath = toolPath;

  final String? _toolPath;

  /// The executable a `launch` or `attach` request with no `customTool`
  /// starts.
  String get toolPath =>
      _toolPath ??
      globals.fs.path.join(globals.fs.path.dirname(Cache.flutterRoot!), 'bin', 'flutter-watchos');

  // Source: stock `DebugAdapterCommand.runCommand`, with the input stream
  // passed through [WatchosDapToolTransformer].
  @override
  Future<FlutterCommandResult> runCommand() async {
    final server = DapServer(
      globals.stdio.stdin.transform(WatchosDapToolTransformer(toolPath)),
      globals.stdio.stdout.nonBlocking,
      fileSystem: globals.fs,
      platform: globals.platform,
      ipv6: ipv6 ?? false,
      enableDds: enableDds,
      test: boolArg('test'),
      onError: (Object? e) {
        globals.printError(
          'Input could not be parsed as a Debug Adapter Protocol message.\n'
          'The "flutter-watchos debug-adapter" command is intended for use by '
          'tooling that communicates using the Debug Adapter Protocol.\n\n'
          '$e',
        );
      },
    );

    await server.channel.closed;

    return FlutterCommandResult.success();
  }
}

/// Puts [toolPath] as the `customTool` of each Debug Adapter Protocol
/// `launch` and `attach` request that names none.
///
/// The input is the protocol's byte stream: each message is a
/// `Content-Length` header block, a blank line, and a JSON body. A request
/// that already names a `customTool`, every other message, and anything that
/// does not parse pass through byte for byte, so stock's adapter sees and
/// reports them as before. A rewritten request drops `customToolReplacesArgs`,
/// which stock ignores when there is no `customTool`, so the tool still gets
/// all of stock's arguments.
class WatchosDapToolTransformer extends StreamTransformerBase<List<int>, List<int>> {
  /// Rewrites requests to start [toolPath].
  const WatchosDapToolTransformer(this.toolPath);

  /// The executable a request with no `customTool` gets.
  final String toolPath;

  static const List<int> _headerEnd = <int>[13, 10, 13, 10];

  @override
  Stream<List<int>> bind(Stream<List<int>> stream) async* {
    var pending = <int>[];
    var passThrough = false;
    await for (final List<int> chunk in stream) {
      if (passThrough) {
        yield chunk;
        continue;
      }
      pending.addAll(chunk);
      while (true) {
        final int headerEnd = _indexOfHeaderEnd(pending);
        if (headerEnd < 0) {
          break;
        }
        final int? length = _contentLength(pending.sublist(0, headerEnd));
        if (length == null) {
          // Not a header this transformer understands: stock reports it.
          passThrough = true;
          break;
        }
        final int end = headerEnd + _headerEnd.length + length;
        if (pending.length < end) {
          break;
        }
        yield _rewrite(
          pending.sublist(0, end),
          pending.sublist(headerEnd + _headerEnd.length, end),
        );
        pending = pending.sublist(end);
      }
      if (passThrough && pending.isNotEmpty) {
        yield pending;
        pending = <int>[];
      }
    }
    if (pending.isNotEmpty) {
      yield pending;
    }
  }

  /// The message with [toolPath] as its `customTool`, or [message] itself
  /// when it is not a `launch` or `attach` request without one.
  List<int> _rewrite(List<int> message, List<int> body) {
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(body));
    } on FormatException {
      return message;
    }
    if (json is! Map<String, Object?> || json['type'] != 'request') {
      return message;
    }
    final Object? command = json['command'];
    final Object? arguments = json['arguments'];
    if ((command != 'launch' && command != 'attach') ||
        arguments is! Map<String, Object?> ||
        arguments['customTool'] != null) {
      return message;
    }
    arguments
      ..['customTool'] = toolPath
      ..remove('customToolReplacesArgs');
    final List<int> newBody = utf8.encode(jsonEncode(json));
    return <int>[...ascii.encode('Content-Length: ${newBody.length}\r\n\r\n'), ...newBody];
  }

  /// Where the blank line after the header block starts in [bytes], or -1.
  static int _indexOfHeaderEnd(List<int> bytes) {
    for (var i = 0; i + _headerEnd.length <= bytes.length; i++) {
      if (bytes[i] == 13 && bytes[i + 1] == 10 && bytes[i + 2] == 13 && bytes[i + 3] == 10) {
        return i;
      }
    }
    return -1;
  }

  /// The `Content-Length` of a header block, or null when it has none.
  static int? _contentLength(List<int> header) {
    final String text;
    try {
      text = ascii.decode(header);
    } on FormatException {
      return null;
    }
    for (final String line in text.split('\r\n')) {
      final int colon = line.indexOf(':');
      if (colon > 0 && line.substring(0, colon).trim().toLowerCase() == 'content-length') {
        final int? length = int.tryParse(line.substring(colon + 1).trim());
        return length != null && length >= 0 ? length : null;
      }
    }
    return null;
  }
}
