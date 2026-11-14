#!/bin/bash
set -euo pipefail

# Usage: ./run_ios.sh unsigned|signed|simulator
# Signed export requires an unlocked login keychain and DEVELOPMENT_TEAM.
repo_root="$(cd "$(dirname "$0")" && pwd)"
output_dir="${IOS_BUILD_DIR:-$repo_root/build/ios}"
mode="${1:-unsigned}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
common=(-project "$repo_root/native/ios/MuseumCompanion.xcodeproj"
  -scheme MuseumCompanion -derivedDataPath "$output_dir/DerivedData")

case "$mode" in
  simulator)
    # DAT initialization requires a properly sealed simulator app. Local ad hoc
    # signing needs no Apple account; disabling signing caused Internal error.
    xcodebuild "${common[@]}" -configuration Debug \
      -destination 'generic/platform=iOS Simulator' \
      CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO build
    ;;
  unsigned|signed)
    archive="$output_dir/MuseumCompanion-$mode.xcarchive"
    signing=(CODE_SIGNING_ALLOWED=NO)
    if [[ "$mode" == signed ]]; then
      : "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to your Apple development team ID}"
      signing=(-allowProvisioningUpdates "DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
    fi
    xcodebuild "${common[@]}" -configuration Release \
      -destination 'generic/platform=iOS' -archivePath "$archive" \
      "${signing[@]}" archive
    if [[ "$mode" == signed ]]; then
      cat > "$output_dir/ExportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>debugging</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST
      xcodebuild -exportArchive -archivePath "$archive" \
        -exportPath "$output_dir/signed" \
        -exportOptionsPlist "$output_dir/ExportOptions.plist" \
        -allowProvisioningUpdates
    else
      staging="$(mktemp -d "$output_dir/ipa.XXXXXX")"
      trap 'rm -rf "$staging"' EXIT
      mkdir "$staging/Payload"
      ditto "$archive/Products/Applications/MuseumCompanion.app" \
        "$staging/Payload/MuseumCompanion.app"
      (cd "$staging" && /usr/bin/zip -q -r -y "$staging/MuseumCompanion-unsigned.ipa" Payload)
      mv -f "$staging/MuseumCompanion-unsigned.ipa" "$output_dir/MuseumCompanion-unsigned.ipa"
      echo "Unsigned IPA (requires re-signing before installation): $output_dir/MuseumCompanion-unsigned.ipa"
    fi
    ;;
  *) echo 'Usage: ./run_ios.sh unsigned|signed|simulator' >&2; exit 2 ;;
esac
