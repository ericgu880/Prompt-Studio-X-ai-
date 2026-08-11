#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/Scripts/swift_toolchain.sh"

SWIFTC="$(find_compatible_swift_tool swiftc)"
SDK_PATH="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/promptstudio-hover-scroller.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

"$SWIFTC" \
    -sdk "$SDK_PATH" \
    "$ROOT_DIR/Sources/PromptStudio/Views/TransparentOverlayScroller.swift" \
    "$ROOT_DIR/Tests/HoverRevealScrollerRegressionTests/main.swift" \
    -o "$BUILD_DIR/HoverRevealScrollerRegressionTests"

"$BUILD_DIR/HoverRevealScrollerRegressionTests"
