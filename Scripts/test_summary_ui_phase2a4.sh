#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/Scripts/swift_toolchain.sh"

CORE_FILE="$ROOT_DIR/Sources/PromptStudioCore/LibrarySummaryPagination.swift"
COORDINATOR_FILE="$ROOT_DIR/Sources/PromptStudio/Views/SummaryMasonryCollectionView.swift"
LIST_FILE="$ROOT_DIR/Sources/PromptStudio/Views/SummaryListView.swift"
APPSTATE_FILE="$ROOT_DIR/Sources/PromptStudio/SummaryAppStateIntegration.swift"
APPSTATE_BASE_FILE="$ROOT_DIR/Sources/PromptStudio/AppState.swift"
HOST_FILE="$ROOT_DIR/Sources/PromptStudio/Views/PromptStudioView.swift"
PROVIDER_FILE="$ROOT_DIR/Sources/PromptStudio/Views/SummaryProviderLoadState.swift"
CACHE_FILE="$ROOT_DIR/Sources/PromptStudio/SharedThumbnailImageCache.swift"
REPOSITORY_FILE="$ROOT_DIR/Sources/PromptStudioCore/PromptRepository.swift"
TEST_FILE="$ROOT_DIR/Tests/PromptStudioSummaryUITests/SummaryCollectionCoordinatorTests.swift"
SUMMARY_TEST_FILE="$ROOT_DIR/Tests/PromptStudioSummaryUITests/SummaryAppStateIntegrationTests.swift"
CORE_TEST_FILE="$ROOT_DIR/Tests/PromptStudioCoreTests/LibraryBrowserStateTests.swift"
SUMMARY_RENDERER_TEST="$ROOT_DIR/Tests/PromptStudioSummaryUITests/SummaryAttachedRendererTests.swift"
SUMMARY_PROVIDER_TEST="$ROOT_DIR/Tests/PromptStudioSummaryUITests/SummaryProviderLoadTests.swift"
DETAIL_FILE="$ROOT_DIR/Sources/PromptStudioCore/ItemDetailService.swift"

require_literal() {
    local file="$1"
    local literal="$2"
    local label="$3"
    if ! rg -Fq "$literal" "$file"; then
        echo "missing ${label}: ${literal}" >&2
        exit 1
    fi
}

require_literal "$CORE_FILE" 'public static let pageSize = 300' 'fixed Summary page size'
require_literal "$CORE_FILE" 'public func prefetchIfNeeded(visibleRect: CGRect, contentHeight: CGFloat) async' 'prefetch entry point'
require_literal "$CORE_FILE" 'visibleRect.height * 2' 'two-viewport prefetch bound'
require_literal "$COORDINATOR_FILE" 'final class SummaryMasonryCollectionCoordinator' 'native coordinator'
require_literal "$COORDINATOR_FILE" 'NSCollectionViewDataSource' 'native data source'
require_literal "$COORDINATOR_FILE" 'collectionView.insertItems(at: Set(indexPaths))' 'incremental append'
require_literal "$COORDINATOR_FILE" 'collectionView.reloadItems(at: changedPaths)' 'append targeted reload'
require_literal "$COORDINATOR_FILE" 'let changedPaths = Set(existingContentChanges.compactMap(indexPath(for:)))' 'append folder/item path union'
require_literal "$COORDINATOR_FILE" 'let paths = Set(contentChanges.compactMap(indexPath(for:)))' 'targeted folder/item path union'
require_literal "$COORDINATOR_FILE" 'let geometryChanges = changedEntries(old: entries, new: nextEntries, geometryOnly: true)' 'item-only geometry path'
require_literal "$COORDINATOR_FILE" 'NSHostingView' 'hosted Summary card callback'
require_literal "$COORDINATOR_FILE" 'override func menu(for event: NSEvent) -> NSMenu?' 'native Summary context menu'
require_literal "$COORDINATOR_FILE" 'SummaryContextMenuActionTarget' 'context menu action target'
require_literal "$COORDINATOR_FILE" 'PromptItemDragPayload(itemIDs: ids)' 'multi-ID item drag payload'
require_literal "$COORDINATOR_FILE" 'FolderDragPayload(folderIDs: ids)' 'multi-ID folder drag payload'
require_literal "$CACHE_FILE" 'representedGeneration' 'generation-scoped loader cancellation'
require_literal "$CACHE_FILE" '[ThumbnailImageRequest: Set<UUID>]' 'request-scoped thumbnail waiters'
require_literal "$LIST_FILE" 'SummaryListItemRow' 'Summary list source'
require_literal "$LIST_FILE" 'SummaryListInteractionSupport' 'List ID-native selection ordering'
require_literal "$LIST_FILE" 'SummaryListDropCoordinator' 'List asynchronous drop coordinator'
require_literal "$LIST_FILE" 'return false' 'List drop fail-closed callback'
require_literal "$APPSTATE_FILE" 'updateItemFolderIDs' 'typed ID-only folder mutation'
require_literal "$APPSTATE_BASE_FILE" 'summaryAttachError = error.localizedDescription' 'attach fail-closed state'
require_literal "$HOST_FILE" 'else if summaryGate == .failClosed' 'visible attach failure'
require_literal "$HOST_FILE" 'items: state.loadLegacyItemsForExplicitSummaryMode()' 'explicit legacy-only full-item boundary'
require_literal "$APPSTATE_BASE_FILE" 'if summaryPaginator == nil,' 'Summary selection avoids legacy full-item priority path'
require_literal "$APPSTATE_BASE_FILE" 'await summaryPaginator.cancelAndWait()' 'AppState physical Summary teardown barrier'
require_literal "$APPSTATE_BASE_FILE" 'await summaryMutationRefreshTask.value' 'AppState mutation task teardown barrier'
require_literal "$APPSTATE_BASE_FILE" 'includeLegacyItems: false' 'normal startup projection-only load'
require_literal "$APPSTATE_BASE_FILE" 'loadLegacyItemsForExplicitSummaryMode' 'explicit legacy load entry point'
require_literal "$PROVIDER_FILE" 'private var timeoutTask: Task<Void, Never>?' 'provider timeout task ownership'
require_literal "$PROVIDER_FILE" 'guard !finished else {' 'provider single-publication guard'
require_literal "$PROVIDER_FILE" 'timeoutTask?.cancel()' 'provider timeout cancellation'
require_literal "$REPOSITORY_FILE" 'SELECT id FROM prompt_items LIMIT 1;' 'seed ID-only probe'
require_literal "$CORE_FILE" 'case replacement' 'replacement error phase'
require_literal "$CORE_FILE" 'case append' 'append error phase'
require_literal "$CORE_FILE" 'summaries = []' 'replacement clears stale rows'
require_literal "$CORE_FILE" 'isStaleRevisionError' 'stale append replacement classification'
require_literal "$CORE_FILE" 'lastFailedQuery = replacementQuery' 'stale append retry query'
require_literal "$CORE_FILE" 'public func cancelAndWait() async' 'paginator teardown barrier'
require_literal "$DETAIL_FILE" 'public func itemDetail(id: String) async throws -> PromptItem?' 'ID-based Detail loader'
require_literal "$COORDINATOR_FILE" 'collectionView.onMarqueeBegin' 'marquee begin wiring'
require_literal "$COORDINATOR_FILE" 'collectionView.onMarqueeChange' 'marquee change wiring'
require_literal "$COORDINATOR_FILE" 'collectionView.onMarqueeEnd' 'marquee end wiring'
require_literal "$COORDINATOR_FILE" 'collectionView.onMarqueeCancel' 'marquee cancel wiring'
require_literal "$COORDINATOR_FILE" 'collectionView.onBlankClick' 'blank-click selection wiring'
require_literal "$LIST_FILE" '.onDrag' 'List folder drag origin'
require_literal "$PROVIDER_FILE" 'lock.lock()' 'provider continuation lock ownership'
require_literal "$PROVIDER_FILE" 'lock.unlock()' 'provider continuation lock release'
require_literal "$TEST_FILE" 'reloadHistory == [Set([IndexPath(item: 0, section: 0)])]' 'folder append witness'
require_literal "$TEST_FILE" 'summaryListFolderMultiDragAndAsyncDrop' 'List multi-folder drag/drop witness'
require_literal "$SUMMARY_TEST_FILE" 'summaryStartupBoundaryUsesRealRepositoryCounter' 'real repository startup boundary witness'
require_literal "$SUMMARY_TEST_FILE" 'appStateTeardownWaitsForPhysicalSummaryRequest' 'AppState teardown witness'
require_literal "$SUMMARY_RENDERER_TEST" 'nativeMarquee.onMarqueeBegin != nil' 'attached Summary marquee witness'
require_literal "$SUMMARY_PROVIDER_TEST" 'summaryProviderCancellationRacingTimeoutInstallation' 'provider cancellation race witness'
require_literal "$CORE_TEST_FILE" 'summaryPaginatorCancelAndWaitSettlesPhysicalRequest' 'paginator physical teardown witness'
require_literal "$CORE_TEST_FILE" 'staleAppendRetryRestartsCommittedQuery' 'stale append retry witness'
require_literal "$CORE_TEST_FILE" 'await executor.waitForPageStart(1)' 'deterministic one-flight witness'
require_literal "$CORE_TEST_FILE" 'cursorDidNotContinue' 'keyset cursor witness'

if rg -n 'PromptItem\(' "$COORDINATOR_FILE" "$LIST_FILE"; then
    echo 'Summary surfaces must not decode full PromptItem values.' >&2
    exit 1
fi

if [[ "${SUMMARY_UI_STATIC_ONLY:-0}" == "1" ]]; then
    echo 'Summary Phase 2A.4 static validation passed.'
    exit 0
fi

SWIFT_EXEC="$(find_compatible_swift_tool swift "${SWIFT_EXEC:-}")"
"$SWIFT_EXEC" build --package-path "$ROOT_DIR" --target PromptStudio
"$SWIFT_EXEC" test --package-path "$ROOT_DIR" --filter PromptStudioCoreTests
"$SWIFT_EXEC" test --package-path "$ROOT_DIR" --filter PromptStudioSummaryUITests
"$ROOT_DIR/Scripts/test_masonry_layout_index.sh"

echo 'Summary Phase 2A.4.2-2A.4.3 validation passed.'
