#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_FILE="$ROOT_DIR/Sources/PromptStudio/Views/PromptStudioView.swift"

markdown_body="$(sed -n '/private final class NativeMarkdownCardView/,/private struct NativeMarkdownCardContentView/p' "$SOURCE_FILE")"

if ! grep -q 'representedItemIsDeleted' <<<"$markdown_body"; then
    echo "Markdown card must retain the deleted state for its native context menu." >&2
    exit 1
fi

menu_body="$(sed -n '/override func menu(for event: NSEvent) -> NSMenu? {/,/private func setup()/p' <<<"$markdown_body")"
if ! grep -q 'if representedItemIsDeleted' <<<"$menu_body" || \
   ! grep -q 'state.restoreSelected()' <<<"$menu_body" || \
   ! grep -q 'state.beginPermanentDeleteSelectedTrashItems()' <<<"$menu_body" || \
   ! grep -q 'moveItemsToTrash(actionItemIDs)' <<<"$menu_body"; then
    echo "Markdown trash context menu must distinguish restore/permanent-delete from move-to-trash." >&2
    exit 1
fi

echo "Trash context menu regression tests passed"
