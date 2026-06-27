// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_watchos/flutter_watchos.dart';

void main() => runApp(const FlutterWatchosExampleApp());

class FlutterWatchosExampleApp extends StatelessWidget {
  const FlutterWatchosExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Force a dark theme so text/buttons stay readable on the black watch
    // background — the default light text theme renders dark-on-black.
    return const MaterialApp(
      home: HomeScreen(),
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // A compact, scrollable layout — sized for the watch screen.
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        // WatchCrownScroll adds the native end-of-content bump haptic; the crown
        // scroll motion/acceleration/ticks come from the watchOS host.
        child: WatchCrownScroll(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            children: [
              const Text(
                'flutter_watchos',
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: Colors.white),
              ),
              const SizedBox(height: 8),
              _Row('isWatch', '${FlutterWatchosPlatform.isWatch}'),
              _Row('Platform.isIOS', '${FlutterWatchosPlatform.isAppleMobile}'),
              _Row('isWatchOS', '${WatchOSInfo.isWatchOS}'),
              _Row('version', WatchOSInfo.watchOSVersion),
              _Row('model', WatchOSInfo.deviceModel),
              _Row('machine', WatchOSInfo.machineId),
              _Row('simulator', '${WatchOSInfo.isSimulator}'),
              _Row('screen', WatchOSInfo.screenResolution),
              _Row('scale', '${WatchOSInfo.screenScale}x'),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const CrownDemoScreen(),
                    ),
                  ),
                  child: const Text('crown demo →'),
                ),
              ),
              for (final type in WatchHapticType.values)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: ElevatedButton(
                    onPressed: () => WatchHaptics.play(type),
                    child: Text('haptic: ${type.name}'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Demonstrates raw Digital Crown input via [WatchCrown]: the crown drives a
/// 0–100 value directly (it does not scroll), with a tick at each end.
class CrownDemoScreen extends StatefulWidget {
  const CrownDemoScreen({super.key});

  @override
  State<CrownDemoScreen> createState() => _CrownDemoScreenState();
}

class _CrownDemoScreenState extends State<CrownDemoScreen> {
  static const double _sensitivity = 6.0; // crown units → value units
  double _value = 50;
  StreamSubscription<CrownRotationEvent>? _sub;

  @override
  void initState() {
    super.initState();
    // Subscribing switches the crown into raw mode; cancelling (in dispose)
    // hands it back to scroll for the rest of the app.
    _sub = WatchCrown.instance.rotations.listen(_onRotate);
  }

  void _onRotate(CrownRotationEvent e) {
    final double next = (_value + e.delta * _sensitivity).clamp(0.0, 100.0);
    if (next == _value) return;
    if ((next == 0.0 || next == 100.0) && next != _value) {
      WatchHaptics.play(WatchHapticType.stop); // hit an end
    }
    setState(() => _value = next);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('Turn the crown',
                      style: TextStyle(color: Colors.white70, fontSize: 13)),
                  const SizedBox(height: 8),
                  Text(
                    _value.toStringAsFixed(0),
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 48,
                        fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: 140,
                    child: LinearProgressIndicator(
                      value: _value / 100,
                      backgroundColor: Colors.white24,
                      color: Colors.lightBlueAccent,
                    ),
                  ),
                ],
              ),
            ),
            // The watch host has no native swipe-back, so provide one.
            Align(
              alignment: Alignment.topLeft,
              child: IconButton(
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.chevron_left,
                    color: Colors.white, size: 28),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: const TextStyle(color: Colors.white70, fontSize: 12)),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}
