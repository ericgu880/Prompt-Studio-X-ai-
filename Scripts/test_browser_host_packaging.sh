#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_SCRIPT="$ROOT_DIR/Scripts/build_app.sh"

/usr/bin/grep -F -- '--product PromptStudioCaptureHost' "$BUILD_SCRIPT" >/dev/null
/usr/bin/grep -F -- 'Contents/Helpers/PromptStudioCaptureHost' "$BUILD_SCRIPT" >/dev/null
/usr/bin/grep -F -- 'Contents/Resources/BrowserExtension' "$BUILD_SCRIPT" >/dev/null
/usr/bin/grep -F -- '/usr/bin/codesign "${helper_codesign_args[@]}"' "$BUILD_SCRIPT" >/dev/null

# Registration must remain an explicit user command and must not be invoked by packaging.
if /usr/bin/grep -E 'register_browser_hosts\.sh (register|repair)' "$BUILD_SCRIPT" >/dev/null; then
    echo "build_app.sh must not silently register browser hosts" >&2
    exit 1
fi

echo "Browser host packaging policy tests passed"
