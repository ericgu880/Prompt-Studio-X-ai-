#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/extension_policy.sh"
MANIFEST_NAME="com.creatigo.promptstudio.capture"

usage() {
    cat >&2 <<'USAGE'
Usage:
  register_browser_hosts.sh register /absolute/path/to/PromptStudioCaptureHost
  register_browser_hosts.sh repair /absolute/path/to/PromptStudioCaptureHost
  register_browser_hosts.sh register-dev /absolute/path/to/PromptStudioCaptureHost
  register_browser_hosts.sh remove

Registration is explicit and user-scoped. The app never calls this script silently.
USAGE
}

ACTION="${1:-}"
HOST_PATH="${2:-${PROMPTSTUDIO_CAPTURE_HOST_PATH:-}}"
case "$ACTION" in
    register|repair|register-dev) ;;
    remove) ;;
    *) usage; exit 2 ;;
esac

HOME_DIR="${HOME:?HOME is required for user-level browser registration}"
BASE_DIR="$HOME_DIR/Library/Application Support"
APP_ROOTS_RAW="${PROMPTSTUDIO_BROWSER_APP_ROOTS:-/Applications:$HOME_DIR/Applications}"
IFS=':' read -r -a APP_ROOTS <<< "$APP_ROOTS_RAW"

ALL_MANIFEST_DIRS=(
    "$BASE_DIR/Google/Chrome/NativeMessagingHosts"
    "$BASE_DIR/Microsoft Edge/NativeMessagingHosts"
    "$BASE_DIR/Arc/User Data/NativeMessagingHosts"
)
DETECTED_MANIFEST_DIRS=()
append_unique_manifest_dir() {
    local candidate="$1"
    local existing
    for existing in "${DETECTED_MANIFEST_DIRS[@]-}"; do
        [[ "$existing" == "$candidate" ]] && return
    done
    DETECTED_MANIFEST_DIRS+=("$candidate")
}
for app_root in "${APP_ROOTS[@]}"; do
    [[ -d "$app_root/Google Chrome.app" ]] && append_unique_manifest_dir "${ALL_MANIFEST_DIRS[0]}"
    [[ -d "$app_root/Microsoft Edge.app" ]] && append_unique_manifest_dir "${ALL_MANIFEST_DIRS[1]}"
    [[ -d "$app_root/Arc.app" ]] && append_unique_manifest_dir "${ALL_MANIFEST_DIRS[2]}"
done

if [[ "$ACTION" == remove ]]; then
    # Removal is safe and deterministic even after a browser app is uninstalled: only
    # this host's own manifest name in the known user directories is ever deleted.
    MANIFEST_DIRS=("${ALL_MANIFEST_DIRS[@]}")
elif [[ ${#DETECTED_MANIFEST_DIRS[@]} -eq 0 ]]; then
    echo "No supported browser application was found in: $APP_ROOTS_RAW" >&2
    exit 1
else
    MANIFEST_DIRS=("${DETECTED_MANIFEST_DIRS[@]}")
fi

if [[ "$ACTION" == register || "$ACTION" == repair ]]; then
    validate_production_extension_id "${PROMPTSTUDIO_EXTENSION_ID:-}"
    ALLOWED_ORIGIN="$(extension_origin_for_id "$PROMPTSTUDIO_EXTENSION_ID")"
else
    ALLOWED_ORIGIN="$(extension_origin_for_id "$PROMPTSTUDIO_DEV_EXTENSION_ID")"
fi

if [[ "$ACTION" != remove ]]; then
    if [[ -z "$HOST_PATH" || "$HOST_PATH" != /* ]]; then
        echo "The native host path must be absolute." >&2
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
    write_capture_host_manifest_json "$temporary" "$HOST_PATH" "$ALLOWED_ORIGIN"
    chmod 600 "$temporary"
    mv -f "$temporary" "$destination"
    echo "registered $destination"
}

case "$ACTION" in
    register|repair|register-dev)
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
