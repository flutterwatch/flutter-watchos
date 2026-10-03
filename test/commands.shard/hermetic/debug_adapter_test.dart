// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/debug_adapters/flutter_adapter_args.dart';
import 'package:flutter_tools/src/debug_adapters/server.dart';
import 'package:flutter_watchos/commands/debug_adapter.dart';

import '../../src/common.dart';
import '../../src/context.dart';

const String _tool = '/clone/bin/flutter-watchos';

/// The timeout of each test that runs stock's adapter.
///
/// The adapter starts a real process, a shell script standing in for the
/// tool, and the test waits for it to write its arguments. That takes about a
/// second on an idle machine and more on a loaded CI runner, over the 2 s every
/// other test gets.
const _adapterTimeout = Timeout(Duration(seconds: 10));

/// [json] framed as a Debug Adapter Protocol message.
List<int> _frame(Map<String, Object?> json) {
  final List<int> body = utf8.encode(jsonEncode(json));
  return <int>[...ascii.encode('Content-Length: ${body.length}\r\n\r\n'), ...body];
}

/// The messages in [bytes], decoded, split at their `Content-Length`.
List<Map<String, Object?>> _unframe(List<int> bytes) {
  final messages = <Map<String, Object?>>[];
  var rest = bytes;
  while (rest.isNotEmpty) {
    final String text = latin1.decode(rest);
    final int headerEnd = text.indexOf('\r\n\r\n');
    final int length = int.parse(
      RegExp(r'Content-Length: (\d+)').firstMatch(text.substring(0, headerEnd))![1]!,
    );
    final int start = headerEnd + 4;
    messages.add(
      jsonDecode(utf8.decode(rest.sublist(start, start + length))) as Map<String, Object?>,
    );
    rest = rest.sublist(start + length);
  }
  return messages;
}

Map<String, Object?> _request(int seq, String command, [Map<String, Object?>? arguments]) =>
    <String, Object?>{'seq': seq, 'type': 'request', 'command': command, 'arguments': ?arguments};

/// What [chunks] become after the transformer.
Future<List<int>> _transform(List<List<int>> chunks) async {
  final List<List<int>> out = await Stream<List<int>>.fromIterable(
    chunks,
  ).transform(const WatchosDapToolTransformer(_tool)).toList();
  return out.expand((List<int> chunk) => chunk).toList();
}

void main() {
  group('WatchosDapToolTransformer', () {
    test('a launch request with no customTool gets bin/flutter-watchos', () async {
      final List<int> out = await _transform(<List<int>>[
        _frame(_request(2, 'launch', <String, Object?>{'cwd': '/app', 'program': 'lib/main.dart'})),
      ]);

      final Map<String, Object?> request = _unframe(out).single;
      final args = FlutterLaunchRequestArguments.fromJson(
        request['arguments']! as Map<String, Object?>,
      );
      expect(args.customTool, _tool);
      expect(args.program, 'lib/main.dart');
      expect(args.cwd, '/app');
      expect(request['seq'], 2);
    });

    test('an attach request with no customTool gets bin/flutter-watchos', () async {
      final List<int> out = await _transform(<List<int>>[
        _frame(_request(2, 'attach', <String, Object?>{'cwd': '/app'})),
      ]);

      final args = FlutterAttachRequestArguments.fromJson(
        _unframe(out).single['arguments']! as Map<String, Object?>,
      );
      expect(args.customTool, _tool);
    });

    test('a request that names a customTool is kept byte for byte', () async {
      final List<int> launch = _frame(
        _request(2, 'launch', <String, Object?>{
          'cwd': '/app',
          'customTool': '/custom/flutter',
          'customToolReplacesArgs': 1,
        }),
      );

      expect(await _transform(<List<int>>[launch]), launch);
    });

    test('customToolReplacesArgs without a customTool is dropped, as stock ignores it', () async {
      final List<int> out = await _transform(<List<int>>[
        _frame(
          _request(2, 'launch', <String, Object?>{'cwd': '/app', 'customToolReplacesArgs': 2}),
        ),
      ]);

      final arguments = _unframe(out).single['arguments']! as Map<String, Object?>;
      expect(arguments['customTool'], _tool);
      expect(arguments.containsKey('customToolReplacesArgs'), isFalse);
    });

    test('other messages pass byte for byte, split or joined in any chunks', () async {
      final List<int> initialize = _frame(
        _request(1, 'initialize', <String, Object?>{'adapterID': 'dart'}),
      );
      final List<int> done = _frame(_request(3, 'configurationDone'));
      final List<int> launch = _frame(
        _request(2, 'launch', <String, Object?>{'cwd': '/app', 'program': 'lib/main.dart'}),
      );
      final all = <int>[...initialize, ...launch, ...done];
      // One byte at a time, then all at once.
      final List<int> bytewise = await _transform(<List<int>>[
        for (final int byte in all) <int>[byte],
      ]);
      final List<int> joined = await _transform(<List<int>>[all]);

      expect(joined, bytewise);
      final List<Map<String, Object?>> messages = _unframe(joined);
      expect(messages.map((Map<String, Object?> m) => m['command']), <String>[
        'initialize',
        'launch',
        'configurationDone',
      ]);
      expect(joined.sublist(0, initialize.length), initialize);
      expect(joined.sublist(joined.length - done.length), done);
    });

    test('input it cannot parse passes through for stock to report', () async {
      final List<int> garbage = ascii.encode('Nonsense: 1\r\n\r\n{"type":"request"}');
      final badJson = <int>[...ascii.encode('Content-Length: 3\r\n\r\n'), 123, 123, 123];

      expect(await _transform(<List<int>>[garbage]), garbage);
      expect(await _transform(<List<int>>[badJson]), badJson);
    });

    test('a message cut off at the end of input passes through as it came', () async {
      final List<int> cut = _frame(_request(2, 'launch', <String, Object?>{'cwd': '/app'}));
      final List<int> partial = cut.sublist(0, cut.length - 5);

      expect(await _transform(<List<int>>[partial]), partial);
    });
  });

  group("stock's adapter behind the transformer", () {
    late io.Directory temp;
    late String record;
    // Stock's adapter sets the process's current directory to the request's
    // `cwd`, and test files share the process: the requests name the one
    // the tests run in, so nothing moves.
    late String cwd;

    setUpAll(() {
      Cache.flutterRoot = '/fake/flutter';
    });

    setUp(() {
      temp = io.Directory(
        io.Directory.systemTemp.createTempSync('watchos_dap_test.').resolveSymbolicLinksSync(),
      );
      record = '${temp.path}/argv.txt';
      cwd = io.Directory.current.path;
    });

    tearDown(() {
      io.Directory.current = cwd;
      temp.deleteSync(recursive: true);
    });

    /// A script at [name] in the temp folder that writes its path and its
    /// arguments, one per line, to [record].
    String script(String name) {
      final file = io.File('${temp.path}/$name')
        ..writeAsStringSync('#!/bin/sh\nprintf "%s\\n" "\$0" "\$@" > "$record"\n');
      io.Process.runSync('chmod', <String>['+x', file.path]);
      return file.path;
    }

    /// Runs stock's [DapServer] with [requests] passed through the
    /// transformer for [toolPath], and returns the lines the started tool
    /// recorded: its path, then its arguments.
    Future<List<String>> session(
      String toolPath,
      Map<String, Object?> request, {
      bool test = false,
    }) async {
      final input = StreamController<List<int>>();
      final output = StreamController<List<int>>();
      final sent = <int>[];
      output.stream.listen(sent.addAll);
      final server = DapServer(
        input.stream.transform(WatchosDapToolTransformer(toolPath)),
        output.sink,
        fileSystem: MemoryFileSystem.test(),
        platform: FakePlatform(),
        test: test,
      );
      input
        ..add(_frame(_request(1, 'initialize', <String, Object?>{'adapterID': 'dart'})))
        ..add(_frame(_request(2, 'configurationDone')))
        ..add(_frame(request));
      final recordFile = io.File(record);
      // Under [_adapterTimeout], so a tool that never starts fails with what
      // the adapter sent rather than with a bare timeout.
      final DateTime deadline = DateTime.now().add(const Duration(seconds: 8));
      while (!recordFile.existsSync() || !recordFile.readAsStringSync().endsWith('\n')) {
        if (DateTime.now().isAfter(deadline)) {
          fail('no tool started; the adapter sent: ${utf8.decode(sent, allowMalformed: true)}');
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      server.stop();
      await input.close();
      return recordFile.readAsLinesSync();
    }

    test('launch with no customTool starts bin/flutter-watchos run --machine', () async {
      final String tool = script('flutter-watchos');

      final List<String> argv = await session(
        tool,
        _request(3, 'launch', <String, Object?>{
          'cwd': cwd,
          'program': 'lib/main.dart',
          'noDebug': true,
        }),
      );

      expect(argv.first, tool);
      expect(argv.sublist(1), containsAllInOrder(<String>['run', '--machine']));
      expect(argv.sublist(1), containsAllInOrder(<String>['--target', 'lib/main.dart']));
    });

    test('attach with no customTool starts bin/flutter-watchos attach --machine', () async {
      final String tool = script('flutter-watchos');

      final List<String> argv = await session(
        tool,
        _request(3, 'attach', <String, Object?>{'cwd': cwd}),
      );

      expect(argv.first, tool);
      expect(argv.sublist(1), containsAllInOrder(<String>['attach', '--machine']));
    });

    test('debug-adapter --test starts bin/flutter-watchos test --machine', () async {
      final String tool = script('flutter-watchos');

      final List<String> argv = await session(
        tool,
        _request(3, 'launch', <String, Object?>{
          'cwd': cwd,
          'program': 'test/widget_test.dart',
          'noDebug': true,
        }),
        test: true,
      );

      expect(argv.first, tool);
      expect(argv.sublist(1), containsAllInOrder(<String>['test', '--machine']));
      expect(argv.last, 'test/widget_test.dart');
    });

    test("a request's own customTool is kept, with its customToolReplacesArgs", () async {
      final String tool = script('flutter-watchos');
      final String custom = script('custom-flutter');

      final List<String> argv = await session(
        tool,
        _request(3, 'launch', <String, Object?>{
          'cwd': cwd,
          'program': 'lib/main.dart',
          'noDebug': true,
          'customTool': custom,
          'customToolReplacesArgs': 1,
        }),
      );

      expect(argv.first, custom);
      // Stock removed the first of its arguments, `run`, for the custom tool.
      expect(argv[1], '--machine');
    });
  }, timeout: _adapterTimeout);

  group('WatchosDebugAdapterCommand', () {
    testUsingContext('a given tool path is the one sessions start', () {
      expect(WatchosDebugAdapterCommand(toolPath: '/elsewhere/tool').toolPath, '/elsewhere/tool');
    });

    testUsingContext(
      'by default sessions start bin/flutter-watchos next to the pinned SDK',
      () {
        Cache.flutterRoot = '/clone/flutter';

        expect(WatchosDebugAdapterCommand().toolPath, _tool);
      },
      overrides: <Type, Generator>{
        FileSystem: () => MemoryFileSystem.test(),
        ProcessManager: () => FakeProcessManager.empty(),
      },
    );
  });
}
