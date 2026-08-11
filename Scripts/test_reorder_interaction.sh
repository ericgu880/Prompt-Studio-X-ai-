#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_FILE="$ROOT_DIR/Sources/PromptStudio/Views/PromptStudioView.swift"

if [[ ! -f "$SOURCE_FILE" ]]; then
    echo "PromptStudioView.swift is missing." >&2
    exit 1
fi

if /usr/bin/grep -q 'if draggedItemID != nil' "$SOURCE_FILE"; then
    echo "Masonry grid must not apply a global animation while an item is being dragged." >&2
    exit 1
fi

for required in \
    'var transaction = Transaction(animation: nil)' \
    'transaction.disablesAnimations = true' \
    'withTransaction(transaction)' \
    'private func clearItemReorder()' \
    '@State private var settlingItemID: String?' \
    '@State private var settlingToken = UUID()' \
    '.allowsHitTesting(settlingItemID != item.id)' \
    'private func settleItemReorder(draggedID: String)' \
    'DispatchQueue.main.asyncAfter(deadline: .now() + Self.reorderAnimationDuration)' \
    'private func cancelReorderSettlement()'; do
    if ! /usr/bin/grep -q "$required" "$SOURCE_FILE"; then
        echo "Missing immediate reorder cleanup contract: $required" >&2
        exit 1
    fi
done

if ! /usr/bin/grep -B1 -q 'state.swapFilteredItems(draggedID, targetID)' "$SOURCE_FILE"; then
    echo "Reorder preview state must be cleared before committing the final swap." >&2
    exit 1
fi

if ! /usr/bin/grep -q 'withAnimation(.easeInOut(duration: 0.18))' "$SOURCE_FILE"; then
    echo "Live reorder preview animation must remain enabled while dragging over a target." >&2
    exit 1
fi

echo "Reorder interaction regression tests passed"
