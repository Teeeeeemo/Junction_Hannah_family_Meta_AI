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
git -C "$repo_root" rev-parse HEAD > "$output_dir/source-commit.txt"
git -C "$repo_root" diff --stat > "$output_dir/source-changes.txt"
xcodebuild -version > "$output_dir/xcode-version.txt"
git -C "$repo_root" diff --binary HEAD > "$output_dir/source.patch"
python3 - "$repo_root" "$output_dir" <<'PY'
import hashlib, json, pathlib, subprocess, sys
root, output = map(pathlib.Path, sys.argv[1:])
names = subprocess.check_output(["git", "-C", str(root), "ls-files", "-c", "-o", "--exclude-standard", "-z"]).decode().split("\0")
manifest = {name: hashlib.sha256((root / name).read_bytes()).hexdigest()
            for name in sorted(set(names)) if name and (root / name).is_file()}
serialized = json.dumps(manifest, sort_keys=True, indent=2) + "\n"
(output / "source-manifest.json").write_text(serialized)
(output / "source-tree-sha256.txt").write_text(hashlib.sha256(serialized.encode()).hexdigest() + "\n")
PY
xcrun simctl bootstatus "$simulator_id" -b > "$output_dir/boot.log" 2>&1
common=(-project "$repo_root/native/ios/MuseumCompanion.xcodeproj" -scheme MuseumCompanion
  -destination "platform=iOS Simulator,id=$simulator_id" -derivedDataPath "${IOS_UI_DERIVED_DATA:-$output_dir/DerivedData}"
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO ONLY_ACTIVE_ARCH=YES)
if ! xcodebuild "${common[@]}" build-for-testing > "$output_dir/build.log" 2>&1; then
  tail -60 "$output_dir/build.log"; exit 1
fi
xcrun simctl install "$simulator_id" "${IOS_UI_DERIVED_DATA:-$output_dir/DerivedData}/Build/Products/Debug-iphonesimulator/MuseumCompanion.app"
swift "$repo_root/scripts/make-ios-test-video.swift" "$output_dir/museum-ui-fixture.mp4" "${IOS_UI_VIDEO_SECONDS:-240}" > "$output_dir/video.log" 2>&1
printf '%s\n' "${IOS_UI_VIDEO_SECONDS:-240}" > "$output_dir/video-duration-seconds.txt"
container="$(xcrun simctl get_app_container "$simulator_id" com.muse.museumcompanion data)"
mkdir -p "$container/Documents"
cp "$output_dir/museum-ui-fixture.mp4" "$container/Documents/"
touch "$container/Documents/museum-ui-empty.mp4"
result=0
# Optional focused rerun; the default always executes the complete suite.
# Example: IOS_UI_TEST_ONLY=MuseumCompanionUITests/DebugInputUITests/testNativeHUDAndAutomaticTour
if [[ -n "${IOS_UI_TEST_ONLY:-}" ]]; then
  common+=("-only-testing:$IOS_UI_TEST_ONLY")
  printf '%s\n' "$IOS_UI_TEST_ONLY" > "$output_dir/test-selection.txt"
fi
xcodebuild "${common[@]}" test-without-building -resultBundlePath "$output_dir/UITests.xcresult" > "$output_dir/test.log" 2>&1 || result=$?
xcrun xcresulttool export attachments --path "$output_dir/UITests.xcresult" --output-path "$output_dir/attachments" > "$output_dir/export.log" 2>&1 || true
xcrun xcresulttool get test-results summary --path "$output_dir/UITests.xcresult" > "$output_dir/test-summary.json" 2> "$output_dir/summary-export.log" || true
python3 - "$output_dir" <<'PY'
import json, pathlib, re, shutil, sys
output = pathlib.Path(sys.argv[1])
manifest = output / "attachments/manifest.json"
if manifest.exists():
    evidence = output / "evidence"
    evidence.mkdir(exist_ok=True)
    for test in json.loads(manifest.read_text()):
        name = test["testIdentifier"].split("/")[-1].removesuffix("()")
        for item in test["attachments"]:
            source = output / "attachments" / item["exportedFileName"]
            label = item["suggestedHumanReadableName"].split("_0_")[0]
            if source.suffix == ".png" or (source.suffix == ".txt" and "accessibility tree" in label.lower()):
                label = re.sub(r"[^\w .-]", "_", label)
                shutil.copy2(source, evidence / (name + "__" + label + source.suffix))
PY
printf '%s\n' "$result" > "$output_dir/test-exit-code.txt"
tail -22 "$output_dir/test.log"
printf '\nUI test evidence: %s\n' "$output_dir"
exit "$result"
