#!/bin/bash
# Builds "Flow Capture.app" (a menu bar app, no Dock icon, no terminal) into ./dist.
#   scripts/build-app.sh
# Optional environment:
#   SIGN_IDENTITY="Apple Development: Your Name (ABC123)"   keep macOS permissions across rebuilds (see README)
#   BUNDLE_ID=com.yourname.flowcapture                       change the app's identifier
set -euo pipefail
cd "$(dirname "$0")/.."

# A broken or half-updated copy of Apple's command line tools crashes with "dyld: Symbol not found ... swift-package".
# Check for that first and explain the fix in plain words.
if ! swift package --version >/dev/null 2>&1; then
  cat <<'MSG'

Apple's build tools on this Mac look damaged or out of date, so the app can't be built yet.
This is a known macOS problem (often after an update) and not something you did.

Fix: reinstall the tools. Paste these two lines one at a time (the first asks for your Mac password):

    sudo rm -rf /Library/Developer/CommandLineTools
    xcode-select --install

Click Install in the pop-up, wait for it to finish, then run this script again.
MSG
  exit 1
fi

APP_NAME="Flow Capture"
EXECUTABLE="FlowCapture"
BUNDLE_ID="${BUNDLE_ID:-com.flowcapture.app}"
VERSION="${VERSION:-0.1.0}"
APP="dist/$APP_NAME.app"

# UNIVERSAL=1 builds one app that runs on both Apple Silicon and Intel Macs (used for downloadable releases).
ARCH_FLAGS=""
[ "${UNIVERSAL:-0}" = "1" ] && ARCH_FLAGS="--arch arm64 --arch x86_64"

echo "→ Building release binary ${ARCH_FLAGS:+(universal)}"
swift build -c release $ARCH_FLAGS
BIN_DIR="$(swift build -c release $ARCH_FLAGS --show-bin-path)"

echo "→ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"

echo "→ Bundling the FigJam plugin"
cp -R figjam-plugin "$APP/Contents/Resources/figjam-plugin"

echo "→ Drawing the icon"
ICONSET="$(mktemp -d)/AppIcon.iconset"
swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$EXECUTABLE</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Signing: a stable identity keeps Screen Recording / Accessibility permissions across rebuilds.
# Without one, fall back to an ad-hoc signature (works, but macOS may ask for the permissions again after each rebuild).
IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 'Apple Development' | sed -E 's/.*"(.+)".*/\1/' || true)"
fi
if [ -n "$IDENTITY" ]; then
  echo "→ Signing with: $IDENTITY"
  codesign --force --deep --options runtime --sign "$IDENTITY" "$APP"
else
  echo "→ Signing ad-hoc (no signing identity found)"
  codesign --force --deep --sign - "$APP"
fi
codesign --verify --deep --strict "$APP" && echo "→ Signature OK"

echo
echo "Done: $APP"
echo "  Run:      open \"$APP\""
echo "  Install:  cp -R \"$APP\" /Applications/"
