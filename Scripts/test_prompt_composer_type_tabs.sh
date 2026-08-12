#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_FILE="$ROOT_DIR/Sources/PromptStudio/Views/Overlays.swift"

for required in \
    'private struct CreateComposerTypeTab' \
    'StudioColor.primaryAction' \
    'StudioColor.primaryActionText' \
    'CreateComposerColor.tabHover' \
    'StudioColor.hairline' \
    'StudioMotion.fast(reduceMotion: reduceMotion)' \
    '.accessibilityAddTraits(active ? .isSelected : [])'; do
    if ! /usr/bin/grep -Fq "$required" "$SOURCE_FILE"; then
        echo "Missing Prompt composer type-tab state contract: $required" >&2
        exit 1
    fi
done

if /usr/bin/grep -Fq '.background(active ? StudioColor.selection : Color.clear)' "$SOURCE_FILE"; then
    echo "Prompt composer type tabs must not use the indistinguishable selection background." >&2
    exit 1
fi

echo "Prompt composer type-tab regression tests passed"
