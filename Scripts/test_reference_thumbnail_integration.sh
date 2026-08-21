#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREVIEW_FILE="$ROOT_DIR/Sources/PromptStudio/Views/ReferenceAssetViews.swift"
SIDE_PANEL_FILE="$ROOT_DIR/Sources/PromptStudio/Views/AssetSidePanelComponents.swift"
STATE_FILE="$ROOT_DIR/Sources/PromptStudio/AppState.swift"
SERVICE_FILE="$ROOT_DIR/Sources/PromptStudioCore/ReferenceThumbnailService.swift"

require_pattern() {
    local file="$1"
    local pattern="$2"
    local message="$3"
    if ! /usr/bin/grep -Fq "$pattern" "$file"; then
        echo "$message" >&2
        exit 1
    fi
}

require_pattern "$PREVIEW_FILE" 'enum ReferenceAssetPreviewMode' \
    "Reference previews must distinguish thumbnail display from original-file display."
require_pattern "$PREVIEW_FILE" 'case thumbnail(libraryURL: URL)' \
    "Side-panel reference previews must resolve thumbnails inside the active library."
require_pattern "$PREVIEW_FILE" 'ReferenceThumbnailService.shared' \
    "Reference thumbnail previews must use the persistent reference thumbnail service."
require_pattern "$PREVIEW_FILE" 'reference.thumbnail.placeholder' \
    "Reference thumbnails must record placeholder rendering without blocking selection."
require_pattern "$SIDE_PANEL_FILE" 'mode: usesPersistentThumbnail ? .thumbnail(libraryURL: libraryURL) : .original' \
    "The side-panel reference section must render persistent thumbnails, never original images."
if /usr/bin/grep -Fq 'scheduleReferenceThumbnailBackfill' "$STATE_FILE"; then
    echo "Library load must not prewarm every historical reference thumbnail." >&2
    exit 1
fi
require_pattern "$STATE_FILE" 'prioritizeReferenceThumbnails' \
    "Selecting an item must prioritize only that item's reference thumbnails."
require_pattern "$STATE_FILE" 'filter(Self.isImageReferenceAsset)' \
    "Video, audio, and document references must stay on format placeholders instead of entering the image thumbnail queue."
require_pattern "$STATE_FILE" 'recordInspectorReady' \
    "Selection-to-inspector readiness must be measured independently from image decoding."
require_pattern "$SERVICE_FILE" 'let preparation = await Task.detached' \
    "Cached reference thumbnails must be validated away from the main actor."
require_pattern "$SERVICE_FILE" 'func cancelPendingRequests()' \
    "Switching libraries must cancel queued reference-thumbnail work from the old library."
require_pattern "$SERVICE_FILE" 'promotePendingGeneration(for: key, to: priority)' \
    "Selecting an item must promote its already queued thumbnail requests ahead of background backfill."
require_pattern "$SERVICE_FILE" 'try await Task.detached(priority: .utility)' \
    "Reference-thumbnail cleanup must enumerate files away from the main actor."

if /usr/bin/grep -A80 'private struct SidePanelReferenceThumbnail' "$SIDE_PANEL_FILE" \
    | /usr/bin/grep -Fq 'ThumbnailImage(path: reference.path'; then
    echo "Side-panel reference thumbnails must not decode original reference files." >&2
    exit 1
fi

echo "Reference thumbnail integration regression tests passed"
