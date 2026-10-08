#!/bin/bash
# Makes the file people download: dist/Flow-Capture.zip (runs on Apple Silicon and Intel Macs).
#   scripts/make-release.sh
# Then upload that zip to a GitHub release. The file name stays the same on purpose, so the link
#   https://github.com/<you>/flow-capture/releases/latest/download/Flow-Capture.zip
# always points at the newest release.
set -euo pipefail
cd "$(dirname "$0")/.."

UNIVERSAL=1 ./scripts/build-app.sh

APP="dist/Flow Capture.app"
ZIP="dist/Flow-Capture.zip"
rm -f "$ZIP"
# ditto keeps the code signature intact (a plain zip can break it).
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo
echo "Architectures: $(lipo -archs "$APP/Contents/MacOS/FlowCapture")"
echo "Release file : $ZIP ($(du -h "$ZIP" | cut -f1))"
echo "SHA-256      : $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
echo
echo "Next: on GitHub open Releases → Draft a new release → drag $ZIP in → Publish."
