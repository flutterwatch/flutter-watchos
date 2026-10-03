#!/usr/bin/env bash
# Copyright 2026 The FlutterWatch Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# The safe-area matrix: builds an app once per safe-area setting, runs every
# build on Simulators this script creates for the run and deletes afterwards,
# and checks the first SAFEAREA| line of every launch with check_insets.sh.
#
# Usage:
#   tool/safe_area/run_matrix.sh --work <dir> --out <dir> [options]
#
#   --work <dir>       scratch space. The run makes its own directory in it and
#                      deletes that, with every build output, when it ends.
#   --out <dir>        where the logs, screenshots and summary.txt go
#   --cli <path>       the flutter-watchos that builds
#                      (default: this repo's bin/flutter-watchos)
#   --app <kind>       probe:   tool/safe_area/saprobe (the default);
#                      created: a fresh `create --platforms=watchos` app, left
#                               as create wrote it and built through
#                               safe_area_log/main.dart;
#                      native:  the native SwiftUI probe in native/. Its NPROBE|
#                               lines are kept, not checked.
#   --devices <list>   comma-separated device types, as named after
#                      com.apple.CoreSimulator.SimDeviceType. (default: one per
#                      screen size, see DEFAULT_DEVICES)
#   --runtime <id>     the Simulator runtime
#                      (default: com.apple.CoreSimulator.SimRuntime.watchOS-27-0)
#   --settings <list>  comma-separated FlutterWatchOSSafeArea values, one build
#                      each; `none` builds without the key (default: none,platform)
#   --default-mode <m> the mode a build without the key gets, which is the
#                      default of the host that builds it: corners (the default)
#                      or platform, for a CLI from before corners was the default
#   --scale <x>        FlutterWatchOSContentScale for every build (default: unset)
#   --pages <list>     probe pages to launch (default: 0,3,4,5); a created app
#                      has one, the native probe's default is 0,1,2,3,4
#   --min-gib <n>      stop before a build or a new Simulator when `df -g /System/Volumes/Data`
#                      shows less than this available (default: 15)
#
# Each build is labelled with --dart-define=MODE=platform or MODE=corners, the
# mode its host reports for its setting, and check_insets.sh holds the line
# to that label. The environment reaches the CLI, so WATCHOS_ENGINE_ARTIFACTS
# picks the engine; the run sets FLUTTER_WATCHOS_BUILD_REGISTRY=0 and builds
# with --no-register-build, because a measurement build is not one to record.
# The probe and the created app get their settings through files in the app's
# data container (Documents/saprobe_PAGE.txt, saprobe_DEV.txt): Dart's
# Platform.environment is empty under this embedder.
#
# Exit status: 0 when every launch passes check_insets.sh; 1 when one does not;
# 2 on bad usage; 3 when a build or a Simulator step fails, or disk is short.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOL_DIR="$REPO_ROOT/tool/safe_area"
FIXTURE="$TOOL_DIR/fixtures/watch_safe_area_insets.json"
CORNERS="$REPO_ROOT/test/fixtures/watch_corner_radii.json"

# One device type per screen size, all on watchOS 27.0.
DEFAULT_DEVICES="Apple-Watch-SE-3-40mm,Apple-Watch-Series-9-41mm,Apple-Watch-SE-3-44mm"
DEFAULT_DEVICES+=",Apple-Watch-Series-10-42mm,Apple-Watch-Series-9-45mm,Apple-Watch-Ultra-2-49mm"
DEFAULT_DEVICES+=",Apple-Watch-Series-12-46mm,Apple-Watch-Ultra-3-49mm"

WORK=""
OUT=""
CLI="$REPO_ROOT/bin/flutter-watchos"
APP=probe
DEVICES="$DEFAULT_DEVICES"
RUNTIME=com.apple.CoreSimulator.SimRuntime.watchOS-27-0
SETTINGS=none,platform
DEFAULT_MODE=corners
SCALE=""
PAGES=""
MIN_GIB=15

usage() { echo "run_matrix: error: $*" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --work) WORK="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --cli) CLI="${2:-}"; shift 2 ;;
    --app) APP="${2:-}"; shift 2 ;;
    --devices) DEVICES="${2:-}"; shift 2 ;;
    --runtime) RUNTIME="${2:-}"; shift 2 ;;
    --settings) SETTINGS="${2:-}"; shift 2 ;;
    --default-mode) DEFAULT_MODE="${2:-}"; shift 2 ;;
    --scale) SCALE="${2:-}"; shift 2 ;;
    --pages) PAGES="${2:-}"; shift 2 ;;
    --min-gib) MIN_GIB="${2:-}"; shift 2 ;;
    *) usage "unknown argument: $1 (see the comment at the top of $0)" ;;
  esac
done

[[ -n "$WORK" && -d "$WORK" ]] || usage "--work must name an existing directory"
[[ -n "$OUT" ]] || usage "--out is required"
[[ "$APP" == probe || "$APP" == created || "$APP" == native ]] || usage "--app is probe, created or native"
[[ "$DEFAULT_MODE" == corners || "$DEFAULT_MODE" == platform ]] || usage "--default-mode is corners or platform"
[[ "$MIN_GIB" =~ ^[0-9]+$ ]] || usage "--min-gib takes a whole number"
[[ -z "$SCALE" || "$SCALE" =~ ^[0-9.]+$ ]] || usage "--scale takes a number"
[[ "$APP" == native || -x "$CLI" ]] || usage "no flutter-watchos at $CLI"
if [[ -z "$PAGES" ]]; then
  case "$APP" in
    probe) PAGES=0,3,4,5 ;;
    created) PAGES=app ;;
    native) PAGES=0,1,2,3,4 ;;
  esac
fi
[[ "$APP" != native ]] || SETTINGS=none

IFS=',' read -r -a DEVICE_LIST <<< "$DEVICES"
IFS=',' read -r -a SETTING_LIST <<< "$SETTINGS"
IFS=',' read -r -a PAGE_LIST <<< "$PAGES"
# watchOS-26-5 -> 26.5, for a fixture entry's per-runtime values.
RUNTIME_VERSION="$(printf '%s' "${RUNTIME##*watchOS-}" | tr '-' '.')"

mkdir -p "$OUT/logs" "$OUT/shots" || usage "cannot write to $OUT"
RUN="$(mktemp -d "$WORK/safe_area_run.XXXXXX")" || usage "cannot write to $WORK"
RUN="$(cd -P "$RUN" && pwd)"
SUMMARY="$OUT/summary.txt"
CREATED_SIMS=()
LABELS=()
BUNDLE_IDS=()
launches=0
failures=0

log() { echo "$(date +%T) $*" | tee -a "$SUMMARY" >&2; }
die() { log "stop: $*"; exit 3; }

# Deletes the Xcode DerivedData of projects inside this run's directory, and
# nothing else: `flutter-watchos build` leaves xcodebuild's intermediates in
# the default DerivedData, one folder per project path.
delete_derived_data() {
  local root="$HOME/Library/Developer/Xcode/DerivedData" dir workspace
  [[ -d "$root" ]] || return 0
  for dir in "$root"/*/; do
    [[ -f "$dir/info.plist" ]] || continue
    workspace="$(plutil -extract WorkspacePath raw -o - "$dir/info.plist" 2>/dev/null || true)"
    case "$workspace" in
      "$RUN"/* | "/private$RUN"/* | "${RUN#/private}"/*)
        rm -rf "$dir" && log "deleted DerivedData ${dir%/}" ;;
    esac
  done
}

cleanup() {
  local udid
  for udid in ${CREATED_SIMS[@]+"${CREATED_SIMS[@]}"}; do
    xcrun simctl shutdown "$udid" >/dev/null 2>&1
    xcrun simctl delete "$udid" >/dev/null 2>&1 && log "deleted simulator $udid"
  done
  delete_derived_data
  rm -rf "$RUN"
}
trap cleanup EXIT

check_disk() {
  local avail
  avail="$(df -g /System/Volumes/Data | awk 'NR == 2 { print $4 }')"
  log "disk avail=${avail}GiB (stops below ${MIN_GIB})"
  [[ "$avail" =~ ^[0-9]+$ && "$avail" -ge "$MIN_GIB" ]] || die "less than ${MIN_GIB} GiB available"
}

# The mode a build with this FlutterWatchOSSafeArea setting reports: only
# `platform`, in any letter case, selects watchOS's insets on a corners-default
# host; only `corners` selects the corner inset on a platform-default one.
label_for() {
  local lower
  lower="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  if [[ "$1" == none ]]; then
    echo "$DEFAULT_MODE"
  elif [[ "$DEFAULT_MODE" == corners ]]; then
    [[ "$lower" == platform ]] && echo platform || echo corners
  else
    [[ "$lower" == corners ]] && echo corners || echo platform
  fi
}

prepare_flutter_app() {
  case "$APP" in
    probe)
      rsync -a --exclude .dart_tool --exclude build --exclude watchos "$TOOL_DIR/saprobe/" "$RUN/app/" ||
        die "cannot copy the probe"
      # The copy lives elsewhere: point its package dependency at this repo.
      sed -i '' "s#path: ../../../packages/flutter_watchos#path: $REPO_ROOT/packages/flutter_watchos#" \
        "$RUN/app/pubspec.yaml"
      (cd "$RUN/app" && "$CLI" create --platforms=watchos --org dev.fwprobe .) >> "$OUT/logs/create.log" 2>&1 ||
        die "create --platforms=watchos failed in the probe copy, see $OUT/logs/create.log"
      ;;
    created)
      (cd "$RUN" && "$CLI" create --platforms=watchos --org dev.fwprobe --project-name safe_area_app app) \
        >> "$OUT/logs/create.log" 2>&1 || die "create --platforms=watchos failed, see $OUT/logs/create.log"
      mkdir -p "$RUN/app/safe_area_log"
      cp "$TOOL_DIR/safe_area_log/main.dart" "$RUN/app/safe_area_log/main.dart"
      ;;
  esac
  (cd "$RUN/app" && "$CLI" pub get --offline) >> "$OUT/logs/create.log" 2>&1 ||
    die "pub get --offline failed, see $OUT/logs/create.log"
}

# Builds setting number $1 into $RUN/apps/$1.app and deletes the build outputs.
build_flutter_app() {
  local index="$1" setting="${SETTING_LIST[$1]}" label plist="$RUN/app/watchos/Runner/Info.plist"
  local target=() built="$RUN/app/build/watchos/Debug-watchsimulator/Runner.app"
  label="$(label_for "$setting")"
  plutil -remove FlutterWatchOSSafeArea "$plist" >/dev/null 2>&1
  if [[ "$setting" != none ]]; then
    plutil -insert FlutterWatchOSSafeArea -string "$setting" "$plist" || die "cannot set the key in $plist"
  fi
  if [[ -n "$SCALE" ]]; then
    plutil -remove FlutterWatchOSContentScale "$plist" >/dev/null 2>&1
    plutil -insert FlutterWatchOSContentScale -real "$SCALE" "$plist" || die "cannot set the scale in $plist"
  fi
  [[ "$APP" != created ]] || target=(-t safe_area_log/main.dart)
  check_disk
  log "build $APP #$index setting=$setting label=$label${SCALE:+ scale=$SCALE}"
  (cd "$RUN/app" && FLUTTER_WATCHOS_BUILD_REGISTRY=0 "$CLI" build watchos --simulator --no-register-build \
    ${target[@]+"${target[@]}"} "--dart-define=MODE=$label") > "$OUT/logs/build-$APP-$index.log" 2>&1 ||
    die "build #$index failed, see $OUT/logs/build-$APP-$index.log"
  [[ -d "$built" ]] || die "build #$index made no $built"
  mkdir -p "$RUN/apps"
  ditto "$built" "$RUN/apps/$index.app"
  LABELS[$index]="$label"
  BUNDLE_IDS[$index]="$(plutil -extract CFBundleIdentifier raw -o - "$built/Info.plist")"
  rm -rf "$RUN/app/build"
  delete_derived_data
}

build_native_app() {
  check_disk
  log "build native probe"
  xcodebuild -project "$TOOL_DIR/native/NativeProbe.xcodeproj" -scheme NativeProbe -configuration Debug \
    -sdk watchsimulator -destination 'generic/platform=watchOS Simulator' -derivedDataPath "$RUN/native" \
    build > "$OUT/logs/build-native.log" 2>&1 ||
    die "native build failed, see $OUT/logs/build-native.log"
  mkdir -p "$RUN/apps"
  ditto "$RUN/native/Build/Products/Debug-watchsimulator/NativeProbe.app" "$RUN/apps/0.app"
  rm -rf "$RUN/native"
  LABELS[0]=native
  BUNDLE_IDS[0]="$(plutil -extract CFBundleIdentifier raw -o - "$RUN/apps/0.app/Info.plist")"
}

# Writes $4 to Documents/$3 in the data container of app $2 on simulator $1.
set_file() {
  local data
  data="$(xcrun simctl get_app_container "$1" "$2" data)" || die "no data container for $2"
  mkdir -p "$data/Documents" && printf '%s' "$4" > "$data/Documents/$3"
}

run_device() {
  local type="$1" udid index page stem start first prefix process tag
  if [[ "$APP" == native ]]; then prefix=nprobe; process=NativeProbe; tag=NPROBE; else
    prefix=saprobe; process=Runner; tag=SAFEAREA; fi
  # A new Simulator takes disk too: the same floor as a build.
  check_disk
  udid="$(xcrun simctl create "fw-safe-area $type" "com.apple.CoreSimulator.SimDeviceType.$type" "$RUNTIME")" ||
    die "cannot create $type on $RUNTIME"
  CREATED_SIMS+=("$udid")
  log "created $type $udid on $RUNTIME"
  xcrun simctl boot "$udid" || die "cannot boot $udid"
  xcrun simctl bootstatus "$udid" -b > /dev/null || die "$udid did not finish booting"
  sleep 5
  for index in "${!SETTING_LIST[@]}"; do
    xcrun simctl install "$udid" "$RUN/apps/$index.app" || die "cannot install on $udid"
    set_file "$udid" "${BUNDLE_IDS[$index]}" "${prefix}_DEV.txt" "$type"
    first=1
    for page in "${PAGE_LIST[@]}"; do
      [[ "$page" == app ]] || set_file "$udid" "${BUNDLE_IDS[$index]}" "${prefix}_PAGE.txt" "$page"
      xcrun simctl terminate "$udid" "${BUNDLE_IDS[$index]}" > /dev/null 2>&1
      sleep 1
      start="$(date '+%Y-%m-%d %H:%M:%S')"
      xcrun simctl launch "$udid" "${BUNDLE_IDS[$index]}" > /dev/null || die "cannot launch on $udid"
      if [[ "$first" == 1 ]]; then sleep 14; first=0; else sleep 7; fi
      stem="$type.$APP.$index-${SETTING_LIST[$index]}.p$page"
      xcrun simctl io "$udid" screenshot --mask=black "$OUT/shots/$stem.png" > /dev/null 2>&1
      xcrun simctl spawn "$udid" log show --start "$start" --style compact \
        --predicate "process == \"$process\"" > "$RUN/oslog.txt" 2>&1
      grep -a -o "$tag|.*" "$RUN/oslog.txt" > "$OUT/logs/$stem.txt"
      launches=$((launches + 1))
      if [[ "$APP" == native ]]; then
        log "kept $stem ($(wc -l < "$OUT/logs/$stem.txt" | tr -d ' ') lines)"
      elif "$TOOL_DIR/check_insets.sh" "$OUT/logs/$stem.txt" "$FIXTURE" "$CORNERS" "$RUNTIME_VERSION" \
        > "$OUT/logs/$stem.check.txt" 2>&1; then
        log "PASS $stem label=${LABELS[$index]}: $(tail -1 "$OUT/logs/$stem.check.txt")"
      else
        failures=$((failures + 1))
        log "FAIL $stem label=${LABELS[$index]}: $(tail -1 "$OUT/logs/$stem.check.txt")"
      fi
    done
    xcrun simctl terminate "$udid" "${BUNDLE_IDS[$index]}" > /dev/null 2>&1
    xcrun simctl uninstall "$udid" "${BUNDLE_IDS[$index]}" > /dev/null 2>&1
  done
  xcrun simctl shutdown "$udid" > /dev/null 2>&1
  xcrun simctl delete "$udid" && log "deleted simulator $udid"
  local kept=() u
  for u in "${CREATED_SIMS[@]}"; do [[ "$u" == "$udid" ]] || kept+=("$u"); done
  CREATED_SIMS=(${kept[@]+"${kept[@]}"})
}

log "run_matrix: app=$APP devices=$DEVICES runtime=$RUNTIME settings=$SETTINGS default-mode=$DEFAULT_MODE${SCALE:+ scale=$SCALE} pages=$PAGES"
if [[ "$APP" == native ]]; then
  build_native_app
else
  log "cli=$CLI ($(git -C "$(dirname "$CLI")/.." rev-parse --short HEAD 2>/dev/null || echo '?'))"
  prepare_flutter_app
  for index in "${!SETTING_LIST[@]}"; do
    build_flutter_app "$index"
  done
fi
for type in "${DEVICE_LIST[@]}"; do
  run_device "$type"
done
log "run_matrix: $launches launches, $failures failed"
[[ "$failures" -eq 0 ]]
