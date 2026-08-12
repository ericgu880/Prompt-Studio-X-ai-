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
grep -q 'selectFolderForPreview' "$PROMPT_VIEW"
grep -q 'folderInfoInspector(for:' "$INSPECTOR"
grep -q 'infoLine("文件名", folder.name)' "$INSPECTOR"
grep -q 'infoLine("文件数",' "$INSPECTOR"
grep -q 'infoLine("Size",' "$INSPECTOR"
grep -q 'infoLine("创建日期",' "$INSPECTOR"
grep -q 'var createdAt: Date' "$ROOT/Sources/PromptStudioCore/Models.swift"
grep -q 'createdAt TEXT NOT NULL' "$ROOT/Sources/PromptStudioCore/PromptRepository.swift"
grep -q 'migrateLibraryFoldersSchema' "$ROOT/Sources/PromptStudioCore/PromptRepository.swift"

echo "folder inspector preview regression checks passed"
