// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

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
