import Foundation
import PromptStudioCore

func testLibraryQuerySQLBuilderRefusesUnreadyVersionSummary() throws {
    do {
        _ = try LibraryQuerySQLBuilder.build(LibraryQuery(pageSize: 1))
        throw CoreUnitTestError.failure("unready Summary SQL must fail closed")
    } catch LibraryQuerySQLBuilderError.versionSequenceNotReady {
        // Expected: no lexical/rowid fallback may be emitted.
    }
}

private func readyBuild(_ query: LibraryQuery) throws -> LibraryQuerySQL {
    try LibraryQuerySQLBuilder.build(query, capabilities: .itemSequence)
}

private func readyBuildCount(_ query: LibraryQuery) throws -> LibraryQueryCountSQL {
    try LibraryQuerySQLBuilder.buildCount(query, capabilities: .itemSequence)
}

func testLibraryQuerySQLBuilderUsesKeysetPaginationAndBoundValues() throws {
    let first = try readyBuild(LibraryQuery(pageSize: 300))
    try expect(first.limit == 301, "the first page should request page size plus one row")
    try expect(first.sql.contains("ORDER BY p.sortOrder ASC, p.itemCreatedAtSortKey DESC, p.itemSequence ASC"), "default queries should use persisted item sequence sort order")
    try expect(first.sql.contains("LIMIT ?"), "page limits should be bound parameters")
    try expect(first.sql.contains("SELECT ps_trim_whitespace(v.prompt)"), "hasPrompt should inspect only the persisted latest version")
    try expect(first.sql.contains("MAX(v2.versionCreatedAtSortKey)"), "hasPrompt should use persisted Date sort keys")
    try expect(first.sql.contains("LIMIT 1"), "hasPrompt should select one legacy latest version")
    try expect(first.sql.contains("ps_reference_asset_count"), "hasReferences should use the legacy ReferenceAsset decode scalar")
    try expect(!first.sql.contains("json_array_length"), "hasReferences must not use JSON array cardinality as a decode proxy")
    try expect(first.values.contains(where: { if case .int(301) = $0 { return true }; return false }), "the page limit should be bound, not interpolated")

    let recent = try readyBuild(LibraryQuery.recent(pageSize: 600))
    try expect(recent.limit == 601, "a 600-item page should request 601 rows")
    try expect(recent.sql.contains("ORDER BY p.itemLastUsedAtSortKey DESC, p.itemCreatedAtSortKey DESC, p.itemSequence ASC"), "recent queries should sort by persisted last use")

    let dangerousID = "folder' OR 1=1 --"
    let folder = try readyBuild(LibraryQuery.folder(dangerousID, pageSize: 10))
    try expect(folder.sql.contains("p.folderId = ?"), "folder filters should use placeholders")
    try expect(!folder.sql.contains(dangerousID), "filter values must never be interpolated into SQL")
    try expect(folder.values.contains(where: { if case .text(dangerousID) = $0 { return true }; return false }), "folder IDs should be bound as SQL values")
}

func testLibraryQuerySQLBuilderCursorFingerprintMismatchIsRejected() throws {
    let first = try readyBuild(LibraryQuery(pageSize: 2))
    let cursor = LibraryQueryCursor(
        queryFingerprint: first.queryFingerprint,
        sortOrder: 2,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        id: "item-2",
        itemCreatedAtSortKey: 1_700_000_000_000_000,
        itemLastUsedAtSortKey: 0,
        itemSequence: 2
    )
    do {
        _ = try readyBuild(LibraryQuery.folder("different", pageSize: 2, cursor: cursor))
        throw CoreUnitTestError.failure("a cursor from another query must be rejected")
    } catch LibraryQueryError.cursorQueryFingerprintMismatch {
        // Expected.
    }
}

func testLibraryQuerySQLBuilderKeysetKeepsRowsWithEqualSortKeys() throws {
    let first = try readyBuild(LibraryQuery(pageSize: 3))
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    let cursor = LibraryQueryCursor(
        queryFingerprint: first.queryFingerprint,
        sortOrder: 7,
        createdAt: createdAt,
        id: "item-7",
        itemCreatedAtSortKey: 1_700_000_000_000_000,
        itemLastUsedAtSortKey: 0,
        itemSequence: 7
    )
    let second = try readyBuild(
        LibraryQuery(pageSize: 3, cursor: cursor)
    )
    try expect(second.sql.contains("p.sortOrder > ? OR (p.sortOrder = ? AND p.itemCreatedAtSortKey < ?)"), "keyset pagination should advance after sortOrder and persisted createdAt ties")
    try expect(second.sql.contains("p.itemCreatedAtSortKey = ? AND p.itemSequence > ?"), "keyset pagination should use the persisted sequence as the final tie breaker")
    try expect(second.values.count == 7, "a default keyset page should bind three sort keys plus its limit")
}

func testLibraryQuerySQLBuilderFirstPageHasNoPseudoCursorPredicate() throws {
    let built = try readyBuild(LibraryQuery(pageSize: 3))
    try expect(!built.sql.contains("p.sortOrder > ?"), "the first page must not add a synthetic keyset cursor")
    try expect(built.values.count == 1, "the first page should only bind its limit")
}

func testLibraryQuerySQLBuilderRejectsCursorWithoutOrderingKey() throws {
    let recent = try readyBuild(LibraryQuery.recent())
    let malformedRecent = LibraryQueryCursor(
        queryFingerprint: recent.queryFingerprint,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        id: "item"
    )
    do {
        _ = try readyBuild(LibraryQuery.recent(cursor: malformedRecent))
        throw CoreUnitTestError.failure("recent cursors must carry lastUsedAt")
    } catch LibraryQueryError.invalidCursor {
        // Expected.
    }

    let all = try readyBuild(LibraryQuery())
    let malformedAll = LibraryQueryCursor(
        queryFingerprint: all.queryFingerprint,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        id: "item"
    )
    do {
        _ = try readyBuild(LibraryQuery(cursor: malformedAll))
        throw CoreUnitTestError.failure("default cursors must carry sortOrder")
    } catch LibraryQueryError.invalidCursor {
        // Expected.
    }
}

func testLibraryQuerySQLBuilderCountUsesSameFilterWithoutPagination() throws {
    let query = LibraryQuery.folder("folder-a", pageSize: 300, type: .image, favoriteOnly: true)
    let page = try readyBuild(query)
    let count = try readyBuildCount(query)
    try expect(count.sql.hasPrefix("SELECT COUNT(*) AS totalCount FROM prompt_items p"), "count SQL should aggregate prompt_items")
    try expect(!count.sql.contains("ORDER BY") && !count.sql.contains("LIMIT"), "count SQL should not carry page ordering or pagination")
    try expect(count.queryFingerprint == page.queryFingerprint, "count SQL should share the page query fingerprint")
    try expect(count.values.count == page.values.count - 1, "count SQL should omit only the page LIMIT binding")
    try expect(count.sql.contains("p.folderId = ?") && count.sql.contains("p.type = ?") && count.sql.contains("p.favorite = 1"), "count SQL should preserve all composed filters")
}

func testLibraryQueryRevisionInvalidatesExistingCursor() throws {
    let firstQuery = LibraryQuery(.all, dataRevision: 41)
    let firstSQL = try readyBuild(firstQuery)
    let cursor = LibraryItemCursor(
        queryFingerprint: firstSQL.queryFingerprint,
        sortOrder: 10,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        id: "item-10",
        itemCreatedAtSortKey: 1_700_000_000_000_000,
        itemLastUsedAtSortKey: 0,
        itemSequence: 10
    )
    do {
        _ = try readyBuild(LibraryQuery(.all, cursor: cursor, dataRevision: 42))
        throw CoreUnitTestError.failure("a data revision change must invalidate an old keyset cursor")
    } catch LibraryQueryError.cursorQueryFingerprintMismatch {
        // Expected.
    }
}

func testLibraryQueryPhase2A1IndexesAreExplicitAndExplainable() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    var item = sampleItem(title: "index fixture", prompt: "index fixture")
    item.folderId = "index-folder"
    item.modelId = "index-model"
    item.favorite = true
    item.lastUsedAt = Date(timeIntervalSince1970: 1_700_000_100)
    try repository.saveItem(item)
    _ = try repository.prepareVersionSequenceMigration()
    _ = try repository.runVersionSequenceMigration(batchSize: 10)
    _ = try repository.prepareItemSequenceMigration()
    _ = try repository.runItemSequenceMigration(batchSize: 10)
    let database = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    try LibraryQuerySQLBuilder.installPhase2A4_1ItemIndexes(using: { statement in
        try database.execute(statement)
    })
    let count = try readyBuildCount(LibraryQuery.folder("index-folder"))
    let countRows = try database.query(count.sql, values: count.values)
    try expect(countRows.first?["totalCount"] ?? nil == "1", "the COUNT query should execute against the same SQLite schema")

    let cases: [(LibraryQuery, String)] = [
        (LibraryQuery(), "idx_phase2a4_1_prompt_items_all"),
        (LibraryQuery.folder("index-folder"), "idx_phase2a4_1_prompt_items_folder"),
        (LibraryQuery.type(.image), "idx_phase2a4_1_prompt_items_type"),
        (LibraryQuery.model("index-model"), "idx_phase2a4_1_prompt_items_model"),
        (LibraryQuery.favorite, "idx_phase2a4_1_prompt_items_favorite"),
        (LibraryQuery.recent, "idx_phase2a4_1_prompt_items_recent"),
        (LibraryQuery.trash, "idx_phase2a4_1_prompt_items_trash")
    ]
    for (query, indexName) in cases {
        let built = try readyBuild(query)
        let plan = try database.query("EXPLAIN QUERY PLAN \(built.sql)", values: built.values)
        let details = plan.compactMap { $0["detail"] ?? nil }.joined(separator: "\n")
        try expect(details.contains(indexName), "\(query.collection) should be explainable through \(indexName): \(details)")
    }

    let all = try readyBuild(LibraryQuery())
    let allPlan = try database.query("EXPLAIN QUERY PLAN \(all.sql)", values: all.values)
    let allDetails = allPlan.compactMap { $0["detail"] ?? nil }.joined(separator: "\n")
    try expect(allDetails.contains("idx_phase2a4_prompt_versions_latest"), "ready hasPrompt EXISTS should use the persisted latest-version index")
}
