#!/bin/bash
# Builds CastOff and installs it into ~/Applications.
# Set INSTALL_DIR to install somewhere else.

set -euo pipefail
cd "$(dirname "$0")"

INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
BUILT="build/CastOff.app"

command -v swiftc >/dev/null || { echo "swiftc not found. Install Xcode or run: xcode-select --install" >&2; exit 1; }

rm -rf build
mkdir -p "$BUILT/Contents/MacOS"
cp Resources/Info.plist "$BUILT/Contents/Info.plist"

echo "Compiling..."
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13.0" Sources/*.swift -o "$BUILT/Contents/MacOS/CastOff"
codesign --force --sign - "$BUILT"

pkill -x CastOff 2>/dev/null || true
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_DIR/CastOff.app"
mv "$BUILT" "$INSTALL_DIR/CastOff.app"
rm -rf build

open "$INSTALL_DIR/CastOff.app"
echo "Installed $INSTALL_DIR/CastOff.app. Look for the eject icon in your menu bar."
