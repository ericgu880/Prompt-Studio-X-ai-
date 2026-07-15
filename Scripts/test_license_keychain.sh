#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/.build/license-keychain-tests"
SDK_PATH="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"

source "$ROOT_DIR/Scripts/swift_toolchain.sh"
SWIFT_EXEC="$(find_compatible_swift_tool swiftc "${SWIFT_EXEC:-}")"

mkdir -p "$OUTPUT_DIR"

"$SWIFT_EXEC" \
    -parse-as-library \
    -swift-version 6 \
    -sdk "$SDK_PATH" \
    "$ROOT_DIR/Sources/PromptStudio/License/LicenseCertificate.swift" \
    "$ROOT_DIR/Sources/PromptStudio/License/LicenseState.swift" \
    "$ROOT_DIR/Sources/PromptStudio/License/KeychainLicenseStore.swift" \
    "$ROOT_DIR/Sources/PromptStudio/License/LicenseEncoding.swift" \
    "$ROOT_DIR/Sources/PromptStudio/License/LicenseDateCoding.swift" \
    "$ROOT_DIR/Sources/PromptStudio/License/LicenseRuntimeConfiguration.swift" \
    "$ROOT_DIR/Sources/PromptStudio/License/LicenseCertificateVerifier.swift" \
    "$ROOT_DIR/Sources/PromptStudio/License/LicenseDevice.swift" \
    "$ROOT_DIR/Tests/LicenseKeychainRegressionTests/LicenseAPIClientStub.swift" \
    "$ROOT_DIR/Sources/PromptStudio/License/DeviceIdentityManager.swift" \
    "$ROOT_DIR/Sources/PromptStudio/License/TrialManager.swift" \
    "$ROOT_DIR/Sources/PromptStudio/License/FeatureGate.swift" \
    "$ROOT_DIR/Sources/PromptStudio/License/LicenseManager.swift" \
    "$ROOT_DIR/Tests/LicenseKeychainRegressionTests/main.swift" \
    -o "$OUTPUT_DIR/LicenseKeychainRegressionTests"

"$OUTPUT_DIR/LicenseKeychainRegressionTests"
