#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPSTATE="$ROOT_DIR/Sources/PromptStudio/AppState.swift"
INTEGRATION="$ROOT_DIR/Sources/PromptStudio/SummaryAppStateIntegration.swift"
PREVIEW="$ROOT_DIR/Sources/PromptStudio/Views/PromptStudioView.swift"
INSPECTOR="$ROOT_DIR/Sources/PromptStudio/Views/InspectorView.swift"
OVERLAYS="$ROOT_DIR/Sources/PromptStudio/Views/Overlays.swift"
SUMMARY_LIST="$ROOT_DIR/Sources/PromptStudio/Views/SummaryListView.swift"
SUMMARY_MASONRY="$ROOT_DIR/Sources/PromptStudio/Views/SummaryMasonryCollectionView.swift"
APP="$ROOT_DIR/Sources/PromptStudio/PromptStudioApp.swift"
SESSION="$ROOT_DIR/Sources/PromptStudioCore/PreviewPageSession.swift"
REPOSITORY="$ROOT_DIR/Sources/PromptStudioCore/PromptRepository.swift"
TAG_MIGRATION="$ROOT_DIR/Sources/PromptStudioCore/TagRelationMigration.swift"

require_literal() {
    local file="$1"
    local literal="$2"
    local label="$3"
    if ! rg -Fq "$literal" "$file"; then
        echo "missing ${label}: ${literal}" >&2
        exit 1
    fi
}

require_literal "$SESSION" 'public final class PreviewPageSession' 'preview session owner'
require_literal "$SESSION" 'queryFingerprint' 'session query fingerprint'
require_literal "$SESSION" 'dataRevision' 'session data revision'
require_literal "$SESSION" 'generation' 'session generation'
require_literal "$SESSION" 'loadedSummaryIDs' 'resident Summary IDs'
require_literal "$SESSION" 'tailLoadInFlight' 'single tail request guard'
require_literal "$SESSION" 'detailController.select(id: selectedID)' 'exact-ID shared detail selection'
require_literal "$APPSTATE" 'var selectedItemID: String?' 'immediate Summary identity source'
require_literal "$APPSTATE" 'summaryPreviewPageSession' 'AppState session ownership'
require_literal "$APPSTATE" 'return summaryDetailController?.currentDetail' 'shared detail content source'
require_literal "$INTEGRATION" 'navigateSummaryPreview' 'production preview navigation seam'
require_literal "$PREVIEW" 'SummaryPreviewHost' 'production detail state host'
require_literal "$PREVIEW" 'state.beginSummaryPreviewNavigation' 'owned PreviewPageSession navigation wiring'
require_literal "$INSPECTOR" 'summaryFolderInfoInspector' 'projection-only Summary inspector folder path'
require_literal "$INSPECTOR" 'SummaryInspectorDetailStateView' 'Inspector shared detail state path'
require_literal "$OVERLAYS" 'init(summary: LibraryItemSummary' 'Summary preview rail identity path'
require_literal "$APP" 'if !appState.isLibraryReady' 'startup readiness guard'
require_literal "$APPSTATE" 'includeLegacyItems: false' 'cold startup projection path'
require_literal "$APPSTATE" 'loadLegacyItemsForExplicitSummaryMode' 'explicit legacy seam'
require_literal "$TAG_MIGRATION" 'refreshTagsFromMetadataJSON' 'seed-time metadata-only tag refresh'
require_literal "$REPOSITORY" 'SELECT id FROM prompt_items LIMIT 1;' 'ID-only seed probe'

for file in "$SUMMARY_LIST" "$SUMMARY_MASONRY"; do
    if rg -n 'PromptItem\s*\(' "$file"; then
        echo "Summary surface must not construct/decode PromptItem values: $file" >&2
        exit 1
    fi
    if rg -n 'state\.(items|filteredItems)|\bloadItems\s*\(' "$file"; then
        echo "Summary surface contains a legacy full-item boundary: $file" >&2
        exit 1
    fi
done

if rg -n '\bloadItems\s*\(' "$APP" "$PREVIEW" "$INSPECTOR" "$OVERLAYS"; then
    echo 'ordinary SwiftUI Summary/preview/inspector files must not call loadItems' >&2
    exit 1
fi

echo 'Approved loadItems callsite classification:'
rg -n '\bloadItems\s*\(' "$ROOT_DIR/Sources" | while IFS=: read -r file line text; do
    case "$file:$line" in
        *"Sources/PromptStudio/AppState.swift"*)
            echo "  explicit legacy startup seam: $file:$line" ;;
        *"Sources/PromptStudioCore/PromptRepository.swift"*)
            echo "  approved legacy loader definition: $file:$line" ;;
        *"Sources/PromptStudioCore/TagRelationMigration.swift"*)
            echo "  migration fallback (metadata-only path must remain ordinary-safe): $file:$line" ;;
        *"PromptStudioAutomationService.swift"*)
            echo "  explicit automation maintenance: $file:$line" ;;
        *"Sources/PromptStudioPhase2A4Benchmark/"*)
            echo "  benchmark-only legacy oracle: $file:$line" ;;
        *"Sources/PromptStudioCore/ItemDetailService.swift"*)
            echo "  detail-service documentation only: $file:$line" ;;
        *"Sources/PromptStudioCoreUnitTests/"*|*"Tests/"*)
            echo "  fixture/test-only repository load: $file:$line" ;;
        *)
            echo "  UNCLASSIFIED: $file:$line" >&2
            exit 1 ;;
    esac
done

echo 'Detail startup v1 static validation passed.'
