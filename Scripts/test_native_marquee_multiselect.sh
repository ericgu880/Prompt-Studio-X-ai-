#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NATIVE_MARQUEE_FILE="$ROOT_DIR/Sources/PromptStudio/Views/NativeMarqueeCollectionView.swift"
PROMPT_STUDIO_VIEW_FILE="$ROOT_DIR/Sources/PromptStudio/Views/PromptStudioView.swift"
APP_STATE_FILE="$ROOT_DIR/Sources/PromptStudio/AppState.swift"

require_fixed_text() {
    local text="$1"
    local file="$2"
    local message="$3"

    if ! /usr/bin/grep -Fq "$text" "$file"; then
        echo "$message" >&2
        exit 1
    fi
}

require_pattern() {
    local pattern="$1"
    local file="$2"
    local message="$3"

    if ! /usr/bin/grep -Eq "$pattern" "$file"; then
        echo "$message" >&2
        exit 1
    fi
}

if [[ ! -f "$NATIVE_MARQUEE_FILE" ]]; then
    echo "Native marquee collection view source is missing: $NATIVE_MARQUEE_FILE" >&2
    exit 1
fi

require_pattern 'NativeMarqueeCollectionView[[:space:]]*\([[:space:]]*frame:[[:space:]]*\.zero' \
    "$PROMPT_STUDIO_VIEW_FILE" \
    "PromptStudioView must host NativeMarqueeCollectionView(frame: .zero)."
require_fixed_text 'onMarqueeChange' "$PROMPT_STUDIO_VIEW_FILE" \
    "PromptStudioView must handle native marquee selection changes."
require_fixed_text 'indexPathsForItems(in: rect)' "$NATIVE_MARQUEE_FILE" \
    "Native marquee selection must use indexPathsForItems(in: rect)."
require_fixed_text 'PromptItemDragPayload.pasteboardTypeIdentifier' "$PROMPT_STUDIO_VIEW_FILE" \
    "PromptStudioView drag handling must use PromptItemDragPayload.pasteboardTypeIdentifier."
require_fixed_text 'state.moveItems(itemIDs, toFolderID: row.folder.id)' "$PROMPT_STUDIO_VIEW_FILE" \
    "PromptStudioView folder drops must move all selected item IDs."
require_pattern 'func[[:space:]]+orderedItemIDsForDrag[[:space:]]*\([[:space:]]*startingWith[[:space:]]+itemID:[[:space:]]*String[[:space:]]*\)' \
    "$APP_STATE_FILE" \
    "AppState must provide orderedItemIDsForDrag(startingWith itemID: String)."
require_pattern 'flags[[:space:]]*==[[:space:]]*\.command' "$PROMPT_STUDIO_VIEW_FILE" \
    "DeleteSelectionKeyMonitor must only delete for an unmodified Delete key."
require_fixed_text 'AppKitBridge.isTextInputActive()' "$PROMPT_STUDIO_VIEW_FILE" \
    "DeleteSelectionKeyMonitor must not delete while text input is active."

echo "Native marquee multi-selection regression tests passed"
