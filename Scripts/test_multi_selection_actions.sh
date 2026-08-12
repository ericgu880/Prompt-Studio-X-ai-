#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_STATE="$ROOT_DIR/Sources/PromptStudio/AppState.swift"
VIEW="$ROOT_DIR/Sources/PromptStudio/Views/PromptStudioView.swift"
CONTEXT="$ROOT_DIR/Sources/PromptStudioCore/PromptItemSelectionActionContext.swift"
REPOSITORY="$ROOT_DIR/Sources/PromptStudioCore/PromptRepository.swift"

for contract in \
    'PromptItemSelectionActionContext.resolve' \
    'selectionActionContext(clickedItemID:' \
    'collectionView.beginDraggingSession' \
    'promptStudioPasteboardItem(itemIDs: plan.completePayload.itemIDs)' \
    'session.draggingFormation = .stack'; do
    if ! grep -Fq "$contract" "$VIEW" "$APP_STATE" "$CONTEXT"; then
        echo "Missing unified multi-selection contract: $contract" >&2
        exit 1
    fi
done

if [[ $(grep -Fc 'let context = actionContext?' "$VIEW") -lt 3 ]] || \
   [[ $(grep -Fc 'state.moveItems(itemIDs, toFolderID: destination.folderID)' "$VIEW") -lt 3 ]]; then
    echo "Image, Markdown, and fallback cards must use the shared action context for folder moves." >&2
    exit 1
fi

if grep -Fq 'InteractionSelectionMonitor' "$VIEW" || \
   grep -Fq 'interactionSelectionSnapshot' "$APP_STATE" || \
   grep -Fq 'NativeFallbackCardDraggingSource' "$VIEW"; then
    echo "Legacy per-card/global selection snapshots must not remain." >&2
    exit 1
fi

if ! grep -Fq 'func moveItemsToTrash(_ itemIDs: [String])' "$APP_STATE" || \
   ! grep -Fq 'repository?.markDeleted(itemIDs:' "$APP_STATE" || \
   ! grep -Fq 'public func markDeleted(itemIDs:' "$REPOSITORY" || \
   [[ $(grep -Fc 'state.moveItemsToTrash(actionItemIDs)' "$VIEW") -lt 3 ]]; then
    echo "Delete actions must operate on the complete selected ID set." >&2
    exit 1
fi

if ! grep -Fq 'state.moveItems(itemIDs, toFolderID: row.folder.id)' "$VIEW" || \
   ! grep -Fq 'state.moveItems(payload.itemIDs, toFolderID: dropFolderID)' "$VIEW"; then
    echo "Folder drop targets must accept the complete drag payload." >&2
    exit 1
fi

if ! grep -Fq 'promptStudioDragTextPrefix' "$VIEW" || \
   ! grep -Fq 'promptStudioItemIDs(fromDragText:' "$VIEW" || \
   ! grep -Fq 'state.moveItems(itemIDs, toFolderID: dropFolderID)' "$VIEW"; then
    echo "Text drag fallback must preserve and decode the complete selection." >&2
    exit 1
fi

echo "Multi-selection action regression tests passed"
