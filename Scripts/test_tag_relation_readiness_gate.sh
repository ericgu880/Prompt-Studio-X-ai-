#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATION_FILE="$ROOT_DIR/Sources/PromptStudioCore/TagRelationMigration.swift"
APP_STATE_FILE="$ROOT_DIR/Sources/PromptStudio/AppState.swift"
REPOSITORY_FILE="$ROOT_DIR/Sources/PromptStudioCore/PromptRepository.swift"

gate_body="$(awk '
    /var tagRelationsReady: Bool/ { capture = 1 }
    capture { print }
    capture && /^    }$/ { exit }
' "$MIGRATION_FILE")"

grep -q 'tagRelationStructureIsReady' <<<"$gate_body"
if grep -Eq 'integrity_check|foreign_key_check|SELECT[[:space:]]+\*[^;]*prompt_items|FROM[[:space:]]+prompt_items' <<<"$gate_body"; then
    echo "tagRelationsReady must remain a lightweight schema gate" >&2
    exit 1
fi

if grep -Eq 'validateTagRelationConsistency|tagRelationStructureIsValid|prepareTagRelationMigration|runTagRelationBackfill' "$APP_STATE_FILE"; then
    echo "AppState startup must not invoke migration or deep tag validation" >&2
    exit 1
fi

ready_body="$(awk '
    /func tagRelationStructureIsReady\(\)/ { capture = 1 }
    capture { print }
    capture && /^    }$/ { exit }
' "$MIGRATION_FILE")"
if grep -Eq 'integrity_check|foreign_key_check|FROM[[:space:]]+prompt_items' <<<"$ready_body"; then
    echo "lightweight tag readiness must not scan prompt_items or run integrity checks" >&2
    exit 1
fi

# This slice guards only explicit before/after graph loads added to mutation
# methods. Legacy refreshTagsAfterMutation work is intentionally outside this
# assertion and remains a separate repository concern.
if grep -Eq 'loadItems(ByID)?\(|loadVersions\(' <(awk '
    /public func saveItem\(/ { capture = 1 }
    capture { print }
    capture && /public func copyAssetIntoLibrary/ { exit }
' "$REPOSITORY_FILE"); then
    echo "item-detail invalidation methods must not add before/after graph loads" >&2
    exit 1
fi

echo "tag relation readiness gate is lightweight and startup-safe"
