// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_watchos/commands/login.dart';

import '../src/common.dart';
import '../src/context.dart';

void main() {
  // `--help` is the first thing a new user reads. It used to say an account
  // was "required to download engine artifacts", which is not true of the
  // Simulator engine.
  testUsingContext('login says what an account is for, and that the Simulator needs none', () {
    final String description = WatchosLoginCommand().description;
    expect(description, contains('physical watch'));
    expect(description, contains('the Simulator needs none'));
    expect(description, isNot(contains('required')));
  });
}
