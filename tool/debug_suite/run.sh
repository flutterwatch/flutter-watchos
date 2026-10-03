#!/usr/bin/env bash
# Copyright 2026 The FlutterWatch Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# The watch Simulator debug suite: the debugging checks that need a booted
# watch Simulator, which the unit tests cannot make.
#
# Creates an app from fixture_main.dart.tmpl and runs the debugging checks
# against it on one watch Simulator: run with r, R and q, vmcheck through the
# printed VM Service URI, DevTools over HTTP, attach, the log matrix in the run
# console and in logs, --start-paused, --machine, the mode refusal, screenshot,
# test, drive and --trace-startup. Each check writes one PASS, FAIL or SKIP
# line; verdict.dart compares them with expectations.txt, where a check that
# a known limitation makes fail is a strict expected failure.
#
# Usage:
#   tool/debug_suite/run.sh <simulator-udid>
#   tool/debug_suite/run.sh --create <runtime-id> [<device-type-id>]
#     --create makes a Simulator for the run and deletes it afterwards.
#
# Environment:
#   WATCHOS_ENGINE_ARTIFACTS  required: the engine artifacts to run against.
#   FLUTTER_WATCHOS_CLI       the CLI under test (default: bin/flutter-watchos
#                             of this checkout).
#   DEBUG_SUITE_MIN_GIB       space needed before anything starts (default 15).
#   DEBUG_SUITE_OUT           where results and logs go (default:
#                             ./debug_suite_out).
#
# Everything else the suite makes (the app, a fresh HOME, the build, the
# installed app and a --create Simulator) is deleted when it ends.
#
# Exit 0 when every check matches expectations.txt, 1 when not, 2 when the
# suite could not run.

set -uo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SUITE_DIR/../.." && pwd)"
CLI="${FLUTTER_WATCHOS_CLI:-$REPO_ROOT/bin/flutter-watchos}"
DART="$REPO_ROOT/flutter/bin/dart"
MIN_GIB="${DEBUG_SUITE_MIN_GIB:-15}"
OUT="${DEBUG_SUITE_OUT:-$PWD/debug_suite_out}"
APP_NAME=debug_suite_app

die() { echo "debug_suite: error: $*" >&2; exit 2; }
note() { echo "debug_suite: $*"; }

# --- Arguments and preconditions --------------------------------------------

UDID=""
CREATE_RUNTIME=""
CREATE_TYPE=""
case "${1:-}" in
  --create)
    CREATE_RUNTIME="${2:-}"
    CREATE_TYPE="${3:-}"
    [ -n "$CREATE_RUNTIME" ] || die "--create needs a runtime id"
    ;;
  "" | -h | --help)
    sed -n '6,34p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
  *) UDID="$1" ;;
esac

[ -x "$CLI" ] || die "CLI not found at $CLI"
[ -x "$DART" ] || die "Dart not found at $DART (run the CLI once to set up flutter/)"
[ -n "${WATCHOS_ENGINE_ARTIFACTS:-}" ] || die "set WATCHOS_ENGINE_ARTIFACTS"
[ -d "$WATCHOS_ENGINE_ARTIFACTS" ] || die "no engine artifacts at $WATCHOS_ENGINE_ARTIFACTS"

SCRATCH_PARENT="${TMPDIR:-/tmp}"
available_gib="$(df -g "$SCRATCH_PARENT" | awk 'NR == 2 { print $4 }')"
if [ -z "$available_gib" ] || [ "$available_gib" -lt "$MIN_GIB" ]; then
  die "only ${available_gib:-?} GiB available under $SCRATCH_PARENT; the suite needs $MIN_GIB"
fi
note "$available_gib GiB available (need $MIN_GIB)"

WORK="$(mktemp -d "$SCRATCH_PARENT/fw_debug_suite.XXXXXX")" || die "mktemp failed"
APP="$WORK/$APP_NAME"
RESULTS="$WORK/results.txt"
CREATED_SIM=""
BUNDLE_ID=""
PIDS=()
: > "$RESULTS"

cleanup() {
  local pid
  for pid in "${PIDS[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done
  if [ -n "$UDID" ] && [ -n "$BUNDLE_ID" ]; then
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1
    xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1
  fi
  if [ -n "$CREATED_SIM" ]; then
    xcrun simctl shutdown "$CREATED_SIM" >/dev/null 2>&1
    xcrun simctl delete "$CREATED_SIM" >/dev/null 2>&1
  fi
  mkdir -p "$OUT"
  cp "$WORK"/*.log "$WORK"/*.txt "$OUT"/ 2>/dev/null
  rm -rf "$WORK"
  note "results and logs in $OUT"
}
trap cleanup EXIT
trap 'exit 2' INT TERM

if [ -n "$CREATE_RUNTIME" ]; then
  if [ -z "$CREATE_TYPE" ]; then
    CREATE_TYPE="$(xcrun simctl list devicetypes --json | python3 -c '
import json, sys
types = [t["identifier"] for t in json.load(sys.stdin)["devicetypes"]
         if t.get("productFamily") == "Apple Watch"]
print(types[-1] if types else "")
')"
    [ -n "$CREATE_TYPE" ] || die "no Apple Watch device type"
  fi
  UDID="$(xcrun simctl create fw-debug-suite "$CREATE_TYPE" "$CREATE_RUNTIME")" ||
    die "simctl create failed"
  CREATED_SIM="$UDID"
  note "created Simulator $UDID ($CREATE_TYPE, $CREATE_RUNTIME)"
fi

SIM_NAME="$(xcrun simctl list devices --json | UDID="$UDID" python3 -c '
import json, os, sys
for devices in json.load(sys.stdin)["devices"].values():
    for d in devices:
        if d["udid"] == os.environ["UDID"]:
            print(d["name"])
')"
[ -n "$SIM_NAME" ] || die "no Simulator with UDID $UDID"
xcrun simctl boot "$UDID" >/dev/null 2>&1
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || die "Simulator $UDID did not boot"
note "Simulator $SIM_NAME ($UDID) is booted"

export HOME="$WORK/home"
export FLUTTER_WATCHOS_BUILD_REGISTRY=0
mkdir -p "$HOME"

# --- Helpers -----------------------------------------------------------------

# result PASS|FAIL|SKIP <id> <detail>
result() {
  echo "$1 $2 ${3:-}" | tee -a "$RESULTS"
}

# check <id> <detail> <command...>: PASS when the command succeeds.
check() {
  local id="$1" detail="$2"
  shift 2
  if "$@"; then result PASS "$id" "$detail"; else result FAIL "$id" "$detail"; fi
}

# wait_for <file> <extended-regex> <seconds>
wait_for() {
  local i
  for ((i = 0; i < $3; i++)); do
    grep -qE "$2" "$1" 2>/dev/null && return 0
    sleep 1
  done
  return 1
}

# wait_exit <pid> <seconds>: the pid's exit code, or 124 after the timeout.
wait_exit() {
  local i
  for ((i = 0; i < $2; i++)); do
    if ! kill -0 "$1" 2>/dev/null; then
      wait "$1"
      return $?
    fi
    sleep 1
  done
  kill "$1" 2>/dev/null
  wait "$1" 2>/dev/null
  return 124
}

# timed <seconds> <log> <command...>: runs the command in the app directory.
timed() {
  local seconds="$1" log="$2" pid
  shift 2
  (cd "$APP" && "$@") >"$log" 2>&1 &
  pid=$!
  PIDS+=("$pid")
  wait_exit "$pid" "$seconds"
}

# pty_start <name> <command...>: starts the command in a pty, in the app
# directory; its output goes to $WORK/<name>.log, keys to $WORK/<name>.fifo.
pty_start() {
  local name="$1"
  shift
  (cd "$APP" && exec python3 "$SUITE_DIR/ptydrive.py" "$WORK/$name.log" "$WORK/$name.fifo" -- "$@") &
  LAST_PID=$!
  PIDS+=("$LAST_PID")
  local i
  for ((i = 0; i < 50; i++)); do
    [ -p "$WORK/$name.fifo" ] && return 0
    sleep 0.1
  done
}

# keys <name> <keys>
keys() {
  [ -p "$WORK/$1.fifo" ] && printf '%s' "$2" >"$WORK/$1.fifo"
}

# count <file> <fixed-string>: lines that contain the string.
count() {
  grep -cF -- "$2" "$1" 2>/dev/null || true
}

vmcheck() {
  (cd "$REPO_ROOT" && "$DART" tool/debug_suite/vmcheck.dart "$@")
}

VM_URL_RE='A Dart VM Service on .* is available at: (http://[^ ]*)'
DEVTOOLS_RE='DevTools debugger and profiler on .* is available at: (http://[^ ]*)'

vm_url_in() {
  grep -oE "$VM_URL_RE" "$1" | head -1 | sed -E "s|$VM_URL_RE|\\1|" | tr -d '\r'
}

# --- The app -----------------------------------------------------------------

note "creating the fixture app"
(cd "$WORK" && "$CLI" create --platforms=watchos --project-name "$APP_NAME" "$APP_NAME") \
  >"$WORK/create.log" 2>&1 || die "create failed (see create.log)"
cp "$SUITE_DIR/fixture_main.dart.tmpl" "$APP/lib/main.dart"
mkdir -p "$APP/integration_test" "$APP/test_driver"
cat >"$APP/integration_test/app_test.dart" <<EOF
import 'package:$APP_NAME/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('shows the label', (WidgetTester tester) async {
    await tester.pumpWidget(const FixtureApp());
    expect(find.text('SUITE_TEXT_A'), findsOneWidget);
  });
}
EOF
cat >"$APP/test/widget_test.dart" <<EOF
import 'package:$APP_NAME/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows the label', (WidgetTester tester) async {
    await tester.pumpWidget(const FixtureApp());
    expect(find.text('SUITE_TEXT_A'), findsOneWidget);
  });
}
EOF
cat >"$APP/test_driver/integration_test.dart" <<'EOF'
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver();
EOF
(cd "$APP" && "$CLI" pub add 'dev:integration_test:{"sdk":"flutter"}') \
  >>"$WORK/create.log" 2>&1 || die "pub add integration_test failed (see create.log)"
BREAKPOINT_LINE="$(grep -n 'SUITE_BREAKPOINT' "$APP/lib/main.dart" | cut -d: -f1)"

# --- run: URLs, log matrix, vmcheck, DevTools, attach, r, R, q ----------------

note "run -d $UDID"
pty_start run "$CLI" run -d "$UDID"
RUN_PID=$LAST_PID
if wait_for "$WORK/run.log" "$VM_URL_RE" 600; then
  VM_URL="$(vm_url_in "$WORK/run.log")"
  result PASS run.vm_service_url "$VM_URL"
  BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw \
    "$(find "$APP/build" -type d -name Runner.app -path '*watchos*' | head -1)/Info.plist" 2>/dev/null)"
  check run.devtools_url "DevTools line" grep -qE "$DEVTOOLS_RE" "$WORK/run.log"
  http_code="$(curl -s -o /dev/null -w '%{http_code}' "${VM_URL}devtools/")"
  check devtools.http "GET /devtools/ -> $http_code" [ "$http_code" = 200 ]

  sleep 8 # The unhandled exception comes after 1 s; let every marker arrive.
  L="$WORK/run.log"
  for pair in print:SUITE_MARK_PRINT debug_print:SUITE_MARK_DEBUGPRINT \
    stdout:SUITE_MARK_STDOUT stderr:SUITE_MARK_STDERR; do
    n="$(count "$L" "${pair#*:}")"
    check "run.log.${pair%%:*}" "${pair#*:} lines=$n" [ "$n" = 1 ]
  done
  n1="$(count "$L" SUITE_MARK_MULTI_1)"
  n2="$(count "$L" SUITE_MARK_MULTI_2)"
  [ "$n1" = 1 ] && [ "$n2" = 1 ]
  check run.log.multiline "lines=$n1,$n2" [ $? = 0 ]
  n="$(count "$L" 'SUITE_MARK_QUOTE "quoted" end')"
  check run.log.quote "whole lines=$n" [ "$n" = 1 ]
  n="$(count "$L" 'EXCEPTION CAUGHT BY')"
  [ "$n" = 1 ] && grep -qF SUITE_MARK_FLUTTER_ERROR "$L"
  check run.log.flutter_error "blocks=$n" [ $? = 0 ]
  n="$(grep -F 'Unhandled Exception' "$L" | grep -cF SUITE_MARK_UNHANDLED || true)"
  check run.log.unhandled_exception "lines=$n" [ "$n" = 1 ]

  vmcheck "$VM_URL" "package:$APP_NAME/main.dart" "$BREAKPOINT_LINE" >"$WORK/vmcheck.txt" 2>&1
  grep -E '^(PASS|FAIL) ' "$WORK/vmcheck.txt" | tee -a "$RESULTS"

  note "attach --debug-url"
  pty_start attach "$CLI" attach -d "$UDID" --debug-url "$VM_URL"
  ATTACH_PID=$LAST_PID
  if wait_for "$WORK/attach.log" 'Flutter run key commands|is available at' 180; then
    keys attach d
    wait_exit "$ATTACH_PID" 30
    check attach.debug_url "connected, d exits $?" true
  else
    result FAIL attach.debug_url "no connection in 180 s"
    kill "$ATTACH_PID" 2>/dev/null
  fi

  note "hot reload"
  sed -i '' 's/SUITE_TEXT_A/SUITE_TEXT_B/' "$APP/lib/main.dart"
  keys run r
  if wait_for "$WORK/run.log" 'Reloaded' 30 &&
    vmcheck "$VM_URL" --dump-app 2>&1 | grep -q SUITE_TEXT_B; then
    result PASS run.hot_reload "the edited Text is in debugDumpApp"
  else
    result FAIL run.hot_reload "no reload, or the edited Text is not in debugDumpApp"
  fi
  sed -i '' 's/SUITE_TEXT_B/SUITE_TEXT_A/' "$APP/lib/main.dart"

  note "hot restart"
  keys run R
  if wait_for "$WORK/run.log" 'Restarted application' 60; then
    value="$(vmcheck "$VM_URL" --eval marker 2>&1 | grep '^VALUE' | tr -d '\r')"
    check run.hot_restart "marker after R: $value" [ "$value" = 'VALUE unset' ]
  else
    result FAIL run.hot_restart "no restart in 60 s"
  fi

  keys run q
  wait_exit "$RUN_PID" 60
  rc=$?
  check run.quit "q exits $rc" [ "$rc" = 0 ]
else
  result FAIL run.vm_service_url "no VM Service line in 600 s"
  kill "$RUN_PID" 2>/dev/null
fi

# --- run --start-paused --------------------------------------------------------

note "run --start-paused"
pty_start paused "$CLI" run -d "$UDID" --start-paused
PAUSED_PID=$LAST_PID
if wait_for "$WORK/paused.log" "$VM_URL_RE" 300; then
  sleep 3
  state="$(vmcheck "$(vm_url_in "$WORK/paused.log")" --pause-state 2>&1 | grep '^PAUSE' | tr -d '\r')"
  printed="$(count "$WORK/paused.log" SUITE_MARK_PRINT)"
  [ "$state" = 'PAUSE PauseStart' ] && [ "$printed" = 0 ]
  check run.start_paused "$state, main() lines=$printed" [ $? = 0 ]
  keys paused q
  wait_exit "$PAUSED_PID" 60
else
  result FAIL run.start_paused "no VM Service line in 300 s"
  kill "$PAUSED_PID" 2>/dev/null
fi

# --- logs ---------------------------------------------------------------------

note "logs -d $UDID"
if [ -n "$BUNDLE_ID" ]; then
  (cd "$APP" && "$CLI" logs -d "$UDID") >"$WORK/logs.log" 2>&1 &
  LOGS_PID=$!
  PIDS+=("$LOGS_PID")
  sleep 5
  xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null 2>&1
  sleep 10
  kill "$LOGS_PID" 2>/dev/null
  wait "$LOGS_PID" 2>/dev/null
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1
  check logs.header "$(head -1 "$WORK/logs.log")" grep -qF "Showing $SIM_NAME logs:" "$WORK/logs.log"
  grep -qF SUITE_MARK_PRINT "$WORK/logs.log" && grep -qF SUITE_MARK_DEBUGPRINT "$WORK/logs.log"
  check logs.markers "print and debugPrint markers" [ $? = 0 ]
else
  result SKIP logs.header "no app bundle id: the first run failed"
  result SKIP logs.markers "no app bundle id: the first run failed"
fi

# --- run --machine ------------------------------------------------------------

note "run --machine"
mkfifo "$WORK/machine.in"
exec 7<>"$WORK/machine.in" # Held open, so the daemon does not read EOF.
(cd "$APP" && "$CLI" run --machine -d "$UDID") <"$WORK/machine.in" >"$WORK/machine.log" 2>&1 &
MACHINE_PID=$!
PIDS+=("$MACHINE_PID")
if wait_for "$WORK/machine.log" '"event":"app.started"' 300; then
  check machine.app_started "app.started and a wsUri" grep -q '"wsUri"' "$WORK/machine.log"
else
  result FAIL machine.app_started "$(grep -m1 -E 'Error|Bad state' "$WORK/machine.log")"
fi
kill "$MACHINE_PID" 2>/dev/null
wait "$MACHINE_PID" 2>/dev/null
exec 7>&-
[ -n "$BUNDLE_ID" ] && xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1

# --- Modes, screenshot --------------------------------------------------------

note "run --profile on the Simulator"
timed 300 "$WORK/profile.log" "$CLI" run --profile -d "$UDID"
rc=$?
traces="$(grep -cE '^#[0-9]+ ' "$WORK/profile.log" || true)"
[ "$rc" != 0 ] && [ "$traces" = 0 ]
check modes.profile_no_stack_trace "exit $rc, stack frames=$traces" [ $? = 0 ]

note "screenshot"
timed 120 "$WORK/screenshot.log" "$CLI" screenshot -d "$UDID" -o "$WORK/shot.png"
rc=$?
size="$(stat -f %z "$WORK/shot.png" 2>/dev/null || echo 0)"
dims="$(sips -g pixelWidth -g pixelHeight "$WORK/shot.png" 2>/dev/null | awk '/pixel/ { printf "%s ", $2 }')"
[ "$rc" = 0 ] && [ "$size" -gt 0 ]
check screenshot.png "exit $rc, $size bytes, $dims" [ $? = 0 ]
rm -f "$WORK/shot.png"

# --- test, drive, --trace-startup ---------------------------------------------

note "test"
timed 600 "$WORK/test.log" "$CLI" test
rc=$?
check test.unit "exit $rc" [ "$rc" = 0 ]

note "test integration_test -d $UDID"
timed 600 "$WORK/integration.log" "$CLI" test integration_test/app_test.dart -d "$UDID"
rc=$?
check test.integration "exit $rc" [ "$rc" = 0 ]

note "drive"
timed 600 "$WORK/drive.log" "$CLI" drive --driver=test_driver/integration_test.dart \
  --target=integration_test/app_test.dart -d "$UDID"
rc=$?
check drive.exit "exit $rc" [ "$rc" = 0 ]
[ "$rc" = 0 ] && ! grep -q 'integration_test plugin was not detected' "$WORK/drive.log"
check drive.integration_test "exit $rc; plugin warning absent" [ $? = 0 ]

note "run --trace-startup"
rm -f "$APP/build/start_up_info.json"
timed 300 "$WORK/trace.log" "$CLI" run --trace-startup -d "$UDID"
rc=$?
keys_found="$(python3 -c '
import json, sys
keys = ["engineEnterTimestampMicros", "timeToFrameworkInitMicros",
        "timeToFirstFrameRasterizedMicros", "timeToFirstFrameMicros",
        "timeAfterFrameworkInitMicros"]
try:
    data = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    data = {}
print(sum(1 for k in keys if k in data))
' "$APP/build/start_up_info.json")"
check trace.startup "exit $rc, stock keys=$keys_found/5" [ "$keys_found" = 5 ]

# --- Verdict --------------------------------------------------------------------

(cd "$REPO_ROOT" && "$DART" tool/debug_suite/verdict.dart \
  tool/debug_suite/expectations.txt "$RESULTS") | tee "$WORK/verdict.txt"
exit "${PIPESTATUS[0]}"
