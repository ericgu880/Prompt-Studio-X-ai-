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
    'operation == []' \
    'session.animatesToStartingPositionsOnCancelOrFail = false' \
    'context == .withinApplication ? .move : []' \
    'dragStartLocation = nil' \
    'hasStartedDragging = false'; do
    if ! /usr/bin/grep -Fq "$required" "$SOURCE_FILE"; then
        echo "Missing native drag cancel contract: $required" >&2
        exit 1
    fi
done

if [[ $(/usr/bin/grep -Fc 'endedAt screenPoint: NSPoint' "$SOURCE_FILE") -ne 2 ]] || \
   [[ $(/usr/bin/grep -Fc 'session.animatesToStartingPositionsOnCancelOrFail = false' "$SOURCE_FILE") -ne 2 ]]; then
    echo "Image and Markdown native cards must both disable failed-drag return animation." >&2
    exit 1
fi

if /usr/bin/grep -Eq 'NativeDragReturnAnimator|NativeDragReturnGhostView' "$SOURCE_FILE"; then
    echo "Native drag cancellation must not add a return ghost." >&2
    exit 1
fi

echo "Native drag cancel regression tests passed"
