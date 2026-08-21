import Foundation
import PromptStudioCore

func testLibraryQueryServiceRefusesUnreadyVersionSummary() async throws {
    final class CallCounter: @unchecked Sendable { var count = 0 }
    let counter = CallCounter()
    let service = LibraryQueryService(executor: { _, _ in
        counter.count += 1
        return []
    })
    do {
        _ = try await service.query(LibraryQuery(pageSize: 1))
        throw CoreUnitTestError.failure("unready query service must fail closed")
    } catch LibraryQuerySQLBuilderError.versionSequenceNotReady {
        // Expected: the executor must never see a semantically unsafe query.
    }
    try expect(counter.count == 0, "unready query service must reject before executing SQL")
}

private final class LibraryQueryExecutorStub: @unchecked Sendable {
    var rows: [[String: String?]]
    var sql: String = ""
    var values: [SQLiteValue] = []
    var onQuery: (() -> Void)?

    init(rows: [[String: String?]]) {
        self.rows = rows
    }
}

private final class LibraryQuerySnapshotExecutorStub: LibraryQueryRowExecutor, @unchecked Sendable {
    private(set) var standaloneQueryCount = 0
    private(set) var snapshotQueryCount = 0
    let rows: [[String: String?]]
    var onSnapshot: (() -> Void)?

    init(rows: [[String: String?]]) {
        self.rows = rows
    }

    func query(sql: String, values: [SQLiteValue]) async throws -> [[String: String?]] {
        standaloneQueryCount += 1
        return sql.contains("COUNT(*)") ? [["totalCount": "\(rows.count)"]] : rows
    }

    func queryPageAndCount(
        pageSQL: String,
        pageValues: [SQLiteValue],
        countSQL: String,
        countValues: [SQLiteValue]
    ) async throws -> LibraryQueryReadBatch {
        snapshotQueryCount += 1
        onSnapshot?()
        return LibraryQueryReadBatch(
            pageRows: rows,
            countRows: [["totalCount": "\(rows.count)"]]
        )
    }
}

private final class AtomicReadWriterState: @unchecked Sendable {
    private let lock = NSLock()
    private var didRun = false
    private var error: Error?

    func claimWriter() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didRun else { return false }
        didRun = true
        return true
    }

    func record(error: Error) {
        lock.lock()
        self.error = error
        lock.unlock()
    }

    var writerError: Error? {
        lock.lock()
        defer { lock.unlock() }
        return error
    }
}

private enum AtomicReadWriterMutation: CaseIterable, Equatable, Sendable {
    case insert
    case delete
    case favorite
    case folderMove
    case trash
    case restore

    var query: LibraryQuery {
        switch self {
        case .favorite:
            LibraryQuery(.favorite, pageSize: 300)
        case .folderMove:
            LibraryQuery(.folder("folder-old"), pageSize: 300)
        case .restore:
            LibraryQuery(.trash, pageSize: 300)
        case .insert, .delete, .trash:
            LibraryQuery(.all, pageSize: 300)
        }
    }

    var expectedCount: Int {
        self == .favorite ? 0 : 301
    }

    var expectsTargetInPage: Bool {
        switch self {
        case .delete, .folderMove, .trash, .restore:
            true
        case .insert, .favorite:
            false
        }
    }

    func configureInitialItems(_ items: inout [PromptItem]) {
        switch self {
        case .folderMove:
            for index in items.indices {
                items[index].folderId = "folder-old"
                items[index].folderName = "Old Folder"
            }
        case .restore:
            for index in items.indices {
                items[index].deletedAt = Date(timeIntervalSince1970: 100)
            }
        case .insert, .delete, .favorite, .trash:
            break
        }
    }

    func apply(to repository: PromptRepository, target: PromptItem) throws {
        switch self {
        case .insert:
            var inserted = sampleItem(title: "inserted during read", prompt: "inserted during read")
            inserted.id = "atomic-inserted"
            inserted.sortOrder = 10_000
            inserted.versions = []
            try repository.saveItem(inserted)
        case .delete:
            try repository.permanentlyDelete(itemID: target.id)
        case .favorite:
            var favorite = target
            favorite.favorite = true
            try repository.saveItem(favorite)
        case .folderMove:
            var moved = target
            moved.folderId = "folder-new"
            moved.folderName = "New Folder"
            moved.updatedAt = Date()
            try repository.updateItemFolders([moved])
        case .trash:
            try repository.markDeleted(itemID: target.id, deletedAt: Date(timeIntervalSince1970: 200))
        case .restore:
            try repository.markDeleted(itemID: target.id, deletedAt: nil)
        }
    }
}

private func summaryRow(
    id: String,
    sortOrder: Int,
    createdAt: Date,
    lastUsedAt: Date = Date(timeIntervalSince1970: 0),
    hasPrompt: Bool = true,
    hasReferences: Bool = false
) -> [String: String?] {
    let encoder = ISO8601DateFormatter()
    let itemCreatedAtSortKey = Int64((createdAt.timeIntervalSince1970 * 1_000_000).rounded())
    let itemLastUsedAtSortKey = Int64((lastUsedAt.timeIntervalSince1970 * 1_000_000).rounded())
    let itemSequence = Int64(id.split(separator: "-").last.flatMap { Int64($0) }.map { $0 + 1 } ?? 1)
    return [
        "id": id,
        "title": "Title \(id)",
        "type": PromptType.image.rawValue,
        "assetKind": AssetKind.image.rawValue,
        "modelId": "model",
        "modelName": "Model",
        "folderId": "folder",
        "folderName": "Folder",
        "category": "图片",
        "assetPath": "/tmp/\(id).png",
        "thumbnailPath": "/tmp/\(id).thumb.png",
        "aspectRatio": "16:9",
        "width": "1920",
        "height": "1080",
        "format": "PNG",
        "fileSize": "123",
        "favorite": "1",
        "pinnedAt": nil,
        "deletedAt": nil,
        "createdAt": encoder.string(from: createdAt),
        "updatedAt": encoder.string(from: createdAt),
        "lastUsedAt": encoder.string(from: lastUsedAt),
        "sortOrder": "\(sortOrder)",
        "itemCreatedAtSortKey": "\(itemCreatedAtSortKey)",
        "itemLastUsedAtSortKey": "\(itemLastUsedAtSortKey)",
        "itemSequence": "\(itemSequence)",
        "hasPrompt": hasPrompt ? "1" : "0",
        "hasReferences": hasReferences ? "1" : "0"
    ]
}

func testLibraryQueryServiceTrimsExtraRowAndBuildsNextCursor() async throws {
    let tiedCreatedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let stub = LibraryQueryExecutorStub(rows: (0..<301).map { index in
        summaryRow(id: "item-\(index)", sortOrder: 7, createdAt: tiedCreatedAt)
    })
    let service = LibraryQueryService(executor: { sql, values in
        if sql.contains("COUNT(*)") {
            return [["totalCount": "301"]]
        }
        stub.sql = sql
        stub.values = values
        return stub.rows
    }, versionSequenceReady: true, itemSequenceReady: true)
    let page = try await service.query(LibraryQuery(pageSize: 300))
    try expect(page.items.count == 300, "a 301-row fetch should expose only 300 items")
    try expect(page.hasMore && page.nextCursor != nil, "a 301-row fetch should return a next cursor")
    try expect(page.totalCount == 301, "page totalCount should come from the filter-equivalent COUNT query")
    guard let nextCursor = page.nextCursor else {
        throw CoreUnitTestError.failure("the next cursor should be typed")
    }
    try expect(
        nextCursor.sortOrder == 7
            && nextCursor.createdAtSortKey == "1700000000000000"
            && nextCursor.itemCreatedAtSortKey == 1_700_000_000_000_000
            && nextCursor.itemSequence == 300
            && nextCursor.id == "item-299",
        "the next cursor should preserve equal sort keys and use persisted item sequence as the tie breaker"
    )
    try expect(stub.sql.contains("LIMIT ?"), "service should execute the parameter-bound builder SQL")
}

func testLibraryQueryServiceExactPageHasNoCursor() async throws {
    let tiedCreatedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let stub = LibraryQueryExecutorStub(rows: (0..<600).map { index in
        summaryRow(id: "item-\(index)", sortOrder: 4, createdAt: tiedCreatedAt)
    })
    let service = LibraryQueryService(executor: { sql, _ in
        if sql.contains("COUNT(*)") {
            return [["totalCount": "600"]]
        }
        return stub.rows
    }, versionSequenceReady: true, itemSequenceReady: true)
    let page = try await service.query(LibraryQuery(pageSize: 600))
    try expect(page.items.count == 600, "a 600-row fetch should expose all 600 items")
    try expect(!page.hasMore && page.nextCursor == nil, "an exact page should not manufacture a cursor")
    try expect(page.totalCount == 600, "exact pages should still report the COUNT query total")
}

func testLibraryQueryServiceGenerationGuardRejectsStaleResultsWithoutCancellation() async throws {
    let stub = LibraryQueryExecutorStub(rows: [summaryRow(id: "item-1", sortOrder: 1, createdAt: Date(timeIntervalSince1970: 1_700_000_000))])
    let service = LibraryQueryService(executor: { sql, _ in
        if sql.contains("COUNT(*)") {
            return [["totalCount": "1"]]
        }
        return stub.rows
    }, versionSequenceReady: true, itemSequenceReady: true)
    let firstGeneration = service.beginGeneration()
    _ = service.beginGeneration()
    do {
        _ = try await service.query(LibraryQuery(pageSize: 1), generation: firstGeneration)
        throw CoreUnitTestError.failure("a result from an older generation must be rejected")
    } catch LibraryQueryError.staleResult {
        // Expected; the executor still ran, so generation is not cancellation.
    }
}

func testLibraryQueryServiceUsesRealSQLiteForKeysetBoundaries() async throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let tiedCreatedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let items: [PromptItem] = (0..<601).map { index in
        var item = sampleItem(title: "query integration \(index)", prompt: "query integration")
        // Deliberately make lexical ID order differ from insertion order so
        // the equal-key boundary proves persisted itemSequence, not id.
        item.id = String(format: "query-integration-%03d", 600 - index)
        item.createdAt = tiedCreatedAt
        item.updatedAt = tiedCreatedAt
        item.lastUsedAt = tiedCreatedAt
        item.sortOrder = 9
        item.favorite = index < 300
        item.modelId = index < 301 ? "query-model-301" : "query-model-other"
        item.folderId = index < 600 ? "query-folder-600" : "query-folder-other"
        item.versions = []
        item.referenceAssets = []
        return item
    }
    try repository.saveItems(items)
    _ = try repository.prepareVersionSequenceMigration()
    _ = try repository.runVersionSequenceMigration(batchSize: 500)
    _ = try repository.prepareItemSequenceMigration()
    _ = try repository.runItemSequenceMigration(batchSize: 500)
    let database = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    let service = LibraryQueryService(executor: { sql, values in
        try database.query(sql, values: values)
    }, versionSequenceReady: true, itemSequenceReady: true)

    let first = try await service.query(LibraryQuery(pageSize: 300))
    try expect(first.items.count == 300 && first.hasMore, "real SQLite should return 300 items plus a 301st lookahead row")
    try expect(first.totalCount == 601, "real SQLite count should report all 601 filtered rows")
    try expect(first.items.first?.id == "query-integration-600" && first.items.last?.id == "query-integration-301", "equal sort keys should use persisted insertion sequence on the first page")

    let second = try await service.query(LibraryQuery(pageSize: 300, cursor: first.nextCursor))
    try expect(second.items.count == 300 && second.hasMore, "the second real SQLite page should also have a lookahead row")
    try expect(second.items.first?.id == "query-integration-300" && second.items.last?.id == "query-integration-001", "keyset cursor should resume after the equal-key boundary")
    try expect(second.totalCount == 601, "every page should report the same filter-equivalent total")

    let third = try await service.query(LibraryQuery(pageSize: 600))
    try expect(third.items.count == 600 && third.hasMore && third.nextCursor != nil, "a 600-item page should use LIMIT 601 and expose a cursor for 601 rows")

    let realBoundaryCases: [(LibraryQuery, Int, Int)] = [
        (.favorite(), 300, 1),
        (.model("query-model-301"), 301, 2),
        (.folder("query-folder-600"), 600, 2),
        (.all(), 601, 3)
    ]
    for (query, expectedCount, expectedPages) in realBoundaryCases {
        var cursor: LibraryQueryCursor?
        var ids: [String] = []
        var pages = 0
        var totalCount = -1
        repeat {
            let page = try await service.query(LibraryQuery(query.collection, pageSize: 300, cursor: cursor, type: query.type, modelId: query.modelId, favoriteOnly: query.favoriteOnly))
            totalCount = page.totalCount
            ids.append(contentsOf: page.items.map(\.id))
            cursor = page.nextCursor
            pages += 1
            if !page.hasMore { break }
        } while pages < 10
        let expectedIDs = items.filter { item in
            switch query.collection {
            case .all: return !item.isDeleted
            case .favorite: return item.favorite && !item.isDeleted
            case .model(let id): return item.modelId == id && !item.isDeleted
            case .folder(let id): return item.folderId == id && !item.isDeleted
            default: return false
            }
        }.map(\.id)
        try expect(totalCount == expectedCount && ids == expectedIDs, "real SQLite \(query.collection) boundary must preserve count/order")
        try expect(Set(ids).count == ids.count && pages == expectedPages, "real SQLite \(query.collection) boundary must have exact pages without duplicates")
    }
}

func testLibraryQueryServiceKeysetBoundariesAcrossAllShapes() async throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    var fixtures: [PromptItem] = []
    fixtures.reserveCapacity(1_202)
    for index in 0..<1_202 {
        var item = sampleItem(title: "shape (index)", prompt: "shape")
        item.id = String(format: "shape-%04d", index)
        item.createdAt = createdAt
        item.updatedAt = createdAt
        item.lastUsedAt = Date(timeIntervalSince1970: 1_900_000_000)
        item.sortOrder = 3
        item.folderId = "shape-folder"
        item.folderName = "Shape"
        item.modelId = "shape-model"
        item.modelName = "Shape Model"
        item.favorite = true
        item.tags = ["shape-tag"]
        item.versions = []
        if index >= 601 { item.deletedAt = Date(timeIntervalSince1970: 1_901_000_000) }
        fixtures.append(item)
    }
    try repository.saveItems(fixtures)
    _ = try repository.prepareVersionSequenceMigration()
    _ = try repository.runVersionSequenceMigration(batchSize: 500)
    _ = try repository.prepareTagRelationMigration()
    _ = try repository.runTagRelationBackfill(batchSize: 500)
    _ = try repository.prepareItemSequenceMigration()
    _ = try repository.runItemSequenceMigration(batchSize: 500)
    let database = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    let service = LibraryQueryService(
        executor: { sql, values in try database.query(sql, values: values) },
        tagRelationsReady: true,
        versionSequenceReady: true,
        itemSequenceReady: true
    )
    let shapes: [LibraryQuery] = [
        .all(), .folder("shape-folder"), .tag("shape-tag"), .type(.image),
        .model("shape-model"), .favorite(), .recent(), .trash(),
        LibraryQuery(.all, type: .image, modelId: "shape-model", favoriteOnly: true)
    ]
    for shape in shapes {
        func pageQuery(size: Int, cursor: LibraryItemCursor?) -> LibraryQuery {
            LibraryQuery(shape.collection, pageSize: size, cursor: cursor, type: shape.type, modelId: shape.modelId, favoriteOnly: shape.favoriteOnly)
        }
        let baseline = try await service.query(pageQuery(size: 2_000, cursor: nil))
        var cursor: LibraryQueryCursor?
        var pages = 0
        var ids: [String] = []
        repeat {
            let page = try await service.query(pageQuery(size: 60, cursor: cursor))
            try expect(page.totalCount == baseline.totalCount, "\(shape.collection) count must remain stable across keyset pages")
            ids.append(contentsOf: page.items.map(\.id))
            cursor = page.nextCursor
            pages += 1
            if !page.hasMore { break }
        } while pages < 20
        try expect(ids == baseline.items.map(\.id), "\(shape.collection) keyset pages must match baseline order without gaps")
        try expect(Set(ids).count == ids.count, "\(shape.collection) keyset pages must not duplicate IDs")
        try expect(pages >= 10 || baseline.totalCount == 0, "\(shape.collection) fixture must exercise at least ten pages")
    }

}

func testLibraryQueryServiceUsesIndependentReadConnection() async throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let item = sampleItem(title: "read connection", prompt: "summary")
    try repository.saveItem(item)
    _ = try repository.prepareVersionSequenceMigration()
    _ = try repository.runVersionSequenceMigration(batchSize: 10)
    _ = try repository.prepareItemSequenceMigration()
    _ = try repository.runItemSequenceMigration(batchSize: 10)

    let readConnection = try SQLiteReadConnection(path: repository.databaseURL.path)
    let service = LibraryQueryService(executor: readConnection, versionSequenceReady: true, itemSequenceReady: true)
    let page = try await service.query(LibraryQuery(pageSize: 300))

    try expect(page.items.map(\.id) == [item.id], "query service should use the independent read-only SQLite connection")
}

func testLibraryQueryServiceSQLiteWitnessUsesOneReadSnapshot() async throws {
    try await runLibraryQueryServiceSQLiteSnapshotMutation(.insert)
}

func testLibraryQueryServiceSQLiteSnapshotSurvivesDeleteCommit() async throws {
    try await runLibraryQueryServiceSQLiteSnapshotMutation(.delete)
}

func testLibraryQueryServiceSQLiteSnapshotSurvivesFavoriteCommit() async throws {
    try await runLibraryQueryServiceSQLiteSnapshotMutation(.favorite)
}

func testLibraryQueryServiceSQLiteSnapshotSurvivesFolderMoveCommit() async throws {
    try await runLibraryQueryServiceSQLiteSnapshotMutation(.folderMove)
}

func testLibraryQueryServiceSQLiteSnapshotSurvivesTrashCommit() async throws {
    try await runLibraryQueryServiceSQLiteSnapshotMutation(.trash)
}

func testLibraryQueryServiceSQLiteSnapshotSurvivesRestoreCommit() async throws {
    try await runLibraryQueryServiceSQLiteSnapshotMutation(.restore)
}

private func runLibraryQueryServiceSQLiteSnapshotMutation(
    _ mutation: AtomicReadWriterMutation
) async throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    var items = (0..<301).map { index -> PromptItem in
        var item = sampleItem(title: "atomic insert \(index)", prompt: "atomic insert")
        item.id = String(format: "atomic-insert-%03d", index)
        item.sortOrder = index
        item.versions = []
        return item
    }
    mutation.configureInitialItems(&items)
    try repository.saveItems(items)
    _ = try repository.prepareVersionSequenceMigration()
    _ = try repository.runVersionSequenceMigration(batchSize: 500)
    _ = try repository.prepareItemSequenceMigration()
    _ = try repository.runItemSequenceMigration(batchSize: 500)

    let writer = try PromptRepository(libraryURL: repository.libraryURL)
    let target = items[0]
    let writerFinished = DispatchSemaphore(value: 0)
    let writerState = AtomicReadWriterState()
    let readConnection = try SQLiteReadConnection(
        path: repository.databaseURL.path,
        queryPageAndCountHook: {
            guard writerState.claimWriter() else { return }

            do {
                try mutation.apply(to: writer, target: target)
            } catch {
                writerState.record(error: error)
            }
            writerFinished.signal()
        }
    )
    let service = LibraryQueryService(executor: readConnection, versionSequenceReady: true, itemSequenceReady: true)
    let task = Task {
        try await service.query(mutation.query)
    }

    guard waitForAtomicWriterBarrier(writerFinished) else {
        task.cancel()
        _ = try? await task.value
        throw CoreUnitTestError.failure("the read page did not reach the WAL writer barrier")
    }
    let page = try await task.value
    if let capturedWriterError = writerState.writerError {
        throw CoreUnitTestError.failure("WAL \(mutation) writer should commit during the read snapshot: \(capturedWriterError)")
    }
    try expect(
        page.totalCount == mutation.expectedCount,
        "page and count must both observe the pre-\(mutation) snapshot"
    )
    if mutation.expectsTargetInPage {
        try expect(
            page.items.contains(where: { $0.id == target.id }),
            "pre-\(mutation) page must retain the target row"
        )
    } else if mutation == .insert {
        try expect(
            !page.items.contains(where: { $0.id == "atomic-inserted" }),
            "pre-insert page must not include the committed insert"
        )
    } else {
        try expect(page.items.isEmpty, "pre-favorite page must remain empty")
    }
}

private func waitForAtomicWriterBarrier(_ semaphore: DispatchSemaphore) -> Bool {
    semaphore.wait(timeout: .now() + .seconds(5)) == .success
}

func testLibraryQuerySessionCancelsPreviousRequest() async throws {
    let firstStarted = DispatchSemaphore(value: 0)
    let service = LibraryQueryService(executor: { sql, _ in
        if sql.contains("COUNT(*)") {
            return [["totalCount": "0"]]
        }
        firstStarted.signal()
        while !Task.isCancelled {
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CancellationError()
    }, versionSequenceReady: true, itemSequenceReady: true)
    let session = LibraryQuerySession(service: service)
    let first = Task { try await session.query(LibraryQuery(.all)) }
    try waitForQuerySessionStart(firstStarted)
    let second = Task { try await session.query(LibraryQuery(.folder("folder"))) }

    do {
        _ = try await first.value
        throw CoreUnitTestError.failure("a newer session request must cancel the prior task")
    } catch is CancellationError {
        // Expected.
    }
    second.cancel()
    await session.cancel()
}

func testLibraryQueryServicePreservesRawFractionalCursorKeys() async throws {
    var rows = (0..<301).map { index in
        summaryRow(id: "fractional-\(index)", sortOrder: 7, createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    }
    rows[299]["createdAt"] = "2026-08-17T15:31:20.987654Z"
    rows[299]["lastUsedAt"] = "2026-08-17T15:31:21.123456Z"
    rows[299]["itemCreatedAtSortKey"] = "1786980680987654"
    rows[299]["itemLastUsedAtSortKey"] = "1786980681123456"
    let capturedRows = rows
    let service = LibraryQueryService(executor: { sql, _ in
        sql.contains("COUNT(*)") ? [["totalCount": "301"]] : capturedRows
    }, versionSequenceReady: true, itemSequenceReady: true)

    let defaultPage = try await service.query(LibraryQuery(pageSize: 300))
    try expect(
        defaultPage.nextCursor?.createdAtSortKey == "1786980680987654"
            && defaultPage.nextCursor?.itemCreatedAtSortKey == 1_786_980_680_987_654,
        "default cursor must use persisted numeric timestamp metadata"
    )

    let recentPage = try await service.query(LibraryQuery.recent(pageSize: 300))
    try expect(
        recentPage.nextCursor?.itemLastUsedAtSortKey == 1_786_980_681_123_456,
        "recent cursor must use persisted numeric last-used metadata"
    )
}

func testLibraryQueryCursorRequiresRestartAfterDeleteInsertAndReorder() async throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let tiedCreatedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let items = (0..<301).map { index -> PromptItem in
        var item = sampleItem(title: "mutation \(index)", prompt: "mutation")
        item.id = String(format: "mutation-%03d", index)
        item.sortOrder = index / 3
        item.createdAt = tiedCreatedAt
        item.updatedAt = tiedCreatedAt
        item.versions = []
        return item
    }
    try repository.saveItems(items)
    _ = try repository.prepareVersionSequenceMigration()
    _ = try repository.runVersionSequenceMigration(batchSize: 500)
    _ = try repository.prepareItemSequenceMigration()
    _ = try repository.runItemSequenceMigration(batchSize: 500)
    let readConnection = try SQLiteReadConnection(path: repository.databaseURL.path)
    let service = LibraryQueryService(executor: readConnection, versionSequenceReady: true, itemSequenceReady: true)
    let database = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)

    let revisionOne = try await service.query(LibraryQuery(.all, pageSize: 300, dataRevision: 1))
    guard let deleteCursor = revisionOne.nextCursor else {
        throw CoreUnitTestError.failure("301 rows should produce a boundary cursor")
    }
    try database.run("DELETE FROM prompt_items WHERE id = ?;", values: [.text("mutation-299")])
    try expectCursorRejectedAfterMutation(deleteCursor, revision: 2)

    var inserted = sampleItem(title: "inserted", prompt: "inserted")
    inserted.id = "mutation-299a"
    inserted.sortOrder = 99
    inserted.createdAt = tiedCreatedAt
    inserted.updatedAt = tiedCreatedAt
    inserted.versions = []
    try repository.saveItem(inserted)
    try expectCursorRejectedAfterMutation(deleteCursor, revision: 3)

    try database.run("UPDATE prompt_items SET sortOrder = -1 WHERE id = ?;", values: [.text("mutation-300")])
    try expectCursorRejectedAfterMutation(deleteCursor, revision: 4)
}

func testLibraryQueryServiceUsesOneReadSnapshotForPageAndCount() async throws {
    let executor = LibraryQuerySnapshotExecutorStub(rows: [
        summaryRow(id: "snapshot", sortOrder: 0, createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    ])
    let service = LibraryQueryService(executor: executor, versionSequenceReady: true, itemSequenceReady: true)
    let page = try await service.query(LibraryQuery(.all))
    try expect(page.items.map(\.id) == ["snapshot"] && page.totalCount == 1, "snapshot batch should return page rows and count")
    try expect(executor.snapshotQueryCount == 1, "page and count must use one snapshot operation")
    try expect(executor.standaloneQueryCount == 0, "service must not issue separate page and count reads")
}

func testLibraryQueryServiceAutomaticallyRejectsCursorAfterRevisionAdvance() async throws {
    let rows = (0..<301).map { index in
        summaryRow(id: "revision-\(index)", sortOrder: index, createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    }
    let revision = LibraryDataRevision()
    let executor = LibraryQuerySnapshotExecutorStub(rows: rows)
    let service = LibraryQueryService(executor: executor, dataRevision: revision, versionSequenceReady: true, itemSequenceReady: true)
    let first = try await service.query(LibraryQuery(.all, pageSize: 300))
    guard let cursor = first.nextCursor else {
        throw CoreUnitTestError.failure("revision test requires a next cursor")
    }

    _ = revision.advance()
    do {
        _ = try await service.query(LibraryQuery(.all, pageSize: 300, cursor: cursor))
        throw CoreUnitTestError.failure("service must reject a cursor after the shared data revision advances")
    } catch LibraryQueryError.cursorQueryFingerprintMismatch {
        // Expected: callers restart from page one after a data-changing write.
    }
}

func testLibraryQueryServiceRejectsSnapshotWhenRevisionChangesDuringRead() async throws {
    let revision = LibraryDataRevision()
    let executor = LibraryQuerySnapshotExecutorStub(rows: [
        summaryRow(id: "stale-snapshot", sortOrder: 0, createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    ])
    executor.onSnapshot = { _ = revision.advance() }
    let service = LibraryQueryService(executor: executor, dataRevision: revision, versionSequenceReady: true, itemSequenceReady: true)

    do {
        _ = try await service.query(LibraryQuery(.all))
        throw CoreUnitTestError.failure("a revision change during the read snapshot must reject the result")
    } catch LibraryQueryError.staleDataRevision {
        // Expected.
    }
}

private func expectCursorRejectedAfterMutation(
    _ cursor: LibraryItemCursor,
    revision: UInt64
) throws {
    do {
        _ = try LibraryQuerySQLBuilder.build(
            LibraryQuery(.all, pageSize: 300, cursor: cursor, dataRevision: revision),
            capabilities: .itemSequence
        )
        throw CoreUnitTestError.failure("delete, insert, or reorder must invalidate the previous cursor")
    } catch LibraryQueryError.cursorQueryFingerprintMismatch {
        // Expected: restart at the first page with the new data revision.
    }
}

private func waitForQuerySessionStart(_ semaphore: DispatchSemaphore) throws {
    guard semaphore.wait(timeout: .now() + .seconds(2)) == .success else {
        throw CoreUnitTestError.failure("query session did not start within two seconds")
    }
}
