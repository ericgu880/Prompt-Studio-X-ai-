#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-debug}"

cd "$ROOT_DIR"

swift build -c "$CONFIGURATION" --product PromptStudio

BUILD_DIR="$ROOT_DIR/.build/$CONFIGURATION"
APP_PATH="$BUILD_DIR/PromptStudio.app"
EXECUTABLE_PATH="$BUILD_DIR/PromptStudio"
RESOURCE_BUNDLE="$BUILD_DIR/PromptStudio_PromptStudio.bundle"

rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"

cp "$ROOT_DIR/Packaging/Info.plist" "$APP_PATH/Contents/Info.plist"
cp "$EXECUTABLE_PATH" "$APP_PATH/Contents/MacOS/PromptStudio"

if [[ -f "$ROOT_DIR/Packaging/AppIcon.icns" ]]; then
    cp "$ROOT_DIR/Packaging/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
fi

if [[ -d "$RESOURCE_BUNDLE" ]]; then
    cp -R "$RESOURCE_BUNDLE" "$APP_PATH/Contents/Resources/"
fi

chmod +x "$APP_PATH/Contents/MacOS/PromptStudio"

echo "$APP_PATH"
