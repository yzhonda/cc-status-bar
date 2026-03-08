#!/bin/bash
set -e

# CC Status Bar - Test Script
# This script is used by both pre-push hook and GitHub Actions

echo "=== Swift Tests ==="
swift test -Xswiftc -warnings-as-errors

echo ""
echo "=== Shell Script Checks ==="
bash -n scripts/install-voicevox-engine.sh
bash -n scripts/voicevox-alert.sh
bash scripts/test-voicevox-alert.sh

echo ""
echo "=== TypeScript Build Check ==="
cd StreamDeckPlugin/com.ccstatusbar.sdPlugin
npx tsc --noEmit

echo ""
echo "=== All tests passed ==="
