#!/usr/bin/env bash
# Copyright 2026 The FlutterWatch Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# Lists the commits in a range that change what ships without changing a
# test.
#
# Every change to behaviour comes with a test. A commit that touches lib/,
# bin/ (the pins in bin/internal/*.version included), host/ or templates/
# and nothing under test/ is either exempt (a comment, a message, a repin
# the end-to-end run covers) or missing its test. This script cannot tell
# which, so it lists each such commit for a reviewer to decide. Run it on
# every rewrite of a release branch.
#
# Usage:
#   tool/check_untested_commits.sh <revision range>
#   tool/check_untested_commits.sh --self-test
#
# The range is anything `git rev-list` takes, for example `main..HEAD` or
# `8fe2c4d^..714fac9`. Merge commits are skipped: their changes are listed
# with the commits they merge.
#
# Prints one line per commit: its short hash, its subject, and the shipped
# paths it changes. Exits 0 when it lists nothing, 1 when it lists a commit,
# and 2 on a usage or git error.

set -euo pipefail

# The paths whose changes ship, and the one that holds the tests. Paths are
# from the repository root.
shipped_paths=(lib bin host templates)
test_path=test

list_untested_commits() {
  local range="$1"
  local commits
  if ! commits="$(git rev-list --reverse --no-merges "$range" --)"; then
    echo "error: git rev-list could not read the range '$range'." >&2
    return 2
  fi
  local listed=0 commit shipped
  for commit in $commits; do
    shipped="$(git diff-tree --root --no-commit-id --name-only -r "$commit" -- "${shipped_paths[@]}")"
    if [[ -z "$shipped" ]]; then
      continue
    fi
    if [[ -n "$(git diff-tree --root --no-commit-id --name-only -r "$commit" -- "$test_path")" ]]; then
      continue
    fi
    listed=$((listed + 1))
    git log -1 --format='%h %s' "$commit"
    echo "$shipped" | sed 's/^/    /'
  done
  if ((listed == 0)); then
    echo "No commit in $range changes lib/, bin/, host/ or templates/ without a test."
    return 0
  fi
  echo "$listed commit(s) in $range change what ships without a change under test/."
  return 1
}

# Builds a scratch repository with one commit of each kind and checks that
# exactly the right ones are listed.
self_test() {
  self_test_dir="$(mktemp -d)"
  trap 'rm -rf "$self_test_dir"' EXIT
  (
    cd "$self_test_dir"
    git init -q
    git config user.name 'Self Test'
    git config user.email 'self-test@example.com'
    git config commit.gpgsign false
    commit() { # <subject> <file>...
      local subject="$1"
      shift
      local file
      for file in "$@"; do
        mkdir -p "$(dirname "$file")"
        echo "$subject" >> "$file"
      done
      git add -A
      git commit -q -m "$subject"
    }
    commit 'base' README.md
    local base
    base="$(git rev-parse HEAD)"
    commit 'lib change with its test' lib/a.dart test/general/a_test.dart
    commit 'lib change alone' lib/a.dart
    commit 'bin script alone' bin/flutter-watchos
    commit 'repin alone' bin/internal/engine.version
    commit 'host change alone' host/FlutterRunner.swift
    commit 'template change alone' templates/app/Runner/App.swift.tmpl
    commit 'docs alone' README.md doc/get-started.md
    commit 'test alone' test/general/b_test.dart
    commit 'host change with a test data file' host/FlutterHostView.swift test/data/x.json
    commit 'package change alone' packages/flutter_watchos/lib/src/crown.dart
    commit 'a library in a nested lib alone' tool/lib/helper.dart
    git checkout -q -b side
    commit 'lib change on a side branch' lib/b.dart
    git checkout -q -
    git merge -q --no-ff -m 'merge side' side

    local output status=0
    output="$(list_untested_commits "$base..HEAD")" || status=$?
    local subjects
    subjects="$(echo "$output" | grep -v '^    ' | sed -E 's/^[0-9a-f]+ //' | sed '$d')"
    local expected
    expected="$(printf '%s\n' \
      'lib change alone' \
      'bin script alone' \
      'repin alone' \
      'host change alone' \
      'template change alone' \
      'lib change on a side branch')"
    if [[ "$subjects" != "$expected" || "$status" != 1 ]]; then
      echo "self-test FAILED: exit $status, listed:"
      echo "$output"
      exit 1
    fi
    if ! echo "$output" | grep -qx '    bin/internal/engine.version'; then
      echo "self-test FAILED: the repin's path is not shown:"
      echo "$output"
      exit 1
    fi

    status=0
    output="$(list_untested_commits "$base..$base")" || status=$?
    if [[ "$status" != 0 ]]; then
      echo "self-test FAILED: an empty range exits $status:"
      echo "$output"
      exit 1
    fi

    status=0
    output="$(list_untested_commits 'no-such-revision..HEAD' 2> /dev/null)" || status=$?
    if [[ "$status" != 2 ]]; then
      echo "self-test FAILED: a bad range exits $status, not 2."
      exit 1
    fi
  )
  echo 'self-test passed'
}

main() {
  if [[ $# -ne 1 ]]; then
    echo 'usage: tool/check_untested_commits.sh <revision range> | --self-test' >&2
    exit 2
  fi
  if [[ "$1" == '--self-test' ]]; then
    self_test
    return
  fi
  local top
  if ! top="$(git rev-parse --show-toplevel)"; then
    exit 2
  fi
  cd "$top"
  local status=0
  list_untested_commits "$1" || status=$?
  exit "$status"
}

main "$@"
