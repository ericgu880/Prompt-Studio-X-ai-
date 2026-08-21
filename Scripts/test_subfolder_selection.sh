#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_FILE="$ROOT_DIR/Sources/PromptStudio/Views/PromptStudioView.swift"

lazy_host_body="$(sed -n '/private final class LazyAssetContextMenuHostingView/,/private final class NativeAssetSelectionChromeView/p' "$SOURCE_FILE")"
if ! grep -q 'folderOpenButtonRect' <<<"$lazy_host_body" || ! grep -q 'return super\.hitTest(point)' <<<"$lazy_host_body"; then
    echo "Native folder drag handling must preserve SwiftUI hit testing for the open button." >&2
    exit 1
fi

subfolder_body="$(sed -n '/private struct SubfolderCardView: View/,/private struct ImmediateFolderClickCapture/p' "$SOURCE_FILE")"
if ! grep -q 'Image(systemName: "arrow.right")' <<<"$subfolder_body"; then
    echo "Subfolder card must retain its explicit open button." >&2
    exit 1
fi

snapshot_body="$(sed -n '/private static func candidateIDs/,/private static func matches/p' "$ROOT_DIR/Sources/PromptStudioCore/LibraryFilterSnapshot.swift")"
if ! grep -q 'case \.folder(let folderID)' <<<"$snapshot_body" || ! grep -q 'state\.folderIDs\[folderID\]' <<<"$snapshot_body"; then
    echo "Folder navigation must filter direct assets only; descendants are opened separately." >&2
    exit 1
fi

echo "Subfolder selection regression tests passed"
