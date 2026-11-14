#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
evidence_dir="${LIVE_AUDIO_EVIDENCE_DIR:-$repo_root/build/live-audio-check}"
mkdir -p "$evidence_dir"
evidence_dir="$(cd "$evidence_dir" && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/museum-live-audio.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
swiftc -module-cache-path "$test_dir/ModuleCache" \
  "$repo_root/scripts/test-ios-live-audio.swift" -o "$test_dir/live-audio-check" \
  > "$evidence_dir/build.log" 2>&1
"$test_dir/live-audio-check" 2>&1 | tee "$evidence_dir/render.log"
echo "Audio evidence: $evidence_dir"
