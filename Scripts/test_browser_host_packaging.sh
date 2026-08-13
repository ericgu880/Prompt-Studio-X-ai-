#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_SCRIPT="$ROOT_DIR/Scripts/build_app.sh"

/usr/bin/grep -F -- '--product PromptStudioCaptureHost' "$BUILD_SCRIPT" >/dev/null
/usr/bin/grep -F -- 'Contents/Helpers/PromptStudioCaptureHost' "$BUILD_SCRIPT" >/dev/null
/usr/bin/grep -F -- 'Contents/Resources/BrowserExtension' "$BUILD_SCRIPT" >/dev/null
/usr/bin/grep -F -- 'if [[ "$CONFIGURATION" != release ]]' "$BUILD_SCRIPT" >/dev/null
/usr/bin/grep -F -- '/usr/bin/codesign "${helper_codesign_args[@]}"' "$BUILD_SCRIPT" >/dev/null
/usr/bin/grep -F -- 'validate_production_extension_id' "$BUILD_SCRIPT" >/dev/null

# The development bundle copies the complete image-capable MV3 extension tree. Release builds use
# the separately published Web Store extension and therefore intentionally omit this dev-key tree.
test -f "$ROOT_DIR/BrowserExtension/image-capture.js"
/usr/bin/grep -F -- '"contextMenus"' "$ROOT_DIR/BrowserExtension/manifest.json" >/dev/null
/usr/bin/grep -F -- '"scripting"' "$ROOT_DIR/BrowserExtension/manifest.json" >/dev/null
/usr/bin/grep -F -- '"all_frames": true' "$ROOT_DIR/BrowserExtension/manifest.json" >/dev/null
/usr/bin/grep -F -- 'imageBegin' "$ROOT_DIR/BrowserExtension/image-capture.js" >/dev/null
/usr/bin/grep -F -- 'imageDragPreview' "$ROOT_DIR/BrowserExtension/background.js" >/dev/null

missing_output="$(SIGN_IDENTITY=- "$BUILD_SCRIPT" release 2>&1 || true)"
[[ "$missing_output" == *"PROMPTSTUDIO_EXTENSION_ID must be an explicit"* ]]
dev_output="$(PROMPTSTUDIO_EXTENSION_ID=ejdemjnekbbpodkgfpngckkhghfeheng SIGN_IDENTITY=- "$BUILD_SCRIPT" release 2>&1 || true)"
[[ "$dev_output" == *"must not be the development extension ID"* ]]

# Registration must remain an explicit user command and must not be invoked by packaging.
if /usr/bin/grep -E 'register_browser_hosts\.sh (register|repair)' "$BUILD_SCRIPT" >/dev/null; then
    echo "build_app.sh must not silently register browser hosts" >&2
    exit 1
fi

echo "Browser host packaging policy tests passed"
