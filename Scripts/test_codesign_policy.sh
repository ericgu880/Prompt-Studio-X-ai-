#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/Scripts/codesign_policy.sh"
TEST_ROOT="$ROOT_DIR/.build/codesign-policy-tests"
rm -rf "$TEST_ROOT"
mkdir -p "$TEST_ROOT"

validate_signing_configuration debug "-"

if validate_signing_configuration debug "Developer ID Application: PromptStudio (ABCDE12345)" "" >/dev/null 2>&1; then
    echo "Developer ID signed debug builds must require the expected Team ID" >&2
    exit 1
fi
validate_signing_configuration debug "Developer ID Application: PromptStudio (ABCDE12345)" "ABCDE12345"

if validate_signing_configuration release "-" "ABCDE12345" >/dev/null 2>&1; then
    echo "release must reject ad-hoc signing" >&2
    exit 1
fi

if validate_signing_configuration release "" "ABCDE12345" >/dev/null 2>&1; then
    echo "release must reject an empty signing identity" >&2
    exit 1
fi

if validate_signing_configuration release "Developer ID Application: PromptStudio (ABCDE12345)" "" >/dev/null 2>&1; then
    echo "release must require the expected Team ID" >&2
    exit 1
fi

if validate_signing_configuration release "Developer ID Application: PromptStudio (ABCDE12345)" "not-a-team" >/dev/null 2>&1; then
    echo "release must reject an invalid expected Team ID" >&2
    exit 1
fi

validate_signing_configuration release "Developer ID Application: PromptStudio (ABCDE12345)" "ABCDE12345"

SAFE_ENTITLEMENTS="$TEST_ROOT/Safe.entitlements"
UNSAFE_ENTITLEMENTS="$TEST_ROOT/Unsafe.entitlements"
INVALID_ENTITLEMENTS="$TEST_ROOT/Invalid.entitlements"
/usr/bin/plutil -create xml1 "$SAFE_ENTITLEMENTS"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.get-task-allow bool false' "$SAFE_ENTITLEMENTS"
/usr/bin/plutil -create xml1 "$UNSAFE_ENTITLEMENTS"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.get-task-allow bool true' "$UNSAFE_ENTITLEMENTS"
cp /usr/bin/true "$INVALID_ENTITLEMENTS"
validate_release_entitlements release "$SAFE_ENTITLEMENTS"
validate_release_entitlements debug "$UNSAFE_ENTITLEMENTS"
if validate_release_entitlements release "$UNSAFE_ENTITLEMENTS" >/dev/null 2>&1; then
    echo "release must reject get-task-allow=true" >&2
    exit 1
fi
if validate_release_entitlements release "$TEST_ROOT/Missing.entitlements" >/dev/null 2>&1; then
    echo "release must reject a missing entitlements file" >&2
    exit 1
fi
if validate_release_entitlements release "$INVALID_ENTITLEMENTS" >/dev/null 2>&1; then
    echo "release must reject an invalid entitlements plist" >&2
    exit 1
fi

outside_output="$(
    cd /tmp
    SIGN_IDENTITY='Developer ID Application: PromptStudio (ABCDE12345)' \
    EXPECTED_TEAM_ID='ABCDE12345' \
    ENTITLEMENTS_PATH='.build/codesign-policy-tests/Unsafe.entitlements' \
        "$ROOT_DIR/Scripts/build_app.sh" release 2>&1 || true
)"
if [[ "$outside_output" != *"Release entitlements must not enable"* ]]; then
    echo "relative entitlements paths must be validated from the same directory used for signing" >&2
    exit 1
fi

LOCK_FILE="$TEST_ROOT/package.lock"
acquire_package_lock "$LOCK_FILE" "$$"
if acquire_package_lock "$LOCK_FILE" "$$" >/dev/null 2>&1; then
    echo "a second packaging process must not acquire an active lock" >&2
    exit 1
fi
release_package_lock "$LOCK_FILE"

VALID_PUBLIC_KEY="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
validate_license_signing_key release "prod-2026-01" "$VALID_PUBLIC_KEY"
if validate_license_signing_key release "prod-2026-01" "too-short" >/dev/null 2>&1; then
    echo "release must reject a malformed Ed25519 public key" >&2
    exit 1
fi

validate_optional_https_url "PROMPTSTUDIO_PURCHASE_URL" ""
validate_optional_https_url "PROMPTSTUDIO_PURCHASE_URL" "https://checkout.example/path"
if validate_optional_https_url "PROMPTSTUDIO_PURCHASE_URL" "http://checkout.example" >/dev/null 2>&1; then
    echo "configured purchase links must require HTTPS" >&2
    exit 1
fi
if validate_optional_https_url "PROMPTSTUDIO_PURCHASE_URL" "https://user:password@checkout.example" >/dev/null 2>&1; then
    echo "configured purchase links must reject embedded credentials" >&2
    exit 1
fi
if validate_license_signing_key release "bad key id" "$VALID_PUBLIC_KEY" >/dev/null 2>&1; then
    echo "release must reject a malformed license key ID" >&2
    exit 1
fi

GOOD_DETAILS=$'Authority=Developer ID Application: PromptStudio (ABCDE12345)\nTeamIdentifier=ABCDE12345\nTimestamp=Jul 16, 2026\nCodeDirectory v=20500 flags=0x10000(runtime)'
GOOD_REQUIREMENT='designated => anchor apple generic and identifier "com.creatigo.promptstudio" and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = ABCDE12345'
validate_release_signature_metadata "$GOOD_DETAILS" "$GOOD_REQUIREMENT" "ABCDE12345"
if validate_release_signature_metadata "$GOOD_DETAILS" "$GOOD_REQUIREMENT" "ZZZZZ99999" >/dev/null 2>&1; then
    echo "release metadata must reject a different Team ID" >&2
    exit 1
fi
WEAK_REQUIREMENT='designated => anchor apple generic and identifier "com.creatigo.promptstudio" and certificate leaf[subject.OU] = ABCDE12345'
if validate_release_signature_metadata "$GOOD_DETAILS" "$WEAK_REQUIREMENT" "ABCDE12345" >/dev/null 2>&1; then
    echo "release metadata must require the Developer ID CA and Application certificate OIDs" >&2
    exit 1
fi

TEST_APP="$TEST_ROOT/AdHoc.app"
mkdir -p "$TEST_APP/Contents/MacOS"
/usr/bin/csreq \
    -r='designated => identifier "com.creatigo.promptstudio" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "ABCDE12345"' \
    -b "$TEST_ROOT/team-designated-requirement.bin"
cp /usr/bin/true "$TEST_APP/Contents/MacOS/AdHoc"
/usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string AdHoc' "$TEST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string com.creatigo.promptstudio' "$TEST_APP/Contents/Info.plist"
/usr/bin/codesign --force --sign - --timestamp=none "$TEST_APP"

REQUIREMENT_APP="$TEST_ROOT/Requirement.app"
cp -R "$TEST_APP" "$REQUIREMENT_APP"
requirement_argument="$(developer_id_requirement_argument "ABCDE12345")"
if [[ "$requirement_argument" != =designated* ]]; then
    echo "literal codesign requirements must start with '='" >&2
    exit 1
fi
/usr/bin/codesign --force --sign - --timestamp=none \
    --requirements "$requirement_argument" "$REQUIREMENT_APP"
canonical_requirement="$(/usr/bin/codesign -d -r- "$REQUIREMENT_APP" 2>&1)"
if [[ "$canonical_requirement" != *"/* exists */"* ]]; then
    echo "codesign requirement regression test must exercise canonical macOS output" >&2
    exit 1
fi

UNSAFE_APP="$TEST_ROOT/UnsafeEntitlements.app"
cp -R "$TEST_APP" "$UNSAFE_APP"
/usr/bin/codesign --force --sign - --timestamp=none \
    --entitlements "$UNSAFE_ENTITLEMENTS" "$UNSAFE_APP"
if validate_signed_release_entitlements release "$UNSAFE_APP" >/dev/null 2>&1; then
    echo "post-sign verification must reject embedded get-task-allow=true" >&2
    exit 1
fi

verify_signed_app debug "$TEST_APP"
if verify_signed_app debug "$TEST_APP" "ABCDE12345" >/dev/null 2>&1; then
    echo "Developer ID debug verification must reject an ad-hoc CDHash-only requirement" >&2
    exit 1
fi
if verify_signed_app release "$TEST_APP" "ABCDE12345" >/dev/null 2>&1; then
    echo "release verification must reject an ad-hoc CDHash-only requirement" >&2
    exit 1
fi

echo "Code-signing policy tests passed"
