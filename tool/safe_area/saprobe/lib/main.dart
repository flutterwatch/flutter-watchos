// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Safe-area probe for flutter-watchos, run by tool/safe_area/run_matrix.sh.
//
// Every metrics change prints one SAFEAREA| line with MediaQuery's insets,
// which tool/safe_area/check_insets.sh compares with the fixtures. The page
// is picked at launch by a file the harness writes into the app's data
// container, Documents/saprobe_PAGE.txt:
//   0  measure: screen edge (red), MediaQuery.padding rect (green), values
//   1  ListView inside SafeArea, at rest
//   2  ListView inside SafeArea, scrolled 60
//   3  ListView without SafeArea (ListView pads by MediaQuery itself), at rest
//   4  ListView without SafeArea, scrolled 60
//   5  the upstream `flutter create` counter page (Scaffold + AppBar + FAB)
// Documents/saprobe_DEV.txt names the simulator in the line (dev=). MODE is a
// --dart-define, so each line names the safe-area mode it was built for.
import 'dart:io';

import 'package:flutter/material.dart';

const String kMode = String.fromEnvironment('MODE', defaultValue: 'platform');

// Dart's Platform.environment is empty under this embedder, and simctl's
// SIMCTL_CHILD_* variables do not reach a watch app launched through
// FrontBoard, so the harness passes its settings as files in the app's data
// container: <container>/Documents/saprobe_<KEY>.txt. The container is found
// from systemTemp, which is <container>/tmp.
String _cfg(String key) {
  try {
    final f = File(
      '${Directory.systemTemp.parent.path}/Documents/saprobe_$key.txt',
    );
    if (f.existsSync()) {
      return f.readAsStringSync().trim();
    }
  } on FileSystemException {
    // No file: the default below.
  }
  return '';
}

final int _pageValue = int.tryParse(_cfg('PAGE')) ?? 0;
final String _devValue = _cfg('DEV').isEmpty ? '?' : _cfg('DEV');
int get _page => _pageValue;
String get _dev => _devValue;

String _ei(EdgeInsets e) =>
    'L${e.left.toStringAsFixed(2)},T${e.top.toStringAsFixed(2)},'
    'R${e.right.toStringAsFixed(2)},B${e.bottom.toStringAsFixed(2)}';

void main() {
  runApp(const ProbeApp());
}

class ProbeApp extends StatelessWidget {
  const ProbeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark,
        ),
      ),
      // Material supplies the DefaultTextStyle (no debug underlines).
      home: const MetricsLogger(
        child: Material(color: Colors.black, child: PageSwitch()),
      ),
    );
  }
}

/// Prints one SAFEAREA| line whenever the metrics it sees change.
class MetricsLogger extends StatefulWidget {
  const MetricsLogger({super.key, required this.child});
  final Widget child;
  @override
  State<MetricsLogger> createState() => _MetricsLoggerState();
}

class _MetricsLoggerState extends State<MetricsLogger> {
  String? _last;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final view = View.of(context);
    final line =
        'SAFEAREA|dev=$_dev|mode=$kMode|page=$_page'
        '|size=${mq.size.width.toStringAsFixed(2)}x${mq.size.height.toStringAsFixed(2)}'
        '|dpr=${mq.devicePixelRatio}'
        '|physical=${view.physicalSize.width}x${view.physicalSize.height}'
        '|padding=${_ei(mq.padding)}'
        '|viewPadding=${_ei(mq.viewPadding)}'
        '|viewInsets=${_ei(mq.viewInsets)}'
        '|systemGestureInsets=${_ei(mq.systemGestureInsets)}'
        '|displayFeatures=${mq.displayFeatures}'
        '|textScale=${mq.textScaler.scale(10) / 10}'
        '|display=${view.display.size.width}x${view.display.size.height}@${view.display.devicePixelRatio}';
    if (line != _last) {
      _last = line;
      // ignore: avoid_print
      print(line);
    }
    return widget.child;
  }
}

class PageSwitch extends StatelessWidget {
  const PageSwitch({super.key});
  @override
  Widget build(BuildContext context) {
    switch (_page) {
      case 1:
        return const ListProbe(safe: true, offset: 0);
      case 2:
        return const ListProbe(safe: true, offset: 60);
      case 3:
        return const ListProbe(safe: false, offset: 0);
      case 4:
        return const ListProbe(safe: false, offset: 60);
      case 5:
        return const CounterPage(title: 'Flutter Demo Home Page');
      default:
        return const MeasurePage();
    }
  }
}

class MeasurePage extends StatelessWidget {
  const MeasurePage({super.key});
  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final p = mq.padding;
    return Material(
      color: const Color(0xFF202020),
      child: Stack(
        children: [
          Positioned.fill(child: CustomPaint(painter: _EdgePainter(p))),
          Positioned.fromRect(
            rect: Rect.fromLTRB(
              p.left,
              p.top,
              mq.size.width - p.right,
              mq.size.height - p.bottom,
            ),
            child: Center(
              child: Text(
                '$kMode p$_page\n'
                '${mq.size.width.toStringAsFixed(1)}x${mq.size.height.toStringAsFixed(1)} @${mq.devicePixelRatio}\n'
                'T ${p.top.toStringAsFixed(1)}  B ${p.bottom.toStringAsFixed(1)}\n'
                'L ${p.left.toStringAsFixed(1)}  R ${p.right.toStringAsFixed(1)}',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.white,
                  height: 1.2,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EdgePainter extends CustomPainter {
  _EdgePainter(this.p);
  final EdgeInsets p;
  @override
  void paint(Canvas canvas, Size size) {
    // Screen edge: 2px red just inside the bounds.
    canvas.drawRect(
      (Offset.zero & size).deflate(1),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = const Color(0xFFFF0000),
    );
    // Padding rect: green outline, pale green fill.
    final r = Rect.fromLTRB(
      p.left,
      p.top,
      size.width - p.right,
      size.height - p.bottom,
    );
    canvas.drawRect(r, Paint()..color = const Color(0x3300FF00));
    canvas.drawRect(
      r.deflate(1),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = const Color(0xFF00FF00),
    );
    // Tick marks every 10 logical px along the top edge (white) so the
    // screenshot can be read without the log.
    final tick = Paint()
      ..color = Colors.white
      ..strokeWidth = 1;
    for (double y = 0; y < size.height / 2; y += 10) {
      canvas.drawLine(
        Offset(size.width / 2 - (y % 50 == 0 ? 8 : 4), y),
        Offset(size.width / 2 + (y % 50 == 0 ? 8 : 4), y),
        tick,
      );
    }
  }

  @override
  bool shouldRepaint(_EdgePainter old) => old.p != p;
}

class ListProbe extends StatefulWidget {
  const ListProbe({super.key, required this.safe, required this.offset});
  final bool safe;
  final double offset;
  @override
  State<ListProbe> createState() => _ListProbeState();
}

class _ListProbeState extends State<ListProbe> {
  late final ScrollController _c = ScrollController(
    initialScrollOffset: widget.offset,
  );
  final GlobalKey _first = GlobalKey();
  final GlobalKey _viewport = GlobalKey();

  @override
  void initState() {
    super.initState();
    // Report where row 0 and the viewport ended up, twice (the safe area can
    // land after the first frame).
    for (final ms in [300, 1500]) {
      Future<void>.delayed(Duration(milliseconds: ms), _report);
    }
  }

  void _report() {
    if (!mounted) return;
    String rectOf(GlobalKey k) {
      final ro = k.currentContext?.findRenderObject() as RenderBox?;
      if (ro == null || !ro.attached) return 'offscreen';
      final o = ro.localToGlobal(Offset.zero);
      return '${o.dx.toStringAsFixed(2)},${o.dy.toStringAsFixed(2)} '
          '${ro.size.width.toStringAsFixed(2)}x${ro.size.height.toStringAsFixed(2)}';
    }

    // ignore: avoid_print
    print(
      'SAFEAREA|dev=$_dev|mode=$kMode|page=$_page|list safe=${widget.safe}'
      '|offset=${_c.hasClients ? _c.offset : -1}'
      '|viewport=${rectOf(_viewport)}|row0=${rectOf(_first)}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final list = ListView.builder(
      key: _viewport,
      controller: _c,
      itemCount: 30,
      itemBuilder: (context, i) => Container(
        key: i == 0 ? _first : null,
        height: 40,
        margin: const EdgeInsets.only(bottom: 4),
        color: i == 0
            ? const Color(0xFFE09000)
            : (i.isEven ? const Color(0xFF1E5AA8) : const Color(0xFF16806E)),
        padding: EdgeInsets.zero,
        child: Row(
          children: [
            Text(
              'L$i',
              style: const TextStyle(fontSize: 15, color: Colors.white),
            ),
            const Expanded(
              child: Text(
                'Row text',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: Colors.white),
              ),
            ),
            Text(
              'R$i',
              style: const TextStyle(fontSize: 15, color: Colors.white),
            ),
          ],
        ),
      ),
    );
    // Dark red = screen area the list does not get.
    return ColoredBox(
      color: const Color(0xFF500000),
      child: widget.safe
          ? SafeArea(
              child: ColoredBox(color: Colors.black, child: list),
            )
          : ColoredBox(color: Colors.black, child: list),
    );
  }
}

/// The upstream `flutter create` counter page, as a new app starts out.
class CounterPage extends StatefulWidget {
  const CounterPage({super.key, required this.title});
  final String title;
  @override
  State<CounterPage> createState() => _CounterPageState();
}

class _CounterPageState extends State<CounterPage> {
  int _counter = 0;
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('You have pushed the button this many times:'),
            Text(
              '$_counter',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => setState(() => _counter++),
        tooltip: 'Increment',
        child: const Icon(Icons.add),
      ),
    );
  }
}
