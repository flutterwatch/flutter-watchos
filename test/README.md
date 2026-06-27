# flutter-watchos Tests

Unit tests for the flutter-watchos CLI tool. Structure and harness mirror the
sibling flutter-tvos test suite.

## Structure

```
test/
├── src/               # Re-exports of Flutter's own test infrastructure
│   ├── common.dart            # testWithoutContext, expect, matchers, expectToolExitLater
│   ├── context.dart           # testUsingContext, Generator overrides
│   ├── fakes.dart             # FakeOperatingSystemUtils, …
│   ├── fake_process_manager.dart
│   └── fake_devices.dart
└── general/           # One file per lib area
    ├── watchos_aot_snapshot_test.dart      # NativeWatchosBundle.watchosGenSnapshotArgs
    ├── watchos_artifacts_test.dart         # mode→engine dir + patched-SDK (AOT identity) override
    ├── watchos_emulator_test.dart          # simctl sim listing + devicectl physical parsing
    ├── watchos_linked_frameworks_test.dart # Package.swift .linkedFramework parsing
    └── watchos_upgrade_test.dart           # release-tag selection + git upgrade safety
```

## Running

```bash
# All CLI tests
flutter/bin/dart test test/general/

# A single file
flutter/bin/dart test test/general/watchos_upgrade_test.dart
```

The bundled `flutter_watchos` package has its own tests:

```bash
cd packages/flutter_watchos && ../../flutter/bin/flutter test
```

## Launch-flow smoke test (needs a watchOS simulator)

The unit suite covers the extractable logic but deliberately does **not** mock
the launch orchestration (`_startAppOnSimulator`: a timing-sensitive
boot → install → terminate → await-log-stream-ready → launch flow). That path is
verified end-to-end against a real simulator instead:

```bash
tool/smoke_test.sh                 # auto-picks the first available watchOS sim
tool/smoke_test.sh <SIM_UDID>      # or target a specific one
```

It builds + runs the example and asserts the Dart VM Service comes up; exit 0 =
the app launched. Keep it out of `dart test` runs — it's an integration check,
run it manually or in a sim-equipped CI job.

## Conventions

- `testWithoutContext` for pure functions; `testUsingContext` (with
  `overrides`) for code that reads `globals` (Logger, ProcessManager).
- `FakeProcessManager` scripts exact command lines; assert
  `hasNoRemainingExpectations` so an unexpected/ missing command fails the test.
- Imports use `package:flutter_watchos/...` (the CLI's own package name) and
  `../src/common.dart` for the test harness.
