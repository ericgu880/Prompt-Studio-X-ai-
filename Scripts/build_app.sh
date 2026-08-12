#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-release}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
EXPECTED_TEAM_ID="${EXPECTED_TEAM_ID:-}"
ENTITLEMENTS_PATH="${ENTITLEMENTS_PATH:-}"

cd "$ROOT_DIR"

source "$ROOT_DIR/Scripts/codesign_policy.sh"
source "$ROOT_DIR/Scripts/swift_toolchain.sh"
source "$ROOT_DIR/Scripts/extension_policy.sh"
if [[ "$CONFIGURATION" == release ]]; then
    validate_production_extension_id "${PROMPTSTUDIO_EXTENSION_ID:-}"
fi
validate_signing_configuration "$CONFIGURATION" "$SIGN_IDENTITY" "$EXPECTED_TEAM_ID"
validate_release_entitlements "$CONFIGURATION" "$ENTITLEMENTS_PATH"

LICENSE_PUBLIC_KEY="${LICENSE_SIGNING_PUBLIC_KEY_RAW_B64URL:-}"
LICENSE_KEY_ID="${LICENSE_SIGNING_KEY_ID:-}"
PURCHASE_URL="${PROMPTSTUDIO_PURCHASE_URL:-}"
validate_license_signing_key "$CONFIGURATION" "$LICENSE_KEY_ID" "$LICENSE_PUBLIC_KEY"
validate_optional_https_url "PROMPTSTUDIO_PURCHASE_URL" "$PURCHASE_URL"

LOCK_FILE="$ROOT_DIR/.build/promptstudio-package.lock"
LOCK_ACQUIRED=false
STAGING_APP_PATH=""
PREVIOUS_APP_PATH=""
APP_PATH=""

cleanup_packaging() {
    if [[ -n "$STAGING_APP_PATH" ]]; then
        rm -rf "$STAGING_APP_PATH"
    fi
    if [[ -n "$PREVIOUS_APP_PATH" && -e "$PREVIOUS_APP_PATH" &&
          -n "$APP_PATH" && ! -e "$APP_PATH" ]]; then
        mv "$PREVIOUS_APP_PATH" "$APP_PATH"
    fi
    if [[ "$LOCK_ACQUIRED" == true ]]; then
        release_package_lock "$LOCK_FILE"
    fi
}
trap cleanup_packaging EXIT

mkdir -p "$ROOT_DIR/.build"
if ! acquire_package_lock "$LOCK_FILE" "$$"; then
    echo "Another PromptStudio packaging process is already running." >&2
    exit 1
fi
LOCK_ACQUIRED=true

SWIFT_BUILD_EXEC="$(find_compatible_swift_tool swift "${SWIFT_BUILD_EXEC:-}")"
BUILD_DIR="$("$SWIFT_BUILD_EXEC" build -c "$CONFIGURATION" --show-bin-path)"
"$SWIFT_BUILD_EXEC" build -c "$CONFIGURATION" --product PromptStudio >&2
"$SWIFT_BUILD_EXEC" build -c "$CONFIGURATION" --product PromptStudioCaptureHost >&2

APP_PATH="$BUILD_DIR/PromptStudio.app"
STAGING_APP_PATH="$BUILD_DIR/.PromptStudio.app.staging.$$"
PREVIOUS_APP_PATH="$BUILD_DIR/.PromptStudio.app.previous.$$"
EXECUTABLE_PATH="$BUILD_DIR/PromptStudio"
RESOURCE_BUNDLE="$BUILD_DIR/PromptStudio_PromptStudio.bundle"
CAPTURE_HOST_EXECUTABLE="$BUILD_DIR/PromptStudioCaptureHost"

rm -rf "$STAGING_APP_PATH" "$PREVIOUS_APP_PATH"
mkdir -p "$STAGING_APP_PATH/Contents/MacOS" "$STAGING_APP_PATH/Contents/Resources" "$STAGING_APP_PATH/Contents/Helpers"

cp "$ROOT_DIR/Packaging/Info.plist" "$STAGING_APP_PATH/Contents/Info.plist"
cp "$EXECUTABLE_PATH" "$STAGING_APP_PATH/Contents/MacOS/PromptStudio"
cp "$CAPTURE_HOST_EXECUTABLE" "$STAGING_APP_PATH/Contents/Helpers/PromptStudioCaptureHost"
cp -R "$ROOT_DIR/BrowserExtension" "$STAGING_APP_PATH/Contents/Resources/BrowserExtension"
if [[ "$CONFIGURATION" == release ]]; then
    write_capture_host_allowed_origins_json \
        "$STAGING_APP_PATH/Contents/Helpers/PromptStudioCaptureHost.allowed-origins.json" \
        "$(extension_origin_for_id "$PROMPTSTUDIO_EXTENSION_ID")"
fi

if [[ -n "$LICENSE_PUBLIC_KEY" && -n "$LICENSE_KEY_ID" ]]; then
    /usr/libexec/PlistBuddy -c "Add :PromptStudioLicensePublicKeys dict" "$STAGING_APP_PATH/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :PromptStudioLicensePublicKeys:$LICENSE_KEY_ID string $LICENSE_PUBLIC_KEY" "$STAGING_APP_PATH/Contents/Info.plist"
fi

if [[ -n "$PURCHASE_URL" ]]; then
    /usr/libexec/PlistBuddy -c "Add :PromptStudioPurchaseURL string $PURCHASE_URL" "$STAGING_APP_PATH/Contents/Info.plist"
fi

if [[ -f "$ROOT_DIR/Packaging/AppIcon.icns" ]]; then
    cp "$ROOT_DIR/Packaging/AppIcon.icns" "$STAGING_APP_PATH/Contents/Resources/AppIcon.icns"
fi

if [[ -d "$RESOURCE_BUNDLE" ]]; then
    cp -R "$RESOURCE_BUNDLE" "$STAGING_APP_PATH/Contents/Resources/"
fi

chmod +x "$STAGING_APP_PATH/Contents/MacOS/PromptStudio"
chmod +x "$STAGING_APP_PATH/Contents/Helpers/PromptStudioCaptureHost"

codesign_args=(--force --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign_args+=(--timestamp=none)
else
    codesign_args+=(--options runtime --timestamp)
    codesign_args+=(--requirements "$(developer_id_requirement_argument "$EXPECTED_TEAM_ID")")
fi
if [[ -n "$ENTITLEMENTS_PATH" ]]; then
    if [[ ! -f "$ENTITLEMENTS_PATH" ]]; then
        echo "ENTITLEMENTS_PATH not found: $ENTITLEMENTS_PATH" >&2
        exit 1
    fi
    codesign_args+=(--entitlements "$ENTITLEMENTS_PATH")
fi

helper_codesign_args=(--force --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    helper_codesign_args+=(--timestamp=none)
else
    helper_codesign_args+=(--options runtime --timestamp)
fi

# Sign the nested stdio helper before signing the containing app. The helper intentionally has
# no app entitlements or app designated requirement; the containing app is verified below.
/usr/bin/codesign "${helper_codesign_args[@]}" "$STAGING_APP_PATH/Contents/Helpers/PromptStudioCaptureHost"

/usr/bin/codesign "${codesign_args[@]}" "$STAGING_APP_PATH"
verify_signed_app "$CONFIGURATION" "$STAGING_APP_PATH" "$EXPECTED_TEAM_ID"

had_previous_app=false
if [[ -e "$APP_PATH" ]]; then
    mv "$APP_PATH" "$PREVIOUS_APP_PATH"
    had_previous_app=true
fi
if ! mv "$STAGING_APP_PATH" "$APP_PATH"; then
    if [[ "$had_previous_app" == true ]]; then
        mv "$PREVIOUS_APP_PATH" "$APP_PATH"
    fi
    echo "Failed to install the verified app bundle; the previous bundle was restored." >&2
    exit 1
fi
if [[ "$had_previous_app" == true ]]; then
    rm -rf "$PREVIOUS_APP_PATH"
fi

echo "$APP_PATH"
