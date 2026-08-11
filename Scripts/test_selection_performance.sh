#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VIEW_FILE="$ROOT_DIR/Sources/PromptStudio/Views/PromptStudioView.swift"
STATE_FILE="$ROOT_DIR/Sources/PromptStudio/AppState.swift"

extract_declaration() {
    local file="$1"
    local start="$2"
    local end="$3"
    /usr/bin/sed -n "/$start/,/$end/p" "$file"
}

ASSET_CARD_SOURCE="$(extract_declaration \
    "$VIEW_FILE" \
    '^private struct AssetCardView: View {' \
    '^private struct AssetCardContentView: View')"

LAZY_MENU_SOURCE="$(extract_declaration \
    "$VIEW_FILE" \
    '^private final class LazyAssetContextMenuHostingView' \
    '^private final class NativeImageCardContentView')"

if [[ "$ASSET_CARD_SOURCE" == *'@EnvironmentObject private var state: AppState'* ]]; then
    echo "Fallback asset cards must not observe the monolithic AppState during selection." >&2
    exit 1
fi

if [[ "$ASSET_CARD_SOURCE" == *'.contextMenu {'* ]]; then
    echo "Fallback asset cards must not eagerly construct SwiftUI context menus during selection." >&2
    exit 1
fi

for required in \
    'private final class LazyAssetContextMenuHostingView' \
    'override func menu(for event: NSEvent) -> NSMenu?' \
    'state.folderDestinations()'; do
    if [[ "$LAZY_MENU_SOURCE" != *"$required"* ]]; then
        echo "Missing lazy fallback context-menu contract: $required" >&2
        exit 1
    fi
done

if [[ "$LAZY_MENU_SOURCE" == *'state.folderRows()'* ]]; then
    echo "Move-to-folder menus must not compute recursive folder counts." >&2
    exit 1
fi

for required in \
    'struct FolderDestination: Identifiable, Equatable' \
    'func folderDestinations() -> [FolderDestination]'; do
    if ! /usr/bin/grep -Fq "$required" "$STATE_FILE"; then
        echo "Missing lightweight folder destination API: $required" >&2
        exit 1
    fi
done

if /usr/bin/grep -Eq '@Published[[:space:]]+var[[:space:]]+selectedID|@Published[[:space:]]+var[[:space:]]+selectedIDs' "$STATE_FILE"; then
    echo "Primary and multi-selection must not publish two independent global updates." >&2
    exit 1
fi

for required in \
    'struct SelectionState: Equatable' \
    '@Published private var selectionState = SelectionState()' \
    'private func updateSelection(ids: Set<String>, primaryID: String?)'; do
    if ! /usr/bin/grep -Fq "$required" "$STATE_FILE"; then
        echo "Missing atomic selection publication contract: $required" >&2
        exit 1
    fi
done

echo "Selection performance regression tests passed"
