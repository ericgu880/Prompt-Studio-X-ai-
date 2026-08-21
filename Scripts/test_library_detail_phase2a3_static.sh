#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STARTUP_FILES=(
  "$ROOT/Sources/PromptStudio/AppState.swift"
  "$ROOT/Sources/PromptStudio/LibraryAccess.swift"
  "$ROOT/Sources/PromptStudio/Views/PromptStudioView.swift"
)

for file in "${STARTUP_FILES[@]}"; do
  test -f "$file"
done

# These checks intentionally inspect only normal app startup owners. The full
# O(N) tag/integrity/fk work remains available to explicit diagnostics and
# benchmark tools, but must not be linked into startup or the formal UI.
for pattern in \
  'validateTagRelationConsistency' \
  'prepareTagRelationMigration' \
  'runTagRelationBackfill' \
  'PRAGMA integrity_check' \
  'PRAGMA foreign_key_check' \
  'SQLiteDatabase.validateBackup' \
  'PromptStudioLibraryDetailBenchmark' \
  'PromptStudioTagRelationBenchmark'; do
  if rg -n "$pattern" "${STARTUP_FILES[@]}"; then
    echo "normal app startup contains forbidden full validation/benchmark linkage: $pattern" >&2
    exit 1
  fi
done

# The app may retain the normal repository/schema gate, but the phase2a3
# benchmark must remain an executable target and not an App/UI dependency.
rg -q 'PromptStudioLibraryDetailBenchmark' "$ROOT/Package.swift"
if rg -n 'PromptStudioLibraryDetailBenchmark' "$ROOT/Sources/PromptStudio" "$ROOT/Sources/PromptStudioCore"; then
  echo "benchmark target leaked into app/core startup sources" >&2
  exit 1
fi

echo "Phase 2A.3 startup static guard passed"
