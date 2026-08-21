@preconcurrency import AppKit
import Testing
import PromptStudioCore
@testable import PromptStudio

@Test("Summary attach failure is fail-closed unless the user explicitly selects legacy mode")
func summaryAttachFailureLegacyGate() {
    #expect(summarySurfaceGateDecision(hasPaginator: false, attachError: "attach failed", explicitLegacyMode: false) == .failClosed)
    #expect(summarySurfaceGateDecision(hasPaginator: false, attachError: "attach failed", explicitLegacyMode: true) == .explicitLegacy)
    #expect(summarySurfaceGateDecision(hasPaginator: true, attachError: "attach failed", explicitLegacyMode: true) == .attached)
}

@MainActor
@Test("Attached Summary never evaluates the legacy PromptItem boundary or alignment inputs")
func attachedSummarySkipsLegacyProjectionBoundary() {
    let decodeObservation = SummaryRendererDecodeInstrumentation.beginObservation()
    let fixture = appStatePromptFixture(id: "legacy-boundary", title: "Boundary")
    var legacyItemsEvaluated = false
    func trackedItems() -> [PromptItem] {
        legacyItemsEvaluated = true
        return [fixture]
    }

    let normalItems = legacyPromptItemsForRenderingIfExplicit(.attached, items: trackedItems())
    #expect(normalItems.isEmpty)
    #expect(legacyItemsEvaluated == false)
    #expect(decodeObservation.delta == 0)

    var legacyAlignmentEvaluated = false
    func trackedLegacyEmpty() -> Bool {
        legacyAlignmentEvaluated = true
        return true
    }
    #expect(
        summaryContentFrameAlignment(
            isLibraryReady: true,
            hasSummary: true,
            summaryIsEmpty: false,
            summaryFoldersAreEmpty: true,
            legacyItemsAreEmpty: trackedLegacyEmpty(),
            legacyFoldersAreEmpty: true
        ) == .topLeading
    )
    #expect(legacyAlignmentEvaluated == false)

    let explicitItems = legacyPromptItemsForRenderingIfExplicit(.explicitLegacy, items: trackedItems())
    #expect(explicitItems.map(\.id) == ["legacy-boundary"])
    #expect(legacyItemsEvaluated)
    #expect(decodeObservation.delta == 1)
}

@Test("Summary typed capabilities retain every legacy open/reveal/export/move/import action")
func summaryTypedCapabilitiesCoverLegacyActions() {
    #expect(SummaryItemContextAction.allCases.contains(.openDefaultApplication))
    #expect(SummaryItemContextAction.allCases.contains(.revealInFinder))
    #expect(SummaryItemContextAction.allCases.contains(.export))
    #expect(SummaryItemContextAction.allCases.contains(.move))
    #expect(SummaryFolderContextAction.allCases.contains(.importAssets))
    #expect(SummaryFolderContextAction.allCases.contains(.export))
    let detailDependent = SummaryItemContextCapability(
        action: .export,
        enabled: false,
        reason: "需要打开项目详情后使用"
    )
    let folderImport = SummaryFolderContextCapability(
        action: .importAssets,
        enabled: false,
        reason: "请从导入面板选择目标文件夹"
    )
    #expect(!detailDependent.enabled && detailDependent.reason != nil)
    #expect(!folderImport.enabled && folderImport.reason != nil)
}

@MainActor
@Test("Normal Summary startup skips full-item loading while explicit legacy loads a temp repository")
func summaryStartupBoundaryUsesRealRepositoryCounter() throws {
    let libraryURL = URL(fileURLWithPath: "/tmp/PromptStudio-SummaryStartupBoundary-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: libraryURL) }
    try PromptRepository.createLibraryDirectories(at: libraryURL)
    let repository = try PromptRepository(libraryURL: libraryURL)
    try repository.bootstrap()
    let folder = LibraryFolder(id: "folder-boundary", name: "Boundary")
    try repository.saveFolder(folder)
    try repository.saveItem(appStatePromptFixture(id: "item-boundary", title: "Boundary"))

    let state = AppState(libraryURL: libraryURL)
    let normalObservation = SummaryStartupBoundaryInstrumentation.beginObservation(for: libraryURL)
    #expect(try state.loadRepositoryItemCountForTesting(repository: repository, explicitLegacyMode: false) == 0)
    #expect(normalObservation.delta == 0)

    let explicitObservation = SummaryStartupBoundaryInstrumentation.beginObservation(for: libraryURL)
    #expect(try state.loadRepositoryItemCountForTesting(repository: repository, explicitLegacyMode: true) == 1)
    #expect(explicitObservation.delta == 1)
}

@MainActor
@Test("Cold DEBUG seed keeps Summary startup at zero full-item loads")
func coldDebugSeedDoesNotCrossLegacyLoadBoundary() throws {
    let libraryURL = URL(fileURLWithPath: "/tmp/PromptStudio-SummaryColdSeed-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: libraryURL) }
    try PromptRepository.createLibraryDirectories(at: libraryURL)
    let repository = try PromptRepository(libraryURL: libraryURL)
    try repository.bootstrap()

    let loadObservation = PromptRepositoryLoadInstrumentation.beginObservation(for: libraryURL)
    let legacyObservation = SummaryStartupBoundaryInstrumentation.beginObservation(for: libraryURL)
    try repository.seedIfNeeded(
        items: [appStatePromptFixture(id: "cold-seed", title: "Cold seed")],
        models: [],
        tags: []
    )

    #expect(loadObservation.delta == 0)
    #expect(legacyObservation.delta == 0)
}

@MainActor
@Test("Summary empty ID callbacks clear the opposite selection domain")
func summaryEmptyIDCallbacksClearOppositeSelectionDomain() {
    let state = AppState(libraryURL: URL(fileURLWithPath: "/tmp/PromptStudio-SummarySelection-\(UUID().uuidString)"))

    state.selectFolders(ids: ["folder-a"], primaryID: "folder-a")
    state.selectSummaryItems([])
    #expect(state.selectedIDs.isEmpty)
    #expect(state.selectedFolderIDs.isEmpty)

    state.selectItems(ids: ["item-a"], primaryID: "item-a")
    state.selectSummaryFolderIDs([])
    #expect(state.selectedIDs.isEmpty)
    #expect(state.selectedFolderIDs.isEmpty)

    state.selectFolders(ids: ["folder-a"], primaryID: "folder-a")
    state.selectSummaryItems(["item-a"])
    #expect(state.selectedIDs == ["item-a"])
    #expect(state.selectedFolderIDs.isEmpty)
}

@MainActor
@Test("Delete capability uses resident Summary IDs when the legacy item array is empty")
func summaryDeleteCapabilityUsesResidentRows() async {
    let executor = DeleteCapabilitySummaryExecutor()
    let service = LibraryQueryService(executor: executor, capabilities: .itemSequence)
    let browser = LibraryBrowserState(service: service, initialQuery: LibraryQuery(pageSize: 300))
    let paginator = LibrarySummaryPaginator(browser: browser)
    let state = AppState(libraryURL: URL(fileURLWithPath: "/tmp/PromptStudio-SummaryDeleteCapability-\(UUID().uuidString)"))
    state.installSummaryPaginatorForTesting(paginator)

    await paginator.replace(query: LibraryQuery(pageSize: 300))
    state.selectSummaryItems(["item-a"])
    #expect(state.items.isEmpty)
    #expect(state.deleteSelectionCapability == .items(Set(["item-a"])))
    #expect(state.canDeleteSelection)

    state.selectSummaryItems(["item-deleted"])
    #expect(state.deleteSelectionCapability == .none)
    #expect(!state.canDeleteSelection)

    state.selectSummaryItems([])
    state.folders = [LibraryFolder(id: "folder-a", name: "A")]
    state.selectSummaryFolderIDs(["folder-a"])
    #expect(state.deleteSelectionCapability == .folders(Set(["folder-a"])))
}

@MainActor
@Test("Summary folder deletion confirmation counts live subtree items without loading legacy items")
func summaryFolderDeleteConfirmationUsesMetadataCount() async throws {
    let libraryURL = URL(fileURLWithPath: "/tmp/PromptStudio-SummaryFolderCount-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: libraryURL) }
    try PromptRepository.createLibraryDirectories(at: libraryURL)
    let repository = try PromptRepository(libraryURL: libraryURL)
    try repository.bootstrap()

    let root = LibraryFolder(id: "folder-count-root", name: "Count Root")
    let child = LibraryFolder(id: "folder-count-child", name: "Count Child", parentId: root.id)
    try repository.saveFolder(root)
    try repository.saveFolder(child)

    var first = appStatePromptFixture(id: "folder-count-active-root", title: "Root item")
    first.folderId = root.id
    first.folderName = root.name
    var second = appStatePromptFixture(id: "folder-count-active-child", title: "Child item")
    second.folderId = child.id
    second.folderName = child.name
    var trash = appStatePromptFixture(id: "folder-count-trash", title: "Trash item")
    trash.folderId = child.id
    trash.folderName = child.name
    trash.deletedAt = Date(timeIntervalSince1970: 1_700_000_100)
    try repository.saveItems([first, second, trash])
    _ = try repository.prepareVersionSequenceMigration()
    _ = try repository.runVersionSequenceMigration(batchSize: 50)
    _ = try repository.prepareItemSequenceMigration()
    _ = try repository.runItemSequenceMigration(batchSize: 50)

    let state = AppState(libraryURL: libraryURL)
    await state.installLibraryContextForTesting(
        repository: repository,
        folders: [root, child],
        items: [],
        tags: []
    )
    state.enableTrialForTesting()
    let paginator = try #require(state.summaryPaginator)
    await waitForSummaryCommit(paginator)
    let loadObservation = PromptRepositoryLoadInstrumentation.beginObservation(for: libraryURL)

    state.beginDeleteFolders([root.id])

    guard case .folderDeleteConfirmation(let request) = state.modal else {
        Issue.record("Summary folder deletion should present a confirmation request")
        await state.stopLibraryBackgroundWorkForTesting()
        return
    }
    #expect(request.itemCount == 2)
    #expect(state.items.isEmpty)
    #expect(loadObservation.delta == 0)
    await state.stopLibraryBackgroundWorkForTesting()
}

@MainActor
@Test("Legacy delete capability preserves full-item selection behavior")
func legacyDeleteCapabilityPreservesItemArrayBehavior() {
    let state = AppState(libraryURL: URL(fileURLWithPath: "/tmp/PromptStudio-LegacyDeleteCapability-\(UUID().uuidString)"))
    state.items = [appStatePromptFixture(id: "legacy-active", title: "Active")]
    state.selectItems(ids: ["legacy-active"], primaryID: "legacy-active")
    #expect(state.deleteSelectionCapability == .items(Set(["legacy-active"])))

    var deleted = appStatePromptFixture(id: "legacy-deleted", title: "Deleted")
    deleted.deletedAt = Date(timeIntervalSince1970: 1_700_000_001)
    state.items = [deleted]
    state.selectItems(ids: [deleted.id], primaryID: deleted.id)
    #expect(state.deleteSelectionCapability == .none)
}

@MainActor
@Test("Late thumbnail completion from an old context cannot update a duplicate ID in the replacement context")
func lateThumbnailCompletionCannotCrossLibraryContext() async throws {
    let oldURL = URL(fileURLWithPath: "/tmp/PromptStudio-ThumbnailOld-\(UUID().uuidString)")
    let newURL = URL(fileURLWithPath: "/tmp/PromptStudio-ThumbnailNew-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: oldURL)
        try? FileManager.default.removeItem(at: newURL)
    }
    try PromptRepository.createLibraryDirectories(at: oldURL)
    try PromptRepository.createLibraryDirectories(at: newURL)
    let oldRepository = try PromptRepository(libraryURL: oldURL)
    let newRepository = try PromptRepository(libraryURL: newURL)
    try oldRepository.bootstrap()
    try newRepository.bootstrap()

    var oldItem = appStatePromptFixture(id: "duplicate-thumbnail-id", title: "Old")
    oldItem.thumbnailPath = ""
    var newItem = appStatePromptFixture(id: oldItem.id, title: "New")
    newItem.thumbnailPath = ""
    try oldRepository.saveItem(oldItem)
    try newRepository.saveItem(newItem)

    let gate = ThumbnailPersistenceGate()
    let state = AppState(libraryURL: oldURL)
    state.setThumbnailPersistenceOverrideForTesting { _ in
        await gate.markStarted()
        await gate.waitForRelease()
    }
    await state.installLibraryContextForTesting(repository: oldRepository, folders: [], items: [oldItem], tags: [])

    let oldFlush = Task { @MainActor in
        try? await state.enqueueThumbnailUpdatesForTesting([oldItem.id: "/tmp/old-thumbnail.jpg"])
    }
    await gate.waitForStart()
    state.setThumbnailPersistenceOverrideForTesting(nil)
    let replacement = Task { @MainActor in
        await state.installLibraryContextForTesting(repository: newRepository, folders: [], items: [newItem], tags: [])
    }
    try await Task.sleep(nanoseconds: 5_000_000)
    #expect(state.libraryURL.standardizedFileURL == oldURL.standardizedFileURL)
    #expect(state.items.first?.thumbnailPath == "")

    await gate.release()
    await oldFlush.value
    await replacement.value
    #expect(state.libraryURL.standardizedFileURL == newURL.standardizedFileURL)
    #expect(state.items.first?.title == "New")
    #expect(state.items.first?.thumbnailPath == "")
    #expect(state.thumbnailPathOverride(for: oldItem.id) == nil)
    await state.stopLibraryBackgroundWorkForTesting()
}

@MainActor
@Test("Summary selection publishes its ID immediately and starts the one shared detail controller")
func summarySelectionPublishesIDBeforeDetailLoad() async throws {
    let libraryURL = URL(fileURLWithPath: "/tmp/PromptStudio-SummaryDetailSelection-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: libraryURL) }
    try PromptRepository.createLibraryDirectories(at: libraryURL)
    let repository = try PromptRepository(libraryURL: libraryURL)
    try repository.bootstrap()
    try repository.saveFolder(LibraryFolder(id: "folder-detail", name: "Detail"))
    try repository.saveItem(appStatePromptFixture(id: "detail-item", title: "Detail"))

    let state = AppState(libraryURL: libraryURL)
    await state.startLibraryLoadForTesting(repository: repository)
    guard let paginator = state.summaryPaginator,
          let controller = state.summaryDetailController else {
        Issue.record("Summary startup did not install its paginator and detail controller")
        return
    }
    await paginator.replace(query: LibraryQuery(pageSize: LibrarySummaryPaginator.pageSize))

    state.selectSummaryItem(id: "detail-item")

    #expect(state.selectedID == "detail-item")
    #expect(state.selectedItemID == "detail-item")
    #expect(controller === state.summaryDetailController)
    #expect(controller.selectedID == "detail-item")
    #expect(controller.state == .loading || controller.state == .loaded)
    await state.stopLibraryBackgroundWorkForTesting()
}

@Test("Summary inspector exposes loaded detail instead of a loading placeholder")
func summaryInspectorLoadedStateIsNotLoading() {
    #expect(summaryInspectorDetailPresentation(for: .loaded) == .loaded)
    #expect(summaryInspectorDetailPresentation(for: .loading) == .loading)
}

@MainActor
@Test("Summary preview selects the shared detail controller exactly once")
func summaryPreviewSelectsDetailExactlyOnce() async throws {
    let libraryURL = URL(fileURLWithPath: "/tmp/PromptStudio-SummaryPreviewSelection-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: libraryURL) }
    try PromptRepository.createLibraryDirectories(at: libraryURL)
    let repository = try PromptRepository(libraryURL: libraryURL)
    try repository.bootstrap()
    let folder = LibraryFolder(id: "folder-preview-selection", name: "Preview")
    let item = appStatePromptFixture(id: "preview-selection-item", title: "Preview")
    try repository.saveFolder(folder)
    try repository.saveItem(item)

    let state = AppState(libraryURL: libraryURL)
    await state.installLibraryContextForTesting(
        repository: repository,
        folders: [folder],
        items: [],
        tags: []
    )
    let paginator = try #require(state.summaryPaginator)
    let controller = try #require(state.summaryDetailController)
    await waitForSummaryCommit(paginator)

    state.previewSummaryItem(id: item.id)

    #expect(controller.generation == 1)
    #expect(controller.selectedID == item.id)
    await state.stopLibraryBackgroundWorkForTesting()
}

@MainActor
@Test("Summary detail reloads through the repository invalidation hub")
func summaryDetailReloadsAfterRepositoryMutation() async throws {
    let libraryURL = URL(fileURLWithPath: "/tmp/PromptStudio-SummaryDetailInvalidation-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: libraryURL) }
    try PromptRepository.createLibraryDirectories(at: libraryURL)
    let repository = try PromptRepository(libraryURL: libraryURL)
    try repository.bootstrap()
    let folder = LibraryFolder(id: "folder-detail-invalidation", name: "Detail")
    let item = appStatePromptFixture(id: "detail-invalidation-item", title: "Before")
    try repository.saveFolder(folder)
    try repository.saveItem(item)

    let state = AppState(libraryURL: libraryURL)
    await state.installLibraryContextForTesting(
        repository: repository,
        folders: [folder],
        items: [],
        tags: []
    )
    let paginator = try #require(state.summaryPaginator)
    let controller = try #require(state.summaryDetailController)
    await waitForSummaryCommit(paginator)
    state.selectSummaryItem(id: item.id)

    for _ in 0..<200 where controller.state != .loaded {
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    #expect(controller.currentDetail?.title == "Before")

    var updated = item
    updated.title = "After"
    updated.updatedAt = updated.updatedAt.addingTimeInterval(1)
    try repository.saveItem(updated)

    for _ in 0..<200 where controller.currentDetail?.title != "After" {
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    #expect(controller.currentDetail?.title == "After")
    await state.stopLibraryBackgroundWorkForTesting()
}

@MainActor
@Test("Summary detail reloads the renamed folder through the shared repository hub")
func summaryDetailReloadsFolderNameAfterRepositoryRename() async throws {
    let libraryURL = URL(fileURLWithPath: "/tmp/PromptStudio-SummaryFolderRename-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: libraryURL) }
    try PromptRepository.createLibraryDirectories(at: libraryURL)
    let repository = try PromptRepository(libraryURL: libraryURL)
    try repository.bootstrap()

    let folder = LibraryFolder(id: "folder-rename-detail", name: "Before")
    var item = appStatePromptFixture(id: "folder-rename-detail-item", title: "Detail")
    item.folderId = folder.id
    item.folderName = folder.name
    try repository.saveFolder(folder)
    try repository.saveItem(item)

    let state = AppState(libraryURL: libraryURL)
    await state.installLibraryContextForTesting(
        repository: repository,
        folders: [folder],
        items: [],
        tags: []
    )
    let controller = try #require(state.summaryDetailController)
    let paginator = try #require(state.summaryPaginator)
    await waitForSummaryCommit(paginator)
    state.selectSummaryItem(id: item.id)

    for _ in 0..<300 where controller.currentDetail?.folderName != folder.name {
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    #expect(controller.currentDetail?.folderName == folder.name)

    let beforeRename = repository.libraryDataRevision.current
    try repository.renameFolder(id: folder.id, name: "After")

    for _ in 0..<300 where controller.currentDetail?.folderName != "After" {
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    #expect(controller.currentDetail?.folderName == "After")
    #expect(repository.libraryDataRevision.current > beforeRename)
    await state.stopLibraryBackgroundWorkForTesting()
}

@MainActor
@Test("Legacy AppState folder rename updates resident items with one invalidation")
func legacyAppStateFolderRenamePublishesOneInvalidationForAllItems() async throws {
    let libraryURL = URL(fileURLWithPath: "/tmp/PromptStudio-LegacyFolderRename-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: libraryURL) }
    try PromptRepository.createLibraryDirectories(at: libraryURL)
    let repository = try PromptRepository(libraryURL: libraryURL)
    try repository.bootstrap()

    let folder = LibraryFolder(id: "legacy-rename-folder", name: "Before")
    var first = appStatePromptFixture(id: "legacy-rename-first", title: "First")
    first.folderId = folder.id
    first.folderName = folder.name
    var second = appStatePromptFixture(id: "legacy-rename-second", title: "Second")
    second.folderId = folder.id
    second.folderName = folder.name
    try repository.saveFolder(folder)
    try repository.saveItem(first)
    try repository.saveItem(second)

    let state = AppState(libraryURL: libraryURL)
    await state.installLibraryContextForTesting(
        repository: repository,
        folders: [folder],
        items: [first, second],
        tags: []
    )
    state.enableTrialForTesting()
    let recorder = SummaryInvalidationRecorder()
    let subscription = repository.itemDetailInvalidationHub.subscribe { recorder.append($0) }
    defer { subscription.cancel() }

    let beforeRevision = repository.libraryDataRevision.current
    #expect(state.renameFolder(id: folder.id, name: "After"))
    #expect(recorder.events.count == 1)
    #expect(recorder.events[0].changedItemIDs == [first.id, second.id])
    #expect(repository.libraryDataRevision.current == beforeRevision + 1)
    #expect(state.items.map(\.folderName) == ["After", "After"])
    await state.stopLibraryBackgroundWorkForTesting()
}

@MainActor
@Test("AppState multi-folder reorder advances one shared revision")
func appStateFolderReorderPublishesOneSharedRevision() async throws {
    let libraryURL = URL(fileURLWithPath: "/tmp/PromptStudio-FolderReorderRevision-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: libraryURL) }
    try PromptRepository.createLibraryDirectories(at: libraryURL)
    let repository = try PromptRepository(libraryURL: libraryURL)
    try repository.bootstrap()
    let folders = [
        LibraryFolder(id: "reorder-a", name: "A", sortOrder: 0),
        LibraryFolder(id: "reorder-b", name: "B", sortOrder: 1),
        LibraryFolder(id: "reorder-c", name: "C", sortOrder: 2)
    ]
    for folder in folders { try repository.saveFolder(folder) }

    let state = AppState(libraryURL: libraryURL)
    await state.installLibraryContextForTesting(
        repository: repository,
        folders: folders,
        items: [],
        tags: []
    )
    state.enableTrialForTesting()

    let beforeReorder = repository.libraryDataRevision.current
    state.reorderFolders(parentId: nil, orderedIDs: ["reorder-c", "reorder-a", "reorder-b"])
    #expect(repository.libraryDataRevision.current == beforeReorder + 1)
    #expect(state.folders.sorted(by: { $0.sortOrder < $1.sortOrder }).map(\.id) == ["reorder-c", "reorder-a", "reorder-b"])

    let beforeSwap = repository.libraryDataRevision.current
    state.swapFolderOrder(draggedID: "reorder-c", targetID: "reorder-b")
    #expect(repository.libraryDataRevision.current == beforeSwap + 1)
    await state.stopLibraryBackgroundWorkForTesting()
}

@MainActor
@Test("Statistics cache keeps last-known counts and exposes a stale error until the next invalidate succeeds")
func statisticsCachePublishesFailureAndClearsOnRetry() async throws {
    let libraryURL = URL(fileURLWithPath: "/tmp/PromptStudio-StatisticsCacheRetry-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: libraryURL) }
    try PromptRepository.createLibraryDirectories(at: libraryURL)
    let repository = try PromptRepository(libraryURL: libraryURL)
    try repository.bootstrap()

    let expected = LibraryStatistics(
        activeCount: 3,
        favoriteCount: 2,
        recentCount: 1,
        trashCount: 4,
        folderCounts: ["folder": 3]
    )
    let loader = StatisticsCacheLoaderScript(
        outcomes: [
            .failure(StatisticsCacheTestError(message: "statistics read failed")),
            .success(expected)
        ]
    )
    let cache = LibraryStatisticsCache(loader: { repository in
        try loader.load(repository)
    })

    cache.invalidate(repository: repository, folders: [])
    for _ in 0..<500 where cache.staleError == nil {
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    #expect(cache.statistics != expected)
    #expect(cache.staleError != nil)
    #expect(cache.errorMessage?.contains("stale") == true)
    #expect(cache.statistics.activeCount == 0)

    cache.retry()
    for _ in 0..<500 where cache.statistics != expected || cache.staleError != nil {
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    #expect(cache.statistics == expected)
    #expect(cache.staleError == nil)
    #expect(cache.errorMessage == nil)
    #expect(loader.callCount == 2)
    cache.cancel()
}

@MainActor
@Test("Statistics cache serializes physical loads and clears replacement and cancel state")
func statisticsCacheSerializesPhysicalLoadsAndClearsLifecycleState() async throws {
    let firstURL = URL(fileURLWithPath: "/tmp/PromptStudio-StatisticsPhysicalA-\(UUID().uuidString)")
    let secondURL = URL(fileURLWithPath: "/tmp/PromptStudio-StatisticsPhysicalB-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: firstURL)
        try? FileManager.default.removeItem(at: secondURL)
    }
    try PromptRepository.createLibraryDirectories(at: firstURL)
    try PromptRepository.createLibraryDirectories(at: secondURL)
    let firstRepository = try PromptRepository(libraryURL: firstURL)
    let secondRepository = try PromptRepository(libraryURL: secondURL)
    let expected = LibraryStatistics(activeCount: 8, favoriteCount: 3, recentCount: 2, trashCount: 1)
    let loader = StatisticsCachePhysicalLoader(result: expected)
    let cache = LibraryStatisticsCache(loader: { repository in
        try loader.load(repository)
    })

    cache.invalidate(repository: firstRepository, folders: [])
    await loader.waitForFirstStart()
    #expect(loader.firstStarted)
    cache.invalidate(repository: secondRepository, folders: [])
    cache.invalidate(repository: secondRepository, folders: [])
    try? await Task.sleep(nanoseconds: 250_000_000)
    #expect(loader.maxActiveCount == 1)

    loader.releaseFirstLoad()
    for _ in 0..<500 where loader.callCount < 2 || cache.statistics != expected {
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    #expect(loader.callCount == 2)
    #expect(loader.activeCount == 0)

    await cache.cancelAndWait()
    #expect(cache.statistics.activeCount == 0)
    #expect(cache.staleError == nil)
    await loader.waitForIdle()
    #expect(loader.activeCount == 0)

    let activeLoader = StatisticsCachePhysicalLoader(result: expected)
    let activeCache = LibraryStatisticsCache(loader: { repository in
        try activeLoader.load(repository)
    })
    activeCache.invalidate(repository: firstRepository, folders: [])
    await activeLoader.waitForFirstStart()
    #expect(activeLoader.firstStarted)
    let activeCancelTask = Task { @MainActor in
        activeLoader.markCancelBarrierEntered()
        await activeCache.cancelAndWait()
        activeLoader.markCancelBarrierCompleted()
    }
    await activeLoader.waitForCancelBarrierEntry()
    #expect(activeLoader.cancelBarrierEntered)
    #expect(!activeLoader.cancelBarrierCompleted)
    #expect(activeLoader.activeCount == 1)
    activeLoader.releaseFirstLoad()
    await activeCancelTask.value
    #expect(activeLoader.cancelBarrierCompleted)
    #expect(activeLoader.activeCount == 0)
}

@MainActor
@Test("Statistics cache rejects delayed stale submissions after replacement and cancellation")
func statisticsCacheRejectsDelayedStaleSubmissions() async throws {
    let firstURL = URL(fileURLWithPath: "/tmp/PromptStudio-StatisticsSubmitA-\(UUID().uuidString)")
    let secondURL = URL(fileURLWithPath: "/tmp/PromptStudio-StatisticsSubmitB-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: firstURL)
        try? FileManager.default.removeItem(at: secondURL)
    }
    try PromptRepository.createLibraryDirectories(at: firstURL)
    try PromptRepository.createLibraryDirectories(at: secondURL)
    let firstRepository = try PromptRepository(libraryURL: firstURL)
    let secondRepository = try PromptRepository(libraryURL: secondURL)
    let expected = LibraryStatistics(activeCount: 5, favoriteCount: 2, recentCount: 1, trashCount: 0)

    let replacementGate = StatisticsSubmissionGate()
    let replacementRecorder = StatisticsRepositoryRecorder(result: expected)
    let replacementCache = LibraryStatisticsCache(
        refreshDelayNanoseconds: 1,
        beforeSubmit: { generation in await replacementGate.pauseFirstGeneration(generation) },
        loader: { repository in replacementRecorder.load(repository) }
    )
    replacementCache.invalidate(repository: firstRepository, folders: [])
    await replacementGate.waitForFirstPause()
    replacementCache.invalidate(repository: secondRepository, folders: [])
    for _ in 0..<500 where replacementRecorder.paths.isEmpty {
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    await replacementGate.release()
    try? await Task.sleep(nanoseconds: 20_000_000)
    #expect(replacementRecorder.paths == [secondRepository.libraryURL.path])
    #expect(replacementCache.statistics == expected)
    await replacementCache.cancelAndWait()

    let cancellationGate = StatisticsSubmissionGate()
    let cancellationRecorder = StatisticsRepositoryRecorder(result: expected)
    let cancellationCache = LibraryStatisticsCache(
        refreshDelayNanoseconds: 1,
        beforeSubmit: { generation in await cancellationGate.pauseFirstGeneration(generation) },
        loader: { repository in cancellationRecorder.load(repository) }
    )
    cancellationCache.invalidate(repository: firstRepository, folders: [])
    await cancellationGate.waitForFirstPause()
    await cancellationCache.cancelAndWait()
    await cancellationGate.release()
    try? await Task.sleep(nanoseconds: 20_000_000)
    #expect(cancellationRecorder.paths.isEmpty)
    #expect(cancellationCache.statistics.activeCount == 0)
}

@MainActor
@Test("Statistics cache clears stale context when replacing repositories")
func statisticsCacheClearsStaleContextOnReplacement() async throws {
    let firstURL = URL(fileURLWithPath: "/tmp/PromptStudio-StatisticsReplacementA-\(UUID().uuidString)")
    let secondURL = URL(fileURLWithPath: "/tmp/PromptStudio-StatisticsReplacementB-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: firstURL)
        try? FileManager.default.removeItem(at: secondURL)
    }
    try PromptRepository.createLibraryDirectories(at: firstURL)
    try PromptRepository.createLibraryDirectories(at: secondURL)
    let firstRepository = try PromptRepository(libraryURL: firstURL)
    let secondRepository = try PromptRepository(libraryURL: secondURL)
    let expected = LibraryStatistics(activeCount: 4, favoriteCount: 1, recentCount: 1, trashCount: 0)
    let loader = StatisticsCacheLoaderScript(
        outcomes: [
            .failure(StatisticsCacheTestError(message: "first library statistics failed")),
            .success(expected)
        ]
    )
    let cache = LibraryStatisticsCache(loader: { repository in
        try loader.load(repository)
    })

    cache.invalidate(repository: firstRepository, folders: [])
    for _ in 0..<500 where cache.staleError == nil {
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    #expect(cache.staleError != nil)

    cache.invalidate(repository: secondRepository, folders: [])
    #expect(cache.staleError == nil)
    #expect(cache.statistics.activeCount == 0)
    for _ in 0..<500 where cache.staleError != nil || cache.statistics != expected {
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    #expect(cache.statistics == expected)
    #expect(cache.staleError == nil)
    cache.cancel()
}

@MainActor
@Test("Summary surface retains resident rows for append errors but not replacement errors")
func summarySurfaceRetainsResidentRowsForAppendErrors() {
    let appendError = LibrarySummaryPaginator.ErrorState(
        phase: .append,
        message: "append failed",
        requestKind: .append
    )
    let replacementError = LibrarySummaryPaginator.ErrorState(
        phase: .replacement,
        message: "replacement failed",
        requestKind: .replacement
    )

    #expect(
        summarySurfacePresentation(
            initialLoading: false,
            appendLoading: false,
            error: appendError,
            hasResidentSurface: true
        ) == .surface
    )
    #expect(
        summarySurfacePresentation(
            initialLoading: false,
            appendLoading: false,
            error: appendError,
            hasResidentSurface: false
        ) == .loadState
    )
    #expect(
        summarySurfacePresentation(
            initialLoading: false,
            appendLoading: false,
            error: replacementError,
            hasResidentSurface: true
        ) == .loadState
    )
    #expect(
        summarySurfacePresentation(
            initialLoading: false,
            appendLoading: true,
            error: nil,
            hasResidentSurface: true
        ) == .surface
    )
}

@MainActor
@Test("Production AppState startup migrates a legacy repository before its first Summary query")
func normalAppStateStartupObservesRealLoadItemsBoundary() async throws {
    let libraryURL = URL(fileURLWithPath: "/tmp/PromptStudio-SummaryNormalStartup-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: libraryURL) }
    try PromptRepository.createLibraryDirectories(at: libraryURL)
    let repository = try PromptRepository(libraryURL: libraryURL)
    try repository.bootstrap()
    try repository.saveFolder(LibraryFolder(id: "folder-startup", name: "Startup"))
    var startupItem = appStatePromptFixture(id: "item-startup", title: "Startup")
    startupItem.tags = ["startup-tag"]
    startupItem.favorite = true
    try repository.saveItem(startupItem)
    #expect(!repository.tagRelationsReady)
    #expect(!repository.versionSequenceMigrationReady)
    #expect(!repository.itemSequenceMigrationReady)

    let state = AppState(libraryURL: libraryURL)
    let normalLoadObservation = PromptRepositoryLoadInstrumentation.beginObservation(for: libraryURL)
    let normalLegacyObservation = SummaryStartupBoundaryInstrumentation.beginObservation(for: libraryURL)
    await state.startLibraryLoadForTesting(repository: repository)
    let normalLoadDelta = normalLoadObservation.delta
    let normalLegacyDelta = normalLegacyObservation.delta
    #expect(normalLoadDelta == 0)
    #expect(normalLegacyDelta == 0)
    #expect(repository.tagRelationsReady)
    #expect(repository.versionSequenceMigrationReady)
    #expect(repository.itemSequenceMigrationReady)
    let paginator = try #require(state.summaryPaginator)
    await waitForSummaryCommit(paginator)
    #expect(paginator.error == nil)
    #expect(paginator.summaries.map(\.id) == ["item-startup"])
    await paginator.replace(query: .favorite(pageSize: 300))
    #expect(paginator.error == nil)
    #expect(paginator.summaries.map(\.id) == ["item-startup"])
    await paginator.replace(query: .tag("startup-tag", pageSize: 300))
    #expect(paginator.error == nil)
    #expect(paginator.summaries.map(\.id) == ["item-startup"])

    let backupDirectory = libraryURL.appendingPathComponent("backups", isDirectory: true)
    let firstLaunchBackups = try FileManager.default.contentsOfDirectory(
        at: backupDirectory,
        includingPropertiesForKeys: nil
    ).map(\.lastPathComponent).sorted()
    await state.startLibraryLoadForTesting(repository: repository)
    let secondLaunchBackups = try FileManager.default.contentsOfDirectory(
        at: backupDirectory,
        includingPropertiesForKeys: nil
    ).map(\.lastPathComponent).sorted()
    #expect(secondLaunchBackups == firstLaunchBackups)
    #expect(repository.tagRelationsReady)
    #expect(repository.versionSequenceMigrationReady)
    #expect(repository.itemSequenceMigrationReady)

    let explicitLoadObservation = PromptRepositoryLoadInstrumentation.beginObservation(for: libraryURL)
    let explicitLegacyObservation = SummaryStartupBoundaryInstrumentation.beginObservation(for: libraryURL)
    _ = state.loadLegacyItemsForExplicitSummaryMode()
    #expect(explicitLoadObservation.delta == 1)
    #expect(explicitLegacyObservation.delta == 1)
    if let metricsPath = ProcessInfo.processInfo.environment["PROMPTSTUDIO_SUMMARY_UI_STARTUP_METRICS_PATH"] {
        let metrics: [String: Int] = [
            "normal_summary_full_item_decode": normalLoadDelta,
            "normal_summary_legacy_boundary": normalLegacyDelta,
            "explicit_legacy_full_item_decode": explicitLoadObservation.delta,
            "explicit_legacy_boundary": explicitLegacyObservation.delta
        ]
        let data = try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys])
        try data.write(to: URL(fileURLWithPath: metricsPath), options: .atomic)
    }
    await state.stopLibraryBackgroundWorkForTesting()
}

@MainActor
@Test("Production startup resumes an interrupted migration and coalesces concurrent launches")
func productionStartupResumesInterruptedMigrationAndCoalescesLaunches() async throws {
    let libraryURL = URL(fileURLWithPath: "/tmp/PromptStudio-SummaryInterruptedStartup-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: libraryURL) }
    try PromptRepository.createLibraryDirectories(at: libraryURL)
    let repository = try PromptRepository(libraryURL: libraryURL)
    try repository.bootstrap()
    try repository.saveFolder(LibraryFolder(id: "folder-interrupted", name: "Interrupted"))
    for index in 0..<4 {
        try repository.saveItem(appStatePromptFixture(id: "item-interrupted-\(index)", title: "Item \(index)"))
    }

    _ = try repository.prepareVersionSequenceMigration()
    let partial = try repository.runVersionSequenceMigration(batchSize: 1, maxBatches: 1)
    #expect(!partial.completed)
    #expect(!repository.versionSequenceMigrationReady)
    #expect(!repository.itemSequenceMigrationReady)

    let secondRepository = try PromptRepository(libraryURL: libraryURL)
    let firstState = AppState(libraryURL: libraryURL)
    let secondState = AppState(libraryURL: libraryURL)
    async let firstLaunch: Void = firstState.startLibraryLoadForTesting(repository: repository)
    async let secondLaunch: Void = secondState.startLibraryLoadForTesting(repository: secondRepository)
    _ = await (firstLaunch, secondLaunch)

    #expect(repository.tagRelationsReady)
    #expect(repository.versionSequenceMigrationReady)
    #expect(repository.itemSequenceMigrationReady)
    #expect(firstState.isLibraryReady)
    #expect(secondState.isLibraryReady)
    let firstPaginator = try #require(firstState.summaryPaginator)
    let secondPaginator = try #require(secondState.summaryPaginator)
    await waitForSummaryCommit(firstPaginator)
    await waitForSummaryCommit(secondPaginator)
    #expect(firstPaginator.error == nil)
    #expect(secondPaginator.error == nil)
    let expectedIDs = Set((0..<4).map { "item-interrupted-\($0)" })
    #expect(Set(firstPaginator.summaries.map(\.id)) == expectedIDs)
    #expect(Set(secondPaginator.summaries.map(\.id)) == expectedIDs)

    let backups = try FileManager.default.contentsOfDirectory(
        at: libraryURL.appendingPathComponent("backups", isDirectory: true),
        includingPropertiesForKeys: nil
    ).map(\.lastPathComponent)
    #expect(backups.filter { $0.hasPrefix("promptstudio-tag-relations-") && $0.hasSuffix(".sqlite") }.count == 1)
    #expect(backups.filter { $0.hasPrefix("promptstudio-version-sequence-") && $0.hasSuffix(".sqlite") }.count == 1)
    #expect(backups.filter { $0.hasPrefix("promptstudio-item-sequence-") && $0.hasSuffix(".sqlite") }.count == 1)
    await firstState.stopLibraryBackgroundWorkForTesting()
    await secondState.stopLibraryBackgroundWorkForTesting()
}

@MainActor
@Test("Production startup Retry reruns migration orchestration after a transient failure")
func productionStartupRetryRerunsMigrationOrchestration() async throws {
    let libraryURL = URL(fileURLWithPath: "/tmp/PromptStudio-SummaryMigrationRetry-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: libraryURL) }
    try PromptRepository.createLibraryDirectories(at: libraryURL)
    let repository = try PromptRepository(libraryURL: libraryURL)
    try repository.bootstrap()
    try repository.saveFolder(LibraryFolder(id: "folder-retry", name: "Retry"))
    try repository.saveItem(appStatePromptFixture(id: "item-retry", title: "Retry"))

    let backupsURL = libraryURL.appendingPathComponent("backups", isDirectory: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: backupsURL.path)
    let state = AppState(libraryURL: libraryURL)
    await state.startLibraryLoadForTesting(repository: repository)
    guard case .failed = state.libraryAccessState else {
        Issue.record("A migration backup failure should keep the library in its retryable load-error state")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: backupsURL.path)
        return
    }
    #expect(state.summaryPaginator == nil)
    #expect(!repository.tagRelationsReady)
    #expect(!repository.versionSequenceMigrationReady)

    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: backupsURL.path)
    await state.startLibraryLoadForTesting(repository: repository)
    #expect(state.isLibraryReady)
    #expect(repository.tagRelationsReady)
    #expect(repository.versionSequenceMigrationReady)
    #expect(repository.itemSequenceMigrationReady)
    let paginator = try #require(state.summaryPaginator)
    await waitForSummaryCommit(paginator)
    #expect(paginator.error == nil)
    #expect(paginator.summaries.map(\.id) == ["item-retry"])
    await state.stopLibraryBackgroundWorkForTesting()
}

@MainActor
@Test("AppState generic item/favorite/tag/folder mutations coalesce one Summary refresh and remove deleted IDs")
func appStateGenericMutationsRefreshSummaryByID() async throws {
    let revision = LibraryDataRevision()
    let executor = AppStateMutationExecutor()
    let service = LibraryQueryService(
        executor: executor,
        dataRevision: revision,
        capabilities: .itemSequence
    )
    let browser = LibraryBrowserState(service: service, initialQuery: LibraryQuery(pageSize: 300))
    let paginator = LibrarySummaryPaginator(browser: browser)
    await paginator.replace(query: LibraryQuery(pageSize: 300))

    let state = AppState(libraryURL: URL(fileURLWithPath: "/tmp/PromptStudio-SummaryAppStateIntegration-\(UUID().uuidString)"))
    state.installSummaryPaginatorForTesting(paginator)
    let base = appStatePromptFixture(id: "item-a", title: "before")
    var edited = base
    edited.title = "after"
    edited.favorite = true
    edited.updatedAt = edited.updatedAt.addingTimeInterval(1)

    // These are the synchronous notifications emitted by save/reload,
    // favorite/tag edits, folder rename, and folder move. The generation
    // coalescer must issue one replacement after the complete mutation batch.
    _ = revision.advance()
    state.items = [base]
    state.items = [edited]
    state.tags = [Tag(id: "tag-a", name: "tag-a")]
    state.folders = [LibraryFolder(id: "folder-a", name: "Renamed", parentId: "parent-a")]
    await state.waitForSummaryMutationRefreshForTesting()

    #expect(await executor.callCount() == 2) // initial query + one coalesced replacement
    #expect(paginator.browser.dataRevision == revision.current)
    #expect(paginator.summaries.map(\.id) == ["item-a"])
    #expect(paginator.summaries.first?.title == "after")

    // Delete/reload is a second completed mutation and must remove the same
    // ID rather than leaving a stale resident row or cursor.
    _ = revision.advance()
    state.items = []
    state.tags = []
    state.folders = []
    await state.waitForSummaryMutationRefreshForTesting()
    #expect(await executor.callCount() == 3)
    #expect(paginator.summaries.isEmpty)
    #expect(paginator.browser.nextCursor == nil)
}

@MainActor
@Test("AppState real temporary-repository save/favorite/rename/move/delete paths refresh Summary")
func appStateRealMutationPathsRefreshSummary() async throws {
    let libraryURL = URL(fileURLWithPath: "/tmp/PromptStudio-SummaryRealMutation-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: libraryURL) }
    try PromptRepository.createLibraryDirectories(at: libraryURL)
    let repository = try PromptRepository(libraryURL: libraryURL)
    try repository.bootstrap()
    let folderA = LibraryFolder(id: "folder-a", name: "A", count: 1)
    let folderB = LibraryFolder(id: "folder-b", name: "B")
    try repository.saveFolder(folderA)
    try repository.saveFolder(folderB)
    let item = appStatePromptFixture(id: "item-real", title: "Real")
    try repository.saveItem(item)
    try repository.saveTag(Tag(id: "tag-real", name: "Real Tag"))
    _ = try repository.prepareVersionSequenceMigration()
    _ = try repository.runVersionSequenceMigration(batchSize: 50)
    #expect(repository.versionSequenceMigrationReady)
    _ = try repository.prepareItemSequenceMigration()
    _ = try repository.runItemSequenceMigration(batchSize: 50)
    #expect(repository.itemSequenceMigrationReady)

    let state = AppState(libraryURL: libraryURL)
    await state.installLibraryContextForTesting(
        repository: repository,
        folders: [folderA, folderB],
        items: [],
        tags: [Tag(id: "tag-real", name: "Real Tag")]
    )
    state.enableTrialForTesting()
    let paginator = try #require(state.summaryPaginator)
    await waitForSummaryCommit(paginator)
    #expect(paginator.summaries.map(\.id) == ["item-real"])
    let loadObservation = PromptRepositoryLoadInstrumentation.beginObservation(for: libraryURL)

    // Summary mutations may refresh projections, folders, and tags, but they
    // must never repopulate the legacy full-item array.
    state.toggleFavorite(item)
    await state.waitForSummaryMutationRefreshForTesting()
    #expect(state.items.isEmpty)
    #expect(paginator.summaries.first?.favorite == true)

    #expect(state.renameFolder(id: folderA.id, name: "Renamed A"))
    await state.waitForSummaryMutationRefreshForTesting()
    #expect(paginator.summaries.first?.folderName == "Renamed A")

    // Exercise the ID-native Summary move path against a real repository.
    #expect(state.moveSummaryItems([item.id], toFolderID: folderB.id))
    await state.waitForSummaryMutationRefreshForTesting()
    #expect(paginator.summaries.first?.folderId == folderB.id)

    // Base delete is also a real repository mutation and must remove the row
    // from the active Summary query rather than leaving it resident.
    state.moveItemsToTrash([item.id])
    await state.waitForSummaryMutationRefreshForTesting()
    #expect(state.items.isEmpty)
    #expect(paginator.summaries.isEmpty)

    // Re-enter the deleted row through the paged Trash query, then restore
    // its selected ID without hydrating the legacy array.
    var trashFilter = PromptFilter()
    trashFilter.collection = .trash
    await paginator.replace(filter: trashFilter)
    #expect(paginator.summaries.map(\.id) == [item.id])
    state.selectSummaryItem(id: item.id)
    state.restoreSelected()
    await state.waitForSummaryMutationRefreshForTesting()
    #expect(state.items.isEmpty)
    #expect(paginator.summaries.isEmpty)

    // Folder subtree deletion is also an ordinary Summary mutation. The
    // moved item is soft-deleted and the resident projection becomes empty.
    await paginator.replace(filter: PromptFilter())
    #expect(paginator.summaries.map(\.id) == [item.id])
    state.deleteFolderMovingItemsToTrash(id: folderB.id)
    await state.waitForSummaryMutationRefreshForTesting()
    #expect(state.items.isEmpty)
    #expect(paginator.summaries.isEmpty)
    #expect(state.folders.contains(where: { $0.id == folderB.id }) == false)
    #expect(loadObservation.delta == 0)
}

@MainActor
@Test("AppState context teardown waits for the physical Summary request before dropping it")
func appStateTeardownWaitsForPhysicalSummaryRequest() async throws {
    let executor = AppStateTeardownExecutor()
    let service = LibraryQueryService(executor: executor, capabilities: .itemSequence)
    let browser = LibraryBrowserState(service: service, initialQuery: LibraryQuery(pageSize: 1))
    let paginator = LibrarySummaryPaginator(browser: browser)
    let state = AppState(libraryURL: URL(fileURLWithPath: "/tmp/PromptStudio-SummaryTeardown-\(UUID().uuidString)"))
    state.installSummaryPaginatorForTesting(paginator)

    let request = Task { @MainActor in
        await paginator.replace(query: LibraryQuery(pageSize: 1))
    }
    await executor.waitForStart()
    let teardown = Task { @MainActor in
        await state.stopLibraryBackgroundWorkForTesting()
    }

    #expect(await executor.activeCount() == 1)
    #expect(state.summaryPaginator != nil)
    await executor.release()
    await request.value
    await teardown.value

    #expect(state.summaryPaginator == nil)
    #expect(await executor.activeCount() == 0)
    #expect(!browser.hasActiveRequest)
}

private actor AppStateTeardownExecutor: LibraryQueryRowExecutor {
    private var didStart = false
    private var released = false
    private var active = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func query(sql: String, values: [SQLiteValue]) async throws -> [[String: String?]] { [] }

    func queryPageAndCount(
        pageSQL: String,
        pageValues: [SQLiteValue],
        countSQL: String,
        countValues: [SQLiteValue]
    ) async throws -> LibraryQueryReadBatch {
        active += 1
        didStart = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        defer { active -= 1 }
        await waitForRelease()
        try Task.checkCancellation()
        return LibraryQueryReadBatch(pageRows: [], countRows: [["totalCount": "0"]])
    }

    func waitForStart() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func activeCount() -> Int { active }

    private func waitForRelease() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            if released {
                continuation.resume()
            } else {
                releaseWaiters.append(continuation)
            }
        }
    }
}

@MainActor
private func waitForSummaryCommit(_ paginator: LibrarySummaryPaginator) async {
    for _ in 0..<200 {
        if paginator.hasCommittedQuery && !paginator.isLoading { return }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
}

private actor ThumbnailPersistenceGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func waitForStart() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func waitForRelease() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            if released { continuation.resume() } else { releaseWaiters.append(continuation) }
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private actor DeleteCapabilitySummaryExecutor: LibraryQueryRowExecutor {
    func query(sql: String, values: [SQLiteValue]) async throws -> [[String: String?]] { [] }

    func queryPageAndCount(
        pageSQL: String,
        pageValues: [SQLiteValue],
        countSQL: String,
        countValues: [SQLiteValue]
    ) async throws -> LibraryQueryReadBatch {
        LibraryQueryReadBatch(
            pageRows: [
                appStateSummaryRow(id: "item-a", title: "Active"),
                appStateSummaryRow(id: "item-deleted", title: "Deleted", deletedAt: "2023-11-14T22:13:21Z")
            ],
            countRows: [["totalCount": "2"]]
        )
    }
}

private actor AppStateMutationExecutor: LibraryQueryRowExecutor {
    private var calls = 0

    func query(sql: String, values: [SQLiteValue]) async throws -> [[String: String?]] { [] }

    func queryPageAndCount(
        pageSQL: String,
        pageValues: [SQLiteValue],
        countSQL: String,
        countValues: [SQLiteValue]
    ) async throws -> LibraryQueryReadBatch {
        defer { calls += 1 }
        switch calls {
        case 0:
            return LibraryQueryReadBatch(
                pageRows: [appStateSummaryRow(id: "item-a", title: "before")],
                countRows: [["totalCount": "1"]]
            )
        case 1:
            return LibraryQueryReadBatch(
                pageRows: [appStateSummaryRow(id: "item-a", title: "after")],
                countRows: [["totalCount": "1"]]
            )
        default:
            return LibraryQueryReadBatch(pageRows: [], countRows: [["totalCount": "0"]])
        }
    }

    func callCount() -> Int { calls }
}

private struct StatisticsCacheTestError: Error, LocalizedError, Sendable {
    let message: String

    var errorDescription: String? { message }
}

private final class StatisticsCacheLoaderScript: @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [Result<LibraryStatistics, Error>]
    private var calls = 0

    init(outcomes: [Result<LibraryStatistics, Error>]) {
        self.outcomes = outcomes
    }

    var callCount: Int {
        lock.withLock { calls }
    }

    func load(_ repository: PromptRepository) throws -> LibraryStatistics {
        try lock.withLock {
            calls += 1
            guard !outcomes.isEmpty else {
                return Result<LibraryStatistics, Error>.failure(
                    StatisticsCacheTestError(message: "unexpected statistics retry")
                )
            }
            return outcomes.removeFirst()
        }.get()
    }
}

private final class SummaryInvalidationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [ItemDetailInvalidationEvent] = []

    var events: [ItemDetailInvalidationEvent] {
        lock.withLock { recordedEvents }
    }

    func append(_ event: ItemDetailInvalidationEvent) {
        lock.withLock { recordedEvents.append(event) }
    }
}

private final class StatisticsCachePhysicalLoader: @unchecked Sendable {
    private let lock = NSLock()
    private let result: LibraryStatistics
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var calls = 0
    private var active = 0
    private var maxActive = 0
    private var firstStartedValue = false
    private var cancelBarrierEnteredValue = false
    private var cancelBarrierCompletedValue = false
    private var cancelBarrierEntryWaiters: [CheckedContinuation<Void, Never>] = []

    init(result: LibraryStatistics) {
        self.result = result
    }

    var firstStarted: Bool {
        lock.withLock { firstStartedValue }
    }

    var callCount: Int {
        lock.withLock { calls }
    }

    var activeCount: Int {
        lock.withLock { active }
    }

    var maxActiveCount: Int {
        lock.withLock { maxActive }
    }

    var cancelBarrierCompleted: Bool {
        lock.withLock { cancelBarrierCompletedValue }
    }

    var cancelBarrierEntered: Bool {
        lock.withLock { cancelBarrierEnteredValue }
    }

    func load(_ repository: PromptRepository) throws -> LibraryStatistics {
        let isFirst = lock.withLock { () -> Bool in
            calls += 1
            active += 1
            maxActive = max(maxActive, active)
            let first = calls == 1
            if first { firstStartedValue = true }
            return first
        }
        if isFirst { releaseSemaphore.wait() }
        defer { lock.withLock { active -= 1 } }
        return result
    }

    func releaseFirstLoad() {
        releaseSemaphore.signal()
    }

    func markCancelBarrierCompleted() {
        lock.withLock { cancelBarrierCompletedValue = true }
    }

    func markCancelBarrierEntered() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            cancelBarrierEnteredValue = true
            let waiters = cancelBarrierEntryWaiters
            cancelBarrierEntryWaiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func waitForCancelBarrierEntry() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock { () -> Bool in
                if cancelBarrierEnteredValue { return true }
                cancelBarrierEntryWaiters.append(continuation)
                return false
            }
            if resumeImmediately { continuation.resume() }
        }
    }

    func waitForFirstStart() async {
        for _ in 0..<500 where !firstStarted {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    func waitForIdle() async {
        for _ in 0..<500 where activeCount != 0 {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

private actor StatisticsSubmissionGate {
    private var firstPaused = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func pauseFirstGeneration(_ generation: UInt64) async {
        guard generation == 1 else { return }
        firstPaused = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            if released { continuation.resume() } else { releaseWaiters.append(continuation) }
        }
    }

    func waitForFirstPause() async {
        guard !firstPaused else { return }
        await withCheckedContinuation { continuation in
            if firstPaused { continuation.resume() } else { startWaiters.append(continuation) }
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private final class StatisticsRepositoryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let result: LibraryStatistics
    private var recordedPaths: [String] = []

    init(result: LibraryStatistics) {
        self.result = result
    }

    var paths: [String] { lock.withLock { recordedPaths } }

    func load(_ repository: PromptRepository) -> LibraryStatistics {
        lock.withLock { recordedPaths.append(repository.libraryURL.path) }
        return result
    }
}

private func appStatePromptFixture(id: String, title: String) -> PromptItem {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    return PromptItem(
        id: id,
        title: title,
        type: .image,
        assetKind: .image,
        modelId: "model",
        modelName: "Model",
        folderId: "folder-a",
        folderName: "Folder",
        category: "image",
        assetPath: "/tmp/summary-item.png",
        aspectRatio: "16:9",
        width: 1920,
        height: 1080,
        format: "PNG",
        fileSize: 1,
        favorite: false,
        createdAt: date,
        updatedAt: date,
        lastUsedAt: date
    )
}

private func appStateSummaryRow(
    id: String,
    title: String,
    deletedAt: String? = nil
) -> [String: String?] {
    let dateValue = Date(timeIntervalSince1970: 1_700_000_000)
    let date = ISO8601DateFormatter().string(from: dateValue)
    return [
        "id": id, "title": title, "type": PromptType.image.rawValue, "assetKind": AssetKind.image.rawValue,
        "modelId": "model", "modelName": "Model", "folderId": "folder-a", "folderName": "Folder",
        "category": "image", "assetPath": "/tmp/summary-item.png", "thumbnailPath": "", "aspectRatio": "16:9",
        "width": "1920", "height": "1080", "format": "PNG", "fileSize": "1", "favorite": "1",
        "pinnedAt": nil, "deletedAt": deletedAt, "createdAt": date, "updatedAt": date, "lastUsedAt": date,
        "sortOrder": "0", "itemCreatedAtSortKey": "1700000000000000", "itemLastUsedAtSortKey": "0",
        "itemSequence": "1", "hasPrompt": "1", "hasReferences": "0"
    ]
}
