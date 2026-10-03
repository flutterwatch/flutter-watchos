#!/usr/bin/env bash
# Copyright 2026 The FlutterWatch Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# The Xcode and watchOS matrix of spec 0002 (criterion 26): the end-to-end
# checks the unit suite cannot make, run with this machine's Xcode.
#
# Steps (criteria of spec 0002):
#   2    create, then build watchos --simulator.
#   3    run at target 26.0 on the older and the newer watchOS Simulator
#        runtime: the VM Service line, `renderer = metal (Impeller)`, the first
#        frame, a screenshot that is not blank, no new Runner-*.ips, and
#        "Application finished." after q.
#   4    the same on the newer runtime with the software renderer.
#   5    unsigned --profile and --release at 26.0: Runner is arm64 + arm64_32,
#        minos 26.0 per slice, the arm64_32 slice links no Flutter.framework
#        and holds the fallback text, both frameworks declare a
#        MinimumOSVersion no newer than the app's, and the xcodebuild log has
#        exactly one `ld: warning: ignoring file` line, for Flutter.framework.
#   6    unsigned --profile and --release at 27.0: a thin arm64 Runner,
#        minos 27.0, no `ld: warning: ignoring file` line.
#   6b   at 27.0 the host archive is thin arm64 and no arm64_32 host module
#        is compiled.
#   7    a 27.0 app runs on the newer runtime (the step 3 checks).
#   7b   a 27.0 app on the older runtime: run, drive and test exit non-zero
#        before xcodebuild, name the device, both versions, and print no stack
#        trace. This needs M113 (join J2) in the CLI under test.
#   10   device builds, unsigned, at 26.0 and 27.0, of the
#        shared_preferences_watchos and firebase_core_watchos examples, with
#        the exact list of warnings. Needs --plugins.
#   17   every direct-path plugin example (no external SwiftPM dependency)
#        on the Simulator at 26.0 and at 27.0. Needs --plugins.
#
# Targets other than the template's 26.0 are set through XCODE_XCCONFIG_FILE,
# which the CLI's deployment target lookup follows, so no project is edited.
# Device builds are unsigned the same way (CODE_SIGNING_ALLOWED=NO and
# CODE_SIGNING_REQUIRED=NO). The CLI's -v output does not carry xcodebuild's
# warnings, so the warning checks re-run the same xcodebuild directly.
#
# Usage:
#   tool/xcode_matrix.sh [options]
#     --only LIST        comma-separated steps (default: 2,3,4,5,6,6b,7,7b,10,17)
#     --plugins DIR      a plugins checkout; its HEAD is cloned into the work dir
#     --out DIR          logs and summary.txt (default: a new temporary dir)
#     --min-gib N        GiB that must be available before each heavy step
#                        (default 20; spec 0002 asks for at least 15)
#     --old-runtime V    the older watchOS Simulator runtime (default 26.5)
#     --new-runtime V    the newer watchOS Simulator runtime (default 27.0)
#     --lock DIR         take this lock directory (mkdir, retried every 60 s)
#                        for the whole run and remove it at the end
#     --keep             keep the work directory (apps and builds)
#   FLUTTER_WATCHOS      the CLI to test (default: bin/flutter-watchos here)
#
# One heavy step runs at a time. Before each, the script checks that at
# least --min-gib GiB are available on the data volume and stops otherwise;
# it logs `df -g` before and after each. It deletes each step's build output
# when the step ends, and at the end the simulators it created, the
# DerivedData of its own projects and, unless --keep, its work directory.
# The exit status is 0 when no step failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FW="${FLUTTER_WATCHOS:-$REPO_ROOT/bin/flutter-watchos}"
ONLY="2,3,4,5,6,6b,7,7b,10,17"
PLUGINS=""
OUT=""
MIN_GIB=20
OLD_RT="26.5"
NEW_RT="27.0"
LOCK=""
KEEP=0
DATA_VOLUME="/System/Volumes/Data"
[ -d "$DATA_VOLUME" ] || DATA_VOLUME="/"

usage() { sed -n '/^# The Xcode and watchOS matrix/,/^$/s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --only) ONLY="$2"; shift 2 ;;
    --plugins) PLUGINS="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --min-gib) MIN_GIB="$2"; shift 2 ;;
    --old-runtime) OLD_RT="$2"; shift 2 ;;
    --new-runtime) NEW_RT="$2"; shift 2 ;;
    --lock) LOCK="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "xcode_matrix: unknown option $1 (see --help)" >&2; exit 64 ;;
  esac
done

[ -x "$FW" ] || { echo "xcode_matrix: no CLI at $FW" >&2; exit 2; }
case "$MIN_GIB" in ''|*[!0-9]*) echo "xcode_matrix: --min-gib takes a whole number" >&2; exit 64 ;; esac

if [ -z "$OUT" ]; then
  OUT="$(mktemp -d "${TMPDIR:-/tmp}/xcode_matrix.XXXXXX")"
fi
mkdir -p "$OUT/logs"
OUT="$(cd "$OUT" && pwd -P)"
WORK="$OUT/work"
mkdir -p "$WORK"
SUMMARY="$OUT/summary.txt"
: > "$SUMMARY"
APP="$WORK/matrix_app"
CREATED_SIMS=""
HELD_LOCK=""
FAILURES=0

say() { printf 'xcode_matrix: %s\n' "$*" | tee -a "$OUT/matrix.log" >&2; }

# result STATUS STEP DETAIL: one summary line; FAIL counts towards the exit status.
result() {
  printf '%-4s %-22s %s\n' "$1" "$2" "$3" | tee -a "$SUMMARY" >&2
  if [ "$1" = FAIL ]; then FAILURES=$((FAILURES + 1)); fi
}

wants() { case ",$ONLY," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

available_gib() { df -g "$DATA_VOLUME" | awk 'NR == 2 { print $4 }'; }

heavy_begin() {
  local avail
  avail="$(available_gib)"
  say "df -g before $1: $(df -g "$DATA_VOLUME" | awk 'NR == 2')"
  case "$avail" in ''|*[!0-9]*) avail=0 ;; esac
  if [ "$avail" -lt "$MIN_GIB" ]; then
    say "stopping before $1: $avail GiB available, at least $MIN_GIB GiB needed"
    result STOP "$1" "$avail GiB available, $MIN_GIB GiB needed"
    exit 3
  fi
}

heavy_end() { say "df -g after $1: $(df -g "$DATA_VOLUME" | awk 'NR == 2')"; }

# wait_for FILE PATTERN SECONDS [PID]: 0 once FILE matches the extended
# regular expression PATTERN; 1 after SECONDS, or once PID has exited
# without it.
wait_for() {
  local file="$1" pattern="$2" seconds="$3" pid="${4:-}" i=0
  while [ "$i" -lt "$seconds" ]; do
    if grep -qE "$pattern" "$file" 2>/dev/null; then return 0; fi
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
      grep -qE "$pattern" "$file" 2>/dev/null
      return
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

# with_timeout SECONDS COMMAND...: runs COMMAND and stops it after SECONDS;
# 124 when it had to be stopped. simctl can wait for ever on a device that
# is not booted.
with_timeout() {
  local seconds="$1" pid i=0
  shift
  "$@" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$i" -ge "$seconds" ]; then
      kill "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 1
    i=$((i + 1))
  done
  wait "$pid"
}

# version_le A B: A <= B for dotted version numbers.
version_le() {
  python3 - "$1" "$2" <<'PY'
import sys
def parts(v):
    return [int(p) for p in (v.split('.') + ['0', '0'])[:3]]
sys.exit(0 if parts(sys.argv[1]) <= parts(sys.argv[2]) else 1)
PY
}

count_crash_reports() {
  find "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 -name 'Runner-*.ips' 2>/dev/null | wc -l | tr -d ' '
}

# The DerivedData directories Xcode made for projects under the work dir.
delete_derived_data() {
  local dd plist workspace
  for dd in "$HOME"/Library/Developer/Xcode/DerivedData/*; do
    [ -d "$dd" ] || continue
    plist="$dd/info.plist"
    workspace=""
    if [ -f "$plist" ]; then
      workspace="$(/usr/libexec/PlistBuddy -c 'Print :WorkspacePath' "$plist" 2>/dev/null || true)"
    fi
    case "$workspace" in
      "$WORK"/*|/private"$WORK"/*|"${WORK#/private}"/*) ;;
      *)
        if [ -n "$workspace" ] || ! grep -rqs -- "${WORK#/private}" "$dd/Build/Intermediates.noindex/XCBuildData" 2>/dev/null; then
          continue
        fi
        ;;
    esac
    rm -rf "$dd" && say "deleted DerivedData $(basename "$dd")"
  done
}

cleanup() {
  local status=$?
  local pid udid
  for pid in $(jobs -p); do kill "$pid" 2>/dev/null; done
  for udid in $CREATED_SIMS; do
    xcrun simctl shutdown "$udid" >/dev/null 2>&1
    if xcrun simctl delete "$udid" >/dev/null 2>&1; then say "deleted simulator $udid"; fi
  done
  delete_derived_data
  if [ "$KEEP" = 1 ]; then
    say "work directory kept: $WORK"
  else
    rm -rf "$WORK"
  fi
  if [ -n "$HELD_LOCK" ]; then rmdir "$HELD_LOCK" 2>/dev/null; fi
  say "df -g at the end: $(df -g "$DATA_VOLUME" | awk 'NR == 2')"
  say "summary: $SUMMARY ($FAILURES failed)"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

if [ -n "$LOCK" ]; then
  until mkdir "$LOCK" 2>/dev/null; do
    say "waiting for the lock $LOCK"
    sleep 60
  done
  HELD_LOCK="$LOCK"
fi

# --- The toolchain, recorded first (spec 0002, criterion 13 asks for it). ---

{
  echo "date: $(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "cli: $FW ($(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo 'not a git checkout'))"
  echo "xcode-select: $(xcode-select -p 2>/dev/null) DEVELOPER_DIR=${DEVELOPER_DIR:-unset}"
  xcodebuild -version 2>&1 | tr '\n' ' '
  echo
  sdk="$(xcrun --sdk watchos --show-sdk-path 2>/dev/null)"
  echo "watchOS SDK: $sdk"
  echo "MaximumDeploymentTarget: $(plutil -extract MaximumDeploymentTarget raw "$sdk/SDKSettings.json" 2>&1)"
  echo "DefaultDeploymentTarget: $(plutil -extract DefaultDeploymentTarget raw "$sdk/SDKSettings.json" 2>&1)"
  xcrun simctl list runtimes 2>&1 | grep -i watchos
  sw_vers 2>&1 | tr '\n' ' '
  echo
} > "$OUT/logs/toolchain.txt"
say "toolchain: $(head -4 "$OUT/logs/toolchain.txt" | tail -1)"

cat > "$WORK/unsigned-26.0.xcconfig" <<'XC'
CODE_SIGNING_ALLOWED = NO
CODE_SIGNING_REQUIRED = NO
XC
cat > "$WORK/unsigned-27.0.xcconfig" <<'XC'
CODE_SIGNING_ALLOWED = NO
CODE_SIGNING_REQUIRED = NO
WATCHOS_DEPLOYMENT_TARGET = 27.0
XC
cat > "$WORK/target-27.0.xcconfig" <<'XC'
WATCHOS_DEPLOYMENT_TARGET = 27.0
XC

# --- Simulators -------------------------------------------------------------

# create_simulator VERSION: sets SIM_UDID and SIM_NAME to a new simulator on
# the watchOS VERSION runtime, which this script deletes at the end.
create_simulator() {
  local version="$1" pick runtime devtype
  pick="$(xcrun simctl list runtimes --json | python3 -c '
import json, sys
version = sys.argv[1]
for runtime in json.load(sys.stdin).get("runtimes", []):
    if runtime.get("platform") != "watchOS" or runtime.get("version") != version:
        continue
    if runtime.get("isAvailable") is False:
        continue
    types = [t for t in runtime.get("supportedDeviceTypes", [])
             if t.get("name", "").startswith("Apple Watch Series")]
    if types:
        print(runtime["identifier"], types[0]["identifier"])
        break
' "$version")"
  if [ -z "$pick" ]; then
    say "no available watchOS $version Simulator runtime with an Apple Watch Series device"
    return 1
  fi
  runtime="${pick% *}"
  devtype="${pick#* }"
  SIM_NAME="xcode-matrix watchOS $version"
  SIM_UDID="$(xcrun simctl create "$SIM_NAME" "$devtype" "$runtime")" || return 1
  CREATED_SIMS="$CREATED_SIMS $SIM_UDID"
  say "created simulator $SIM_UDID ($SIM_NAME, $devtype)"
}

OLD_SIM=""
OLD_SIM_NAME=""
NEW_SIM=""
NEW_SIM_NAME=""
simulators() {
  if [ -z "$OLD_SIM" ] && create_simulator "$OLD_RT"; then
    OLD_SIM="$SIM_UDID"
    OLD_SIM_NAME="$SIM_NAME"
  fi
  if [ -z "$NEW_SIM" ] && create_simulator "$NEW_RT"; then
    NEW_SIM="$SIM_UDID"
    NEW_SIM_NAME="$SIM_NAME"
  fi
}

# --- The app ----------------------------------------------------------------

make_app() {
  if [ -d "$APP/watchos" ]; then return 0; fi
  say "creating $APP"
  (cd "$WORK" && "$FW" create matrix_app) > "$OUT/logs/create.log" 2>&1
}

clean_app_build() { rm -rf "$APP/build" "$WORK/symroot" "$WORK/dd"; }

# The app's own xcodebuild, run directly for its warnings: the CLI's -v
# output does not carry them. Same arguments as the CLI's device build, plus
# `clean` so the link runs again.
direct_xcodebuild() {
  local project_dir="$1" xcconfig="$2" log="$3"
  (cd "$project_dir/watchos" && env XCODE_XCCONFIG_FILE="$xcconfig" xcodebuild \
    -project Runner.xcodeproj -scheme Runner -configuration Release \
    -sdk watchos -destination 'generic/platform=watchOS' \
    -derivedDataPath "$WORK/dd" SYMROOT="$WORK/symroot" \
    COMPILER_INDEX_STORE_ENABLE=NO clean build) > "$log" 2>&1
}

# non_blank BMP: 0 when the screenshot has at least 8 colours.
non_blank() {
  python3 - "$1" <<'PY'
import struct, sys
data = open(sys.argv[1], 'rb').read()
if data[:2] != b'BM':
    sys.exit(2)
offset, = struct.unpack_from('<I', data, 10)
width, height = struct.unpack_from('<ii', data, 18)
step = struct.unpack_from('<H', data, 28)[0] // 8
row = (width * step + 3) & ~3
colours = set()
for y in range(0, abs(height), 4):
    base = offset + y * row
    for x in range(0, width, 4):
        colours.add(data[base + x * step:base + x * step + 3])
sys.exit(0 if len(colours) >= 8 else 1)
PY
}

# run_app STEP UDID RENDERER [XCCONFIG]: `run` on the simulator UDID and the
# step 3 checks; RENDERER is `metal (Impeller)` or `software`.
run_app() {
  local step="$1" udid="$2" renderer="$3" xcconfig="${4:-}"
  local label log fifo shot applog start pid crashes_before crashes_after problems=""
  label="$(echo "$step" | tr ' /' '__')"
  log="$OUT/logs/$label-run.log"
  fifo="$WORK/$label.stdin"
  shot="$OUT/logs/$label.bmp"
  applog="$OUT/logs/$label-app.log"
  heavy_begin "$step"
  crashes_before="$(count_crash_reports)"
  start="$(date '+%Y-%m-%d %H:%M:%S')"
  rm -f "$fifo"
  mkfifo "$fifo"
  (
    cd "$APP" || exit 1
    if [ -n "$xcconfig" ]; then export XCODE_XCCONFIG_FILE="$xcconfig"; fi
    if [ "$renderer" = software ]; then export SIMCTL_CHILD_FLUTTER_WATCHOS_RENDERER=software; fi
    exec "$FW" run -d "$udid" < "$fifo" > "$log" 2>&1
  ) &
  pid=$!
  # Read-write, so this open never waits for the reader.
  exec 7<> "$fifo"
  if wait_for "$log" 'Dart VM Service on .* is available at' 900 "$pid"; then
    sleep 8
    with_timeout 60 xcrun simctl io "$udid" screenshot --type=bmp "$shot" > /dev/null 2>&1
    with_timeout 120 xcrun simctl spawn "$udid" log show --style compact --start "$start" \
      --predicate 'process == "Runner"' > "$applog" 2>&1
    grep -qF "renderer = $renderer" "$applog" || problems="$problems; no 'renderer = $renderer' in the app log"
    grep -qE 'watchOS first frame' "$applog" || problems="$problems; no first frame in the app log"
    if [ ! -s "$shot" ]; then
      problems="$problems; no screenshot"
    elif ! non_blank "$shot"; then
      problems="$problems; the screenshot is blank"
    fi
    printf 'q' >&7
    wait_for "$log" 'Application finished\.' 120 "$pid" || problems="$problems; no 'Application finished.' after q"
  else
    problems="$problems; no VM Service line"
  fi
  exec 7>&-
  sleep 2
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null
    problems="$problems; run still running at the end"
  fi
  wait "$pid" 2>/dev/null
  xcrun simctl shutdown "$udid" > /dev/null 2>&1
  crashes_after="$(count_crash_reports)"
  if [ "$crashes_after" -gt "$crashes_before" ]; then
    problems="$problems; $((crashes_after - crashes_before)) new Runner-*.ips"
  fi
  if [ -z "$problems" ]; then
    result PASS "$step" "VM Service, renderer = $renderer, first frame, screenshot, Application finished"
  else
    result FAIL "$step" "${problems#; } (logs/$label-*)"
  fi
  clean_app_build
  heavy_end "$step"
}

# refused STEP LOG COMMAND...: the 27.0 app on the older runtime must be
# refused before xcodebuild, naming the device, both versions, with no stack
# trace.
refused() {
  local step="$1" log="$2" status problems=""
  shift 2
  (cd "$APP" && env XCODE_XCCONFIG_FILE="$WORK/target-27.0.xcconfig" "$FW" "$@" -v) > "$log" 2>&1
  status=$?
  [ "$status" -ne 0 ] || problems="$problems; exit status 0"
  grep -qF "$OLD_SIM_NAME" "$log" || problems="$problems; the device is not named"
  grep -F "$OLD_RT" "$log" | grep -qF "27.0" ||
    problems="$problems; no line names both watchOS $OLD_RT and 27.0"
  if grep -qE '^#0 ' "$log"; then problems="$problems; a stack trace"; fi
  if grep -qE 'Running Xcode build|Executing xcodebuild' "$log"; then problems="$problems; xcodebuild ran"; fi
  if [ -z "$problems" ]; then
    result PASS "$step" "refused before xcodebuild (exit $status)"
  else
    result FAIL "$step" "${problems#; } ($(basename "$log"))"
  fi
}

prepare_integration_test() {
  mkdir -p "$APP/integration_test" "$APP/test_driver"
  cat > "$APP/integration_test/matrix_test.dart" <<'DART'
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('starts', (WidgetTester tester) async {});
}
DART
  cat > "$APP/test_driver/integration_test.dart" <<'DART'
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver();
DART
  if ! grep -q 'integration_test:' "$APP/pubspec.yaml"; then
    python3 - "$APP/pubspec.yaml" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
extra = '  integration_test:\n    sdk: flutter\n  flutter_driver:\n    sdk: flutter\n'
if 'dev_dependencies:\n' in text:
    text = text.replace('dev_dependencies:\n', 'dev_dependencies:\n' + extra, 1)
else:
    text += '\ndev_dependencies:\n' + extra
open(path, 'w').write(text)
PY
  fi
  (cd "$APP" && "$FW" pub get) > "$OUT/logs/7b-pub-get.log" 2>&1
}

# device_build STEP TARGET MODE: unsigned `build watchos --MODE` at TARGET
# and the checks of criteria 5 (26.0) or 6 and 6b (27.0).
device_build() {
  local step="$1" target="$2" mode="$3"
  local label xcconfig log xlog app runner archs arch minos app_min fw_min framework problems=""
  label="$(echo "$step" | tr ' /' '__')"
  xcconfig="$WORK/unsigned-$target.xcconfig"
  log="$OUT/logs/$label-build.log"
  xlog="$OUT/logs/$label-xcodebuild.log"
  heavy_begin "$step"
  # A host module left from an earlier target would hide what this one built.
  rm -rf "$APP/watchos/Flutter/.host_build" "$APP/watchos/Flutter/FlutterWatchOS.swiftmodule"
  if ! (cd "$APP" && env XCODE_XCCONFIG_FILE="$xcconfig" "$FW" build watchos "--$mode" -v) > "$log" 2>&1; then
    result FAIL "$step" "build watchos --$mode failed (logs/$label-build.log)"
    clean_app_build
    heavy_end "$step"
    return
  fi
  app="$APP/build/watchos/Release-watchos/Runner.app"
  runner="$app/Runner"
  archs="$(lipo -archs "$runner" 2>/dev/null | tr ' ' '\n' | sort | tr '\n' ' ')"
  archs="${archs% }"
  if [ "$target" = 26.0 ]; then
    [ "$archs" = "arm64 arm64_32" ] || problems="$problems; lipo -archs is '$archs', not 'arm64 arm64_32'"
    if otool -arch arm64_32 -L "$runner" 2>/dev/null | grep -q 'Flutter.framework'; then
      problems="$problems; the arm64_32 slice links Flutter.framework"
    fi
    lipo -thin arm64_32 "$runner" -output "$WORK/runner_arm64_32" 2>/dev/null
    grep -qa 'Requires Apple Watch Series 9' "$WORK/runner_arm64_32" 2>/dev/null ||
      problems="$problems; the arm64_32 slice has no fallback text"
    rm -f "$WORK/runner_arm64_32"
  else
    [ "$archs" = "arm64" ] || problems="$problems; lipo -archs is '$archs', not 'arm64'"
    local host_archs
    host_archs="$(lipo -archs "$APP/watchos/Flutter/libFlutterWatchOSHost.a" 2>/dev/null)"
    [ "$host_archs" = "arm64" ] || problems="$problems; the host archive is '$host_archs', not 'arm64' (6b)"
    if [ -e "$APP/watchos/Flutter/.host_build/FlutterWatchOS_arm64_32.o" ] ||
       [ -e "$APP/watchos/Flutter/FlutterWatchOS.swiftmodule/arm64_32-apple-watchos.swiftmodule" ]; then
      problems="$problems; an arm64_32 host module was compiled (6b)"
    fi
    grep -qF 'Built the FlutterWatchOS host module' "$log" &&
      ! grep -F 'Built the FlutterWatchOS host module' "$log" | grep -qF 'arm64_32' ||
      problems="$problems; the -v log does not show an arm64-only host module (6b)"
  fi
  for arch in $archs; do
    minos="$(otool -arch "$arch" -l "$runner" 2>/dev/null | awk '/LC_BUILD_VERSION/ { found = 1 } found && $1 == "minos" { print $2; exit }')"
    [ "$minos" = "$target" ] || problems="$problems; $arch minos is '$minos', not $target"
  done
  app_min="$(plutil -extract MinimumOSVersion raw "$app/Info.plist" 2>/dev/null)"
  for framework in Flutter App; do
    fw_min="$(plutil -extract MinimumOSVersion raw "$app/Frameworks/$framework.framework/Info.plist" 2>/dev/null)"
    if [ -z "$fw_min" ] || [ -z "$app_min" ] || ! version_le "$fw_min" "$app_min"; then
      problems="$problems; $framework.framework MinimumOSVersion '$fw_min' against the app's '$app_min'"
    fi
  done
  if direct_xcodebuild "$APP" "$xcconfig" "$xlog"; then
    local ignoring
    ignoring="$(grep -c 'ld: warning: ignoring file' "$xlog")"
    if [ "$target" = 26.0 ]; then
      if [ "$ignoring" != 1 ] || ! grep 'ld: warning: ignoring file' "$xlog" | grep -q 'Flutter.framework'; then
        problems="$problems; $ignoring 'ld: warning: ignoring file' lines, not one for Flutter.framework"
      fi
    elif [ "$ignoring" != 0 ]; then
      problems="$problems; $ignoring 'ld: warning: ignoring file' lines, not none"
    fi
  else
    problems="$problems; the direct xcodebuild failed (logs/$label-xcodebuild.log)"
  fi
  if [ -z "$problems" ]; then
    result PASS "$step" "Runner $archs, minos $target, MinimumOSVersion app $app_min, ld warnings as expected"
  else
    result FAIL "$step" "${problems#; }"
  fi
  clean_app_build
  heavy_end "$step"
}

# --- Plugins ----------------------------------------------------------------

clone_plugins() {
  if [ -d "$WORK/plugins" ]; then return 0; fi
  if [ -z "$PLUGINS" ]; then return 1; fi
  git clone --quiet --local "$PLUGINS" "$WORK/plugins" > "$OUT/logs/plugins-clone.log" 2>&1 || return 1
  say "plugins at $(git -C "$WORK/plugins" rev-parse --short HEAD)"
}

# The packages whose watchos/Package.swift declares no SwiftPM dependency
# (the CLI builds those with clang itself) and that have an example app.
direct_path_packages() {
  local dir manifest
  for dir in "$WORK"/plugins/packages/*/; do
    manifest="$dir/watchos/Package.swift"
    [ -f "$manifest" ] && [ -d "$dir/example/watchos" ] || continue
    if sed 's#//.*##' "$manifest" | grep -q '\.package('; then continue; fi
    basename "$dir"
  done
}

# plugin_device_build STEP PACKAGE TARGET: criterion 10.
plugin_device_build() {
  local step="$1" package="$2" target="$3" example label xcconfig xlog warnings unexpected
  example="$WORK/plugins/packages/$package/example"
  label="$(echo "$step" | tr ' /' '__')"
  xcconfig="$WORK/unsigned-$target.xcconfig"
  xlog="$OUT/logs/$label-xcodebuild.log"
  heavy_begin "$step"
  if ! (cd "$example" && env XCODE_XCCONFIG_FILE="$xcconfig" "$FW" build watchos --release) > "$OUT/logs/$label-build.log" 2>&1; then
    result FAIL "$step" "build watchos --release failed (logs/$label-build.log)"
  elif ! direct_xcodebuild "$example" "$xcconfig" "$xlog"; then
    result FAIL "$step" "the direct xcodebuild failed (logs/$label-xcodebuild.log)"
  else
    # Xcode's App Intents metadata note is printed for every app and is not
    # about this build; every other warning is judged.
    warnings="$(grep 'warning:' "$xlog" | grep -v 'appintentsmetadataprocessor' | sort -u)"
    if [ "$target" = 26.0 ]; then
      unexpected="$(printf '%s\n' "$warnings" | grep -v -e 'ld: warning: ignoring file .*Flutter\.framework/Flutter.*arm64_32' \
        -e 'ld: warning: ignoring file .*libflutter_watchos_plugins\.a.*arm64_32' | grep -v '^$')"
      if ! printf '%s\n' "$warnings" | grep -q 'Flutter\.framework/Flutter'; then
        unexpected="${unexpected}${unexpected:+ / }no Flutter.framework arm64_32 warning"
      fi
    else
      unexpected="$(printf '%s\n' "$warnings" | grep -v '^$')"
    fi
    if [ -z "$unexpected" ]; then
      result PASS "$step" "built; warnings as expected"
    else
      printf '%s\n' "$unexpected" > "$OUT/logs/$label-unexpected-warnings.txt"
      result FAIL "$step" "unexpected warnings (logs/$label-unexpected-warnings.txt)"
    fi
  fi
  rm -rf "$example/build" "$WORK/symroot" "$WORK/dd"
  heavy_end "$step"
}

# plugin_simulator_build STEP PACKAGE TARGET: one criterion 17 build.
plugin_simulator_build() {
  local step="$1" package="$2" target="$3" example label
  example="$WORK/plugins/packages/$package/example"
  label="$(echo "$step" | tr ' /' '__')"
  heavy_begin "$step"
  if (
    cd "$example" || exit 1
    if [ "$target" = 27.0 ]; then export XCODE_XCCONFIG_FILE="$WORK/target-27.0.xcconfig"; fi
    exec "$FW" build watchos --simulator
  ) > "$OUT/logs/$label.log" 2>&1; then
    result PASS "$step" "built for the Simulator at $target"
  else
    result FAIL "$step" "build watchos --simulator failed at $target (logs/$label.log)"
  fi
  rm -rf "$example/build"
  heavy_end "$step"
}

# --- The steps --------------------------------------------------------------

if wants 2 || wants 3 || wants 4 || wants 5 || wants 6 || wants 6b || wants 7 || wants 7b; then
  heavy_begin "create"
  if ! make_app; then
    result FAIL "create" "flutter-watchos create failed (logs/create.log)"
    exit 1
  fi
  heavy_end "create"
fi

if wants 2; then
  heavy_begin "2 build --simulator"
  if (cd "$APP" && "$FW" build watchos --simulator) > "$OUT/logs/2-build-simulator.log" 2>&1; then
    result PASS "2" "create and build watchos --simulator"
  else
    result FAIL "2" "build watchos --simulator failed (logs/2-build-simulator.log)"
  fi
  clean_app_build
  heavy_end "2 build --simulator"
fi

if wants 3 || wants 4 || wants 7 || wants 7b; then
  simulators
fi

if wants 3; then
  if [ -n "$OLD_SIM" ]; then run_app "3 $OLD_RT sim 26.0" "$OLD_SIM" 'metal (Impeller)'; else result FAIL "3 $OLD_RT sim 26.0" "no simulator"; fi
  if [ -n "$NEW_SIM" ]; then run_app "3 $NEW_RT sim 26.0" "$NEW_SIM" 'metal (Impeller)'; else result FAIL "3 $NEW_RT sim 26.0" "no simulator"; fi
fi

if wants 4; then
  if [ -n "$NEW_SIM" ]; then run_app "4 $NEW_RT software" "$NEW_SIM" software; else result FAIL "4" "no simulator"; fi
fi

if wants 7; then
  if [ -n "$NEW_SIM" ]; then
    run_app "7 $NEW_RT sim 27.0" "$NEW_SIM" 'metal (Impeller)' "$WORK/target-27.0.xcconfig"
  else
    result FAIL "7" "no simulator"
  fi
fi

if wants 7b; then
  if [ -z "$OLD_SIM" ]; then
    result FAIL "7b" "no simulator"
  else
    heavy_begin "7b"
    prepare_integration_test
    refused "7b run" "$OUT/logs/7b-run.log" run -d "$OLD_SIM"
    refused "7b drive" "$OUT/logs/7b-drive.log" drive -d "$OLD_SIM" \
      --driver=test_driver/integration_test.dart --target=integration_test/matrix_test.dart
    refused "7b test" "$OUT/logs/7b-test.log" test integration_test/matrix_test.dart -d "$OLD_SIM"
    xcrun simctl shutdown "$OLD_SIM" > /dev/null 2>&1
    clean_app_build
    heavy_end "7b"
  fi
fi

if wants 5; then
  device_build "5 profile 26.0" 26.0 profile
  device_build "5 release 26.0" 26.0 release
fi

if wants 6 || wants 6b; then
  device_build "6 profile 27.0" 27.0 profile
  device_build "6 release 27.0" 27.0 release
fi

if wants 10 || wants 17; then
  if ! clone_plugins; then
    result SKIP "10 17" "no plugins checkout (--plugins DIR)"
  else
    if wants 10; then
      for target in 26.0 27.0; do
        plugin_device_build "10 shared_prefs $target" shared_preferences_watchos "$target"
        plugin_device_build "10 firebase_core $target" firebase_core_watchos "$target"
      done
    fi
    if wants 17; then
      packages="$(direct_path_packages)"
      say "direct-path examples: $(echo "$packages" | wc -w | tr -d ' ') (spec 0002 counts 17 at plugins 10591ec)"
      for target in 26.0 27.0; do
        for package in $packages; do
          plugin_simulator_build "17 $target ${package%_watchos}" "$package" "$target"
        done
      done
    fi
  fi
fi

if [ "$FAILURES" -gt 0 ]; then exit 1; fi
exit 0
