# Porting a plugin to watchOS

`flutter-watchos plugin port` scaffolds a federated `*_watchos` **FFI**
package from an existing iOS or macOS plugin. It is a scaffolder, not a
code translator: the output builds and links on a watch immediately, and a
generated `PORTING_REPORT.md` tells you which of the source plugin's APIs
exist on watchOS so you know what to implement — and what to leave out.

```sh
# From pub.dev (port the Apple implementation package of a federated plugin):
flutter-watchos plugin port --from-pub url_launcher_ios

# From a git repository:
flutter-watchos plugin port --from-git https://github.com/foo/bar.git --ref v2.1.0

# From a local checkout:
flutter-watchos plugin port path/to/plugin_ios
```

## Why the output is FFI

Method-channel plugins are not supported on watchOS — a package whose
`watchos:` block declares only `pluginClass:` builds, but every channel
call throws `MissingPluginException` at runtime (`build`/`run` warn about
this). The supported model is **dart:ffi**: the plugin exports C symbols
from `watchos/Classes/`, the CLI compiles and statically links them into
the watch binary, and Dart resolves them with `DynamicLibrary.process()`.

The porter therefore does **not** copy the source plugin's native code
(it is method-channel code that cannot run on the watch). It emits the FFI
shape directly and analyses the source code for the report instead.

## What gets generated

```
<plugin>_watchos/
├── pubspec.yaml                     # ffiPlugin: true, dartPluginClass, ffiSymbols
├── lib/<plugin>_watchos.dart        # Dart class + FFI bindings (compiles as-is)
├── watchos/
│   ├── Classes/<plugin>_watchos_ffi.h   # C declarations to fill in
│   ├── Classes/<plugin>_watchos_ffi.m   # C implementations to fill in
│   └── Package.swift                # FFI manifest; add .linkedFramework(...) here
├── PORTING_REPORT.md                # API compatibility analysis + checklist
├── README.md
├── CHANGELOG.md
└── LICENSE                          # copied from the source plugin
```

One example symbol (`<plugin>_watchos_example`) is wired end-to-end — C
function, `ffiSymbols` entry, Dart binding — so the package builds, links,
and registers before you have written any real code. Replace it with your
real functions.

The Dart class is deliberately **not** wired to the source plugin's
platform interface: interface class names cannot be reliably guessed
(e.g. `sensors_plus` uses `SensorsPlatform`, not `SensorsPlusPlatform`),
and a wrong guess would stop the scaffold from compiling. The exact
`extends` + `registerWith()` wiring is emitted as a ready-to-apply TODO
block above the generated class.

## Options

| Option | Meaning |
|---|---|
| `<source-dir>` | Positional: port a local plugin directory. |
| `--from-pub <package>` | Download the package from pub.dev and port it. |
| `--from-git <url>` | Shallow-clone a git repository and port it. |
| `--ref <ref>` | Branch/tag/sha to check out (with `--from-git` only). |
| `-o, --output <dir>` | Where to write the package. Defaults to `<plugin>_watchos` next to the source (or in the current directory for pub/git sources). |
| `--base-platform ios\|macos` | Which platform implementation to model the port on. Default `ios`. |
| `--license-holder <name>` | Copyright holder line in generated files. |
| `--force` | Overwrite an existing output directory. |
| `--dry-run` | Print what would be written, write nothing. |
| `--no-report` | Skip `PORTING_REPORT.md`. |

## Reading the report

`PORTING_REPORT.md` lists every API from the compatibility database that
the source plugin's native code uses, split into:

- **Not available on watchOS** — no watchOS equivalent exists (WebKit,
  UIKit view controllers, CoreTelephony, …). The capability must be
  omitted or redesigned, often by delegating to the paired iPhone.
- **Available, but review** — the API exists on watchOS but differs
  (different framework, later minimum version, watch-specific behaviour).
  Implement it, checking the note.

Version notes use watchOS availability: pre-26 SDKs, an API introduced in
iOS *N* generally lands in watchOS *N − 7* (iOS 13 → watchOS 6); from
version 26 Apple unified the numbers. watchOS availability is much wider
than tvOS's — CoreLocation, HealthKit, CoreMotion, StoreKit purchasing,
and (watchOS 9+) LocalAuthentication all exist on the watch.

## Finishing a port

1. Declare your C functions in `watchos/Classes/<plugin>_watchos_ffi.h`
   and implement them in the `.m` — one per platform-interface method you
   support. Mark each `__attribute__((visibility("default"))) __attribute__((used))`
   (the generated example shows the pattern).
2. List every exported symbol under `ffiSymbols:` in `pubspec.yaml`, and
   every framework you link in `Package.swift`.
3. Apply the TODO block in `lib/<plugin>_watchos.dart`: import the
   platform interface, `extends` it, and set `instance` in
   `registerWith()`. Add a `lookupFunction` binding per symbol.
4. Verify on a watch: add the package to an app
   (`flutter-watchos create` one if needed), build for `watchsimulator`,
   and `nm` the binary to confirm your symbols are present (type `T`).
   Then run it — the implementation registers automatically via
   `dart_plugin_registrant`.

Worked examples of this exact shape live in the
[flutterwatch/plugins](https://github.com/flutterwatch/plugins) repo
(`path_provider_watchos` is the reference; see its `AUTHORING.md` for the
full recipe, including testing patterns).
