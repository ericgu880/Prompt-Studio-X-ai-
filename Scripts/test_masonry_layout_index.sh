#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/Scripts/swift_toolchain.sh"

VIEW_FILE="$ROOT_DIR/Sources/PromptStudio/Views/PromptStudioView.swift"
for required in \
    'visibleAttributeIndex.entriesIntersecting(rect)' \
    'visibleAttributeIndex.reset(columnCount: columnCount)'; do
    if ! /usr/bin/grep -Fq "$required" "$VIEW_FILE"; then
        echo "Masonry layout is missing indexed viewport contract: $required" >&2
        exit 1
    fi
done
if /usr/bin/grep -Fq 'visibleIndexPaths.compactMap' "$VIEW_FILE"; then
    echo "Masonry viewport queries must not scan every visibleIndexPaths entry." >&2
    exit 1
fi

SWIFT_EXEC="$(find_compatible_swift_tool swiftc "${SWIFT_EXEC:-}")"
SDK_PATH="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/promptstudio-masonry-index.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

"$SWIFT_EXEC" \
    -parse-as-library \
    -swift-version 6 \
    -sdk "$SDK_PATH" \
    "$ROOT_DIR/Sources/PromptStudio/Views/MasonryVisibleAttributeIndex.swift" \
    "$ROOT_DIR/Tests/MasonryCollectionLayoutRegressionTests/main.swift" \
    -o "$BUILD_DIR/MasonryCollectionLayoutRegressionTests"

"$BUILD_DIR/MasonryCollectionLayoutRegressionTests"
