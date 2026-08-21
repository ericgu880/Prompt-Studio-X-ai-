import Foundation
import CryptoKit
import PromptStudioCore

private struct BrowserSQLiteFixture {
    let url: URL
    let repository: PromptRepository
    let items: [PromptItem]
}

private func makeBrowserSQLiteFixture(count: Int = 40, withTags: Bool = true) throws -> BrowserSQLiteFixture {
    let url = try temporaryLibraryURL()
    let repository = try PromptRepository(libraryURL: url)
    var items: [PromptItem] = []
    items.reserveCapacity(count)
    for index in 0..<count {
        var item = sampleItem(
            title: "Browser \(index)",
            modelId: index.isMultiple(of: 2) ? "model-a" : "model-b",
            tags: withTags ? (index.isMultiple(of: 3) ? ["browser", "three"] : ["browser"]) : [],
            prompt: "browser prompt \(index)"
        )
        if index < 3 {
            item.id = ["z-tie", "a-tie", "m-tie"][index]
        } else if index < 6 {
            item.id = ["m-reverse", "a-reverse", "z-reverse"][index - 3]
        } else {
            item.id = String(format: "browser-%04d", index)
        }
        item.sortOrder = index < 6 ? 0 : index
        item.folderId = index.isMultiple(of: 2) ? "folder-a" : "folder-b"
        item.folderName = index.isMultiple(of: 2) ? "Folder A" : "Folder B"
        item.createdAt = index < 6
            ? Date(timeIntervalSince1970: 1_700_000_000)
            : Date(timeIntervalSince1970: 1_700_000_000 - Double(index))
        item.updatedAt = item.createdAt
        item.lastUsedAt = index < 6
            ? Date(timeIntervalSince1970: 10_000)
            : (index.isMultiple(of: 4)
                ? Date(timeIntervalSince1970: 10_000 + Double(index))
                : Date(timeIntervalSince1970: 0))
        item.favorite = index.isMultiple(of: 5)
        if index.isMultiple(of: 7) {
            item.deletedAt = Date(timeIntervalSince1970: 20_000 + Double(index))
        }
        item.versions = item.versions.map { version in
            var copy = version
            copy.promptItemId = item.id
            return copy
        }
        items.append(item)
    }
    try repository.saveItems(items)
    _ = try repository.prepareVersionSequenceMigration()
    _ = try repository.runVersionSequenceMigration(batchSize: 200)
    if withTags {
        _ = try repository.prepareTagRelationMigration()
        _ = try repository.runTagRelationBackfill(batchSize: 200)
        _ = try repository.validateTagRelationConsistency()
        try expect(repository.tagRelationsReady, "browser fixture must finish tag-relation migration")
    }
    try expect(repository.versionSequenceMigrationReady, "browser fixture must finish version-sequence migration")
    _ = try repository.prepareItemSequenceMigration()
    _ = try repository.runItemSequenceMigration(batchSize: 200)
    try expect(repository.itemSequenceMigrationReady, "browser fixture must finish item-sequence migration")
    let readyItems = try repository.loadItems()
    return BrowserSQLiteFixture(url: url, repository: repository, items: readyItems)
}

private func browserExpectedIDs(_ items: [PromptItem], _ filter: PromptFilter) -> [String] {
    PromptFiltering.apply(items, filter: filter).map(\.id)
}

private func browserQuery(_ filter: PromptFilter, pageSize: Int) throws -> LibraryQuery {
    try LibraryBrowserState.query(from: filter, pageSize: pageSize)
}

private func browserSummaryDigest(_ summaries: [LibraryItemSummary]) -> String {
    let rows = summaries.map { summary in
        [
            summary.id,
            summary.title,
            summary.type.rawValue,
            summary.assetKind.rawValue,
            summary.modelId,
            summary.modelName,
            summary.folderId,
            summary.folderName,
            summary.category,
            summary.assetPath,
            summary.thumbnailPath,
            summary.aspectRatio,
            String(summary.width),
            String(summary.height),
            summary.format,
            String(summary.fileSize),
            summary.favorite ? "1" : "0",
            summary.pinnedAt.map { String($0.timeIntervalSince1970) } ?? "<nil>",
            summary.deletedAt.map { String($0.timeIntervalSince1970) } ?? "<nil>",
            String(summary.createdAt.timeIntervalSince1970),
            String(summary.updatedAt.timeIntervalSince1970),
            String(summary.lastUsedAt.timeIntervalSince1970),
            String(summary.sortOrder),
            summary.hasPrompt ? "1" : "0",
            summary.hasReferences ? "1" : "0"
        ].joined(separator: "\u{1f}")
    }.joined(separator: "\u{1e}")
    return SHA256.hash(data: Data(rows.utf8)).map { String(format: "%02x", $0) }.joined()
}

@MainActor
func testLibraryBrowserStateRealSQLitePagesAndShadowParity() async throws {
    let fixture = try makeBrowserSQLiteFixture(count: 60)
    let state = try LibraryBrowserState(repository: fixture.repository, pageSize: 4)

    let shapeFilters: [PromptFilter] = [
        PromptFilter(),
        PromptFilter(collection: .folder("folder-a")),
        PromptFilter(collection: .tag("browser")),
        PromptFilter(collection: .imagePrompts),
        PromptFilter(modelId: "model-a"),
        PromptFilter(collection: .favorites),
        PromptFilter(collection: .recent),
        PromptFilter(collection: .trash),
        PromptFilter(modelId: "model-a", collection: .folder("folder-a"), type: .image, favoriteOnly: true)
    ]

    for (shapeIndex, filter) in shapeFilters.enumerated() {
        let expectedIDs = browserExpectedIDs(fixture.items, filter)
        let query = try browserQuery(filter, pageSize: 4)
        let firstPageStarted = DispatchTime.now().uptimeNanoseconds
        await state.replace(query: query)
        let firstPageMillis = Double(DispatchTime.now().uptimeNanoseconds - firstPageStarted) / 1_000_000.0
        if shapeIndex == 0 {
            let tenPageStarted = DispatchTime.now().uptimeNanoseconds
            var loadedPageCount = 1
            while state.hasMore && loadedPageCount < 10 {
                await state.loadNextPage()
                loadedPageCount += 1
            }
            let tenPageMillis = Double(DispatchTime.now().uptimeNanoseconds - tenPageStarted) / 1_000_000.0
            print(
                String(
                    format: "LibraryBrowserState perf first-page=%.3fms ten-pages=%.3fms pages=%d",
                    firstPageMillis,
                    tenPageMillis,
                    loadedPageCount
                )
            )
        }
        while state.hasMore {
            await state.loadNextPage()
        }
        guard state.error == nil else { throw CoreUnitTestError.failure("real SQLite browser shape should not fail: \(filter)") }
        guard state.summaries.map(\.id) == expectedIDs else { throw CoreUnitTestError.failure("browser shape should preserve legacy IDs/order: \(filter)") }
        guard state.totalCount == expectedIDs.count else { throw CoreUnitTestError.failure("browser shape count should match legacy IDs: \(filter)") }
        guard Set(state.summaries.map(\.id)).count == state.summaries.count else { throw CoreUnitTestError.failure("browser pages must not contain duplicate IDs") }

        let report = await state.validateShadow(
            filter: filter,
            snapshot: LibraryFilterSnapshot(items: fixture.items),
            pageSize: 4
        )
        try expect(report.matches, "shadow parity should pass for shape \(filter): \(report.mismatchMessage ?? "unknown")")
    }
}

@MainActor
func testLibraryBrowserStateReadyBoundaryMatrixParity() async throws {
    let fixture = try makeBrowserSQLiteFixture(count: 3_600)
    let shapeFilters: [PromptFilter] = [
        PromptFilter(),
        PromptFilter(collection: .folder("folder-a")),
        PromptFilter(collection: .tag("browser")),
        PromptFilter(collection: .imagePrompts),
        PromptFilter(modelId: "model-a"),
        PromptFilter(collection: .favorites),
        PromptFilter(collection: .recent),
        PromptFilter(collection: .trash),
        PromptFilter(modelId: "model-a", collection: .folder("folder-a"), type: .image, favoriteOnly: true)
    ]
    let pageSizes = [300, 301, 600, 601]
    var tenPageWitness = false

    for pageSize in pageSizes {
        for filter in shapeFilters {
            let expectedIDs = browserExpectedIDs(fixture.items, filter)
            let state = try LibraryBrowserState(repository: fixture.repository, pageSize: pageSize)
            await state.replace(query: try browserQuery(filter, pageSize: pageSize))

            var pages: [[String]] = [state.summaries.map(\.id)]
            var pageCounts: [Int] = [state.totalCount]
            while state.hasMore {
                let beforeCount = state.summaries.count
                await state.loadNextPage()
                pages.append(Array(state.summaries.dropFirst(beforeCount).map(\.id)))
                pageCounts.append(state.totalCount)
            }

            let flattened = pages.flatMap { $0 }
            try expect(flattened == expectedIDs, "boundary matrix IDs/order mismatch for pageSize=\(pageSize) filter=\(filter)")
            try expect(pageCounts.allSatisfy { $0 == expectedIDs.count }, "boundary matrix count mismatch for pageSize=\(pageSize) filter=\(filter)")
            var seen = Set<String>()
            for id in flattened {
                try expect(seen.insert(id).inserted, "boundary matrix duplicate ID \(id) for pageSize=\(pageSize) filter=\(filter)")
            }

            var offset = 0
            for page in pages {
                let end = min(offset + page.count, expectedIDs.count)
                let expectedPage = Array(expectedIDs[offset..<end])
                try expect(
                    page.joined(separator: "|") == expectedPage.joined(separator: "|"),
                    "boundary matrix per-page hash/order mismatch for pageSize=\(pageSize) filter=\(filter)"
                )
                offset = end
            }
            if pageSize == 300 {
                tenPageWitness = tenPageWitness || pages.count >= 10
            }

            let report = await state.validateShadow(
                filter: filter,
                snapshot: LibraryFilterSnapshot(items: fixture.items),
                pageSize: pageSize
            )
            try expect(report.matches, "boundary matrix shadow mismatch for pageSize=\(pageSize) filter=\(filter): \(report.mismatchMessage ?? "unknown")")
        }
    }
    try expect(tenPageWitness, "pageSize=300 all-shape boundary matrix must walk at least ten pages")
}

@MainActor
func testLibraryBrowserStateRevisionInvalidatesRealSQLiteCursor() async throws {
    let fixture = try makeBrowserSQLiteFixture(count: 24, withTags: false)
    let state = try LibraryBrowserState(repository: fixture.repository, pageSize: 4)
    await state.replace(query: LibraryQuery(.all, pageSize: 4))
    guard state.hasMore else { throw CoreUnitTestError.failure("revision fixture must expose a next cursor") }
    let oldRevision = state.dataRevision
    var changed = fixture.items[0]
    changed.title = "mutated after cursor"
    try fixture.repository.saveItem(changed)
    try expect(fixture.repository.libraryDataRevision.current > oldRevision, "repository mutation must advance data revision")

    await state.loadNextPage()
    guard state.summaries.count == 4 else { throw CoreUnitTestError.failure("stale cursor must not append a page") }
    guard state.nextCursor == nil && !state.hasMore else { throw CoreUnitTestError.failure("stale cursor must be invalidated") }
    guard let stateError = state.error as? LibraryBrowserStateError,
          case .staleDataRevision = stateError else {
        throw CoreUnitTestError.failure("stale cursor should publish a stale-data error")
    }
}

@MainActor
func testLibraryBrowserStateRealSQLiteRapidSwitchCancellation() async throws {
    let fixture = try makeBrowserSQLiteFixture(count: 2_000, withTags: false)
    let metrics = BrowserSQLiteReadMetrics()
    let connection = try SQLiteReadConnection(
        path: fixture.repository.databaseURL.path,
        queryStartHook: { metrics.sqliteStarted() },
        queryPageAndCountHook: { Thread.sleep(forTimeInterval: 0.02) }
    )
    let executor = BrowserSQLiteExecutor(connection: connection, metrics: metrics)
    let service = LibraryQueryService(executor: executor, repository: fixture.repository)
    let state = LibraryBrowserState(service: service, initialQuery: LibraryQuery(pageSize: 8))

    let first = Task { @MainActor in
        await state.replace(query: LibraryQuery(.folder("folder-a"), pageSize: 8))
    }
    var firstStarted = false
    for _ in 0..<200 {
        if metrics.started > 0 {
            firstStarted = true
            break
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    try expect(firstStarted, "rapid-switch barrier must enter a real SQLite request")

    let switchStarted = DispatchTime.now().uptimeNanoseconds
    let tasks = (0..<50).map { index in
        Task { @MainActor in
            await state.replace(query: LibraryQuery(.folder(index.isMultiple(of: 2) ? "folder-a" : "folder-b"), pageSize: 8))
        }
    }
    for task in tasks { await task.value }
    await state.replace(query: LibraryQuery(.folder("folder-b"), pageSize: 8))
    await first.value
    let switchMillis = Double(DispatchTime.now().uptimeNanoseconds - switchStarted) / 1_000_000.0
    print(String(
        format: "LibraryBrowserState perf fifty-switches=%.3fms executor-starts=%d sqlite-starts=%d cancellations=%d max-active=%d",
        switchMillis,
        metrics.started,
        metrics.sqliteStarts,
        metrics.cancellations,
        metrics.maxActive
    ))
    let expectedCollection: LibraryQueryCollection = .folder("folder-b")
    guard state.currentQuery.collection == expectedCollection else { throw CoreUnitTestError.failure("last rapid-switch query must win") }
    guard state.initial == false && state.loadingNext == false else { throw CoreUnitTestError.failure("rapid switches must settle loading flags") }
    guard state.error == nil else { throw CoreUnitTestError.failure("rapid cancellation must not publish stale cancellation errors") }
    guard state.hasActiveRequest == false else { throw CoreUnitTestError.failure("rapid switches must leave no active request") }
    let expectedFolderBIDs = Set(fixture.items.filter { $0.folderId == "folder-b" && !$0.isDeleted }.map(\.id))
    let expectedFolderBPage = Array(browserExpectedIDs(fixture.items, PromptFilter(collection: .folder("folder-b"))).prefix(8))
    guard state.summaries.map(\.id) == expectedFolderBPage,
          state.summaries.allSatisfy({ expectedFolderBIDs.contains($0.id) }) else {
        throw CoreUnitTestError.failure("rapid switches must not apply stale folder-a results")
    }
    try expect(metrics.sqliteStarts > 0, "rapid switch test must exercise real SQLite reads")
    try expect(metrics.cancellations > 0, "rapid switch barrier must observe cancelled requests")
    try expect(metrics.active == 0, "rapid switch barrier must leave no active executor handles")
    try expect(metrics.maxActive <= 1, "rapid switches must serialize physical executor activity (max active \(metrics.maxActive))")
    try expect(switchMillis < 1_000, "rapid switch final latency must stay below one second")
}

@MainActor
func testLibraryBrowserStateSynchronousCancelInterruptsSQLiteAndDoesNotCancelReplacement() async throws {
    let fixture = try makeBrowserSQLiteFixture(count: 2_000, withTags: false)
    let metrics = BrowserSQLiteReadMetrics()
    let connection = try SQLiteReadConnection(
        path: fixture.repository.databaseURL.path,
        queryStartHook: { metrics.sqliteStarted() },
        queryPageAndCountHook: {
            Thread.sleep(forTimeInterval: 0.15)
        }
    )
    let executor = BrowserSQLiteExecutor(connection: connection, metrics: metrics)
    let service = LibraryQueryService(executor: executor, repository: fixture.repository)
    let state = LibraryBrowserState(service: service, initialQuery: LibraryQuery(pageSize: 8))

    let first = Task { @MainActor in
        await state.replace(query: LibraryQuery(.folder("folder-a"), pageSize: 8))
    }
    var started = false
    for _ in 0..<200 {
        if metrics.started > 0 {
            started = true
            break
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    try expect(started, "sync cancel barrier must enter a real SQLite read")

    state.cancel()
    try expect(!state.hasActiveRequest, "sync cancel must clear the published active token immediately")
    await first.value
    try expect(metrics.cancellations > 0, "sync cancel must interrupt the in-flight SQLite executor before replacement")

    let replacement = Task { @MainActor in
        await state.replace(query: LibraryQuery(.folder("folder-b"), pageSize: 8))
    }
    await replacement.value

    let expectedFolderBPage = Array(
        browserExpectedIDs(fixture.items, PromptFilter(collection: .folder("folder-b"))).prefix(8)
    )
    try expect(metrics.active == 0, "sync cancel and replacement must leave no executor backlog")
    try expect(metrics.maxActive <= 1, "sync cancel and replacement must serialize physical executor activity")
    try expect(state.currentQuery.collection == .folder("folder-b"), "replacement query must win after sync cancel")
    try expect(state.summaries.map(\.id) == expectedFolderBPage, "replacement page must not be lost to delayed cancellation")
    try expect(state.error == nil && !state.hasActiveRequest, "sync cancel replacement must settle cleanly")
}

@MainActor
func testLibraryBrowserStateSynchronousCancelImmediatelyFollowedByReplacement() async throws {
    let fixture = try makeBrowserSQLiteFixture(count: 1_000, withTags: false)
    let metrics = BrowserSQLiteReadMetrics()
    let connection = try SQLiteReadConnection(
        path: fixture.repository.databaseURL.path,
        queryStartHook: { metrics.sqliteStarted() },
        queryPageAndCountHook: {
            Thread.sleep(forTimeInterval: 0.15)
        }
    )
    let executor = BrowserSQLiteExecutor(connection: connection, metrics: metrics)
    let service = LibraryQueryService(executor: executor, repository: fixture.repository)
    let state = LibraryBrowserState(service: service, initialQuery: LibraryQuery(pageSize: 8))

    let first = Task { @MainActor in
        await state.replace(query: LibraryQuery(.folder("folder-a"), pageSize: 8))
    }
    var started = false
    for _ in 0..<200 {
        if metrics.started > 0 {
            started = true
            break
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    try expect(started, "immediate replacement barrier must enter a real SQLite read")

    state.cancel()
    let replacement = Task { @MainActor in
        await state.replace(query: LibraryQuery(.folder("folder-b"), pageSize: 8))
    }
    await first.value
    await replacement.value

    let expectedFolderBPage = Array(
        browserExpectedIDs(fixture.items, PromptFilter(collection: .folder("folder-b"))).prefix(8)
    )
    try expect(metrics.cancellations > 0, "immediate replacement must observe the cancelled SQLite request")
    try expect(metrics.active == 0, "immediate replacement must leave no executor backlog")
    try expect(metrics.maxActive <= 1, "immediate replacement must serialize physical executor activity")
    try expect(state.currentQuery.collection == .folder("folder-b"), "immediate replacement must win")
    try expect(state.summaries.map(\.id) == expectedFolderBPage, "immediate replacement page must commit")
    try expect(state.error == nil && !state.hasActiveRequest, "immediate replacement must settle cleanly")
}

@MainActor
func testLibraryBrowserStateCancelAndWaitInterruptsActiveSQLiteRequest() async throws {
    let fixture = try makeBrowserSQLiteFixture(count: 2_000, withTags: false)
    let metrics = BrowserSQLiteReadMetrics()
    let connection = try SQLiteReadConnection(
        path: fixture.repository.databaseURL.path,
        queryStartHook: { metrics.sqliteStarted() },
        queryPageAndCountHook: { Thread.sleep(forTimeInterval: 0.5) }
    )
    let executor = BrowserSQLiteExecutor(connection: connection, metrics: metrics)
    let service = LibraryQueryService(executor: executor, repository: fixture.repository)
    let state = LibraryBrowserState(service: service, initialQuery: LibraryQuery(pageSize: 8))
    let request = Task { @MainActor in
        await state.replace(query: LibraryQuery(.folder("folder-a"), pageSize: 8))
    }
    var started = false
    for _ in 0..<200 {
        if metrics.started > 0 {
            started = true
            break
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    try expect(started, "cancelAndWait witness must enter a real SQLite request")
    await state.cancelAndWait()
    await request.value
    try expect(metrics.cancellations > 0, "cancelAndWait must cancel the SQLite read")
    try expect(metrics.active == 0, "cancelAndWait must leave no active SQLite handles")
    try expect(state.summaries.isEmpty && state.error == nil, "cancelAndWait must not publish stale rows or cancellation errors")
    try expect(!state.hasActiveRequest, "cancelAndWait must clear the logical active token")
}

@MainActor
func testLibraryBrowserStateAwaitedRevisionInterruptsActiveSQLiteRequest() async throws {
    let fixture = try makeBrowserSQLiteFixture(count: 2_000, withTags: false)
    let metrics = BrowserSQLiteReadMetrics()
    let connection = try SQLiteReadConnection(
        path: fixture.repository.databaseURL.path,
        queryStartHook: { metrics.sqliteStarted() },
        queryPageAndCountHook: { Thread.sleep(forTimeInterval: 2.0) }
    )
    let executor = BrowserSQLiteExecutor(connection: connection, metrics: metrics)
    let service = LibraryQueryService(executor: executor, repository: fixture.repository)
    let state = LibraryBrowserState(service: service, initialQuery: LibraryQuery(pageSize: 8))
    let request = Task { @MainActor in
        await state.replace(query: LibraryQuery(.folder("folder-a"), pageSize: 8))
    }
    var started = false
    for _ in 0..<200 {
        if metrics.started > 0 {
            started = true
            break
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    try expect(started, "awaited revision witness must enter a real SQLite request")
    var changed = fixture.items[0]
    changed.title = "awaited-revision-active"
    try fixture.repository.saveItem(changed)
    await state.synchronizeDataRevisionAndWait()
    await request.value
    try expect(metrics.cancellations > 0, "awaited revision must cancel the SQLite read")
    try expect(metrics.active == 0, "awaited revision must leave no active SQLite handles")
    try expect(state.summaries.isEmpty && state.nextCursor == nil && !state.hasMore, "awaited revision must reject stale rows and cursor")
    guard let error = state.error as? LibraryBrowserStateError,
          case .staleDataRevision = error else {
        throw CoreUnitTestError.failure("awaited revision must publish stale-data error")
    }
    try expect(!state.hasActiveRequest, "awaited revision must clear the logical active token")
}

@MainActor
func testLibraryQuerySessionCancelledCallerCannotCancelNewerRequest() async throws {
    actor Executor: LibraryQueryRowExecutor {
        private var didStart = false

        var started: Bool { didStart }

        func query(sql: String, values: [SQLiteValue]) async throws -> [[String : String?]] { [] }

        func queryPageAndCount(
            pageSQL: String,
            pageValues: [SQLiteValue],
            countSQL: String,
            countValues: [SQLiteValue]
        ) async throws -> LibraryQueryReadBatch {
            didStart = true
            try await Task.sleep(for: .milliseconds(120))
            let folder = pageValues.compactMap { value -> String? in
                if case .text(let value) = value { return value }
                return nil
            }.first(where: { $0.hasPrefix("folder-") }) ?? "unknown"
            return LibraryQueryReadBatch(
                pageRows: [browserSummaryRow(id: folder == "folder-b" ? "B" : "A", sortOrder: 0)],
                countRows: [["totalCount": "1"]]
            )
        }
    }

    let executor = Executor()
    let service = LibraryQueryService(executor: executor, capabilities: .itemSequence)
    let session = LibraryQuerySession(service: service)
    let newer = Task {
        try await session.query(LibraryQuery(.folder("folder-b"), pageSize: 1))
    }
    var started = false
    for _ in 0..<200 {
        if await executor.started {
            started = true
            break
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    try expect(started, "newer session request must enter its executor before superseded caller")

    actor CallerGate {
        private var reached = false
        private var released = false

        func reachAndWait() async {
            reached = true
            while !released {
                await Task.yield()
            }
        }

        var hasReached: Bool { reached }

        func release() { released = true }
    }

    let gate = CallerGate()
    let superseded = Task {
        await gate.reachAndWait()
        return try await session.query(LibraryQuery(.folder("folder-a"), pageSize: 1))
    }
    var callerReachedGate = false
    for _ in 0..<200 {
        if await gate.hasReached {
            callerReachedGate = true
            break
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    try expect(callerReachedGate, "superseded caller must reach its controlled actor gate")
    superseded.cancel()
    await gate.release()
    let page = try await newer.value
    try expect(page.items.map(\.id) == ["B"], "newer session request must survive a delayed cancelled caller")
    let supersededResult = try? await superseded.value
    try expect(supersededResult == nil, "superseded caller must not produce a page")
}

@MainActor
func testLibraryBrowserStateUnsupportedFilterAndRetryContract() async throws {
    let fixture = try makeBrowserSQLiteFixture(count: 8, withTags: false)
    let state = try LibraryBrowserState(repository: fixture.repository, pageSize: 4)
    await state.replace(filter: PromptFilter(query: "free text"), pageSize: 4)
    guard let stateError = state.error as? LibraryBrowserStateError,
          case .unsupportedFilters(let fields) = stateError else {
        throw CoreUnitTestError.failure("unsupported free text must remain explicit")
    }
    guard fields == [.freeText] else { throw CoreUnitTestError.failure("free text should be the only unsupported field") }

    let unsupported = PromptFilter(
        textFormat: .markdown,
        assetKindFilter: .image,
        requiredTag: "browser",
        hasPromptOnly: true,
        hasReferenceOnly: true
    )
    do {
        _ = try LibraryBrowserState.query(from: unsupported)
        throw CoreUnitTestError.failure("summary conversion must reject every unsupported filter field")
    } catch LibraryBrowserStateError.unsupportedFilters(let unsupportedFields) {
        try expect(
            unsupportedFields == [.textFormat, .assetKind, .requiredTag, .hasPrompt, .hasReferences],
            "unsupported filter fields should be reported without silent drops"
        )
    }
    let constraint = LibraryBrowserState.searchDocumentConstraint
    try expect(
        !constraint.supportsFreeText && !constraint.supportsTextFormat && !constraint.supportsAssetKind &&
            !constraint.supportsRequiredTag && !constraint.supportsHasPrompt && !constraint.supportsHasReferences,
        "summary SearchDocument constraint should explicitly mark every unsupported field"
    )

    await state.replace(query: LibraryQuery(.all, pageSize: 4))
    let selected = state.summaries.first?.id
    state.selectionID = selected
    await state.loadNextPage()
    guard state.selectionID == selected else { throw CoreUnitTestError.failure("selection must stay ID-based across append") }
    await state.retry()
    guard state.error == nil else { throw CoreUnitTestError.failure("retry after a successful page should remain healthy") }
}

@MainActor
func testLibraryBrowserStateReplaceAppendRaceAndAtomicDisplay() async throws {
    actor Executor: LibraryQueryRowExecutor {
        private var calls = 0

        func query(sql: String, values: [SQLiteValue]) async throws -> [[String : String?]] { [] }

        func queryPageAndCount(
            pageSQL: String,
            pageValues: [SQLiteValue],
            countSQL: String,
            countValues: [SQLiteValue]
        ) async throws -> LibraryQueryReadBatch {
            calls += 1
            let call = calls
            try await Task.sleep(for: .milliseconds(call == 1 ? 200 : 1))
            let id = call == 1 ? "old" : "new"
            return LibraryQueryReadBatch(
                pageRows: [browserSummaryRow(id: id, sortOrder: 0)],
                countRows: [["totalCount": "1"]]
            )
        }
    }

    let service = LibraryQueryService(executor: Executor(), capabilities: .itemSequence)
    let state = LibraryBrowserState(service: service, initialQuery: LibraryQuery(pageSize: 1))
    let first = Task { @MainActor in
        await state.replace(query: LibraryQuery(.folder("old"), pageSize: 1))
    }
    try await Task.sleep(for: .milliseconds(20))
    try expect(state.initial, "replacement should publish initial loading before its first await")
    try expect(!state.hasMore && state.nextCursor == nil, "replacement must clear old pagination immediately")
    try expect(state.currentQuery.collection == .all, "display query must remain atomic while replacement is pending")
    try expect(state.pendingQuery?.collection == .folder("old"), "pending query must identify the requested display")
    await state.loadNextPage()
    try expect(state.summaries.isEmpty, "append must be ignored while initial replacement is active")

    let second = Task { @MainActor in
        await state.replace(query: LibraryQuery(.folder("new"), pageSize: 1))
    }
    await first.value
    await second.value
    try expect(state.currentQuery.collection == .folder("new"), "latest replacement must win the race")
    try expect(state.pendingQuery == nil, "committed replacement must clear pending query")
    try expect(state.summaries.map(\.id) == ["new"], "stale first result must never apply")
    try expect(!state.hasActiveRequest, "replacement race must leave no active request")
}

@MainActor
func testLibraryBrowserStateSameQueryRefreshCommitsNewGeneration() async throws {
    actor Executor: LibraryQueryRowExecutor {
        private var calls = 0

        func query(sql: String, values: [SQLiteValue]) async throws -> [[String : String?]] { [] }

        func queryPageAndCount(
            pageSQL: String,
            pageValues: [SQLiteValue],
            countSQL: String,
            countValues: [SQLiteValue]
        ) async throws -> LibraryQueryReadBatch {
            calls += 1
            return LibraryQueryReadBatch(
                pageRows: [browserSummaryRow(id: "refresh-\(calls)", sortOrder: 0)],
                countRows: [["totalCount": "1"]]
            )
        }
    }

    let service = LibraryQueryService(executor: Executor(), capabilities: .itemSequence)
    let state = LibraryBrowserState(service: service, initialQuery: LibraryQuery(pageSize: 1))
    let query = LibraryQuery(.all, pageSize: 1)
    await state.replace(query: query)
    let firstGeneration = state.generation
    try expect(state.summaries.map(\.id) == ["refresh-1"], "initial query should commit its first page")
    await state.replace(query: state.currentQuery)
    try expect(state.generation > firstGeneration, "same-query refresh must start a new generation")
    try expect(state.summaries.map(\.id) == ["refresh-2"], "same-query refresh must replace the visible page")
    try expect(state.error == nil && !state.hasActiveRequest, "same-query refresh must settle cleanly")
}

@MainActor
func testLibraryBrowserStateInitialFailureRetryAndRevisionDuringInitial() async throws {
    actor FailingExecutor: LibraryQueryRowExecutor {
        private var calls = 0

        func query(sql: String, values: [SQLiteValue]) async throws -> [[String : String?]] { [] }

        func queryPageAndCount(
            pageSQL: String,
            pageValues: [SQLiteValue],
            countSQL: String,
            countValues: [SQLiteValue]
        ) async throws -> LibraryQueryReadBatch {
            calls += 1
            if calls == 1 { throw BrowserExecutorError.firstRequest }
            return LibraryQueryReadBatch(
                pageRows: [browserSummaryRow(id: "retry", sortOrder: 0)],
                countRows: [["totalCount": "1"]]
            )
        }
    }

    let service = LibraryQueryService(executor: FailingExecutor(), capabilities: .itemSequence)
    let state = LibraryBrowserState(service: service, initialQuery: LibraryQuery(pageSize: 1))
    await state.replace(query: LibraryQuery(.folder("retry"), pageSize: 1))
    try expect(!state.initial && !state.loadingNext, "initial failure must settle loading flags")
    try expect(state.nextCursor == nil && !state.hasMore, "initial failure must clear pagination")
    try expect(state.error != nil, "initial failure must be observable")
    await state.retry()
    try expect(state.error == nil && state.summaries.map(\.id) == ["retry"], "retry must rerun the failed initial request")

    let revision = LibraryDataRevision()
    actor SlowExecutor: LibraryQueryRowExecutor {
        private var entered = false

        var didEnter: Bool { entered }

        func query(sql: String, values: [SQLiteValue]) async throws -> [[String : String?]] { [] }

        func queryPageAndCount(
            pageSQL: String,
            pageValues: [SQLiteValue],
            countSQL: String,
            countValues: [SQLiteValue]
        ) async throws -> LibraryQueryReadBatch {
            entered = true
            try await Task.sleep(for: .milliseconds(120))
            return LibraryQueryReadBatch(
                pageRows: [browserSummaryRow(id: "stale", sortOrder: 0)],
                countRows: [["totalCount": "1"]]
            )
        }
    }

    let slowExecutor = SlowExecutor()
    let revisionService = LibraryQueryService(
        executor: slowExecutor,
        dataRevision: revision,
        capabilities: .itemSequence
    )
    let revisionState = LibraryBrowserState(service: revisionService, initialQuery: LibraryQuery(pageSize: 1))
    let initialTask = Task { @MainActor in
        await revisionState.replace(query: LibraryQuery(.all, pageSize: 1))
    }
    var entered = false
    for _ in 0..<200 {
        if await slowExecutor.didEnter {
            entered = true
            break
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    guard entered else {
        throw CoreUnitTestError.failure("revision test did not enter its initial read")
    }
    _ = revision.advance()
    await initialTask.value
    try expect(!revisionState.initial && !revisionState.loadingNext, "revision during initial must settle loading flags")
    try expect(!revisionState.hasActiveRequest, "revision during initial must clear active request state")
    try expect(revisionState.nextCursor == nil && !revisionState.hasMore, "revision during initial must clear pagination")
    try expect(revisionState.summaries.isEmpty, "stale initial result must not apply")
    guard let revisionError = revisionState.error as? LibraryBrowserStateError,
          case .staleDataRevision = revisionError else {
        throw CoreUnitTestError.failure("revision during initial should publish stale-data error")
    }
}

@MainActor
func testLibraryBrowserStateFailedReplacementPreservesDisplayAndRetriesExactQuery() async throws {
    actor Executor: LibraryQueryRowExecutor {
        private(set) var calls = 0
        private(set) var folders: [String] = []

        var callCount: Int { calls }
        var observedFolders: [String] { folders }

        func query(sql: String, values: [SQLiteValue]) async throws -> [[String : String?]] { [] }

        func queryPageAndCount(
            pageSQL: String,
            pageValues: [SQLiteValue],
            countSQL: String,
            countValues: [SQLiteValue]
        ) async throws -> LibraryQueryReadBatch {
            calls += 1
            let folder = pageValues.compactMap { value -> String? in
                if case .text(let value) = value { return value }
                return nil
            }.first(where: { $0 == "old" || $0 == "new" }) ?? "unknown"
            folders.append(folder)
            if calls == 2 {
                throw BrowserExecutorError.firstRequest
            }
            let id = calls == 1 ? "old-display" : "new-display"
            return LibraryQueryReadBatch(
                pageRows: [browserSummaryRow(id: id, sortOrder: 0)],
                countRows: [["totalCount": "1"]]
            )
        }
    }

    let executor = Executor()
    let service = LibraryQueryService(executor: executor, capabilities: .itemSequence)
    let state = LibraryBrowserState(service: service, initialQuery: LibraryQuery(pageSize: 1))
    await state.replace(query: LibraryQuery(.folder("old"), pageSize: 1))
    try expect(state.summaries.map(\.id) == ["old-display"], "display fixture must commit before replacement failure")
    state.selectionID = "old-display"

    await state.replace(query: LibraryQuery(.folder("new"), pageSize: 1))
    try expect(state.currentQuery.collection == .folder("old"), "failed replacement must preserve display query")
    try expect(state.summaries.map(\.id) == ["old-display"], "failed replacement must preserve display summaries")
    try expect(state.pendingQuery?.collection == .folder("new"), "failed replacement must retain pending failed query")
    try expect(state.selectionID == "old-display", "failed replacement must preserve ID selection")
    try expect(state.error != nil, "failed replacement must publish its error")

    await state.retry()
    try expect(state.currentQuery.collection == .folder("new"), "retry must commit the failed replacement query")
    try expect(state.summaries.map(\.id) == ["new-display"], "retry must publish the retried page")
    try expect(state.error == nil && !state.hasActiveRequest, "retried replacement must settle cleanly")
    let calls = await executor.callCount
    let folders = await executor.observedFolders
    try expect(calls == 3, "initial, failed replacement, and one retry must be the only executor calls")
    try expect(folders == ["old", "new", "new"], "retry must execute only the failed replacement fingerprint: calls=\(calls) folders=\(folders)")
}

@MainActor
func testLibraryBrowserStateUnsupportedFiltersDoNotInvokeExecutor() async throws {
    actor CountingExecutor: LibraryQueryRowExecutor {
        private(set) var calls = 0

        var callCount: Int { calls }

        func query(sql: String, values: [SQLiteValue]) async throws -> [[String : String?]] {
            calls += 1
            return []
        }

        func queryPageAndCount(
            pageSQL: String,
            pageValues: [SQLiteValue],
            countSQL: String,
            countValues: [SQLiteValue]
        ) async throws -> LibraryQueryReadBatch {
            calls += 1
            return LibraryQueryReadBatch(pageRows: [], countRows: [["totalCount": "0"]])
        }
    }

    let executor = CountingExecutor()
    let service = LibraryQueryService(executor: executor, capabilities: .itemSequence)
    let state = LibraryBrowserState(service: service, initialQuery: LibraryQuery(pageSize: 4))
    let unsupported = PromptFilter(
        query: "free text",
        textFormat: .markdown,
        assetKindFilter: .image,
        requiredTag: "browser",
        hasPromptOnly: true,
        hasReferenceOnly: true
    )
    await state.replace(filter: unsupported, pageSize: 4)
    guard let error = state.error as? LibraryBrowserStateError,
          case .unsupportedFilters(let fields) = error else {
        throw CoreUnitTestError.failure("unsupported filter should fail closed before the session")
    }
    try expect(
        fields == [.freeText, .textFormat, .assetKind, .requiredTag, .hasPrompt, .hasReferences],
        "unsupported filter fields must remain deterministic"
    )
    let executorCalls = await executor.callCount
    try expect(executorCalls == 0, "unsupported filter must not invoke the executor")
}

@MainActor
func testLibraryBrowserStateShadowRejectsLaterPageCountDrift() async throws {
    actor CountDriftExecutor: LibraryQueryRowExecutor {
        private(set) var calls = 0

        func query(sql: String, values: [SQLiteValue]) async throws -> [[String : String?]] { [] }

        func queryPageAndCount(
            pageSQL: String,
            pageValues: [SQLiteValue],
            countSQL: String,
            countValues: [SQLiteValue]
        ) async throws -> LibraryQueryReadBatch {
            calls += 1
            if calls == 1 {
                return LibraryQueryReadBatch(
                    pageRows: [
                        browserSummaryRow(id: "a", sortOrder: 0),
                        browserSummaryRow(id: "b", sortOrder: 1)
                    ],
                    countRows: [["totalCount": "2"]]
                )
            }
            return LibraryQueryReadBatch(
                pageRows: [browserSummaryRow(id: "b", sortOrder: 1)],
                countRows: [["totalCount": "3"]]
            )
        }
    }

    let itemA = sampleItem(title: "A", prompt: "a")
    var itemB = sampleItem(title: "B", prompt: "b")
    itemB.id = "b"
    var first = itemA
    first.id = "a"
    let snapshot = LibraryFilterSnapshot(items: [first, itemB])
    let service = LibraryQueryService(executor: CountDriftExecutor(), capabilities: .itemSequence)
    let state = LibraryBrowserState(service: service, initialQuery: LibraryQuery(pageSize: 1))
    let report = await state.validateShadow(filter: PromptFilter(), snapshot: snapshot, pageSize: 1)
    guard case .count(let expected, let actual)? = report.mismatch else {
        throw CoreUnitTestError.failure("later-page count drift must produce a deterministic count mismatch")
    }
    try expect(expected == 2 && actual == 3, "later-page count drift must preserve first/later totals")
}

@MainActor
func testLibraryBrowserStateConcurrentAppendCoalescesOneExecutorCall() async throws {
    actor Executor: LibraryQueryRowExecutor {
        private(set) var calls = 0

        var callCount: Int { calls }

        func query(sql: String, values: [SQLiteValue]) async throws -> [[String: String?]] { [] }

        func queryPageAndCount(
            pageSQL: String,
            pageValues: [SQLiteValue],
            countSQL: String,
            countValues: [SQLiteValue]
        ) async throws -> LibraryQueryReadBatch {
            calls += 1
            if calls == 1 {
                return LibraryQueryReadBatch(
                    pageRows: [
                        browserSummaryRow(id: "a", sortOrder: 0),
                        browserSummaryRow(id: "b", sortOrder: 1),
                        browserSummaryRow(id: "c", sortOrder: 2),
                        browserSummaryRow(id: "d", sortOrder: 3)
                    ],
                    countRows: [["totalCount": "4"]]
                )
            }
            try await Task.sleep(for: .milliseconds(40))
            return LibraryQueryReadBatch(
                pageRows: [
                    browserSummaryRow(id: "c", sortOrder: 2),
                    browserSummaryRow(id: "d", sortOrder: 3)
                ],
                countRows: [["totalCount": "4"]]
            )
        }
    }

    let executor = Executor()
    let service = LibraryQueryService(executor: executor, capabilities: .itemSequence)
    let state = LibraryBrowserState(service: service, initialQuery: LibraryQuery(pageSize: 3))
    await state.replace(query: LibraryQuery(.all, pageSize: 3))
    let first = Task { @MainActor in await state.loadNextPage() }
    let second = Task { @MainActor in await state.loadNextPage() }
    await first.value
    await second.value
    let callCount = await executor.callCount
    try expect(callCount == 2, "concurrent append callers must share one page+count executor call")
    try expect(state.summaries.map(\.id) == ["a", "b", "c", "d"], "append must dedupe IDs from the continuation page")
    try expect(state.totalCount == 4 && !state.hasMore, "append must publish count and terminal cursor state")
}

func testLibraryBrowserStateExactCursorTokenRoundTrip() async throws {
    let rows = (0..<301).map { index in
        browserSummaryRow(id: "token-\(index)", sortOrder: index)
    }
    let service = LibraryQueryService(
        executor: { sql, _ in
            sql.contains("COUNT(*)") ? [["totalCount": "301"]] : rows
        },
        capabilities: .itemSequence
    )
    let page = try await service.query(LibraryQuery(.all, pageSize: 300))
    guard let cursor = page.nextCursor else {
        throw CoreUnitTestError.failure("301-row cursor fixture must expose a continuation")
    }
    let token = try cursor.encoded()
    let decoded = try LibraryQueryCursor(encoded: token)
    try expect(decoded == cursor, "cursor encoding must preserve every typed token field")
    try expect(decoded.itemCreatedAtSortKey != nil, "ready cursor must preserve item created sort key")
    try expect(decoded.itemLastUsedAtSortKey != nil, "ready cursor must preserve item last-used sort key")
    try expect(decoded.itemSequence != nil && decoded.itemSequence! > 0, "ready cursor must preserve positive item sequence")
    var continuation = LibraryQuery(.all, pageSize: 300, cursor: decoded)
    let firstSQL = try LibraryQuerySQLBuilder.build(
        LibraryQuery(.all, pageSize: 300),
        capabilities: .itemSequence
    )
    continuation.dataRevision = 0
    let continuationSQL = try LibraryQuerySQLBuilder.build(continuation, capabilities: .itemSequence)
    try expect(continuationSQL.queryFingerprint == firstSQL.queryFingerprint, "decoded cursor must bind to its original query fingerprint")
}

@MainActor
func testLibraryBrowserStateDecodedCursorExecutesContinuationThroughSession() async throws {
    let fixture = try makeBrowserSQLiteFixture(count: 800, withTags: false)
    let state = try LibraryBrowserState(repository: fixture.repository, pageSize: 300)
    let query = LibraryQuery(.all, pageSize: 300)
    await state.replace(query: query)
    let firstBrowserPage = state.summaries
    let session = LibraryQuerySession(service: state.service)
    let baseQuery = state.currentQuery
    let firstSessionPage = try await session.query(baseQuery)
    try expect(firstBrowserPage == firstSessionPage.items, "BrowserState Page1 must preserve every summary field from Session")
    try expect(state.totalCount == firstSessionPage.totalCount, "BrowserState Page1 count must match Session")
    try expect(browserSummaryDigest(firstBrowserPage) == browserSummaryDigest(firstSessionPage.items), "BrowserState Page1 summary hash must match Session")
    try expect(state.nextCursor == firstSessionPage.nextCursor, "BrowserState Page1 cursor must match Session")
    guard let cursor1 = state.nextCursor else {
        throw CoreUnitTestError.failure("800-row BrowserState fixture must expose a first-page cursor")
    }
    let encoded1 = try cursor1.encoded()
    let decoded1 = try LibraryQueryCursor(encoded: encoded1)
    try expect(decoded1 == cursor1, "Page1 cursor encode/decode must preserve every typed field")
    let expectedIDs = browserExpectedIDs(fixture.items, PromptFilter())
    let expectedPage2IDs = Array(expectedIDs.dropFirst(300).prefix(300))
    let expectedPage3IDs = Array(expectedIDs.dropFirst(600))

    var page2Query = baseQuery
    page2Query.cursor = decoded1
    let sessionPage2 = try await session.query(page2Query)
    try expect(sessionPage2.items.map(\.id) == expectedPage2IDs, "decoded Page1 cursor Session Page2 must match exact golden IDs/order")
    try expect(sessionPage2.items.map(\.id).count == Set(sessionPage2.items.map(\.id)).count, "decoded Page1 cursor Session Page2 must not duplicate IDs")
    guard let sessionPage2Cursor = sessionPage2.nextCursor else {
        throw CoreUnitTestError.failure("800-row Page2 must expose a Page3 cursor")
    }

    await state.loadNextPage()
    let browserPage2 = Array(state.summaries.dropFirst(firstBrowserPage.count))
    try expect(browserPage2 == sessionPage2.items, "BrowserState Page2 must preserve every summary field from Session")
    try expect(browserPage2.map(\.id) == expectedPage2IDs, "BrowserState Page2 must match exact golden IDs/order")
    try expect(state.totalCount == sessionPage2.totalCount, "BrowserState Page2 count must match Session")
    try expect(browserSummaryDigest(browserPage2) == browserSummaryDigest(sessionPage2.items), "BrowserState Page2 summary hash must match Session")
    try expect(state.nextCursor == sessionPage2.nextCursor, "BrowserState Page2 cursor must match Session")
    try expect(state.hasMore == sessionPage2.hasMore, "BrowserState Page2 hasMore must match Session")
    guard let cursor2 = state.nextCursor else {
        throw CoreUnitTestError.failure("BrowserState Page2 must expose the actual Page3 cursor")
    }
    try expect(cursor2 == sessionPage2Cursor, "BrowserState actual Page2 cursor must equal Session Page2 cursor")
    let encoded2 = try cursor2.encoded()
    let decoded2 = try LibraryQueryCursor(encoded: encoded2)
    try expect(decoded2 == cursor2, "Page2 cursor encode/decode must preserve every typed field")
    try expect(decoded2 != decoded1, "Page3 continuation must decode the actual Page2 cursor, not reuse Page1 cursor")

    var page3Query = baseQuery
    page3Query.cursor = decoded2
    let sessionPage3 = try await session.query(page3Query)
    try expect(sessionPage3.items.map(\.id) == expectedPage3IDs, "decoded Page2 cursor Session Page3 must match exact golden IDs/order")
    try expect(sessionPage3.items.map(\.id).count == Set(sessionPage3.items.map(\.id)).count, "decoded Page2 cursor Session Page3 must not duplicate IDs")

    await state.loadNextPage()
    let browserPage3 = Array(state.summaries.dropFirst(firstBrowserPage.count + browserPage2.count))
    try expect(browserPage3 == sessionPage3.items, "BrowserState Page3 must preserve every summary field from Session")
    try expect(browserPage3.map(\.id) == expectedPage3IDs, "BrowserState Page3 must match exact golden IDs/order")
    try expect(state.totalCount == sessionPage3.totalCount, "BrowserState Page3 count must match Session")
    try expect(browserSummaryDigest(browserPage3) == browserSummaryDigest(sessionPage3.items), "BrowserState Page3 summary hash must match Session")
    try expect(state.nextCursor == sessionPage3.nextCursor, "BrowserState Page3 cursor must match Session")
    try expect(state.hasMore == sessionPage3.hasMore, "BrowserState Page3 hasMore must match Session")

    let combinedSession = firstSessionPage.items + sessionPage2.items + sessionPage3.items
    try expect(state.summaries == combinedSession, "three-page BrowserState summaries must match combined Session summaries")
    try expect(state.summaries.map(\.id) == expectedIDs, "three-page BrowserState IDs must match exact golden order")
    try expect(Set(state.summaries.map(\.id)).count == expectedIDs.count, "three-page BrowserState result must have no duplicate IDs")
    try expect(state.summaries.count == expectedIDs.count, "three-page BrowserState result must have no missing IDs")
    try expect(browserSummaryDigest(state.summaries) == browserSummaryDigest(combinedSession), "three-page combined summary hash must match Session")
    try expect(state.totalCount == expectedIDs.count, "three-page BrowserState combined count must match golden count")
}

@MainActor
func testLibraryBrowserStateRevisionSynchronizationInvalidatesCursorImmediatelyAndAwaited() async throws {
    let fixture = try makeBrowserSQLiteFixture(count: 24, withTags: false)
    let state = try LibraryBrowserState(repository: fixture.repository, pageSize: 4)
    await state.replace(query: LibraryQuery(.all, pageSize: 4))
    try expect(state.nextCursor != nil, "revision synchronization fixture must expose a cursor")

    var changed = fixture.items[0]
    changed.title = "revision-immediate"
    try fixture.repository.saveItem(changed)
    state.synchronizeDataRevision()
    try expect(state.nextCursor == nil && !state.hasMore, "immediate revision synchronization must clear old pagination")
    guard let immediateError = state.error as? LibraryBrowserStateError,
          case .staleDataRevision = immediateError else {
        throw CoreUnitTestError.failure("immediate revision synchronization must publish stale-data error")
    }

    await state.replace(query: LibraryQuery(.all, pageSize: 4))
    var changedAgain = fixture.items[1]
    changedAgain.title = "revision-awaited"
    try fixture.repository.saveItem(changedAgain)
    await state.synchronizeDataRevisionAndWait()
    try expect(state.nextCursor == nil && !state.hasMore, "awaited revision synchronization must clear old pagination")
    guard let awaitedError = state.error as? LibraryBrowserStateError,
          case .staleDataRevision = awaitedError else {
        throw CoreUnitTestError.failure("awaited revision synchronization must publish stale-data error")
    }
    try expect(!state.hasActiveRequest, "awaited revision synchronization must settle the cancelled request")
}

private enum BrowserExecutorError: Error {
    case firstRequest
}

private func browserSummaryRow(id: String, sortOrder: Int) -> [String: String?] {
    let dateValue = Date(timeIntervalSince1970: 1_700_000_000 - Double(sortOrder))
    let date = ISO8601DateFormatter().string(from: dateValue)
    let itemCreatedAtSortKey = Int64((dateValue.timeIntervalSince1970 * 1_000_000).rounded())
    let itemLastUsedAtSortKey: Int64 = 0
    let itemSequence = Int64(max(1, sortOrder + 1))
    return [
        "id": id, "title": id, "type": PromptType.image.rawValue, "assetKind": AssetKind.image.rawValue,
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

private final class BrowserSQLiteReadMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var activeCount = 0
    private var startedCount = 0
    private var sqliteStartsCount = 0
    private var cancellationsCount = 0
    private var maxActiveCount = 0

    func began() {
        lock.lock()
        startedCount += 1
        activeCount += 1
        maxActiveCount = max(maxActiveCount, activeCount)
        lock.unlock()
    }

    func ended(cancelled: Bool) {
        lock.lock()
        activeCount = max(0, activeCount - 1)
        if cancelled { cancellationsCount += 1 }
        lock.unlock()
    }

    func sqliteStarted() {
        lock.lock()
        sqliteStartsCount += 1
        lock.unlock()
    }

    var started: Int {
        lock.lock()
        defer { lock.unlock() }
        return startedCount
    }

    var sqliteStarts: Int {
        lock.lock()
        defer { lock.unlock() }
        return sqliteStartsCount
    }

    var cancellations: Int {
        lock.lock()
        defer { lock.unlock() }
        return cancellationsCount
    }

    var maxActive: Int {
        lock.lock()
        defer { lock.unlock() }
        return maxActiveCount
    }

    var active: Int {
        lock.lock()
        defer { lock.unlock() }
        return activeCount
    }
}

private final class BrowserSQLiteExecutor: @unchecked Sendable, LibraryQueryRowExecutor {
    private let connection: SQLiteReadConnection
    private let metrics: BrowserSQLiteReadMetrics

    init(connection: SQLiteReadConnection, metrics: BrowserSQLiteReadMetrics) {
        self.connection = connection
        self.metrics = metrics
    }

    func query(sql: String, values: [SQLiteValue]) async throws -> [[String : String?]] {
        try await connection.query(sql, values: values)
    }

    func queryPageAndCount(
        pageSQL: String,
        pageValues: [SQLiteValue],
        countSQL: String,
        countValues: [SQLiteValue]
    ) async throws -> LibraryQueryReadBatch {
        metrics.began()
        do {
            let result = try await connection.queryPageAndCount(
                pageSQL: pageSQL,
                pageValues: pageValues,
                countSQL: countSQL,
                countValues: countValues
            )
            metrics.ended(cancelled: false)
            return result
        } catch is CancellationError {
            metrics.ended(cancelled: true)
            throw CancellationError()
        } catch {
            metrics.ended(cancelled: false)
            throw error
        }
    }
}

private final class LockBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    @discardableResult
    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&stored)
    }

    var value: Value {
        withLock { $0 }
    }
}
