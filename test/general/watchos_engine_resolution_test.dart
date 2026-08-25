// Copyright 2026 The FlutterWatch Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_watchos/watchos_cache.dart';

import '../src/common.dart';

// The CLI asks the service which engine a Flutter version uses, so that a
// framework-only release can reuse an engine instead of forcing a rebuild and
// a fresh 75 MB upload of the same bytes.
//
// Every case that is not a well-formed answer has to degrade to the pinned tag
// in bin/internal/engine.version, because that pin is a complete answer on its
// own. A user who is offline, self-hosting, or on a Flutter version nobody has
// mapped yet must not notice this feature exists.
void main() {
  group('engineTagFromResponse', () {
    test('takes the engine id from a well-formed answer', () {
      expect(
        engineTagFromResponse(200, '{"engine_id":"e76856972325c","status":"current"}'),
        equals('e76856972325c'),
      );
    });

    test('accepts a legacy release tag, which is still a valid prefix', () {
      expect(
        engineTagFromResponse(200, '{"engine_id":"v0.1.8-flutter3.47.1"}'),
        equals('v0.1.8-flutter3.47.1'),
      );
    });

    test('falls back when the version is not mapped', () {
      expect(engineTagFromResponse(404, '{"error":"no_mapping"}'), isNull);
    });

    test('falls back on a server error', () {
      expect(engineTagFromResponse(500, 'upstream exploded'), isNull);
    });

    test('falls back when the body is not JSON', () {
      expect(engineTagFromResponse(200, '<html>a proxy login page</html>'), isNull);
    });

    test('falls back when the body is JSON but not an object', () {
      expect(engineTagFromResponse(200, '["e76856972325c"]'), isNull);
    });

    test('falls back when engine_id is absent', () {
      expect(engineTagFromResponse(200, '{"status":"current"}'), isNull);
    });

    test('falls back when engine_id is not a string', () {
      expect(engineTagFromResponse(200, '{"engine_id":42}'), isNull);
    });

    // The id is interpolated into the download URL as a path segment, and
    // WATCHOS_ARTIFACTS_API can point this CLI at any host — so the shape is
    // checked here rather than trusted from whatever answered.
    test('refuses an id carrying a path separator', () {
      expect(engineTagFromResponse(200, '{"engine_id":"../../etc/passwd"}'), isNull);
      expect(engineTagFromResponse(200, '{"engine_id":"a/b"}'), isNull);
    });

    test('refuses an id that is only dots, which would climb the path', () {
      expect(engineTagFromResponse(200, '{"engine_id":".."}'), isNull);
      expect(engineTagFromResponse(200, '{"engine_id":"."}'), isNull);
    });

    test('refuses an id with a scheme or host in it', () {
      expect(engineTagFromResponse(200, '{"engine_id":"https://evil.test/x"}'), isNull);
    });

    test('refuses an empty id and an over-long one', () {
      expect(engineTagFromResponse(200, '{"engine_id":""}'), isNull);
      expect(engineTagFromResponse(200, '{"engine_id":"${'e' * 101}"}'), isNull);
    });
  });
}
