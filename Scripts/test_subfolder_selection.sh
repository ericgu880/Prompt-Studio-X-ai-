#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_FILE="$ROOT_DIR/Sources/PromptStudio/Views/PromptStudioView.swift"

lazy_host_body="$(sed -n '/private final class LazyAssetContextMenuHostingView/,/private final class NativeAssetSelectionChromeView/p' "$SOURCE_FILE")"
if ! grep -q 'guard item != nil else' <<<"$lazy_host_body" || ! grep -q 'return super\.hitTest(point)' <<<"$lazy_host_body"; then
    echo "Folder hosting view must forward hit testing to its SwiftUI content." >&2
    exit 1
fi

subfolder_body="$(sed -n '/private struct SubfolderCardView: View/,/private struct ImmediateFolderClickCapture/p' "$SOURCE_FILE")"
if ! grep -q 'ImmediateFolderClickCapture' <<<"$subfolder_body"; then
    echo "Subfolder card must retain its click capture view." >&2
    exit 1
fi

app_state_body="$(sed -n '/private func filteredItems(for filter: PromptFilter)/,/private func rebuildItemLookup/p' "$ROOT_DIR/Sources/PromptStudio/AppState.swift")"
if ! grep -q 'let folderIDs: Set<String> = \[folderID\]' <<<"$app_state_body"; then
    echo "Folder navigation must filter direct assets only; descendants are opened separately." >&2
    exit 1
fi

echo "Subfolder selection regression tests passed"
