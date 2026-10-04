// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// Exercises the VM Service calls DevTools' debugger, memory, CPU and
/// performance pages make, against a running debug suite fixture app.
///
/// Usage:
///
///     dart tool/debug_suite/vmcheck.dart <vm-service-uri> <script-uri> <line>
///     dart tool/debug_suite/vmcheck.dart <vm-service-uri> --eval <expression>
///     dart tool/debug_suite/vmcheck.dart <vm-service-uri> --dump-app
///     dart tool/debug_suite/vmcheck.dart <vm-service-uri> --pause-state
///
/// The first form prints one `PASS <id> <detail>` or `FAIL <id> <detail>` line
/// per check, in the format `verdict.dart` reads. A VM Service error fails its
/// check and the run goes on: one broken call must not hide the others.
/// `--eval` prints `VALUE <value>` for an expression in the root library, and
/// `--dump-app` prints the widget tree `ext.flutter.debugDumpApp` returns, and
/// `--pause-state` prints `PAUSE <kind>` for the main isolate's pause event.
library;

import 'dart:async';
import 'dart:io';

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

/// The WebSocket form of a VM Service URI as `run` prints it.
String webSocketUri(String uri) {
  final Uri parsed = Uri.parse(uri);
  if (parsed.scheme == 'ws') {
    return uri;
  }
  final String path = parsed.path.endsWith('/') ? parsed.path : '${parsed.path}/';
  return parsed.replace(scheme: 'ws', path: '${path}ws').toString();
}

void _report(bool passed, String id, String detail) {
  stdout.writeln('${passed ? 'PASS' : 'FAIL'} $id $detail');
}

/// Runs [body] as check [id]; an exception or a timeout fails the check.
Future<T?> _check<T>(String id, Future<T> Function() body, String Function(T) describe) async {
  try {
    final T value = await body().timeout(const Duration(seconds: 30));
    _report(true, id, describe(value));
    return value;
  } on Object catch (error) {
    _report(false, id, error.toString().split('\n').first);
    return null;
  }
}

Future<IsolateRef> _mainIsolate(VmService service) async {
  final VM vm = await service.getVM();
  final List<IsolateRef> isolates = vm.isolates ?? <IsolateRef>[];
  return isolates.firstWhere((IsolateRef r) => r.name == 'main', orElse: () => isolates.first);
}

Future<void> _evaluate(VmService service, String expression) async {
  final IsolateRef isolate = await _mainIsolate(service);
  final Isolate full = await service.getIsolate(isolate.id!);
  final Response value = await service.evaluate(isolate.id!, full.rootLib!.id!, expression);
  stdout.writeln('VALUE ${value is InstanceRef ? value.valueAsString : value}');
}

Future<void> _dumpApp(VmService service) async {
  final IsolateRef isolate = await _mainIsolate(service);
  final Response response = await service.callServiceExtension(
    'ext.flutter.debugDumpApp',
    isolateId: isolate.id,
  );
  stdout.writeln(response.json?['data'] ?? response.json);
}

Future<void> _pauseState(VmService service) async {
  final IsolateRef isolate = await _mainIsolate(service);
  final Isolate full = await service.getIsolate(isolate.id!);
  stdout.writeln('PAUSE ${full.pauseEvent?.kind}');
}

Future<void> _checkAll(VmService service, String scriptUri, int line) async {
  final VM? vm = await _check(
    'vm.get_vm',
    service.getVM,
    (VM vm) => 'os=${vm.operatingSystem} isolates=${vm.isolates?.length}',
  );
  if (vm == null) {
    return;
  }
  final IsolateRef isolateRef = await _mainIsolate(service);
  final String id = isolateRef.id!;
  final Isolate? isolate = await _check(
    'vm.get_isolate',
    () => service.getIsolate(id),
    (Isolate i) => 'name=${i.name} rootLib=${i.rootLib?.uri}',
  );
  if (isolate == null) {
    return;
  }
  final String rootLib = isolate.rootLib!.id!;

  await _check('vm.evaluate', () async {
    final Response sum = await service.evaluate(id, rootLib, '1 + 2');
    final Response set = await service.evaluate(id, rootLib, 'marker = "set-by-vmcheck"');
    final String? sumValue = (sum as InstanceRef).valueAsString;
    final String? setValue = (set as InstanceRef).valueAsString;
    if (sumValue != '3' || setValue != 'set-by-vmcheck') {
      throw StateError('1 + 2 = $sumValue, assignment = $setValue');
    }
    return sumValue;
  }, (String? v) => '1 + 2 = $v');

  await service.streamListen(EventStreams.kDebug);
  final Breakpoint? breakpoint = await _check('vm.breakpoint', () async {
    final hit = Completer<Event>();
    final StreamSubscription<Event> subscription = service.onDebugEvent.listen((Event e) {
      if (e.kind == EventKind.kPauseBreakpoint && !hit.isCompleted) {
        hit.complete(e);
      }
    });
    try {
      final Breakpoint bp = await service.addBreakpointWithScriptUri(id, scriptUri, line);
      await hit.future.timeout(const Duration(seconds: 5));
      return bp;
    } finally {
      await subscription.cancel();
    }
  }, (Breakpoint bp) => '$scriptUri:$line hit');
  if (breakpoint != null) {
    await _check('vm.evaluate_in_frame', () async {
      final Response value = await service.evaluateInFrame(id, 0, 'beats');
      return (value as InstanceRef).valueAsString;
    }, (String? v) => 'beats=$v');
    await service.removeBreakpoint(id, breakpoint.id!);
    await service.resume(id);
  } else {
    _report(false, 'vm.evaluate_in_frame', 'no breakpoint hit');
  }

  await _check(
    'vm.memory_usage',
    () => service.getMemoryUsage(id),
    (MemoryUsage m) => 'heapUsage=${m.heapUsage}',
  );
  await _check(
    'vm.allocation_profile',
    () => service.getAllocationProfile(id, gc: true),
    (AllocationProfile p) => 'classes=${p.members?.length}',
  );
  await _check(
    'vm.heap_snapshot',
    () => HeapSnapshotGraph.getSnapshot(service, isolate),
    (HeapSnapshotGraph g) => 'objects=${g.objects.length}',
  );

  final FlagList flags = await service.getFlagList();
  final String profiler =
      flags.flags?.firstWhere((Flag f) => f.name == 'profiler', orElse: Flag.new).valueAsString ??
      '<absent>';
  _report(profiler == 'true', 'vm.profiler_flag', 'profiler=$profiler');

  await _check('vm.cpu_samples', () async {
    final Timestamp start = await service.getVMTimelineMicros();
    await Future<void>.delayed(const Duration(seconds: 3));
    final Timestamp end = await service.getVMTimelineMicros();
    final CpuSamples samples = await service.getCpuSamples(
      id,
      start.timestamp!,
      end.timestamp! - start.timestamp!,
    );
    if ((samples.sampleCount ?? 0) == 0) {
      throw StateError('sampleCount=0');
    }
    return samples.sampleCount!;
  }, (int count) => 'sampleCount=$count');

  await service.setVMTimelineFlags(<String>['Dart', 'Embedder', 'GC']);
  await service.clearVMTimeline();
  await service.streamListen(EventStreams.kExtension);
  var frames = 0;
  final StreamSubscription<Event> frameEvents = service.onExtensionEvent.listen((Event e) {
    if (e.extensionKind == 'Flutter.Frame') {
      frames++;
    }
  });
  await Future<void>.delayed(const Duration(seconds: 3));
  await frameEvents.cancel();
  _report(frames > 0, 'vm.flutter_frame_events', 'Flutter.Frame events=$frames');
  await _check('vm.timeline_frames', () async {
    final Timeline timeline = await service.getVMTimeline();
    final names = <String>{
      for (final TimelineEvent event in timeline.traceEvents ?? <TimelineEvent>[])
        if (event.json?['name'] case final String name) name,
    };
    final List<String> missing = <String>[
      'Animator::BeginFrame',
      'GPURasterizer::Draw',
    ].where((String n) => !names.contains(n)).toList();
    if (missing.isNotEmpty) {
      throw StateError('missing ${missing.join(', ')}');
    }
    return names.length;
  }, (int n) => 'event names=$n');
  await service.setVMTimelineFlags(<String>[]);
}

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln(
      'usage: dart vmcheck.dart <uri> '
      '(<script-uri> <line> | --eval <expr> | --dump-app | --pause-state)',
    );
    exitCode = 2;
    return;
  }
  final VmService service;
  try {
    service = await vmServiceConnectUri(webSocketUri(args[0]));
  } on Object catch (error) {
    _report(false, 'vm.connect', error.toString().split('\n').first);
    exitCode = 1;
    return;
  }
  try {
    if (args[1] == '--eval') {
      await _evaluate(service, args[2]);
    } else if (args[1] == '--dump-app') {
      await _dumpApp(service);
    } else if (args[1] == '--pause-state') {
      await _pauseState(service);
    } else {
      await _checkAll(service, args[1], int.parse(args[2]));
    }
  } finally {
    await service.dispose();
  }
}
