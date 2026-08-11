#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_FILE="$ROOT_DIR/Sources/PromptStudio/Views/PromptStudioView.swift"

for required in \
    'private final class LazyAssetContextMenuHostingView: NSHostingView<AnyView>' \
    'private final class NativeFallbackCardDraggingSource: NSObject, NSDraggingSource' \
    'override func mouseDown(with event: NSEvent)' \
    'selectAction?(event.modifierFlags)' \
    'override func mouseDragged(with event: NSEvent)' \
    'let session = beginDraggingSession(with: [draggingItem], event: event, source: draggingSource)' \
    'session.animatesToStartingPositionsOnCancelOrFail = false' \
    'usesNativeInput: true'; do
    if ! /usr/bin/grep -Fq "$required" "$SOURCE_FILE"; then
        echo "Missing native fallback-card input contract: $required" >&2
        exit 1
    fi
done

if [[ $(/usr/bin/grep -Fc 'usesNativeInput: true' "$SOURCE_FILE") -ne 1 ]]; then
    echo "Only the active NSCollectionView fallback-card path should enable native input." >&2
    exit 1
fi

echo "Native fallback-card selection input regression tests passed"
