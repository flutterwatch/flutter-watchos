# Safe-area harness

Checks what a watch app built with this CLI gets as `MediaQuery.padding`, on
the watchOS Simulator, against measured values.

| Path | What it is |
|---|---|
| `run_matrix.sh` | Builds an app once per `FlutterWatchOSSafeArea` setting, runs every build on Simulators it creates and deletes, and checks each launch with `check_insets.sh`. Usage is at the top of the script. |
| `check_insets.sh` | Compares the first `SAFEAREA\|` line of a launch log with the expectation for its `mode=`. |
| `check_corner_table.sh` | Regenerates `test/fixtures/watch_corner_radii.json` from Xcode's watch device types and reports any difference. |
| `fixtures/watch_safe_area_insets.json` | watchOS's own safe area per screen size, in points at content scale 1.0. |
| `saprobe/` | The Flutter probe: pages that log and draw the insets, and the upstream counter page. |
| `safe_area_log/main.dart` | The log entrypoint `run_matrix.sh --app created` adds to a fresh `create --platforms=watchos` app. |
| `native/` | The native SwiftUI probe, for comparing with what watchOS itself reports. |

## The two modes

A build without the key reports `corners`: the same inset on all four sides,
`ceil(r(1 - 1/sqrt(2)))` with `r` from the corner fixture, 9 to 17 points. A
build with `FlutterWatchOSSafeArea` set to `platform`, in any letter case,
reports watchOS's own insets, the insets fixture's entry. Any other value
gives `corners`. The clock band, where a line has `band=`, is the insets
fixture's `top` in both modes.

## Running it

```sh
tool/safe_area/run_matrix.sh --work /tmp --out /tmp/safe-area-run \
    --devices Apple-Watch-SE-3-40mm,Apple-Watch-Ultra-3-49mm \
    --settings none,corners,Corners,platfrom,platform,Platform
```

Each build and each Simulator is a heavy step: the script stops before a build
when less than `--min-gib` (15 by default) is available on the Data volume, and
deletes its builds, its Xcode DerivedData and its Simulators when it ends.
Simulator builds are debug builds; release insets are a check on a physical
watch.

## Changing a fixture

`fixtures/watch_safe_area_insets.json` holds Simulator measurements on which
the native probe and Flutter agree. It changes only in a commit that cites a
run in which the native probe gives the new value. An entry may hold a value
for one runtime (`"26.5": { ... }`), used when `check_insets.sh` is given that
runtime; none is needed today. `test/fixtures/watch_corner_radii.json`
changes with the host's radius table, and `check_corner_table.sh` says when.
