#!/bin/bash
set -euo pipefail

# Requires full Xcode on this Mac. Creates and deletes only its own simulator.
# An explicit SIMULATOR_UDID reuses a caller-owned test simulator and keeps it.
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
output_dir="${IOS_UI_TEST_DIR:-$repo_root/build/ios/ui-tests/$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
owns_simulator=false
simulator_id="${SIMULATOR_UDID:-}"
cleanup() {
  if $owns_simulator; then
    xcrun simctl shutdown "$simulator_id" >/dev/null 2>&1 || true
    xcrun simctl delete "$simulator_id" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
if [[ -z "$simulator_id" ]]; then
  runtime="$(xcrun simctl list runtimes --json | python3 -c '
import json,sys
r=[x for x in json.load(sys.stdin)["runtimes"] if x.get("isAvailable") and ".iOS-" in x["identifier"]]
if not r: sys.exit("Install an iOS Simulator runtime through Xcode first.")
print(max(r,key=lambda x:tuple(map(int,x["version"].split("."))))["identifier"])
')"
  simulator_id="$(xcrun simctl create "Museum UI Tests $(date +%H%M%S)" com.apple.CoreSimulator.SimDeviceType.iPhone-15-Pro "$runtime")"
  owns_simulator=true
  xcrun simctl boot "$simulator_id"
fi
printf '%s\n' "$simulator_id" > "$output_dir/simulator-udid.txt"
xcrun simctl bootstatus "$simulator_id" -b > "$output_dir/boot.log" 2>&1
common=(-project "$repo_root/native/ios/MuseumCompanion.xcodeproj" -scheme MuseumCompanion
  -destination "platform=iOS Simulator,id=$simulator_id" -derivedDataPath "$output_dir/DerivedData"
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO ONLY_ACTIVE_ARCH=YES)
if ! xcodebuild "${common[@]}" build-for-testing > "$output_dir/build.log" 2>&1; then
  tail -60 "$output_dir/build.log"; exit 1
fi
xcrun simctl install "$simulator_id" "$output_dir/DerivedData/Build/Products/Debug-iphonesimulator/MuseumCompanion.app"
swift "$repo_root/scripts/make-ios-test-video.swift" "$output_dir/museum-ui-fixture.mp4" > "$output_dir/video.log" 2>&1
container="$(xcrun simctl get_app_container "$simulator_id" com.muse.museumcompanion data)"
mkdir -p "$container/Documents"
cp "$output_dir/museum-ui-fixture.mp4" "$container/Documents/"
touch "$container/Documents/museum-ui-empty.mp4"
result=0
xcodebuild "${common[@]}" test-without-building -resultBundlePath "$output_dir/UITests.xcresult" > "$output_dir/test.log" 2>&1 || result=$?
xcrun xcresulttool export attachments --path "$output_dir/UITests.xcresult" --output-path "$output_dir/attachments" > "$output_dir/export.log" 2>&1 || true
tail -22 "$output_dir/test.log"
printf '\nUI test evidence: %s\n' "$output_dir"
exit "$result"
