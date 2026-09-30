#!/usr/bin/env bash
# Copyright 2026 The FlutterWatch Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# Checks the first SAFEAREA| line of a launch log against the expected insets.
#
# The probe (tool/safe_area/saprobe) and the log entrypoint of a created app
# (tool/safe_area/safe_area_log/main.dart) print one line per metrics change:
#
#   SAFEAREA|dev=U3|mode=corners|page=0|size=211.00x257.00|dpr=2.0|...
#     |padding=L17.00,T17.00,R17.00,B17.00|viewPadding=...|viewInsets=...
#     |systemGestureInsets=...|displayFeatures=[]|...[|band=56.50]
#
# The expectation depends on the line's `mode=`, which the build sets with
# --dart-define=MODE=:
#   platform  the insets fixture's entry for the screen size: watchOS's own
#             safeAreaInsets, measured on the Simulator at content scale 1.0;
#   corners   ceil(r(1 - 1/sqrt(2))) on all four sides, r from the corner
#             fixture (the host's radius table).
# A `band=`, when the line has one, is the insets fixture's `top` in both
# modes: the clock band that WatchStatusBar.heightOf reports.
#
# The content scale is not in the label. It is the line's `dpr=` over 2 (every
# supported watch reports 2.0 at scale 1): the logged size is mapped back to
# points with it, and the expected insets and band are divided by it.
#
# Usage:
#   tool/safe_area/check_insets.sh <log> [<fixture> [<corner-fixture> [<runtime>]]]
#     <fixture>         default: tool/safe_area/fixtures/watch_safe_area_insets.json
#     <corner-fixture>  default: test/fixtures/watch_corner_radii.json
#     <runtime>         e.g. 26.5: use an entry's per-runtime value when it has one
#
# Exit status: 0 when the line matches (every value within 0.01 pt); 1 on a
# mismatch, a non-zero viewInsets or systemGestureInsets, a non-empty
# displayFeatures, a missing or unknown mode=, an unknown screen size, or no
# SAFEAREA| line; 2 on bad usage.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG="${1:-}"
FIXTURE="${2:-$REPO_ROOT/tool/safe_area/fixtures/watch_safe_area_insets.json}"
CORNERS="${3:-$REPO_ROOT/test/fixtures/watch_corner_radii.json}"
RUNTIME="${4:-}"

usage() { echo "check_insets: error: $*" >&2; exit 2; }
fail() { echo "check_insets: FAIL: $*" >&2; exit 1; }

[[ $# -ge 1 && $# -le 4 ]] || usage "usage: $0 <log> [<fixture> [<corner-fixture> [<runtime>]]]"
[[ -f "$LOG" ]] || usage "no log at $LOG"
[[ -f "$FIXTURE" ]] || usage "no fixture at $FIXTURE"
[[ -f "$CORNERS" ]] || usage "no corner fixture at $CORNERS"

line="$(grep -a -m 1 -o 'SAFEAREA|.*' "$LOG" || true)"
[[ -n "$line" ]] || fail "no SAFEAREA| line in $LOG"

# The value of one `key=value` field of the line, or nothing.
field() {
  printf '%s\n' "$line" | tr '|' '\n' | awk -F '=' -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }'
}

mode="$(field mode)"
case "$mode" in
  platform | corners) ;;
  '') fail "the line has no mode=: $line" ;;
  *) fail "unknown mode=$mode (expected platform or corners): $line" ;;
esac

size="$(field size)"
dpr="$(field dpr)"
[[ "$size" =~ ^[0-9.]+x[0-9.]+$ && "$dpr" =~ ^[0-9.]+$ ]] || fail "no size= or dpr= in: $line"
scale="$(awk -v d="$dpr" 'BEGIN { printf "%.6f", d / 2 }')"
key="$(awk -v s="$size" -v c="$scale" 'BEGIN {
  split(s, wh, "x"); printf "%dx%d", int(wh[1] * c + 0.5), int(wh[2] * c + 0.5) }')"

# One value of the insets fixture's entry for this size: the per-runtime value
# when <runtime> is given and the entry has one, else the entry's own.
inset() {
  local value=""
  if [[ -n "$RUNTIME" ]]; then
    # plutil splits a key path at every dot; the runtime's own dot is escaped.
    value="$(plutil -extract "$key.${RUNTIME//./\\.}.$1" raw -o - "$FIXTURE" 2>/dev/null || true)"
  fi
  [[ -n "$value" ]] || value="$(plutil -extract "$key.$1" raw -o - "$FIXTURE" 2>/dev/null || true)"
  [[ -n "$value" ]] || fail "no $1 for $key in $FIXTURE (the screen size is unknown): $line"
  printf '%s' "$value"
}

top="$(inset top)"
if [[ "$mode" == platform ]]; then
  expected="$(awk -v l="$(inset left)" -v t="$top" -v r="$(inset right)" -v b="$(inset bottom)" -v c="$scale" \
    'BEGIN { printf "%.4f %.4f %.4f %.4f", l / c, t / c, r / c, b / c }')"
else
  radius="$(plutil -extract "$key" raw -o - "$CORNERS" 2>/dev/null || true)"
  [[ -n "$radius" ]] || fail "no radius for $key in $CORNERS: $line"
  expected="$(awk -v r="$radius" -v c="$scale" 'BEGIN {
    d = r * (1 - 1 / sqrt(2)); i = int(d); if (i < d) i++
    printf "%.4f %.4f %.4f %.4f", i / c, i / c, i / c, i / c }')"
fi

# Compares an `L..,T..,R..,B..` field with four expected numbers.
check_edges() {
  local name="$1" want="$2" got
  got="$(field "$name")"
  [[ -n "$got" ]] || fail "no $name= in: $line"
  awk -v got="$got" -v want="$want" -v name="$name" 'BEGIN {
    n = split(got, g, ","); split(want, w, " "); split("L T R B", e, " ")
    if (n != 4) { print "check_insets: FAIL: " name "=" got " is not L,T,R,B" > "/dev/stderr"; exit 1 }
    for (i = 1; i <= 4; i++) {
      if (substr(g[i], 1, 1) != e[i]) { print "check_insets: FAIL: " name "=" got " is not L,T,R,B" > "/dev/stderr"; exit 1 }
      v = substr(g[i], 2) + 0; d = v - w[i]; if (d < 0) d = -d
      if (d > 0.01 + 1e-9) {
        printf "check_insets: FAIL: %s %s is %.2f, expected %.2f\n", name, e[i], v, w[i] > "/dev/stderr"; exit 1
      }
    }
  }' || fail "$line"
}

check_edges padding "$expected"
check_edges viewPadding "$expected"
check_edges viewInsets "0 0 0 0"
check_edges systemGestureInsets "0 0 0 0"
[[ "$(field displayFeatures)" == "[]" ]] || fail "displayFeatures is not empty: $line"

band="$(field band)"
if [[ -n "$band" ]]; then
  awk -v got="$band" -v t="$top" -v c="$scale" 'BEGIN {
    w = t / c; d = got - w; if (d < 0) d = -d
    if (d > 0.01 + 1e-9) { printf "check_insets: FAIL: band is %.2f, expected %.2f\n", got, w > "/dev/stderr"; exit 1 }
  }' || fail "$line"
fi

echo "check_insets: OK: mode=$mode size=$key scale=$scale padding=$(field padding)${band:+ band=$band}"
