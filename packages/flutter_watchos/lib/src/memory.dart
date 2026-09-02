// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'watchos_ffi_bindings.dart';
import 'watchos_info_platform.dart' as platform;

/// What watchOS thinks your app is using, and how much room is left.
///
/// watchOS enforces a hard per-process memory limit and kills the app with a
/// bare `SIGKILL` the moment it is crossed — no exception, no crash dialog,
/// and often no report on the device either.
///
/// Dart's `ProcessInfo.currentRss` will not warn you, because it does not
/// count memory the GPU driver holds on the process's behalf while the kernel
/// does. A measured run read 111 MB of RSS at the moment jetsam killed the
/// same process for reaching 302.4 MB. [footprint] is the figure jetsam
/// actually compares against the limit.
///
/// ```dart
/// final mb = WatchMemory.footprint / (1024 * 1024);
/// final headroom = WatchMemory.available / (1024 * 1024);
/// debugPrint('using ${mb.toStringAsFixed(1)}MB, '
///     '${headroom.toStringAsFixed(1)}MB before the limit');
/// ```
///
/// Both readings are cheap enough to poll from a debug overlay.
abstract final class WatchMemory {
  static WatchOSNativeBindings? _bindings;

  static WatchOSNativeBindings get _native {
    if (_bindings == null) {
      if (platform.isWatch) {
        _bindings = WatchOSNativeBindings();
      } else {
        _bindings = WatchOSNativeBindings.forTesting();
      }
    }
    return _bindings!;
  }

  /// Bytes the process may still allocate before watchOS kills it.
  ///
  /// Returns 0 where the platform cannot answer — off-device, on the
  /// Simulator (which has no jetsam limit to report against), and on watchOS
  /// older than 6.0. Check [availableIsSupported] to tell "no headroom left"
  /// apart from "no answer available".
  static int get available {
    if (!platform.isWatch) return 0;
    return _native.availableMemory();
  }

  /// Whether [available] reports a real figure on this device.
  ///
  /// False on the Simulator and off-device, where a zero from [available]
  /// means "unknown" rather than "out of memory".
  static bool get availableIsSupported {
    if (!platform.isWatch) return false;
    return _native.availableMemorySupported();
  }

  /// The process's resident footprint in bytes, as the kernel accounts it.
  ///
  /// This is `phys_footprint`: it includes GPU and IOKit memory charged to
  /// the process, which `ProcessInfo.currentRss` omits. Unlike [available] it
  /// is readable on the Simulator too, though the limit it would be judged
  /// against only exists on a real watch.
  ///
  /// Returns 0 if the kernel call fails.
  static int get footprint {
    if (!platform.isWatch) return 0;
    return _native.memoryFootprint();
  }
}
