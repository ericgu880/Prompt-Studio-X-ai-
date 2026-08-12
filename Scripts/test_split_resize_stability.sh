#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VIEW_FILE="$ROOT_DIR/Sources/PromptStudio/Views/PromptStudioView.swift"

require_pattern() {
    local pattern="$1"
    local message="$2"
    if ! /usr/bin/grep -Fq "$pattern" "$VIEW_FILE"; then
        echo "$message" >&2
        exit 1
    fi
}

require_pattern \
    'DragGesture(minimumDistance: 0, coordinateSpace: .global)' \
    'Split resize drag translation must use the stable global coordinate space.'
require_pattern \
    'isSplitResizing: isSplitResizing,' \
    'The native masonry coordinator must receive the active split-resize state.'
require_pattern \
    'guard !isSplitResizing else {' \
    'The native masonry grid must defer expensive relayout while a divider is moving.'
require_pattern \
    'guard !isSplitResizing, pendingDatasetUpdate == nil else { return }' \
    'Viewport notifications must not reload the native masonry grid during split resize.'

echo "Split resize stability regression tests passed"
