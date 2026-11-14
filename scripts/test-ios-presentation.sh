#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/museum-tour-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
swiftc -module-cache-path "$test_dir/ModuleCache" \
  "$repo_root/native/ios/Sources/TourPresentation.swift" \
  "$repo_root/native/ios/Sources/DebugInputMode.swift" \
  "$repo_root/native/ios/Sources/MuseumBackend.swift" \
  "$repo_root/native/ios/Sources/DebugGuide.swift" \
  "$repo_root/native/ios/Tests/TourPresentationTests.swift" \
  -o "$test_dir/tour-tests"
"$test_dir/tour-tests"
swiftc -module-cache-path "$test_dir/ModuleCache" \
  "$repo_root/native/ios/Sources/SessionEpoch.swift" \
  "$repo_root/native/ios/Tests/SessionEpochTests.swift" \
  -o "$test_dir/session-tests"
"$test_dir/session-tests"
swiftc -module-cache-path "$test_dir/ModuleCache" \
  "$repo_root/native/ios/Sources/MuseumBackend.swift" \
  "$repo_root/native/ios/Sources/MuseumDetailRegistry.swift" \
  "$repo_root/native/ios/Tests/MuseumDetailRegistryTests.swift" \
  -o "$test_dir/detail-registry-tests"
"$test_dir/detail-registry-tests"
