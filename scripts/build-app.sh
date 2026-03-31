#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG="${1:-debug}"
APP_NAME="nom"
BUNDLE_NAME="$APP_NAME.app"
BUILD_DIR="$PROJECT_DIR/.build/$CONFIG"

cd "$PROJECT_DIR"

echo "Building nom ($CONFIG)..."
swift build -c "$CONFIG"

echo "Creating app bundle..."
BUNDLE_DIR="$BUILD_DIR/$BUNDLE_NAME"
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/Contents/MacOS"

cp "$BUILD_DIR/NomApp" "$BUNDLE_DIR/Contents/MacOS/NomApp"
cp Info.plist "$BUNDLE_DIR/Contents/"

# Codesign so permissions persist across rebuilds
codesign --force --sign - "$BUNDLE_DIR" 2>/dev/null || true

echo "Built $BUNDLE_DIR"

if [ "${2:-}" = "--install" ]; then
    INSTALL_PATH="/Applications/$BUNDLE_NAME"
    rm -rf "$INSTALL_PATH"
    cp -R "$BUNDLE_DIR" "$INSTALL_PATH"
    echo "Installed to $INSTALL_PATH"
fi
