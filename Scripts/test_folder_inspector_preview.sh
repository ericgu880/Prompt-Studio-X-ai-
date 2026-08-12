#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_STATE="$ROOT/Sources/PromptStudio/AppState.swift"
INSPECTOR="$ROOT/Sources/PromptStudio/Views/InspectorView.swift"
PROMPT_VIEW="$ROOT/Sources/PromptStudio/Views/PromptStudioView.swift"

grep -q 'selectedFolderID' "$APP_STATE"
grep -q 'var selectedFolder: LibraryFolder?' "$APP_STATE"
grep -q 'func selectFolderForPreview' "$APP_STATE"
grep -q 'func clearSelectedFolder' "$APP_STATE"
grep -q 'state.selectedFolder' "$INSPECTOR"
grep -q 'folderInspector(for:' "$INSPECTOR"
grep -q 'selectFolderForPreview' "$PROMPT_VIEW"
grep -q 'folderStatRow' "$INSPECTOR"

echo "folder inspector preview regression checks passed"
