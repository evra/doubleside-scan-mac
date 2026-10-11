#!/bin/bash
# Builds "build/Duplex Scan.app" (ad-hoc signed) from the Swift package.
set -euo pipefail
cd "$(dirname "$0")/.."

git submodule update --init
swift build -c release --product DuplexScan
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="build/Duplex Scan.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/DuplexScan" "$APP/Contents/MacOS/DuplexScan"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP"

echo "Built $APP"
