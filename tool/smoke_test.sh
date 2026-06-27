#!/usr/bin/env bash
# Copyright 2026 The FlutterWatch Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# Launch-flow smoke test.
#
# Builds and runs the bundled example on a watchOS simulator and asserts the
# Dart VM Service comes up. This exercises the end-to-end install → launch →
# log-stream path that the unit suite (test/general/) intentionally does NOT
# mock — that path is a timing-sensitive multi-command flow (simctl boot →
# install → terminate → await log-stream ready → launch) that is fragile to
# fake with a scripted ProcessManager but cheap to verify for real here.
#
# Usage:
#   tool/smoke_test.sh [SIMULATOR_UDID]
#     SIMULATOR_UDID  default: the first available watchOS simulator.
#
# Exit 0 = the app launched and the VM service was reachable; non-zero = it did
# not come up within the timeout (the tail of the run log is printed).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXAMPLE_DIR="$REPO_ROOT/packages/flutter_watchos/example"
CLI="$REPO_ROOT/bin/flutter-watchos"
TIMEOUT_SECONDS=300

die() { echo "smoke_test: error: $*" >&2; exit 2; }

[ -x "$CLI" ] || die "CLI not found/executable at $CLI"
[ -d "$EXAMPLE_DIR" ] || die "example app not found at $EXAMPLE_DIR"

# Resolve a watchOS simulator UDID (argument wins; otherwise auto-pick the first
# available one).
SIM_UDID="${1:-}"
if [ -z "$SIM_UDID" ]; then
  SIM_UDID="$(xcrun simctl list devices available --json | python3 -c '
import json, sys
data = json.load(sys.stdin)
for runtime, devices in data.get("devices", {}).items():
    if "watchOS" not in runtime:
        continue
    for d in devices:
        if d.get("isAvailable"):
            print(d["udid"]); sys.exit(0)
sys.exit(1)
')" || die "no available watchOS simulator found (pass a UDID explicitly)"
fi

echo "smoke_test: using watchOS simulator $SIM_UDID"

LOG="$(mktemp -t flutter_watchos_smoke.XXXXXX)"
cleanup() {
  pkill -f 'flutter-watchos run' 2>/dev/null || true
  xcrun simctl terminate "$SIM_UDID" com.example.flutterWatchosExample.watchkitapp 2>/dev/null || true
  rm -f "$LOG"
}
trap cleanup EXIT

echo "smoke_test: launching example (log: $LOG)..."
( cd "$EXAMPLE_DIR" && "$CLI" run -d "$SIM_UDID" >"$LOG" 2>&1 ) &
RUN_PID=$!

# Poll the run log for the VM-service banner — the signal that the engine
# booted, the isolate started, and hot-reload/DevTools attached.
ok=0
for _ in $(seq 1 $((TIMEOUT_SECONDS / 2))); do
  if ! kill -0 "$RUN_PID" 2>/dev/null; then
    echo "smoke_test: the run process exited early" >&2
    break
  fi
  if grep -qE 'Dart VM Service on .* is available at' "$LOG"; then
    ok=1
    break
  fi
  sleep 2
done

if [ "$ok" = 1 ]; then
  echo "smoke_test: PASS — Dart VM Service is up:"
  grep -E 'Dart VM Service on .* is available at' "$LOG" | head -1
  exit 0
fi

echo "smoke_test: FAIL — no Dart VM Service within ${TIMEOUT_SECONDS}s. Last 25 log lines:" >&2
tail -25 "$LOG" >&2
exit 1
