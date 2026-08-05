// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// `FlutterWatchosPlatform` is the guard we tell app authors to write instead of
// `Platform.isIOS`, so it has to compile everywhere a cross-platform app does —
// including Web, where dart:io does not exist. The native branch reads the real
// `Platform`; the Web branch answers `false` for every getter.
//
// Note the asymmetry: only the native branch carries
// `extension FlutterWatchosPlatformExt on Platform`. Extending the dart:io
// `Platform` type is impossible on Web, so that extension is native-only API.
export 'platform_extension_web.dart'
    if (dart.library.io) 'platform_extension_native.dart';
