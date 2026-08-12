#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/promptstudio-host-registration.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/home/bin"
HOST_PATH="$TEST_ROOT/home/bin/PromptStudioCaptureHost"
cp /usr/bin/true "$HOST_PATH"
chmod 700 "$HOST_PATH"

HOME="$TEST_ROOT/home" "$ROOT_DIR/Scripts/register_browser_hosts.sh" register "$HOST_PATH" >/dev/null

for manifest in \
    "$TEST_ROOT/home/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.creatigo.promptstudio.capture.json" \
    "$TEST_ROOT/home/Library/Application Support/Microsoft Edge/NativeMessagingHosts/com.creatigo.promptstudio.capture.json" \
    "$TEST_ROOT/home/Library/Application Support/Arc/User Data/NativeMessagingHosts/com.creatigo.promptstudio.capture.json"; do
    [[ -f "$manifest" ]] || { echo "missing manifest: $manifest" >&2; exit 1; }
    /usr/bin/grep -F '"path": "'"$HOST_PATH"'"' "$manifest" >/dev/null
    ! /usr/bin/grep -F '*' "$manifest" >/dev/null
done

cp /usr/bin/false "$HOST_PATH"
chmod 700 "$HOST_PATH"
HOME="$TEST_ROOT/home" "$ROOT_DIR/Scripts/register_browser_hosts.sh" repair "$HOST_PATH" >/dev/null
HOME="$TEST_ROOT/home" "$ROOT_DIR/Scripts/register_browser_hosts.sh" remove >/dev/null

for manifest in \
    "$TEST_ROOT/home/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.creatigo.promptstudio.capture.json" \
    "$TEST_ROOT/home/Library/Application Support/Microsoft Edge/NativeMessagingHosts/com.creatigo.promptstudio.capture.json" \
    "$TEST_ROOT/home/Library/Application Support/Arc/User Data/NativeMessagingHosts/com.creatigo.promptstudio.capture.json"; do
    [[ ! -e "$manifest" ]] || { echo "remove did not remove: $manifest" >&2; exit 1; }
done

echo "Browser host registration policy tests passed"
