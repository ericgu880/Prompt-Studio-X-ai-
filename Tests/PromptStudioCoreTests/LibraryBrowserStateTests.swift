import Foundation
@testable import PromptStudioCore

#if canImport(Testing)
import Testing

@Test("library browser shadow converts only supported filters")
@MainActor
func libraryBrowserShadowConvertsOnlySupportedFilters() throws {
    let query = try LibraryBrowserState.query(
        from: PromptFilter(modelId: "model-a", collection: .folder("folder-a"), favoriteOnly: true),
        pageSize: 25
    )
    #expect(query.collection == LibraryQueryCollection.folder("folder-a"))
    #expect(query.modelId == "model-a")
    #expect(query.favoriteOnly)

    do {
        _ = try LibraryBrowserState.query(from: PromptFilter(query: "needle"))
        Issue.record("free-text search must fail closed")
    } catch LibraryBrowserStateError.unsupportedFilters(let fields) {
        #expect(fields.contains(.freeText))
    }
}

@Test("library browser state appends pages without duplicate IDs")
@MainActor
func libraryBrowserStateAppendsPagesWithoutDuplicateIDs() async throws {
    actor Executor: LibraryQueryRowExecutor {
        private var page = 0

        func query(sql: String, values: [SQLiteValue]) async throws -> [[String : String?]] {
            []
        }

        func queryPageAndCount(
            pageSQL: String,
            pageValues: [SQLiteValue],
            countSQL: String,
            countValues: [SQLiteValue]
        ) async throws -> LibraryQueryReadBatch {
            let rows = page == 0
                ? [browserSummaryRow(id: "a", sortOrder: 0), browserSummaryRow(id: "b", sortOrder: 1), browserSummaryRow(id: "c", sortOrder: 2)]
                : [browserSummaryRow(id: "b", sortOrder: 1), browserSummaryRow(id: "c", sortOrder: 2)]
            page += 1
            return LibraryQueryReadBatch(pageRows: rows, countRows: [["totalCount": "3"]])
        }
    }

    let service = LibraryQueryService(
        executor: Executor(),
        capabilities: .itemSequence
    )
    let state = LibraryBrowserState(service: service, initialQuery: LibraryQuery(pageSize: 2))
    await state.replace(query: LibraryQuery(pageSize: 2))
    #expect(state.summaries.map(\.id) == ["a", "b"])
    #expect(state.hasMore)
    await state.loadNextPage()
    #expect(state.summaries.map(\.id) == ["a", "b", "c"])
    #expect(state.totalCount == 3)
}

@Test("library browser state ignores a cancelled stale replacement")
@MainActor
func libraryBrowserStateIgnoresCancelledStaleReplacement() async throws {
    let executor = GatedReplacementExecutor()
    let service = LibraryQueryService(executor: executor, capabilities: .itemSequence)
    let state = LibraryBrowserState(service: service, initialQuery: LibraryQuery(pageSize: 1))
    let first = Task { @MainActor in await state.replace(query: LibraryQuery(.folder("old"), pageSize: 1)) }
    await executor.waitForOldStart()
    let second = Task { @MainActor in await state.replace(query: LibraryQuery(.folder("new"), pageSize: 1)) }
    await executor.openOld()
    await executor.waitForNewStart()
    #expect(state.summaries.isEmpty)
    await executor.openNew()
    await first.value
    await second.value
    #expect(state.currentQuery.collection == .folder("new"))
    #expect(state.summaries.map(\.id) == ["new-row"])
    #expect(state.error == nil)
}

@Test("library browser shadow reports IDs-only parity and unsupported fields")
@MainActor
func libraryBrowserShadowReportsIDsOnlyParityAndUnsupportedFields() async throws {
    actor Executor: LibraryQueryRowExecutor {
        private var page = 0

        func query(sql: String, values: [SQLiteValue]) async throws -> [[String : String?]] { [] }

        func queryPageAndCount(
            pageSQL: String,
            pageValues: [SQLiteValue],
            countSQL: String,
            countValues: [SQLiteValue]
        ) async throws -> LibraryQueryReadBatch {
            defer { page += 1 }
            let rows = page == 0
                ? [browserSummaryRow(id: "a", sortOrder: 0), browserSummaryRow(id: "b", sortOrder: 1), browserSummaryRow(id: "c", sortOrder: 2)]
                : [browserSummaryRow(id: "c", sortOrder: 2)]
            return LibraryQueryReadBatch(pageRows: rows, countRows: [["totalCount": "3"]])
        }
    }

    var items: [PromptItem] = []
    for (index, id) in ["a", "b", "c"].enumerated() {
        let item = PromptItem(
            id: id,
            title: id,
            type: .image,
            assetKind: .image,
            modelId: "model",
            modelName: "Model",
            folderId: "folder",
            folderName: "Folder",
            category: "image",
            assetPath: "",
            aspectRatio: "16:9",
            width: 1,
            height: 1,
            format: "PNG",
            fileSize: 1,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000 - Double(index)),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000 - Double(index)),
            lastUsedAt: Date(timeIntervalSince1970: 1_700_000_000 - Double(index)),
            sortOrder: index,
            tags: [],
            referenceAssets: [],
            versions: []
        )
        items.append(item)
    }

    let service = LibraryQueryService(executor: Executor(), capabilities: .itemSequence)
    let state = LibraryBrowserState(service: service, initialQuery: LibraryQuery(pageSize: 2))
    let report = await state.validateShadow(
        filter: PromptFilter(),
        snapshot: LibraryFilterSnapshot(items: items),
        pageSize: 2
    )
    #expect(report.matches)
    #expect(report.expectedIDs == ["a", "b", "c"])
    #expect(report.actualIDs == report.expectedIDs)

    let unsupported = await state.validateShadow(
        filter: PromptFilter(query: "needle"),
        snapshot: LibraryFilterSnapshot(items: items),
        pageSize: 2
    )
    #expect(!unsupported.matches)
    if case .unsupportedFilters(let fields) = unsupported.mismatch {
        #expect(fields == [.freeText])
    } else {
        Issue.record("unsupported shadow filter should be reported explicitly")
    }
}

@Test("summary paginator walks ten fixed 300-row pages with exact IDs and one in-flight append")
@MainActor
func summaryPaginatorWalksFixedPagesAndDeduplicates() async throws {
    let executor = TenPageExecutor()
    let service = LibraryQueryService(executor: executor, capabilities: .itemSequence)
    let browser = LibraryBrowserState(service: service, initialQuery: LibraryQuery(pageSize: 1))
    let paginator = LibrarySummaryPaginator(browser: browser)

    await paginator.replace(query: LibraryQuery(pageSize: 7))
    #expect(paginator.currentQuery.pageSize == LibrarySummaryPaginator.pageSize)
    #expect(paginator.summaries.map(\.id) == Array(0..<300).map { "item-\($0)" })

    // Two callers arriving at the same cursor share one append operation.
    async let firstAppend: Void = paginator.loadNextPage()
    await executor.waitForPageStart(1)
    async let secondAppend: Void = paginator.loadNextPage()
    await executor.openPage(1)
    _ = await (firstAppend, secondAppend)
    while paginator.hasMore {
        await paginator.loadNextPage()
    }

    let expectedIDs = Array(0..<3_000).map { "item-\($0)" }
    #expect(paginator.summaries.map(\.id) == expectedIDs)
    #expect(paginator.summaries.count == 3_000)
    #expect(paginator.totalCount == 3_000)
    #expect(!paginator.hasMore)
    let stats = await executor.stats()
    #expect(stats.pageCalls == 10)
    #expect(stats.maxInFlight == 1)
}

@Test("summary replacement uses explicit old/new gates and never publishes stale old rows")
@MainActor
func summaryReplacementDoesNotPublishOldGate() async throws {
    let executor = GatedReplacementExecutor()
    let service = LibraryQueryService(executor: executor, capabilities: .itemSequence)
    let browser = LibraryBrowserState(service: service, initialQuery: LibraryQuery(pageSize: 300))
    let paginator = LibrarySummaryPaginator(browser: browser)

    let oldTask = Task { @MainActor in
        await paginator.replace(query: LibraryQuery(.folder("old"), pageSize: 300))
    }
    await executor.waitForOldStart()

    let newTask = Task { @MainActor in
        await paginator.replace(query: LibraryQuery(.folder("new"), pageSize: 300))
    }

    // BrowserState's replacement barrier waits for the cancelled old gate;
    // opening it is explicit, not a timing yield.  The new gate remains closed
    // while we assert that no old row was ever published.
    await executor.openOld()
    await executor.waitForNewStart()
    #expect(paginator.summaries.isEmpty)
    #expect(paginator.browser.pendingQuery?.collection == .folder("new"))

    await executor.openNew()
    await newTask.value
    await oldTask.value
    #expect(paginator.summaries.map(\.id) == ["new-row"])
    #expect(!paginator.summaries.contains(where: { $0.id == "old-row" }))
}

@Test("summary replacement hides an already committed page until the new gate commits")
@MainActor
func summaryReplacementHidesCommittedPage() async throws {
    let executor = GatedReplacementExecutor()
    let service = LibraryQueryService(executor: executor, capabilities: .itemSequence)
    let browser = LibraryBrowserState(service: service, initialQuery: LibraryQuery(pageSize: 300))
    let paginator = LibrarySummaryPaginator(browser: browser)

    let oldTask = Task { @MainActor in
        await paginator.replace(query: LibraryQuery(.folder("old"), pageSize: 300))
    }
    await executor.waitForOldStart()
    await executor.openOld()
    await oldTask.value
    #expect(paginator.summaries.map(\.id) == ["old-row"])

    let newTask = Task { @MainActor in
        await paginator.replace(query: LibraryQuery(.folder("new"), pageSize: 300))
    }
    await executor.waitForNewStart()
    #expect(paginator.initialLoading)
    #expect(paginator.summaries.isEmpty)

    await executor.openNew()
    await newTask.value
    #expect(paginator.summaries.map(\.id) == ["new-row"])
}

@Test("summary replacement keeps a new gate visible when an old noncooperative request returns late")
@MainActor
func summaryReplacementRejectsLateNonCooperativeOldResult() async throws {
    let executor = GatedReplacementExecutor()
    let service = LibraryQueryService(executor: executor, capabilities: .itemSequence)
    let browser = LibraryBrowserState(service: service, initialQuery: LibraryQuery(pageSize: 300))
    let paginator = LibrarySummaryPaginator(browser: browser)
    let oldQuery = LibraryQuery(.folder("old"), pageSize: 300)

    let initialOld = Task { @MainActor in await paginator.replace(query: oldQuery) }
    await executor.waitForOldStart()
    await executor.openOld()
    await initialOld.value
    #expect(paginator.summaries.map(\.id) == ["old-row"])

    let lateOld = Task { @MainActor in await paginator.replace(query: oldQuery) }
    await executor.waitForLateOldStart()
    let newTask = Task { @MainActor in
        await paginator.replace(query: LibraryQuery(.folder("new"), pageSize: 300))
    }
    // The exact-task barrier keeps the new request behind the old physical
    // provider task. Assert no overlap while the late-old gate is closed,
    // then release and await that old completion explicitly.
    #expect(await executor.newHasStarted() == false)
    #expect(paginator.summaries.isEmpty)

    await executor.openLateOld()
    await lateOld.value
    await executor.waitForNewStart()
    #expect(paginator.summaries.isEmpty)

    await executor.openNew()
    await newTask.value
    #expect(paginator.summaries.map(\.id) == ["new-row"])

    // The late old provider completed before the new gate opened; its stale
    // token must never publish and the new display remains authoritative.
    #expect(paginator.summaries.map(\.id) == ["new-row"])
    #expect(await executor.newStartedWhileOldInFlight() == false)
}

@Test("summary paginator teardown waits for the physical browser request")
@MainActor
func summaryPaginatorCancelAndWaitSettlesPhysicalRequest() async throws {
    let executor = GatedReplacementExecutor()
    let service = LibraryQueryService(executor: executor, capabilities: .itemSequence)
    let browser = LibraryBrowserState(service: service, initialQuery: LibraryQuery(pageSize: 300))
    let paginator = LibrarySummaryPaginator(browser: browser)

    let request = Task { @MainActor in
        await paginator.replace(query: LibraryQuery(.folder("old"), pageSize: 300))
    }
    await executor.waitForOldStart()
    let teardown = Task { @MainActor in await paginator.cancelAndWait() }
    await executor.openOld()
    await request.value
    await teardown.value

    #expect(!browser.hasActiveRequest)
    #expect(!paginator.isLoading)
}

@Test("summary mutation refresh synchronizes revision and replaces stale metadata and deleted rows")
@MainActor
func summaryMutationRefreshSynchronizesRevisionAndRows() async throws {
    let revision = LibraryDataRevision()
    let executor = MutationRefreshExecutor()
    let service = LibraryQueryService(
        executor: executor,
        dataRevision: revision,
        capabilities: .itemSequence
    )
    let browser = LibraryBrowserState(service: service, initialQuery: LibraryQuery(pageSize: 300))
    let paginator = LibrarySummaryPaginator(browser: browser)

    await paginator.replace(query: LibraryQuery(pageSize: 300))
    #expect(paginator.summaries.first?.title == "before")
    let oldCursor = paginator.nextCursor

    _ = revision.advance()
    await paginator.refreshAfterMutation()
    #expect(paginator.browser.dataRevision == revision.current)
    #expect(paginator.nextCursor != oldCursor)
    #expect(paginator.summaries.map(\.id) == ["item-0"])
    #expect(paginator.summaries.map(\.title) == ["after"])
    #expect(paginator.error == nil)

    _ = revision.advance()
    await paginator.refreshAfterMutation()
    #expect(paginator.summaries.isEmpty)
    #expect(paginator.nextCursor == nil)
    #expect(!paginator.hasMore)
    #expect(paginator.error == nil)
}

@Test("summary paginator exposes retry phases for initial, replacement, and resident append errors")
@MainActor
func summaryPaginatorRetryPhases() async throws {
    let executor = RetryPhaseExecutor()
    let service = LibraryQueryService(executor: executor, capabilities: .itemSequence)
    let browser = LibraryBrowserState(service: service, initialQuery: LibraryQuery(pageSize: 1))
    let paginator = LibrarySummaryPaginator(browser: browser)

    await paginator.replace(query: LibraryQuery(pageSize: 1))
    #expect(paginator.error?.phase == .initial)
    #expect(paginator.summaries.isEmpty)

    await paginator.retry()
    #expect(paginator.error == nil)
    #expect(paginator.summaries.count == 300)
    #expect(paginator.hasMore)

    await paginator.replace(query: LibraryQuery(.folder("new"), pageSize: 1))
    #expect(paginator.error?.phase == .replacement)
    // A failed replacement must not re-expose rows from the previous query.
    // The surface owns the loading/error state for this empty replacement.
    #expect(paginator.summaries.isEmpty)

    await paginator.retry()
    #expect(paginator.error == nil)
    #expect(paginator.summaries.map(\.id).allSatisfy { $0.hasPrefix("new-") })
    #expect(paginator.hasMore)

    await paginator.loadNextPage()
    #expect(paginator.error?.phase == .append)
    #expect(paginator.summaries.count == 300)

    await paginator.retry()
    #expect(paginator.error == nil)
    #expect(paginator.summaries.count == 301)
    #expect(!paginator.hasMore)
}

@Test("unsupported Summary filter retry revalidates the same filter and stays fail-closed")
@MainActor
func unsupportedSummaryFilterRetryStaysFailClosed() async throws {
    let executor = UnsupportedFilterRetryExecutor()
    let service = LibraryQueryService(executor: executor, capabilities: .itemSequence)
    let browser = LibraryBrowserState(service: service, initialQuery: LibraryQuery(pageSize: 300))
    let paginator = LibrarySummaryPaginator(browser: browser)

    await paginator.replace(query: LibraryQuery(pageSize: 300))
    #expect(paginator.summaries.map(\.id) == ["supported-row"])
    let callsBeforeUnsupportedFilter = await executor.callCount()

    let unsupported = PromptFilter(query: "needle")
    await paginator.replace(filter: unsupported)
    #expect(paginator.error?.phase == .replacement)
    #expect(paginator.summaries.isEmpty)

    await paginator.retry()
    #expect(paginator.error?.phase == .replacement)
    #expect(paginator.summaries.isEmpty)
    #expect(await executor.callCount() == callsBeforeUnsupportedFilter)
}

@Test("unsupported Summary replacement cancels and settles the physical Browser request")
@MainActor
func unsupportedSummaryReplacementSettlesPhysicalBrowserRequest() async throws {
    let cancellationProbe = Gate()
    let executor = NonCooperativeSummaryExecutor(cancellationProbe: cancellationProbe)
    let service = LibraryQueryService(executor: executor, capabilities: .itemSequence)
    let browser = LibraryBrowserState(service: service, initialQuery: LibraryQuery(pageSize: 300))
    let paginator = LibrarySummaryPaginator(browser: browser)

    await paginator.replace(query: LibraryQuery(pageSize: 300))
    #expect(paginator.summaries.map(\.id) == ["baseline-supported"])
    let supportedRequest = Task { @MainActor in
        await paginator.replace(query: LibraryQuery(.folder("supported"), pageSize: 300))
    }
    await executor.waitForStart()

    let unsupportedRequest = Task { @MainActor in
        await paginator.replace(filter: PromptFilter(query: "unsupported"))
    }
    let cancellationObserved = await waitForGateOrTimeout {
        await cancellationProbe.wait()
    }
    #expect(cancellationObserved, "unsupported replacement must cancel the in-flight Browser request")
    await Task.yield()
    #expect(paginator.error == nil, "unsupported replacement must publish only after the physical barrier settles")

    await executor.release()
    await unsupportedRequest.value
    await supportedRequest.value

    #expect(paginator.error?.phase == .replacement)
    #expect(paginator.summaries.isEmpty)
    #expect(browser.summaries.map(\.id) == ["baseline-supported"], "a late noncooperative Browser result must not commit")
    #expect(await executor.activeCount() == 0)
    #expect(!browser.hasActiveRequest)
}

@Test("supported Summary filter provider failure retries the exact filter")
@MainActor
func supportedSummaryFilterRetryPreservesExactFilterAfterProviderFailure() async throws {
    let executor = SupportedFilterRetryExecutor()
    let service = LibraryQueryService(executor: executor, capabilities: .itemSequence)
    let browser = LibraryBrowserState(service: service, initialQuery: LibraryQuery(pageSize: 300))
    let paginator = LibrarySummaryPaginator(browser: browser)

    await paginator.replace(query: LibraryQuery(pageSize: 300))
    #expect(paginator.summaries.map(\.id) == ["all-row"])
    let filter = PromptFilter(
        modelId: "model-filter",
        collection: .folder("folder-filter"),
        type: .image,
        favoriteOnly: true
    )
    await paginator.replace(filter: filter)
    #expect(paginator.error?.phase == .replacement)
    #expect(paginator.summaries.isEmpty)
    #expect(paginator.retryFilterForTesting == filter)

    await paginator.retry()
    #expect(paginator.error == nil)
    #expect(paginator.summaries.map(\.id) == ["filtered-row"])
    #expect(paginator.retryFilterForTesting == nil)
    let requests = await executor.requests()
    #expect(requests.count == 3)
    #expect(requests[1].pageSQL == requests[2].pageSQL)
    #expect(sqliteValuesEqual(requests[1].pageValues, requests[2].pageValues))
    #expect(requests[1].countSQL == requests[2].countSQL)
    #expect(sqliteValuesEqual(requests[1].countValues, requests[2].countValues))
    #expect(paginator.currentQuery == (try LibraryBrowserState.query(from: filter, pageSize: 300)))
}

@Test("stale append retry restarts the committed query as a replacement")
@MainActor
func staleAppendRetryRestartsCommittedQuery() async throws {
    let revision = LibraryDataRevision()
    let executor = MutationRefreshExecutor()
    let service = LibraryQueryService(
        executor: executor,
        dataRevision: revision,
        capabilities: .itemSequence
    )
    let browser = LibraryBrowserState(service: service, initialQuery: LibraryQuery(pageSize: 300))
    let paginator = LibrarySummaryPaginator(browser: browser)

    await paginator.replace(query: LibraryQuery(pageSize: 300))
    #expect(paginator.summaries.first?.title == "before")
    _ = revision.advance()

    await paginator.loadNextPage()
    #expect(paginator.error?.phase == .replacement)
    #expect(paginator.error?.requestKind == .replacement)
    #expect(!paginator.hasMore)

    await paginator.retry()
    #expect(paginator.error == nil)
    #expect(paginator.summaries.map(\.id) == ["item-0"])
    #expect(paginator.summaries.first?.title == "after")
}

@Test("summary prefetch is exactly two viewports and targeted keys distinguish folder geometry")
@MainActor
func summaryPrefetchAndTargetedKeys() throws {
    #expect(LibrarySummaryPaginator.shouldPrefetch(visibleRect: CGRect(x: 0, y: 0, width: 200, height: 100), contentHeight: 300))
    #expect(!LibrarySummaryPaginator.shouldPrefetch(visibleRect: CGRect(x: 0, y: 0, width: 200, height: 100), contentHeight: 301))

    let base = testSummary(id: "summary-key", folderID: "folder-a", folderName: "A", width: 1920, height: 1080)
    let folderChanged = testSummary(id: base.id, folderID: "folder-b", folderName: "B", width: 1920, height: 1080)
    let geometryChanged = testSummary(id: base.id, folderID: "folder-a", folderName: "A", width: 1080, height: 1920)
    #expect(base.folderKey != folderChanged.folderKey)
    #expect(base.geometryKey != geometryChanged.geometryKey)
}

@Test("ID-only folder mutation preserves category/timestamp and refreshes folder membership")
@MainActor
func idOnlyFolderMutationPreservesProjectionAndMembership() async throws {
    let libraryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("summary-id-mutation-\(UUID().uuidString)")
    let repository = try PromptRepository(libraryURL: libraryURL)
    try repository.saveFolder(LibraryFolder(id: "folder-a", name: "A"))
    try repository.saveFolder(LibraryFolder(id: "folder-b", name: "B"))
    let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    let item = PromptItem(
        id: "move-me", title: "Move me", type: .image, assetKind: .image,
        modelId: "model", modelName: "Model", folderId: "folder-a", folderName: "A",
        category: "custom-category", assetPath: "", thumbnailPath: "", aspectRatio: "16:9",
        width: 1920, height: 1080, format: "PNG", fileSize: 1,
        createdAt: timestamp, updatedAt: timestamp, lastUsedAt: timestamp,
        sortOrder: 0,
        versions: [PromptVersion(promptItemId: "move-me", version: "V1.0", prompt: "prompt")]
    )
    try repository.saveItem(item)
    _ = try repository.prepareVersionSequenceMigration()
    _ = try repository.runVersionSequenceMigration(batchSize: 50)
    _ = try repository.prepareItemSequenceMigration()
    _ = try repository.runItemSequenceMigration(batchSize: 50)

    let result = try repository.updateItemFolderIDs(
        [item.id], toFolderID: "folder-b", targetFolderName: "B", updatedAt: timestamp
    )
    #expect(result.changedIDs == [item.id])
    #expect(result.updatedAt == timestamp)
    let persisted = try #require(repository.loadItems().first(where: { $0.id == item.id }))
    #expect(persisted.folderId == "folder-b")
    #expect(persisted.folderName == "B")
    #expect(persisted.category == "custom-category")
    #expect(persisted.updatedAt == timestamp)

    let readConnection = try SQLiteReadConnection(url: repository.databaseURL)
    let service = LibraryQueryService(executor: readConnection, versionSequenceReady: true, itemSequenceReady: true)
    let browser = LibraryBrowserState(service: service, initialQuery: LibraryQuery(pageSize: 300))
    await browser.replace(filter: PromptFilter(collection: .folder("folder-a")))
    #expect(browser.summaries.isEmpty)
    await browser.replace(filter: PromptFilter(collection: .folder("folder-b")))
    #expect(browser.summaries.map(\.id) == [item.id])

    let unchanged = try repository.updateItemFolderIDs(
        [item.id], toFolderID: "folder-b", targetFolderName: "B", updatedAt: timestamp
    )
    #expect(unchanged.changedIDs.isEmpty)
    #expect(unchanged.unchangedIDs == [item.id])

    try repository.markDeleted(itemID: item.id, deletedAt: timestamp)
    do {
        _ = try repository.updateItemFolderIDs(
            [item.id], toFolderID: "folder-a", targetFolderName: "A", updatedAt: timestamp
        )
        Issue.record("deleted Summary IDs must fail closed")
    } catch PromptRepositoryItemFolderMutationError.itemsDeleted(let ids) {
        #expect(ids == [item.id])
    }
    do {
        _ = try repository.updateItemFolderIDs(
            ["missing-id"], toFolderID: "folder-a", targetFolderName: "A", updatedAt: timestamp
        )
        Issue.record("missing Summary IDs must fail closed")
    } catch PromptRepositoryItemFolderMutationError.itemsMissing(let ids) {
        #expect(ids == ["missing-id"])
    }
    do {
        _ = try repository.updateItemFolderIDs(
            [item.id, "missing-id"], toFolderID: "folder-a", targetFolderName: "A", updatedAt: timestamp
        )
        Issue.record("mixed Summary IDs must fail closed")
    } catch PromptRepositoryItemFolderMutationError.mixedState(let missing, let deleted) {
        #expect(missing == ["missing-id"])
        #expect(deleted == [item.id])
    }
}

private actor RetryPhaseExecutor: LibraryQueryRowExecutor {
    private var calls = 0

    func query(sql: String, values: [SQLiteValue]) async throws -> [[String : String?]] { [] }

    func queryPageAndCount(
        pageSQL: String,
        pageValues: [SQLiteValue],
        countSQL: String,
        countValues: [SQLiteValue]
    ) async throws -> LibraryQueryReadBatch {
        defer { calls += 1 }
        switch calls {
        case 0, 2, 4:
            throw RetryPhaseError.intentional
        default:
            break
        }
        let isNew = pageValues.contains {
            if case .text("new") = $0 { return true }
            return false
        }
        let prefix = isNew || calls >= 2 ? "new" : "old"
        if calls == 1 || calls == 3 {
            let rows = (0...300).map { browserSummaryRow(id: "\(prefix)-\($0)", sortOrder: $0) }
            return LibraryQueryReadBatch(pageRows: rows, countRows: [["totalCount": "601"]])
        }
        return LibraryQueryReadBatch(
            pageRows: [browserSummaryRow(id: "new-301", sortOrder: 301)],
            countRows: [["totalCount": "601"]]
        )
    }
}

private actor UnsupportedFilterRetryExecutor: LibraryQueryRowExecutor {
    private var calls = 0

    func query(sql: String, values: [SQLiteValue]) async throws -> [[String: String?]] { [] }

    func queryPageAndCount(
        pageSQL: String,
        pageValues: [SQLiteValue],
        countSQL: String,
        countValues: [SQLiteValue]
    ) async throws -> LibraryQueryReadBatch {
        calls += 1
        return LibraryQueryReadBatch(
            pageRows: [browserSummaryRow(id: "supported-row", sortOrder: 0)],
            countRows: [["totalCount": "1"]]
        )
    }

    func callCount() -> Int { calls }
}

private actor SupportedFilterRetryExecutor: LibraryQueryRowExecutor {
    struct Request: Sendable {
        let pageSQL: String
        let pageValues: [SQLiteValue]
        let countSQL: String
        let countValues: [SQLiteValue]
    }

    private var calls = 0
    private var recordedRequests: [Request] = []

    func query(sql: String, values: [SQLiteValue]) async throws -> [[String: String?]] { [] }

    func queryPageAndCount(
        pageSQL: String,
        pageValues: [SQLiteValue],
        countSQL: String,
        countValues: [SQLiteValue]
    ) async throws -> LibraryQueryReadBatch {
        recordedRequests.append(Request(
            pageSQL: pageSQL,
            pageValues: pageValues,
            countSQL: countSQL,
            countValues: countValues
        ))
        defer { calls += 1 }
        if calls == 1 { throw RetryPhaseError.intentional }
        let id = calls == 0 ? "all-row" : "filtered-row"
        return LibraryQueryReadBatch(
            pageRows: [browserSummaryRow(id: id, sortOrder: 0)],
            countRows: [["totalCount": "1"]]
        )
    }

    func requests() -> [Request] { recordedRequests }
}

private actor MutationRefreshExecutor: LibraryQueryRowExecutor {
    private var calls = 0

    func query(sql: String, values: [SQLiteValue]) async throws -> [[String : String?]] { [] }

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
                pageRows: (0...300).map { index in
                    browserSummaryRow(
                        id: "item-\(index)",
                        sortOrder: index,
                        title: index == 0 ? "before" : nil
                    )
                },
                countRows: [["totalCount": "301"]]
            )
        case 1:
            return LibraryQueryReadBatch(
                pageRows: [browserSummaryRow(id: "item-0", sortOrder: 0, title: "after")],
                countRows: [["totalCount": "1"]]
            )
        default:
            return LibraryQueryReadBatch(pageRows: [], countRows: [["totalCount": "0"]])
        }
    }
}

private enum RetryPhaseError: Error {
    case intentional
}

private actor TenPageExecutor: LibraryQueryRowExecutor {
    private var nextPage = 0
    private var active = 0
    private(set) var pageCalls = 0
    private(set) var maxInFlight = 0
    private var lastVisibleCursor: (sortOrder: Int64, createdAt: Int64, sequence: Int64)?
    private var startedPages: Set<Int> = []
    private var pageStartWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private let pageOneGate = Gate()

    func query(sql: String, values: [SQLiteValue]) async throws -> [[String : String?]] { [] }

    func queryPageAndCount(
        pageSQL: String,
        pageValues: [SQLiteValue],
        countSQL: String,
        countValues: [SQLiteValue]
    ) async throws -> LibraryQueryReadBatch {
        active += 1
        pageCalls += 1
        maxInFlight = max(maxInFlight, active)
        let page = nextPage
        nextPage += 1
        startedPages.insert(page)
        let waiters = pageStartWaiters.removeValue(forKey: page) ?? []
        waiters.forEach { $0.resume() }

        guard pageValues.last.map({ isSQLiteInt($0, equalTo: 301) }) == true else {
            throw TenPageExecutorError.invalidPageSize(pageValues)
        }
        if let previous = lastVisibleCursor {
            let expected = [
                SQLiteValue.int(previous.sortOrder), SQLiteValue.int(previous.sortOrder),
                SQLiteValue.int(previous.createdAt), SQLiteValue.int(previous.sortOrder),
                SQLiteValue.int(previous.createdAt), SQLiteValue.int(previous.sequence),
                SQLiteValue.int(301)
            ]
            guard sqliteValuesEqual(pageValues, expected) else {
                throw TenPageExecutorError.cursorDidNotContinue(expected: expected, actual: pageValues)
            }
        } else {
            guard sqliteValuesEqual(pageValues, [.int(301)]) else {
                throw TenPageExecutorError.unexpectedInitialValues(pageValues)
            }
        }
        defer { active -= 1 }
        if page == 1 { await pageOneGate.wait() }
        let start = page * 300
        var rows = (start..<(start + 300)).map { browserSummaryRow(id: "item-\($0)", sortOrder: $0) }
        if page < 9 {
            // The duplicate is after the visible 300 rows, so dedupe is tested
            // without changing the expected keyset order.
            rows.append(browserSummaryRow(id: "item-\(max(0, start - 1))", sortOrder: max(0, start - 1)))
        }
        let last = rows[299]
        guard let sortOrder = last["sortOrder"] ?? nil,
              let createdAt = last["itemCreatedAtSortKey"] ?? nil,
              let sequence = last["itemSequence"] ?? nil,
              let parsedSortOrder = Int64(sortOrder),
              let parsedCreatedAt = Int64(createdAt),
              let parsedSequence = Int64(sequence) else {
            throw TenPageExecutorError.malformedCursorRow
        }
        lastVisibleCursor = (
            sortOrder: parsedSortOrder,
            createdAt: parsedCreatedAt,
            sequence: parsedSequence
        )
        return LibraryQueryReadBatch(pageRows: rows, countRows: [["totalCount": "3000"]])
    }

    func stats() -> (pageCalls: Int, maxInFlight: Int) { (pageCalls, maxInFlight) }

    func waitForPageStart(_ page: Int) async {
        if startedPages.contains(page) { return }
        await withCheckedContinuation { pageStartWaiters[page, default: []].append($0) }
    }

    func openPage(_ page: Int) async {
        guard page == 1 else { return }
        await pageOneGate.open()
    }
}

private enum TenPageExecutorError: Error {
    case invalidPageSize([SQLiteValue])
    case unexpectedInitialValues([SQLiteValue])
    case cursorDidNotContinue(expected: [SQLiteValue], actual: [SQLiteValue])
    case malformedCursorRow
}

private func isSQLiteInt(_ value: SQLiteValue, equalTo expected: Int64) -> Bool {
    guard case .int(let actual) = value else { return false }
    return actual == expected
}

private func sqliteValuesEqual(_ lhs: [SQLiteValue], _ rhs: [SQLiteValue]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    return zip(lhs, rhs).allSatisfy { left, right in
        switch (left, right) {
        case (.text(let lhs), .text(let rhs)): return lhs == rhs
        case (.int(let lhs), .int(let rhs)): return lhs == rhs
        case (.double(let lhs), .double(let rhs)): return lhs == rhs
        case (.null, .null): return true
        default: return false
        }
    }
}

private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor GatedReplacementExecutor: LibraryQueryRowExecutor {
    private let oldGate = Gate()
    private let lateOldGate = Gate()
    private let newGate = Gate()
    private var oldCalls = 0
    private var oldStarted = false
    private var lateOldStarted = false
    private var newStarted = false
    private var oldRequestReturned = false
    private var didStartNewWhileOldInFlight = false
    private var oldStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var lateOldStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var newStartWaiters: [CheckedContinuation<Void, Never>] = []

    func query(sql: String, values: [SQLiteValue]) async throws -> [[String : String?]] { [] }

    func queryPageAndCount(
        pageSQL: String,
        pageValues: [SQLiteValue],
        countSQL: String,
        countValues: [SQLiteValue]
    ) async throws -> LibraryQueryReadBatch {
        let isOld = pageValues.contains {
            if case .text("old") = $0 { return true }
            return false
        }
        if isOld {
            defer { oldCalls += 1 }
            if oldCalls == 0 {
                oldStarted = true
                oldStartWaiters.forEach { $0.resume() }
                oldStartWaiters.removeAll()
                await oldGate.wait()
            } else {
                lateOldStarted = true
                lateOldStartWaiters.forEach { $0.resume() }
                lateOldStartWaiters.removeAll()
                await lateOldGate.wait()
            }
            oldRequestReturned = true
            return LibraryQueryReadBatch(pageRows: [browserSummaryRow(id: "old-row", sortOrder: 0)], countRows: [["totalCount": "1"]])
        }

        if !oldRequestReturned {
            didStartNewWhileOldInFlight = true
        }
        newStarted = true
        newStartWaiters.forEach { $0.resume() }
        newStartWaiters.removeAll()
        await newGate.wait()
        return LibraryQueryReadBatch(pageRows: [browserSummaryRow(id: "new-row", sortOrder: 0)], countRows: [["totalCount": "1"]])
    }

    func waitForOldStart() async {
        if oldStarted { return }
        await withCheckedContinuation { oldStartWaiters.append($0) }
    }

    func waitForNewStart() async {
        if newStarted { return }
        await withCheckedContinuation { newStartWaiters.append($0) }
    }

    func newHasStarted() -> Bool { newStarted }
    func newStartedWhileOldInFlight() -> Bool { didStartNewWhileOldInFlight }

    func waitForLateOldStart() async {
        if lateOldStarted { return }
        await withCheckedContinuation { lateOldStartWaiters.append($0) }
    }

    func openOld() async { await oldGate.open() }
    func openLateOld() async { await lateOldGate.open() }
    func openNew() async { await newGate.open() }
}

private actor NonCooperativeSummaryExecutor: LibraryQueryRowExecutor {
    private let releaseGate = Gate()
    private let cancellationProbe: Gate
    private var calls = 0
    private var didStart = false
    private var active = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    init(cancellationProbe: Gate) {
        self.cancellationProbe = cancellationProbe
    }

    func query(sql: String, values: [SQLiteValue]) async throws -> [[String : String?]] { [] }

    func queryPageAndCount(
        pageSQL: String,
        pageValues: [SQLiteValue],
        countSQL: String,
        countValues: [SQLiteValue]
    ) async throws -> LibraryQueryReadBatch {
        defer { calls += 1 }
        if calls == 0 {
            return LibraryQueryReadBatch(
                pageRows: [browserSummaryRow(id: "baseline-supported", sortOrder: 0)],
                countRows: [["totalCount": "1"]]
            )
        }
        active += 1
        didStart = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        defer { active -= 1 }
        await withTaskCancellationHandler(operation: {
            await releaseGate.wait()
        }, onCancel: {
            Task { await cancellationProbe.open() }
        })
        return LibraryQueryReadBatch(
            pageRows: [browserSummaryRow(id: "late-supported", sortOrder: 0)],
            countRows: [["totalCount": "1"]]
        )
    }

    func waitForStart() async {
        guard !didStart else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() async {
        await releaseGate.open()
    }

    func activeCount() -> Int { active }
}

private func waitForGateOrTimeout(_ wait: @escaping @Sendable () async -> Void) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            await wait()
            return true
        }
        group.addTask {
            try? await Task.sleep(for: .milliseconds(250))
            return false
        }
        let result = await group.next() ?? false
        group.cancelAll()
        return result
    }
}

private func testSummary(id: String, folderID: String, folderName: String, width: Int, height: Int) -> LibraryItemSummary {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    return LibraryItemSummary(
        id: id, title: id, type: .image, assetKind: .image,
        modelId: "model", modelName: "Model", folderId: folderID, folderName: folderName,
        category: "image", assetPath: "", thumbnailPath: "", aspectRatio: "16:9",
        width: width, height: height, format: "PNG", fileSize: 1, favorite: false,
        pinnedAt: nil, deletedAt: nil, createdAt: date, updatedAt: date, lastUsedAt: date,
        sortOrder: 0, hasPrompt: false, hasReferences: false
    )
}

private func browserSummaryRow(id: String, sortOrder: Int, title: String? = nil) -> [String: String?] {
    let dateValue = Date(timeIntervalSince1970: 1_700_000_000 - Double(sortOrder))
    let date = ISO8601DateFormatter().string(from: dateValue)
    let itemCreatedAtSortKey = Int64((dateValue.timeIntervalSince1970 * 1_000_000).rounded())
    let itemLastUsedAtSortKey: Int64 = 0
    let itemSequence = Int64(max(1, sortOrder + 1))
    return [
        "id": id, "title": title ?? id, "type": PromptType.image.rawValue, "assetKind": AssetKind.image.rawValue,
        "modelId": "model", "modelName": "Model", "folderId": "folder", "folderName": "Folder", "category": "image",
        "assetPath": "", "thumbnailPath": "", "aspectRatio": "16:9", "width": "1", "height": "1", "format": "PNG", "fileSize": "1",
        "favorite": "0", "pinnedAt": nil, "deletedAt": nil, "createdAt": date, "updatedAt": date, "lastUsedAt": date,
        "sortOrder": "\(sortOrder)",
        "itemCreatedAtSortKey": "\(itemCreatedAtSortKey)",
        "itemLastUsedAtSortKey": "\(itemLastUsedAtSortKey)",
        "itemSequence": "\(itemSequence)",
        "hasPrompt": "1", "hasReferences": "0"
    ]
}
#endif
