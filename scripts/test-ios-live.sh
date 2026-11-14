#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/museum-live-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
swiftc -module-cache-path "$test_dir/ModuleCache" \
  "$repo_root/native/ios/Sources/LiveProtocol.swift" \
  "$repo_root/native/ios/Tests/LiveProtocolTests.swift" -o "$test_dir/live-tests"
"$test_dir/live-tests"
