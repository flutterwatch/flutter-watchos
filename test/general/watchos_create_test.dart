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

  // Stock create ends with "$ flutter run", which does not run the watch app
  // (and is not even installed when flutter-watchos is the only Flutter).
  group('watchosCreateNextSteps', () {
    testWithoutContext('says flutter-watchos run, after a cd into the project', () {
      final String steps = watchosCreateNextSteps('hello_watch', afterStockCreate: false);
      expect(steps, contains('  \$ cd hello_watch\n  \$ flutter-watchos run'));
      expect(steps, contains('flutter-watchos devices'));
      expect(steps, isNot(contains('flutter run')));
    });

    testWithoutContext('after stock create, says the flutter run above is not for the watch', () {
      final String steps = watchosCreateNextSteps('hello_watch', afterStockCreate: true);
      expect(steps, contains('The `flutter run` above runs the app on the other platforms.'));
      expect(steps, contains(r'$ flutter-watchos run'));
    });

    testWithoutContext('no cd when the project is the current directory', () {
      expect(watchosCreateNextSteps('.', afterStockCreate: false), isNot(contains(r'$ cd')));
    });
  });
}
