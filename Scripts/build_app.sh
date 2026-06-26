#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-debug}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
ENTITLEMENTS_PATH="${ENTITLEMENTS_PATH:-}"

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

codesign_args=(--force --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign_args+=(--timestamp=none)
fi
if [[ -n "$ENTITLEMENTS_PATH" ]]; then
    if [[ ! -f "$ENTITLEMENTS_PATH" ]]; then
        echo "ENTITLEMENTS_PATH not found: $ENTITLEMENTS_PATH" >&2
        exit 1
    fi
    codesign_args+=(--entitlements "$ENTITLEMENTS_PATH")
fi

/usr/bin/codesign "${codesign_args[@]}" "$APP_PATH"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "$APP_PATH"
