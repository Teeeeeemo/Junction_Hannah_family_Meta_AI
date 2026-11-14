#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
case "${1:-check}" in
  check)
    npm test
    npm run build
    bash scripts/test-ios-presentation.sh
    bash scripts/test-ios-live.sh
    bash scripts/test-ios-artwork-tracker.sh
    bash scripts/test-ios-live-audio.sh
    bash run_ios.sh simulator
    ;;
  ui) bash scripts/test-ios-ui.sh ;;
  cloud) bash scripts/test-gemini-integration.sh ;;
  cloud-ios) bash scripts/test-ios-cloud.sh ;;
  package) bash run_ios.sh unsigned ;;
  *) echo 'Usage: bash run_mvp.sh check|ui|cloud|cloud-ios|package' >&2; exit 2 ;;
esac
