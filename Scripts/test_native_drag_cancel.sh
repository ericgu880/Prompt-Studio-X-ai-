#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_FILE="$ROOT_DIR/Sources/PromptStudio/Views/PromptStudioView.swift"

if [[ ! -f "$SOURCE_FILE" ]]; then
    echo "PromptStudioView.swift is missing." >&2
    exit 1
fi

for required in \
    'func draggingSession(' \
    'endedAt screenPoint: NSPoint' \
    'let session = collectionView.beginDraggingSession(' \
    'session.animatesToStartingPositionsOnCancelOrFail = false' \
    'context == .withinApplication ? .move : []' \
    'activeDragContext = nil'; do
    if ! /usr/bin/grep -Fq "$required" "$SOURCE_FILE"; then
        echo "Missing native drag cancel contract: $required" >&2
        exit 1
    fi
done

if [[ $(/usr/bin/grep -Fc 'endedAt screenPoint: NSPoint' "$SOURCE_FILE") -ne 1 ]] || \
   [[ $(/usr/bin/grep -Fc 'let session = collectionView.beginDraggingSession(' "$SOURCE_FILE") -ne 1 ]] || \
   [[ $(/usr/bin/grep -A5 -F 'let session = collectionView.beginDraggingSession(' "$SOURCE_FILE" | \
        /usr/bin/grep -Fc 'session.animatesToStartingPositionsOnCancelOrFail = false') -ne 1 ]]; then
    echo "The collection view must own one drag session and disable failed-drag return animation when it starts." >&2
    exit 1
fi

if /usr/bin/grep -Eq 'NativeDragReturnAnimator|NativeDragReturnGhostView|if operation == \[\]' "$SOURCE_FILE"; then
    echo "Native drag cancellation must not add a return ghost or defer the setting until drag completion." >&2
    exit 1
fi

echo "Native drag cancel regression tests passed"
