#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Explicit manual invocation calls the configured paid Gemini service. It sends
# only public/artworks/wheat-field.jpg and does not capture microphone input.
node --import tsx scripts/test-gemini-integration.ts "$@"
