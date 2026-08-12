#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/promptstudio-host-registration.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/home/bin"
mkdir -p "$TEST_ROOT/apps/Google Chrome.app" "$TEST_ROOT/apps/Microsoft Edge.app" "$TEST_ROOT/apps/Arc.app"
HOST_PATH="$TEST_ROOT/home/bin/PromptStudio Capture \" & Host"
cp /usr/bin/true "$HOST_PATH"
chmod 700 "$HOST_PATH"

if HOME="$TEST_ROOT/home" PROMPTSTUDIO_BROWSER_APP_ROOTS="$TEST_ROOT/no-apps" "$ROOT_DIR/Scripts/register_browser_hosts.sh" register-dev "$HOST_PATH" >/dev/null 2>&1; then
    echo "registration must skip/fail when no supported browser app exists" >&2
    exit 1
fi

if HOME="$TEST_ROOT/home" PROMPTSTUDIO_BROWSER_APP_ROOTS="$TEST_ROOT/apps" "$ROOT_DIR/Scripts/register_browser_hosts.sh" register "$HOST_PATH" >/dev/null 2>&1; then
    echo "production registration must require PROMPTSTUDIO_EXTENSION_ID" >&2
    exit 1
fi
HOME="$TEST_ROOT/home" PROMPTSTUDIO_BROWSER_APP_ROOTS="$TEST_ROOT/apps" "$ROOT_DIR/Scripts/register_browser_hosts.sh" register-dev "$HOST_PATH" >/dev/null

for manifest in \
    "$TEST_ROOT/home/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.creatigo.promptstudio.capture.json" \
    "$TEST_ROOT/home/Library/Application Support/Microsoft Edge/NativeMessagingHosts/com.creatigo.promptstudio.capture.json" \
    "$TEST_ROOT/home/Library/Application Support/Arc/User Data/NativeMessagingHosts/com.creatigo.promptstudio.capture.json"; do
    [[ -f "$manifest" ]] || { echo "missing manifest: $manifest" >&2; exit 1; }
    MANIFEST_PATH="$manifest" EXPECTED_HOST_PATH="$HOST_PATH" node <<'NODE'
const fs = require('node:fs');
const manifest = JSON.parse(fs.readFileSync(process.env.MANIFEST_PATH, 'utf8'));
if (manifest.path !== process.env.EXPECTED_HOST_PATH) process.exit(1);
NODE
    ! /usr/bin/grep -F '*' "$manifest" >/dev/null
    /usr/bin/grep -F 'chrome-extension://ejdemjnekbbpodkgfpngckkhghfeheng/' "$manifest" >/dev/null
done

cp /usr/bin/false "$HOST_PATH"
chmod 700 "$HOST_PATH"
HOME="$TEST_ROOT/home" PROMPTSTUDIO_BROWSER_APP_ROOTS="$TEST_ROOT/apps" PROMPTSTUDIO_EXTENSION_ID="abcdefghijklmnopabcdefghijklmnop" "$ROOT_DIR/Scripts/register_browser_hosts.sh" repair "$HOST_PATH" >/dev/null
for manifest in \
    "$TEST_ROOT/home/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.creatigo.promptstudio.capture.json" \
    "$TEST_ROOT/home/Library/Application Support/Microsoft Edge/NativeMessagingHosts/com.creatigo.promptstudio.capture.json" \
    "$TEST_ROOT/home/Library/Application Support/Arc/User Data/NativeMessagingHosts/com.creatigo.promptstudio.capture.json"; do
    /usr/bin/grep -F 'chrome-extension://abcdefghijklmnopabcdefghijklmnop/' "$manifest" >/dev/null
done
HOME="$TEST_ROOT/home" PROMPTSTUDIO_BROWSER_APP_ROOTS="$TEST_ROOT/apps" "$ROOT_DIR/Scripts/register_browser_hosts.sh" remove >/dev/null

for manifest in \
    "$TEST_ROOT/home/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.creatigo.promptstudio.capture.json" \
    "$TEST_ROOT/home/Library/Application Support/Microsoft Edge/NativeMessagingHosts/com.creatigo.promptstudio.capture.json" \
    "$TEST_ROOT/home/Library/Application Support/Arc/User Data/NativeMessagingHosts/com.creatigo.promptstudio.capture.json"; do
    [[ ! -e "$manifest" ]] || { echo "remove did not remove: $manifest" >&2; exit 1; }
done

# A browser can be uninstalled after registration; removal must still delete only this
# host's own stale manifest without requiring an app bundle to remain present.
STALE_MANIFEST="$TEST_ROOT/home/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.creatigo.promptstudio.capture.json"
mkdir -p "$(dirname "$STALE_MANIFEST")"
printf '%s\n' '{"name":"com.creatigo.promptstudio.capture"}' > "$STALE_MANIFEST"
HOME="$TEST_ROOT/home" PROMPTSTUDIO_BROWSER_APP_ROOTS="$TEST_ROOT/no-apps" "$ROOT_DIR/Scripts/register_browser_hosts.sh" remove >/dev/null
[[ ! -e "$STALE_MANIFEST" ]] || { echo "remove did not clean stale manifest" >&2; exit 1; }

echo "Browser host registration policy tests passed"
