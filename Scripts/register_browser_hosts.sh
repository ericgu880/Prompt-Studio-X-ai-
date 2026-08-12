#!/usr/bin/env bash
set -euo pipefail

MANIFEST_NAME="com.creatigo.promptstudio.capture"
PRODUCTION_ORIGIN="chrome-extension://cnafjhfhjdmkknjgojhnkglgllliimjo/"
DEVELOPMENT_ORIGIN="chrome-extension://pnafjhfhjdmkknjgojhnkglgllliimjo/"

usage() {
    cat >&2 <<'USAGE'
Usage:
  register_browser_hosts.sh register /absolute/path/to/PromptStudioCaptureHost
  register_browser_hosts.sh repair /absolute/path/to/PromptStudioCaptureHost
  register_browser_hosts.sh remove

Registration is explicit and user-scoped. The app never calls this script silently.
USAGE
}

ACTION="${1:-}"
HOST_PATH="${2:-${PROMPTSTUDIO_CAPTURE_HOST_PATH:-}}"
case "$ACTION" in
    register|repair) ;;
    remove) ;;
    *) usage; exit 2 ;;
esac

HOME_DIR="${HOME:?HOME is required for user-level browser registration}"
BASE_DIR="$HOME_DIR/Library/Application Support"
MANIFEST_DIRS=(
    "$BASE_DIR/Google/Chrome/NativeMessagingHosts"
    "$BASE_DIR/Microsoft Edge/NativeMessagingHosts"
    "$BASE_DIR/Arc/User Data/NativeMessagingHosts"
)

if [[ "$ACTION" != remove ]]; then
    if [[ -z "$HOST_PATH" || "$HOST_PATH" != /* ]]; then
        echo "The native host path must be absolute." >&2
        exit 2
    fi
    if [[ "$HOST_PATH" == *$'\n'* || "$HOST_PATH" == *$'\r'* || "$HOST_PATH" == *'"'* || "$HOST_PATH" == *'\\'* ]]; then
        echo "The native host path contains characters that cannot be represented safely in JSON." >&2
        exit 2
    fi
    if [[ ! -x "$HOST_PATH" ]]; then
        echo "The native host is not executable: $HOST_PATH" >&2
        exit 2
    fi
fi

write_manifest() {
    local directory="$1"
    local destination="$directory/$MANIFEST_NAME.json"
    local temporary
    mkdir -p "$directory"
    chmod 700 "$directory" 2>/dev/null || true
    temporary="$(mktemp "$directory/.${MANIFEST_NAME}.XXXXXX")"
    cat > "$temporary" <<JSON
{
  "name": "$MANIFEST_NAME",
  "description": "PromptStudio local web capture host",
  "path": "$HOST_PATH",
  "type": "stdio",
  "allowed_origins": [
    "$PRODUCTION_ORIGIN",
    "$DEVELOPMENT_ORIGIN"
  ]
}
JSON
    chmod 600 "$temporary"
    mv -f "$temporary" "$destination"
    echo "registered $destination"
}

case "$ACTION" in
    register|repair)
        for directory in "${MANIFEST_DIRS[@]}"; do
            write_manifest "$directory"
        done
        ;;
    remove)
        for directory in "${MANIFEST_DIRS[@]}"; do
            destination="$directory/$MANIFEST_NAME.json"
            if [[ -e "$destination" ]]; then
                rm -f "$destination"
                echo "removed $destination"
            fi
        done
        ;;
esac
