#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICE="$ROOT_DIR/Sources/PromptStudioCore/MediaImportService.swift"
STATE="$ROOT_DIR/Sources/PromptStudio/AppState.swift"
VIEW="$ROOT_DIR/Sources/PromptStudio/Views/PromptStudioView.swift"
PROGRESS_VIEW="$ROOT_DIR/Sources/PromptStudio/Views/BatchImportProgressView.swift"
PERFORMANCE_STATE="$ROOT_DIR/Sources/PromptStudio/LibraryPerformanceState.swift"

require_pattern() {
    local file="$1" pattern="$2" message="$3"
    if ! /usr/bin/grep -qE "$pattern" "$file"; then
        echo "$message" >&2
        exit 1
    fi
}

reject_pattern_in_function() {
    local file="$1" start="$2" end="$3" pattern="$4" message="$5"
    local body
    body="$(/usr/bin/awk -v start="$start" -v end="$end" '
        index($0, start) { capture = 1 }
        capture { print }
        capture && $0 ~ end { exit }
    ' "$file")"
    if /usr/bin/grep -qE "$pattern" <<<"$body"; then
        echo "$message" >&2
        exit 1
    fi
}

require_pattern "$SERVICE" 'public actor MediaImportService' \
    "Batch imports must run through the Core media import actor."
require_pattern "$SERVICE" 'maxConcurrentFileTasks' \
    "Batch imports must enforce bounded file-processing concurrency."
require_pattern "$SERVICE" 'try repository\.saveItems\(preparedItems\)' \
    "Batch imports must persist with one saveItems transaction."
require_pattern "$STATE" 'let importProgressState = ImportProgressState\(\)' \
    "AppState must own a locally observed import progress state."
require_pattern "$PERFORMANCE_STATE" 'final class ImportProgressState: ObservableObject' \
    "Import progress must be isolated from AppState.objectWillChange."
require_pattern "$STATE" 'await Task\.yield\(\)' \
    "The scanning state must yield a render opportunity before background work."
require_pattern "$STATE" 'await mediaImportService\.scan' \
    "Directory expansion must run outside MainActor."
require_pattern "$STATE" 'await mediaImportService\.importFiles' \
    "File preparation and persistence must run outside MainActor."
reject_pattern_in_function "$STATE" 'func importFiles\(_ urls:' '^    }$' 'repository\.saveItem\(' \
    "AppState importFiles must not save one item per transaction."
reject_pattern_in_function "$STATE" 'func importFiles\(_ urls:' '^    }$' 'expandedImportURLs\(' \
    "AppState importFiles must not scan directories on MainActor."
require_pattern "$VIEW" 'BatchImportProgressOverlay' \
    "The homepage must render batch import progress."
require_pattern "$PROGRESS_VIEW" 'ProgressView' \
    "The batch import status must include progress feedback."
require_pattern "$VIEW" 'canReadFileURLs\(from: sender\)' \
    "Drag hover must use a low-cost file capability check."
reject_pattern_in_function "$VIEW" 'override func draggingUpdated' '^        }$' 'fileURLs\(from: sender\)' \
    "draggingUpdated must not materialize every dropped URL."
if /usr/bin/grep -qE 'prepareMissingThumbnails\(' "$STATE"; then
    echo "Import completion must not queue non-visible thumbnails." >&2
    exit 1
fi

echo "Batch media import regression tests passed"
