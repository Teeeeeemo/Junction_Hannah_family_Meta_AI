#!/usr/bin/env bash
set -euo pipefail
# Explicit paid integration run. Isolated simulator and private temporary CA;
# no host Keychain changes, microphone capture, or physical-device assertions.
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
output_dir="${IOS_CLOUD_TEST_DIR:-$repo_root/../build-artifacts/ios-cloud-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
simulator_id=""
backend_pid=""
cleanup() {
  if [[ -n "$backend_pid" ]]; then kill "$backend_pid" 2>/dev/null || true; wait "$backend_pid" 2>/dev/null || true; fi
  if [[ -n "$simulator_id" ]]; then
    xcrun simctl shutdown "$simulator_id" >/dev/null 2>&1 || true
    xcrun simctl delete "$simulator_id" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
snapshot="$output_dir/source"
mkdir -p "$snapshot"
rsync -a --exclude .git --exclude node_modules --exclude build --exclude dist --exclude '.env*' "$repo_root/" "$snapshot/"
ln -s "$repo_root/node_modules" "$snapshot/node_modules"
ln -s "$repo_root/dist" "$snapshot/dist"
git -C "$repo_root" rev-parse HEAD > "$output_dir/source-commit.txt"
git -C "$repo_root" diff --binary HEAD > "$output_dir/source.patch"
xcodebuild -version > "$output_dir/xcode-version.txt"
runtime="$(xcrun simctl list runtimes --json | python3 -c 'import json,sys; r=[x for x in json.load(sys.stdin)["runtimes"] if x.get("isAvailable") and ".iOS-" in x["identifier"]]; print(max(r,key=lambda x:tuple(map(int,x["version"].split("."))))["identifier"])')"
simulator_id="$(xcrun simctl create "Museum Cloud Acceptance $(date +%H%M%S)" com.apple.CoreSimulator.SimDeviceType.iPhone-15-Pro "$runtime")"
printf '%s\n' "$simulator_id" > "$output_dir/simulator-udid.txt"
xcrun simctl boot "$simulator_id"
xcrun simctl bootstatus "$simulator_id" -b > "$output_dir/boot.log" 2>&1
cat > "$output_dir/localhost.cnf" <<'EOF'
[req]
distinguished_name=dn
x509_extensions=extensions
prompt=no
[dn]
CN=Museum isolated simulator localhost
[extensions]
basicConstraints=critical,CA:TRUE
keyUsage=critical,keyCertSign,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:localhost,IP:127.0.0.1
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -config "$output_dir/localhost.cnf" -keyout "$output_dir/localhost.key" -out "$output_dir/localhost.crt" > "$output_dir/certificate.log" 2>&1
chmod 600 "$output_dir/localhost.key"
xcrun simctl keychain "$simulator_id" add-root-cert "$output_dir/localhost.crt" > "$output_dir/simulator-trust.log" 2>&1
cd "$repo_root"
node --import tsx "$snapshot/scripts/serve-ios-test-backend.ts" "$output_dir" > "$output_dir/backend.log" 2>&1 &
backend_pid=$!
for attempt in {1..100}; do
  [[ -f "$output_dir/backend-ready.json" ]] && break
  kill -0 "$backend_pid" 2>/dev/null || { echo 'Cloud test backend failed; inspect private evidence logs.'; exit 1; }
  sleep 0.1
done
[[ -f "$output_dir/backend-ready.json" ]]
common=(-project "$snapshot/native/ios/MuseumCompanion.xcodeproj" -scheme MuseumCompanion -destination "platform=iOS Simulator,id=$simulator_id" -derivedDataPath "$output_dir/DerivedData" -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO ONLY_ACTIVE_ARCH=YES)
if ! xcodebuild "${common[@]}" build-for-testing > "$output_dir/build.log" 2>&1; then tail -50 "$output_dir/build.log"; exit 1; fi
xcrun simctl install "$simulator_id" "$output_dir/DerivedData/Build/Products/Debug-iphonesimulator/MuseumCompanion.app"
# Cover bounded re-identification and both question turns without an artificial
# 240-second end-of-file interruption. Frame timing and codec are unchanged.
video_seconds="${IOS_CLOUD_VIDEO_SECONDS:-600}"
printf '%s\n' "$video_seconds" > "$output_dir/video-duration-seconds.txt"
swift "$snapshot/scripts/make-ios-artwork-video.swift" "$snapshot/public/artworks/wheat-field.jpg" "$output_dir/museum-cloud-artwork.mp4" "$video_seconds" > "$output_dir/video.log" 2>&1
container="$(xcrun simctl get_app_container "$simulator_id" com.muse.museumcompanion data)"
mkdir -p "$container/Documents"
cp "$output_dir/museum-cloud-artwork.mp4" "$container/Documents/"
cp "$output_dir/museum-cloud-entrance.json" "$container/Documents/"
python3 - "$output_dir/DerivedData/Build/Products" <<'PY'
import pathlib, plistlib, sys
count=0
def inject(value):
    global count
    if isinstance(value,dict):
        if value.get('IsUITestBundle') or value.get('BlueprintName') == 'MuseumCompanionUITests':
            value.setdefault('EnvironmentVariables',{})['MUSE_CLOUD_TEST']='1'
            count += 1
        else:
            for child in value.values(): inject(child)
    elif isinstance(value,list):
        for child in value: inject(child)
for path in pathlib.Path(sys.argv[1]).glob('*.xctestrun'):
    data=plistlib.loads(path.read_bytes())
    inject(data)
    path.write_bytes(plistlib.dumps(data))
if count != 1: raise SystemExit(f'Expected exactly one opt-in UI test target, found {count}')
PY
xctestrun="$(find "$output_dir/DerivedData/Build/Products" -maxdepth 1 -name '*.xctestrun' -print -quit)"
result=0
xcodebuild -xctestrun "$xctestrun" -destination "platform=iOS Simulator,id=$simulator_id" -parallel-testing-enabled NO -only-testing:MuseumCompanionUITests/CloudIntegrationUITests test-without-building -resultBundlePath "$output_dir/CloudUITests.xcresult" > "$output_dir/test.log" 2>&1 || result=$?
xcrun xcresulttool export attachments --path "$output_dir/CloudUITests.xcresult" --output-path "$output_dir/attachments" > "$output_dir/export.log" 2>&1 || true
xcrun xcresulttool get test-results summary --path "$output_dir/CloudUITests.xcresult" > "$output_dir/test-summary.json" 2> "$output_dir/summary-export.log" || true
if [[ "$result" == 0 ]]; then
  python3 - "$output_dir/test-summary.json" <<'PY' || result=1
import json,sys
result=json.load(open(sys.argv[1]))
assert result.get('passedTests') == 1 and result.get('skippedTests') == 0 and result.get('failedTests') == 0, 'Cloud acceptance must run exactly one passing test; skipped tests do not establish real service success'
PY
fi
printf '%s\n' "$result" > "$output_dir/test-exit-code.txt"
tail -22 "$output_dir/test.log"
printf '\nReal native cloud evidence: %s\n' "$output_dir"
exit "$result"
