#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_FILE="$ROOT_DIR/Sources/PromptStudio/Views/PromptStudioView.swift"

for required in \
    'private final class NativeAssetSelectionChromeView: NSView' \
    'private var selectionChromeView: NativeAssetSelectionChromeView?' \
    'selectionChromeView?.setSelected(isSelected)' \
    'rendersSelectionChrome: false' \
    'let deselectedItemIDs = previousItemIDs.subtracting(nextItemIDs)' \
    'let selectedItemIDs = nextItemIDs.subtracting(previousItemIDs)' \
    'updateSelectionVisuals(itemIDs: deselectedItemIDs, isSelected: false)' \
    'updateSelectionVisuals(itemIDs: selectedItemIDs, isSelected: true)' \
    'CATransaction.setDisableActions(true)'; do
    if ! /usr/bin/grep -Fq "$required" "$SOURCE_FILE"; then
        echo "Missing immediate cross-format selection contract: $required" >&2
        exit 1
    fi
done

if /usr/bin/grep -Fq 'private final class AssetCardSelectionState: ObservableObject' "$SOURCE_FILE"; then
    echo "Fallback cards must not use asynchronous ObservableObject selection chrome." >&2
    exit 1
fi

if /usr/bin/grep -Fq '.transition(.opacity)' "$SOURCE_FILE"; then
    echo "Card selection chrome must not fade between selected items." >&2
    exit 1
fi

echo "Immediate selection chrome regression tests passed"
