#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIDE_PANEL="$ROOT_DIR/Sources/PromptStudio/Views/AssetSidePanelComponents.swift"
OVERLAYS="$ROOT_DIR/Sources/PromptStudio/Views/Overlays.swift"

require_pattern() {
    local file="$1"
    local pattern="$2"
    local message="$3"
    if ! /usr/bin/grep -Fq "$pattern" "$file"; then
        echo "$message" >&2
        exit 1
    fi
}

require_pattern "$SIDE_PANEL" 'var onPreview: ((ReferenceAsset) -> Void)?' \
    "Reference thumbnails must expose an optional preview action."
require_pattern "$SIDE_PANEL" 'Image(systemName: "plus")' \
    "Reference thumbnail hover must show a centered plus icon."
require_pattern "$SIDE_PANEL" '.onHover' \
    "Reference thumbnail preview controls must appear on hover."
require_pattern "$SIDE_PANEL" 'accessibilityLabel("放大参考图")' \
    "The reference preview action must be accessible."
require_pattern "$OVERLAYS" '@State private var previewedReference: ReferenceAsset?' \
    "Immersive preview must track the enlarged reference image."
require_pattern "$OVERLAYS" 'previewReferenceSection' \
    "Immersive preview must connect the reference section."
require_pattern "$OVERLAYS" 'previewedReference?.path' \
    "The main preview canvas must render the selected reference path."
require_pattern "$OVERLAYS" 'ReferenceZoomOutCursorModifier' \
    "An enlarged reference must use the circular minus cursor."
require_pattern "$OVERLAYS" '.onTapGesture {' \
    "Clicking the enlarged reference must return to the primary asset."
require_pattern "$OVERLAYS" 'previewedReference = nil' \
    "The zoom-out action must clear the enlarged reference."

echo "Reference asset hover preview regression tests passed"
