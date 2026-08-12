#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/Scripts/swift_toolchain.sh"
SWIFT_EXEC="$(find_compatible_swift_tool swift "${SWIFT_BUILD_EXEC:-}")"
"$SWIFT_EXEC" build --product PromptStudioCaptureHost >/dev/null
HOST_BIN="$("$SWIFT_EXEC" build --show-bin-path)/PromptStudioCaptureHost"

if printf '' | "$HOST_BIN" >/dev/null 2>/dev/null; then
    echo "host must reject missing argv origin" >&2
    exit 1
fi
# This is an intentionally unconfigured fixture, not a claimed Web Store ID.
if printf '' | "$HOST_BIN" "chrome-extension://abcdefghijklmnopabcdefghijklmnop/" >/dev/null 2>/dev/null; then
    echo "host must reject direct execution with an unconfigured production origin" >&2
    exit 1
fi
CONFIG_FILE="$(mktemp "${TMPDIR:-/tmp}/promptstudio-host-origins.XXXXXX.json")"
trap 'rm -f "$CONFIG_FILE"' EXIT
printf '%s\n' '{"allowed_origins":["chrome-extension://abcdefghijklmnopabcdefghijklmnop/"]}' > "$CONFIG_FILE"
if printf '' | PROMPTSTUDIO_CAPTURE_ALLOWED_ORIGINS_FILE="$CONFIG_FILE" "$HOST_BIN" "chrome-extension://abcdefghijklmnopabcdefghijklmnop/" >/dev/null 2>/dev/null; then
    echo "host must not trust an environment-supplied origin allowlist" >&2
    exit 1
fi
printf '' | "$HOST_BIN" "chrome-extension://ejdemjnekbbpodkgfpngckkhghfeheng/" >/dev/null

echo "Capture host argv-origin policy tests passed"
