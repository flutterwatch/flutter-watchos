#!/usr/bin/env bash
# Copyright 2026 The FlutterWatch Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# Checks the host's display-corner table against Xcode's watch device types.
#
# `host/FlutterRunner.swift` keeps a table of display corner radii, keyed by
# screen size in points (`WatchDisplayCorner.radiusByScreenSize`), and derives
# the `corners` safe-area inset from it. The numbers are Apple's own, from the
# `DeviceCornerRadius` key of each Simulator device type.
# `test/fixtures/watch_corner_radii.json` holds a copy that
# test/general/watchos_safe_area_test.dart compares with the Swift table. This
# script regenerates that fixture from the installed device types, so a new
# Xcode that adds a watch or changes a radius is noticed.
#
# Usage:
#   tool/safe_area/check_corner_table.sh [<device-types-root> [<fixture>]]
#     <device-types-root>  default: /Library/Developer/CoreSimulator/Profiles/DeviceTypes
#     <fixture>            default: test/fixtures/watch_corner_radii.json
#
# A device type is read when its profile.plist has a `modelIdentifier` that
# starts with `Watch`, and either no `maxRuntimeVersion` or one of at least
# 26.0, the lowest watchOS the CLI builds for. Its screen size in points is
# `main-screen-width` and `main-screen-height` over `main-screen-scale` from
# the `ScreenDimensionsCapability` of its capabilities.plist; its radius is
# `DeviceCornerRadius` from the same file.
#
# The regenerated fixture goes to stdout; what differs goes to stderr.
#
# Exit status:
#   0  the device types give exactly the fixture's table
#   1  a size or a radius differs, or a size is in only one of the two
#   2  bad usage, an unreadable file, or no watch device type to read
#   3  one screen size maps to two radii (the table cannot hold both)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROOT="${1:-/Library/Developer/CoreSimulator/Profiles/DeviceTypes}"
FIXTURE="${2:-$REPO_ROOT/test/fixtures/watch_corner_radii.json}"
MIN_RUNTIME=26.0

die() { echo "check_corner_table: error: $*" >&2; exit 2; }

[[ $# -le 2 ]] || die "usage: $0 [<device-types-root> [<fixture>]]"
[[ -d "$ROOT" ]] || die "no device-types directory at $ROOT"
[[ -f "$FIXTURE" ]] || die "no fixture at $FIXTURE"

# Prints the value at a plutil key path, or nothing when the key is missing.
plist_value() {
  plutil -extract "$2" raw -o - "$1" 2>/dev/null || true
}

# Exit 0 when version $1 is at least $2, comparing dot-separated numbers.
version_at_least() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    na = split(a, x, "."); nb = split(b, y, "."); n = (na > nb) ? na : nb
    for (i = 1; i <= n; i++) {
      xi = (i <= na) ? x[i] + 0 : 0; yi = (i <= nb) ? y[i] + 0 : 0
      if (xi > yi) exit 0
      if (xi < yi) exit 1
    }
    exit 0
  }'
}

# One "<size> <radius>\t<device type>" line per watch device type read.
entries=""
read_count=0
skipped_count=0
shopt -s nullglob
for type_dir in "$ROOT"/*.simdevicetype; do
  name="$(basename "$type_dir" .simdevicetype)"
  resources="$type_dir/Contents/Resources"
  profile="$resources/profile.plist"
  capabilities="$resources/capabilities.plist"
  [[ -f "$profile" ]] || continue
  model="$(plist_value "$profile" modelIdentifier)"
  [[ "$model" == Watch* ]] || continue

  max_runtime="$(plist_value "$profile" maxRuntimeVersion)"
  if [[ -n "$max_runtime" ]] && ! version_at_least "$max_runtime" "$MIN_RUNTIME"; then
    skipped_count=$((skipped_count + 1))
    continue
  fi

  [[ -f "$capabilities" ]] || die "$name: no capabilities.plist"
  dims=capabilities.ScreenDimensionsCapability
  width="$(plist_value "$capabilities" "$dims.main-screen-width")"
  height="$(plist_value "$capabilities" "$dims.main-screen-height")"
  scale="$(plist_value "$capabilities" "$dims.main-screen-scale")"
  radius="$(plist_value "$capabilities" capabilities.DeviceCornerRadius)"
  [[ -n "$width" && -n "$height" && -n "$scale" ]] ||
    die "$name: no ScreenDimensionsCapability width, height and scale"
  [[ -n "$radius" ]] || die "$name: no DeviceCornerRadius"

  line="$(awk -v w="$width" -v h="$height" -v s="$scale" -v r="$radius" \
    'BEGIN { printf "%gx%g %g", w / s, h / s, r }')"
  entries+="$line"$'\t'"$name"$'\n'
  read_count=$((read_count + 1))
done

[[ $read_count -gt 0 ]] || die "no watch device type with maxRuntimeVersion >= $MIN_RUNTIME under $ROOT"

# Sorted by width, then height; one line per distinct size and radius.
generated="$(printf '%s' "$entries" | cut -f1 | sort -t x -k1,1n -k2,2n | uniq)"

conflicts="$(printf '%s\n' "$generated" | awk '{ n[$1]++ } END { for (s in n) if (n[s] > 1) print s }')"
if [[ -n "$conflicts" ]]; then
  for size in $conflicts; do
    echo "check_corner_table: $size maps to more than one radius:" >&2
    printf '%s' "$entries" | awk -F '\t' -v s="$size" '{ split($1, f, " ") } f[1] == s { print "  " f[2] "  " $2 }' >&2
  done
  exit 3
fi

# The fixture, normalised the same way. `plutil -p` reads JSON and prints one
# `"<size>" => <radius>` line per entry.
fixture_dump="$(plutil -p "$FIXTURE" 2>/dev/null)" || die "cannot read $FIXTURE as JSON"
expected="$(printf '%s\n' "$fixture_dump" |
  awk -F '"' '/=>/ { split($3, v, "=> "); printf "%s %g\n", $2, v[2] + 0 }' |
  sort -t x -k1,1n -k2,2n | uniq)"

# The regenerated fixture.
printf '%s\n' "$generated" | awk '
  BEGIN { print "{" }
  { lines[NR] = sprintf("  \"%s\": %s", $1, $2) }
  END { for (i = 1; i <= NR; i++) print lines[i] (i < NR ? "," : ""); print "}" }'

if [[ "$generated" == "$expected" ]]; then
  count="$(printf '%s\n' "$generated" | wc -l | tr -d ' ')"
  echo "check_corner_table: OK: $read_count device types read, $skipped_count below $MIN_RUNTIME skipped; $count sizes match $FIXTURE" >&2
  exit 0
fi

echo "check_corner_table: the device types under $ROOT do not give the table in $FIXTURE:" >&2
join -a1 -a2 -e - -o 0,1.2,2.2 \
  <(printf '%s\n' "$generated" | sort -k1,1) \
  <(printf '%s\n' "$expected" | sort -k1,1) |
  awk '$2 != $3 { print "  " $1 ": Xcode " $2 ", fixture " $3 }' >&2
exit 1
