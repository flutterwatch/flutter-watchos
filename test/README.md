# flutter-watchos Tests

Unit tests for the flutter-watchos CLI tool. They are hermetic: fake
processes, memory file systems and fake platforms, no network, no simulator,
nothing read from `~/.flutter-watchos/`.

## Structure

```
test/
├── README.md
├── data/                  # Checked-in inputs the tests read
│   ├── artifact_api_contract.json   # what the artifact service answers per engine zip
│   └── forbidden_words_allow.txt    # allow-list of the public-text word rule
├── fixtures/              # Checked-in reference values
│   └── watch_corner_radii.json      # each watch screen size's corner radius, in points
├── src/                   # Shared test helpers
│   ├── common.dart                  # re-export: testWithoutContext, expect, matchers, expectToolExitLater
│   ├── context.dart                 # re-export: testUsingContext, Generator overrides
│   ├── fake_devices.dart            # re-export
│   ├── fake_http_client.dart        # re-export
│   ├── fake_process_manager.dart    # re-export
│   ├── fakes.dart                   # re-export: FakeOperatingSystemUtils, …
│   ├── test_flutter_command_runner.dart  # re-export: createTestCommandRunner
│   ├── forbidden_words.dart         # the word rule for public text, and its allow-list
│   └── host_sources.dart            # cliRootPath, readHostSource, readRunnerTemplate
├── commands.shard/
│   └── hermetic/          # One file per command, run through the command runner
└── general/               # One file per lib area
    │  Engine download, access and account
    ├── watchos_artifact_api_contract_test.dart  # the CLI against data/artifact_api_contract.json
    ├── watchos_artifacts_test.dart         # engine root, engine dir per build mode, patched-SDK override
    ├── watchos_auth_test.dart              # API base, credentials file, token revoke, logout text
    ├── watchos_build_registry_test.dart    # release-build registration, notice, settings
    ├── watchos_cache_update_test.dart      # the engine download with a fake curl and unzip
    ├── watchos_login_test.dart             # login failure messages
    ├── watchos_precache_test.dart          # artifact selection, pending zips, stamps, gates
    │  Build
    ├── watchos_aot_snapshot_test.dart      # gen_snapshot arguments
    ├── watchos_app_bundle_test.dart        # flutter_assets copy, JIT core snapshots
    ├── watchos_build_hooks_test.dart       # native-asset build hooks
    ├── watchos_build_info_test.dart        # SDK name and destination per target
    ├── watchos_kernel_snapshot_test.dart   # kernel compile for AOT modes
    ├── watchos_linked_frameworks_test.dart # Package.swift .linkedFramework parsing
    ├── watchos_native_link_test.dart       # host archive and plugin link flags
    ├── watchos_platform_args_test.dart     # watchOS platform argument expansion
    ├── watchos_shader_target_test.dart     # shader backends in a bundle
    ├── watchos_signing_test.dart           # development team and keychain lookup
    │  Host module, runner and templates
    ├── watchos_accessibility_test.dart     # accessibility C ABI and host mirror
    ├── watchos_content_scale_test.dart     # FlutterWatchOSContentScale
    ├── watchos_crown_proxy_test.dart       # native crown scrolling: host scroll view, runtime
    ├── watchos_host_mode_test.dart         # companion and standalone project wiring
    ├── watchos_host_module_test.dart       # host module sources and swiftc arguments
    ├── watchos_package_web_safety_test.dart # the flutter_watchos package on the Web
    ├── watchos_pbxproj_template_test.dart  # project.pbxproj template substitutions
    ├── watchos_platform_views_test.dart    # platform views C ABI, runner and overlay
    ├── watchos_plugin_views_test.dart      # plugin Swift views and registration
    ├── watchos_runner_test.dart            # the generated Runner and App.swift
    ├── watchos_safe_area_test.dart         # safe-area modes, corner insets, clock band
    ├── watchos_text_input_test.dart        # engine bootstrap, Digital Crown, text input
    │  Devices, run and debug
    ├── watchos_application_package_test.dart # WatchosApp from a project
    ├── watchos_dds_test.dart               # Dart Development Service binding
    ├── watchos_device_discovery_test.dart  # device discovery
    ├── watchos_device_install_test.dart    # install and uninstall, Simulator and watch
    ├── watchos_device_test.dart            # launch arguments, log readers, startApp
    ├── watchos_emulator_test.dart          # simctl and devicectl parsing
    ├── watchos_physical_device_test.dart   # physical watch properties and logs
    ├── watchos_vm_relay_test.dart          # the VM Service relay for a watch
    │  Plugins and plugin porting
    ├── plugin_port_compat_db_test.dart     # compatibility database, watchOS versions
    ├── plugin_port_e2e_test.dart           # port end to end, FFI scaffold, report
    ├── plugin_port_example_test.dart       # ported example pubspec
    ├── plugin_port_fetch_test.dart         # source specs and fetching
    ├── plugin_port_objc_test.dart          # Objective-C port
    ├── plugin_port_swift_test.dart         # Swift port
    ├── plugin_port_test.dart               # source analysis and scaffolding
    ├── watchos_plugins_test.dart           # plugin detection and recommendations
    │  Commands, doctor and repository checks
    ├── watchos_create_stock_app_test.dart  # a watch-only create writes stock's app
    ├── watchos_create_test.dart            # create template errors and next steps
    ├── watchos_doctor_test.dart            # doctor validators
    ├── watchos_public_text_test.dart       # the word rule on .github/ and test names
    ├── watchos_upgrade_test.dart           # release-tag selection and git upgrade safety
    └── watchos_version_fields_test.dart    # version fields that must agree
```

## Running

CI runs both suites with a 2 s limit per test. Run them the same way:

```bash
flutter/bin/dart test --timeout 2s test/general
flutter/bin/dart test --timeout 2s test/commands.shard/hermetic
```

A single file:

```bash
flutter/bin/dart test test/general/watchos_upgrade_test.dart
```

The bundled `flutter_watchos` package and its example have their own tests,
which CI runs in its package job:

```bash
cd packages/flutter_watchos && ../../flutter/bin/flutter test
cd packages/flutter_watchos/example && ../../../flutter/bin/flutter test
```

## Launch-flow smoke test (needs a watchOS simulator)

The unit suite covers the extractable logic but deliberately does **not** mock
the launch orchestration (`_startAppOnSimulator`: a timing-sensitive
boot → install → terminate → await-log-stream-ready → launch flow). That path is
verified end-to-end against a real simulator instead:

```bash
tool/smoke_test.sh
```

With no argument it picks the first available watchOS simulator; give a UDID
to pick one:

```bash
tool/smoke_test.sh <SIM_UDID>
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
- A test that waits on a timer runs under `FakeAsync`, so no test needs more
  than 2 s.
- Test and group names are public text: CI prints them. They follow the word
  rule in `src/forbidden_words.dart`, which `watchos_public_text_test.dart`
  checks; its allow-list never applies to names.
