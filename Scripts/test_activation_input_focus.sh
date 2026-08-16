#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/.build/activation-input-focus-tests"
SDK_PATH="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"

source "$ROOT_DIR/Scripts/swift_toolchain.sh"
SWIFT_EXEC="$(find_compatible_swift_tool swiftc "${SWIFT_EXEC:-}")"

mkdir -p "$OUTPUT_DIR"

"$SWIFT_EXEC" \
    -parse-as-library \
    -swift-version 6 \
    -sdk "$SDK_PATH" \
    "$ROOT_DIR/Sources/PromptStudio/TextInputFocusPolicy.swift" \
    "$ROOT_DIR/Tests/ActivationInputFocusTests/main.swift" \
    -o "$OUTPUT_DIR/ActivationInputFocusTests"

"$OUTPUT_DIR/ActivationInputFocusTests"
