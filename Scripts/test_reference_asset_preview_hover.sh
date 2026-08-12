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
require_pattern "$SIDE_PANEL" 'ReferenceZoomCursorModifier(direction: .in)' \
    "Reference thumbnail hover must use the native zoom-in cursor."
require_pattern "$SIDE_PANEL" '.onHover' \
    "Reference thumbnail preview controls must appear on hover."
require_pattern "$SIDE_PANEL" 'accessibilityLabel("放大参考图")' \
    "The reference preview action must be accessible."
if /usr/bin/grep -qF 'Image(systemName: "plus")' "$SIDE_PANEL"; then
    echo "Reference thumbnails must use a cursor, not an overlaid plus button." >&2
    exit 1
fi
require_pattern "$OVERLAYS" 'previewReferenceSection' \
    "Immersive preview must connect the reference section."
require_pattern "$OVERLAYS" 'state.presentReferenceLightbox(reference)' \
    "Immersive preview must open the shared reference lightbox."

STATE_FILE="$ROOT_DIR/Sources/PromptStudio/AppState.swift"
INSPECTOR_FILE="$ROOT_DIR/Sources/PromptStudio/Views/InspectorView.swift"
ROOT_VIEW="$ROOT_DIR/Sources/PromptStudio/Views/PromptStudioView.swift"
REFERENCE_VIEWS="$ROOT_DIR/Sources/PromptStudio/Views/ReferenceAssetViews.swift"

require_pattern "$INSPECTOR_FILE" 'state.presentReferenceLightbox(reference)' \
    "The selected-item inspector must open the same shared reference lightbox."
require_pattern "$STATE_FILE" '@Published var referenceLightbox: ReferenceAsset?' \
    "Reference lightbox state must be shared between the inspector and immersive preview."
require_pattern "$ROOT_VIEW" 'ReferenceAssetLightbox(' \
    "The app root must present the shared reference lightbox above both preview surfaces."
require_pattern "$REFERENCE_VIEWS" '.fill(.regularMaterial)' \
    "The reference lightbox must blur the content behind its overlay."
require_pattern "$REFERENCE_VIEWS" '.blur(radius: 18, opaque: true)' \
    "The reference lightbox must apply the specified Gaussian blur treatment."
require_pattern "$REFERENCE_VIEWS" 'Color.black.opacity(' \
    "The reference lightbox must add a black translucent mask."
require_pattern "$REFERENCE_VIEWS" 'ReferenceZoomCursorModifier(direction: .out)' \
    "The enlarged original must use the native zoom-out cursor."
require_pattern "$REFERENCE_VIEWS" 'onDismiss()' \
    "Clicking the enlarged original must dismiss the lightbox."

echo "Reference asset hover preview regression tests passed"
