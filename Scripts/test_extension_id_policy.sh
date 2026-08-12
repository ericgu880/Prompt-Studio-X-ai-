#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/Scripts/extension_policy.sh"

[[ "$PROMPTSTUDIO_DEV_EXTENSION_ID" == "ejdemjnekbbpodkgfpngckkhghfeheng" ]]
if validate_production_extension_id "" >/dev/null 2>&1; then exit 1; fi
if validate_production_extension_id "$PROMPTSTUDIO_DEV_EXTENSION_ID" >/dev/null 2>&1; then exit 1; fi
# Valid shape only; this fixture is not a claimed Web Store ID.
if validate_production_extension_id "abcdefghijklmnopabcdefghijklmnop!" >/dev/null 2>&1; then exit 1; fi
validate_production_extension_id "abcdefghijklmnopabcdefghijklmnop"

echo "Extension ID policy tests passed"
