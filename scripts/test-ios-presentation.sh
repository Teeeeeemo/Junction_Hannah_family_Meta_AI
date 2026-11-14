#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/museum-tour-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
swiftc -module-cache-path "$test_dir/ModuleCache" \
  "$repo_root/native/ios/Sources/TourPresentation.swift" \
  "$repo_root/native/ios/Tests/TourPresentationTests.swift" \
  -o "$test_dir/tour-tests"
"$test_dir/tour-tests"
