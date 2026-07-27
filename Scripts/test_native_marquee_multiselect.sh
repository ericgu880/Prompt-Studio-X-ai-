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

require_block_fixed_text() {
    local text="$1"
    local block="$2"
    local message="$3"

    if ! /usr/bin/grep -Fq "$text" <<<"$block"; then
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

DELETE_SELECTION_MONITOR_BLOCK="$(/usr/bin/awk '
    /^struct DeleteSelectionKeyMonitor:/ { in_block = 1 }
    /^struct StandardTextEditingShortcutMonitor:/ { exit }
    in_block { print }
' "$PROMPT_STUDIO_VIEW_FILE")"
require_block_fixed_text 'guard !textInputActive,' "$DELETE_SELECTION_MONITOR_BLOCK" \
    "Batch trash must not run while text input is active."
require_block_fixed_text 'guard flags == .command' "$DELETE_SELECTION_MONITOR_BLOCK" \
    "Batch trash must require Command-Delete with no additional modifiers."
require_block_fixed_text 'return event.keyCode == 51 || event.keyCode == 117' "$DELETE_SELECTION_MONITOR_BLOCK" \
    "Batch trash must handle both Delete and Forward Delete key codes."

echo "Native marquee multi-selection regression tests passed"
