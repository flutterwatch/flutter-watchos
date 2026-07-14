// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_watchos/commands/create.dart';

import '../src/common.dart';

void main() {
  group('watchosCreateTemplateError', () {
    testWithoutContext('accepts the non-plugin templates', () {
      expect(watchosCreateTemplateError('app'), isNull);
      expect(watchosCreateTemplateError('module'), isNull);
      expect(watchosCreateTemplateError('package'), isNull);
      expect(watchosCreateTemplateError('skeleton'), isNull);
    });

    testWithoutContext('rejects --template=plugin with FFI guidance', () {
      final String? message = watchosCreateTemplateError('plugin');

      expect(message, isNotNull);
      expect(message, contains('--template=plugin'));
      expect(message, contains('flutter-watchos plugin port'));
      expect(message, contains('AUTHORING.md'));
      // The rejected model must be named so users don't hand-write a
      // pluginClass-only declaration instead.
      expect(message, contains('method-channel plugins are not supported'));
    });

    testWithoutContext('rejects --template=plugin_ffi too', () {
      final String? message = watchosCreateTemplateError('plugin_ffi');

      expect(message, isNotNull);
      expect(message, contains('--template=plugin_ffi'));
      expect(message, contains('flutter-watchos plugin port'));
    });
  });
}
