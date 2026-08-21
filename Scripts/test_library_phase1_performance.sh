#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
app_state="$root/Sources/PromptStudio/AppState.swift"
view="$root/Sources/PromptStudio/Views/PromptStudioView.swift"
state_objects="$root/Sources/PromptStudio/LibraryPerformanceState.swift"

test -f "$state_objects"
rg -q 'final class LibraryFilterController: ObservableObject' "$state_objects"
rg -q 'final class LibraryStatisticsCache: ObservableObject' "$state_objects"
rg -q 'final class ThumbnailUpdateState: ObservableObject' "$state_objects"
rg -q 'final class ImportProgressState: ObservableObject' "$state_objects"
rg -q 'Task\.sleep\(for: \.milliseconds\(200\)\)' "$state_objects"

rg -q 'LibraryFilterSnapshot' "$app_state"
rg -q 'filterTask\?\.cancel\(\)' "$app_state"
rg -q 'libraryFilterController' "$view"
rg -q 'importProgressState' "$view"
rg -q 'libraryStatisticsCache' "$view"
rg -q 'thumbnailUpdateState' "$view"

if rg -q 'items\.filter \{ !\$0\.isDeleted \}\.count' "$view"; then
  echo 'Sidebar must not scan all items for its count.' >&2
  exit 1
fi
if rg -q 'prepareMissingThumbnails\(\)' "$app_state"; then
  echo 'Startup must not queue every missing thumbnail.' >&2
  exit 1
fi
if rg -q 'scheduleReferenceThumbnailBackfill\(\)' "$app_state"; then
  echo 'Startup/reload must not prewarm every reference thumbnail.' >&2
  exit 1
fi
if rg -q 'try repository\?\.updateThumbnailPath\(itemID:' "$app_state"; then
  echo 'Generated thumbnail persistence must be batched.' >&2
  exit 1
fi

echo 'Library Phase 1 performance regression checks passed.'
