#!/usr/bin/env bash

validate_signing_configuration() {
    local configuration="${1:?configuration is required}"
    local identity="${2-}"
    local expected_team_id="${3-}"

    case "$configuration" in
        debug|release) ;;
        *)
            echo "Unsupported build configuration: $configuration" >&2
            return 1
            ;;
    esac

    if [[ -z "$identity" ]]; then
        echo "SIGN_IDENTITY must be '-' for an ad-hoc debug build or a Developer ID Application identity." >&2
        return 1
    fi
    if [[ "$configuration" == "release" && "$identity" == "-" ]]; then
        echo "Release packaging requires a Developer ID Application signing identity; ad-hoc signing is not allowed." >&2
        return 1
    fi
    if [[ "$identity" != "-" && ! "$expected_team_id" =~ ^[A-Z0-9]{10}$ ]]; then
        echo "Developer ID signing requires EXPECTED_TEAM_ID as a 10-character Apple Team ID." >&2
        return 1
    fi
}

developer_id_requirement_argument() {
    local expected_team_id="${1:?expected Team ID is required}"
    if [[ ! "$expected_team_id" =~ ^[A-Z0-9]{10}$ ]]; then
        echo "A valid 10-character Team ID is required for the designated requirement." >&2
        return 1
    fi
    printf '=designated => identifier "com.creatigo.promptstudio" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "%s"\n' "$expected_team_id"
}

acquire_package_lock() {
    local lock_file="${1:?lock file is required}"
    local owner_pid="${2:?owner PID is required}"
    /usr/bin/shlock -f "$lock_file" -p "$owner_pid"
}

release_package_lock() {
    local lock_file="${1:?lock file is required}"
    /bin/rm -f "$lock_file"
}

validate_license_signing_key() {
    local configuration="${1:?configuration is required}"
    local key_id="${2-}"
    local public_key="${3-}"

    [[ "$configuration" == "release" ]] || return 0
    if [[ ! "$key_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; then
        echo "LICENSE_SIGNING_KEY_ID has an invalid format." >&2
        return 1
    fi
    if [[ ! "$public_key" =~ ^[A-Za-z0-9_-]{43}$ ]]; then
        echo "LICENSE_SIGNING_PUBLIC_KEY_RAW_B64URL must be an unpadded 32-byte Ed25519 public key." >&2
        return 1
    fi

    local normalized decoded_length
    normalized="$(printf '%s' "$public_key" | /usr/bin/tr '_-' '/+')="
    if ! decoded_length="$(printf '%s' "$normalized" | /usr/bin/base64 -D 2>/dev/null | /usr/bin/wc -c | /usr/bin/tr -d ' ')"; then
        echo "LICENSE_SIGNING_PUBLIC_KEY_RAW_B64URL is not valid base64url." >&2
        return 1
    fi
    if [[ "$decoded_length" != "32" ]]; then
        echo "LICENSE_SIGNING_PUBLIC_KEY_RAW_B64URL must decode to exactly 32 bytes." >&2
        return 1
    fi
}

validate_release_entitlements() {
    local configuration="${1:?configuration is required}"
    local entitlements_path="${2-}"

    [[ "$configuration" == "release" && -n "$entitlements_path" ]] || return 0
    if [[ ! -f "$entitlements_path" ]]; then
        echo "Release entitlements file not found: $entitlements_path" >&2
        return 1
    fi
    if ! /usr/bin/plutil -lint -- "$entitlements_path" >/dev/null 2>&1; then
        echo "Release entitlements must be a valid property list: $entitlements_path" >&2
        return 1
    fi

    local key_path='com\.apple\.security\.get-task-allow'
    local value_type
    if value_type="$(/usr/bin/plutil -type "$key_path" "$entitlements_path" 2>/dev/null)"; then
        if [[ "$value_type" != "bool" ]]; then
            echo "Release com.apple.security.get-task-allow entitlement must be a Boolean." >&2
            return 1
        fi
        if [[ "$(/usr/bin/plutil -extract "$key_path" raw -o - "$entitlements_path")" == "true" ]]; then
            echo "Release entitlements must not enable com.apple.security.get-task-allow." >&2
            return 1
        fi
    fi
}

validate_signed_release_entitlements() {
    local configuration="${1:?configuration is required}"
    local app_path="${2:?app path is required}"

    [[ "$configuration" == "release" ]] || return 0
    local extracted_path
    extracted_path="$(/usr/bin/mktemp -t promptstudio-signed-entitlements)"
    if ! /usr/bin/codesign --display --entitlements :- "$app_path" \
        >"$extracted_path" 2>/dev/null; then
        /bin/rm -f "$extracted_path"
        echo "Unable to inspect the signed release entitlements." >&2
        return 1
    fi
    if [[ -s "$extracted_path" ]] &&
       ! validate_release_entitlements release "$extracted_path"; then
        /bin/rm -f "$extracted_path"
        echo "Signed release entitlements failed validation." >&2
        return 1
    fi
    /bin/rm -f "$extracted_path"
}

requirement_has_exists_constraint() {
    local requirement="${1:?requirement is required}"
    local constraint="${2:?certificate constraint is required}"
    [[ "$requirement" == *"$constraint exists"* ||
       "$requirement" == *"$constraint /* exists */"* ]]
}

validate_release_signature_metadata() {
    local details="${1:?signature details are required}"
    local requirement="${2:?designated requirement is required}"
    local expected_team_id="${3:?expected Team ID is required}"

    if [[ "$details" == *"Signature=adhoc"* || "$details" == *"TeamIdentifier=not set"* ]]; then
        echo "Signed app is not using a stable Developer ID identity." >&2
        return 1
    fi
    [[ "$details" == *"Authority=Developer ID Application:"*"($expected_team_id)"* ]] || {
        echo "Signed app authority is not the expected Developer ID Application team." >&2
        return 1
    }
    [[ "$details" == *"TeamIdentifier=$expected_team_id"* ]] || {
        echo "Signed app TeamIdentifier does not match EXPECTED_TEAM_ID." >&2
        return 1
    }
    [[ "$details" == *"flags="*"runtime"* ]] || {
        echo "Signed app is missing hardened runtime." >&2
        return 1
    }
    [[ "$details" == *"Timestamp="* ]] || {
        echo "Signed app is missing a secure signing timestamp." >&2
        return 1
    }
    [[ "$requirement" != *"designated => cdhash"* ]] || {
        echo "Signed app has a CDHash-only designated requirement." >&2
        return 1
    }
    [[ "$requirement" == *'identifier "com.creatigo.promptstudio"'* && "$requirement" == *"anchor apple generic"* ]] || {
        echo "Signed app designated requirement is missing the stable bundle identifier or Apple anchor." >&2
        return 1
    }
    requirement_has_exists_constraint \
        "$requirement" \
        "certificate 1[field.1.2.840.113635.100.6.2.6]" &&
    requirement_has_exists_constraint \
        "$requirement" \
        "certificate leaf[field.1.2.840.113635.100.6.1.13]" || {
        echo "Signed app designated requirement is missing Developer ID certificate constraints." >&2
        return 1
    }
    [[ "$requirement" == *"certificate leaf[subject.OU] = $expected_team_id"* ||
       "$requirement" == *"certificate leaf[subject.OU] = \"$expected_team_id\""* ]] || {
        echo "Signed app designated requirement is not pinned to EXPECTED_TEAM_ID." >&2
        return 1
    }
}

verify_signed_app() {
    local configuration="${1:?configuration is required}"
    local app_path="${2:?app path is required}"
    local expected_team_id="${3-}"

    /usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"
    if [[ "$configuration" != "release" && -z "$expected_team_id" ]]; then
        return 0
    fi

    local details requirement
    details="$(/usr/bin/codesign --display --verbose=4 "$app_path" 2>&1)"
    requirement="$(/usr/bin/codesign --display --requirements - "$app_path" 2>&1)"
    validate_release_signature_metadata "$details" "$requirement" "$expected_team_id" || return
    validate_signed_release_entitlements "$configuration" "$app_path"
}
