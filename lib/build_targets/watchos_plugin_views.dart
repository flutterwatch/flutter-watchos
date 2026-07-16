// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// Support for plugins that ship native SwiftUI platform views.
///
/// A federated watchOS plugin may place `.swift` sources anywhere under its
/// `watchos/` directory (conventionally `watchos/Views/`) next to its FFI
/// classes — no pubspec keys, discovery is by shape, exactly like the `.m`
/// sources. The CLI compiles them per plugin into the same force-loaded
/// static archive as the ObjC/C sources, together with [kPluginViewSupportSwift]
/// (the registration shim below), so plugin code can call:
///
/// ```swift
/// FlutterWatchOSPluginViews.register("my-view") { params in
///     AnyView(MyNativeView(params: params))
/// }
/// ```
///
/// from a C-callable entry point (typically `@_cdecl("<name>_register_views")`,
/// listed under `ffiSymbols` and invoked by the plugin's Dart `registerWith()`),
/// and the app's `WatchPlatformView(viewType: 'my-view')` renders it.
///
/// The shim reaches the app runner's registration entry point
/// (`FlutterWatchOSPlatformViewRegisterNativeFactory`, an `@_cdecl` in the
/// generated `FlutterRunner.swift`) via `dlsym`, never a compile-time import,
/// so the plugin still links inside an app created by an older CLI — its
/// views simply don't appear there, matching `WatchPlatformView.isSupported`
/// semantics.
library;

import 'package:flutter_tools/src/base/file_system.dart';

/// Collects a plugin's SwiftUI view sources: every `.swift` under the
/// plugin's `watchos/` directory ([pluginDir]) except the SwiftPM manifest
/// and anything the CLI itself generates (`Flutter/`, dot-directories such as
/// SwiftPM's `.build/`).
List<String> collectPluginSwiftViewSources(Directory pluginDir) {
  if (!pluginDir.existsSync()) {
    return <String>[];
  }
  final String root = pluginDir.path;
  final sources = <String>[];
  for (final FileSystemEntity entity in pluginDir.listSync(recursive: true)) {
    if (entity is! File) {
      continue;
    }
    if (!entity.path.endsWith('.swift') || entity.basename == 'Package.swift') {
      continue;
    }
    final String relative = entity.path.substring(root.length);
    final List<String> segments = relative
        .split(pluginDir.fileSystem.path.separator)
        .where((String s) => s.isNotEmpty)
        .toList();
    // CLI build output lands under `Flutter/`; SwiftPM/tooling state lives in
    // dot-directories. Neither is plugin view source.
    final bool generated = segments.any(
      (String s) => s == 'Flutter' || s.startsWith('.'),
    );
    if (generated) {
      continue;
    }
    sources.add(entity.path);
  }
  sources.sort();
  return sources;
}

/// The registration shim compiled into every plugin Swift module (each plugin
/// with view sources is compiled as its own module, so these private
/// declarations never collide across plugins).
const String kPluginViewSupportSwift = r'''
// Compiled by flutter-watchos into every plugin module that ships SwiftUI
// view sources. Not part of the plugin — do not copy it into one.
//
// Gives plugin code `FlutterWatchOSPluginViews.register(_:factory:)`, the
// Swift face of the app runner's C registration entry point.

import Darwin
import Foundation
import SwiftUI

private let _factoriesLock = NSLock()
private var _factories: [String: (String) -> AnyView] = [:]

/// The @convention(c) trampoline handed to the runner, once per registered
/// type. Receives (viewType, creationParams); returns the built AnyView
/// RETAINED, boxed by the Swift runtime (`as AnyObject` — SwiftUI hard-rejects
/// class-conforming Views, so the view itself must stay a struct and the
/// runtime box is the only class in the crossing). The runner unwraps it with
/// a plain dynamic cast, since AnyView is SwiftUI's own type on both sides.
/// nil means no factory — render nothing.
private let _factoryTrampoline: @convention(c) (
    UnsafePointer<CChar>?, UnsafePointer<CChar>?
) -> UnsafeMutableRawPointer? = { type, params in
    guard let type else { return nil }
    let viewType = String(cString: type)
    let creationParams = params.map { String(cString: $0) } ?? ""
    _factoriesLock.lock()
    let factory = _factories[viewType]
    _factoriesLock.unlock()
    guard let factory else { return nil }
    return Unmanaged.passRetained(factory(creationParams) as AnyObject).toOpaque()
}

/// Registration surface for a plugin's native SwiftUI views.
public enum FlutterWatchOSPluginViews {
    private typealias _Register = @convention(c) (
        UnsafePointer<CChar>?,
        (@convention(c) (
            UnsafePointer<CChar>?, UnsafePointer<CChar>?
        ) -> UnsafeMutableRawPointer?)?
    ) -> Void

    /// The runner's registration entry point, resolved via dlsym
    /// (RTLD_DEFAULT is the special -2 handle) so nothing links against the
    /// app at compile time. nil when the app was created by a CLI that
    /// predates plugin platform views.
    private static let _register: _Register? = {
        guard let sym = dlsym(
            UnsafeMutableRawPointer(bitPattern: -2),
            "FlutterWatchOSPlatformViewRegisterNativeFactory")
        else { return nil }
        return unsafeBitCast(sym, to: _Register.self)
    }()

    /// Registers (or replaces) the native factory for `viewType`. The factory
    /// receives the Dart widget's `creationParams` string and always runs on
    /// the main thread; `register` itself may be called from any thread
    /// (plugin registration typically arrives over FFI from Dart).
    public static func register(
        _ viewType: String, factory: @escaping (String) -> AnyView
    ) {
        _factoriesLock.lock()
        _factories[viewType] = factory
        _factoriesLock.unlock()
        guard let register = _register else {
            NSLog("FlutterWatchOSPluginViews: this app's runner predates "
                + "plugin platform views; '\(viewType)' will not render. "
                + "Re-create the app with a current flutter-watchos.")
            return
        }
        viewType.withCString { register($0, _factoryTrampoline) }
    }
}
''';
