#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/museum-tracker-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
swiftc -module-cache-path "$test_dir/ModuleCache" \
  "$repo_root/native/ios/Sources/ArtworkTracker.swift" \
  "$repo_root/native/ios/Tests/ArtworkTrackerTests.swift" \
  -o "$test_dir/tracker-tests"
"$test_dir/tracker-tests"
