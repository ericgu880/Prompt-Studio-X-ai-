import CryptoKit
import Foundation
import PromptStudioCore

private let phase2A2RelationIndexName = "idx_phase2a2_prompt_item_tags_tag_order"

private func legacyPromptItemsDrivenTagSQL(from relationDrivenSQL: String) throws -> String {
    let relationPrefix = """
    FROM prompt_item_tags pit
    JOIN prompt_items p ON p.id=pit.promptItemId
    WHERE pit.tagKey=? AND pit.isFirstOccurrence=1 AND pit.isDeleted=0 AND p.deletedAt IS NULL
    """
    let legacyPrefix = """
    FROM prompt_items p
    WHERE EXISTS (SELECT 1 FROM prompt_item_tags pit WHERE pit.tagKey=? AND pit.isFirstOccurrence=1 AND pit.isDeleted=0 AND pit.promptItemId=p.id) AND p.deletedAt IS NULL
    """
    guard relationDrivenSQL.contains(relationPrefix) else {
        throw CoreUnitTestError.failure("Tag page must be relation-driven before legacy parity can be checked")
    }
    return relationDrivenSQL.replacingOccurrences(of: relationPrefix, with: legacyPrefix)
}

private func tagPageIDHash(_ ids: [String]) -> String {
    SHA256.hash(data: Data(ids.joined(separator: "\u{1f}").utf8))
        .map { String(format: "%02x", $0) }
        .joined()
}

private func tagRelationCount(
    _ database: SQLiteDatabase,
    sql: String,
    values: [SQLiteValue]
) throws -> Int {
    let row = try database.query(sql, values: values).first ?? [:]
    guard let text = row["count"] ?? nil, let count = Int(text) else {
        throw CoreUnitTestError.failure("Tag relation count is missing")
    }
    return count
}

private func installPhase2A2TagRelationSchema(_ database: SQLiteDatabase) throws {
    try database.execute(
        """
        CREATE TABLE IF NOT EXISTS prompt_item_tags (
            promptItemId TEXT NOT NULL,
            ordinal INTEGER NOT NULL,
            tagName TEXT COLLATE BINARY NOT NULL,
            tagKey TEXT COLLATE BINARY NOT NULL,
            isFirstOccurrence INTEGER NOT NULL,
            isDeleted INTEGER NOT NULL,
            sortOrder INTEGER NOT NULL,
            createdAt TEXT NOT NULL,
            lastUsedAt TEXT NOT NULL,
            PRIMARY KEY(promptItemId, ordinal)
        ) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS \(phase2A2RelationIndexName)
        ON prompt_item_tags (
            tagKey COLLATE BINARY,
            isFirstOccurrence,
            isDeleted,
            sortOrder ASC,
            createdAt DESC,
            promptItemId ASC
        );
        CREATE INDEX IF NOT EXISTS idx_phase2a1_prompt_versions_prompt_item_id
        ON prompt_versions(promptItemId);
        """
    )
}

private func addPhase2A2TagRows(_ database: SQLiteDatabase, item: PromptItem, isDeleted: Bool = false) throws {
    let formatter = ISO8601DateFormatter()
    for (ordinal, tag) in item.tags.enumerated() {
        try database.run(
            """
            INSERT INTO prompt_item_tags
                (promptItemId, ordinal, tagName, tagKey, isFirstOccurrence, isDeleted, sortOrder, createdAt, lastUsedAt)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            values: [
                .text(item.id),
                .int(Int64(ordinal)),
                .text(tag),
                .text(TagIdentity.relationKey(for: tag)),
                .int(item.tags[..<ordinal].contains(tag) ? 0 : 1),
                .int(isDeleted ? 1 : 0),
                .int(Int64(item.sortOrder)),
                .text(formatter.string(from: item.createdAt)),
                .text(formatter.string(from: item.lastUsedAt))
            ]
        )
    }
}

private func makePhase2A2TagFixture(count: Int) throws -> (URL, [PromptItem]) {
    let libraryURL = try temporaryLibraryURL()
    let repository = try PromptRepository(libraryURL: libraryURL)
    var items: [PromptItem] = []
    items.reserveCapacity(count)
    for index in 0..<count {
        var item = sampleItem(
            title: "Tag fixture \(index)",
            modelId: index.isMultiple(of: 2) ? "model-a" : "model-b",
            tags: index == 0
                ? ["Foo", "foo", "Foo", "", "x/y? &", "é", "e\u{301}"]
                : (index.isMultiple(of: 2) ? ["Foo", "foo"] : ["Foo"]),
            prompt: "tag fixture \(index)"
        )
        item.id = String(format: "tag-item-%04d", index)
        item.versions = item.versions.map { version in
            var updated = version
            updated.promptItemId = item.id
            return updated
        }
        item.sortOrder = index
        item.createdAt = Date(timeIntervalSince1970: 1_700_000_000 - Double(index))
        item.updatedAt = item.createdAt
        item.lastUsedAt = item.createdAt
        item.favorite = index.isMultiple(of: 5)
        items.append(item)
    }
    try repository.saveItems(items)
    let database = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    try installPhase2A2TagRelationSchema(database)
    for item in items {
        try addPhase2A2TagRows(database, item: item)
    }
    _ = try repository.prepareVersionSequenceMigration()
    _ = try repository.runVersionSequenceMigration(batchSize: 500)
    _ = try repository.prepareItemSequenceMigration()
    _ = try repository.runItemSequenceMigration(batchSize: 500)
    return (libraryURL, items)
}

func testLibraryQueryTagSQLGateClosedByDefaultAndOpenWithExplicitCapability() throws {
    do {
        _ = try LibraryQuerySQLBuilder.build(LibraryQuery.tag("Foo"))
        throw CoreUnitTestError.failure("tag SQL must remain disabled without an explicit relation capability")
    } catch LibraryQuerySQLBuilderError.versionSequenceNotReady {
        // Expected: every Summary, including tag Summary, requires persisted
        // version ordering before SQL can be emitted.
    }

    let query = LibraryQuery.tag("Foo", pageSize: 300)
    let built = try LibraryQuerySQLBuilder.build(
        query,
        capabilities: LibraryQueryCapabilities(tagRelationsReady: true, versionSequenceReady: true, itemSequenceReady: true)
    )
    try expect(
        built.sql.contains("FROM prompt_item_tags pit\nJOIN prompt_items p ON p.id=pit.promptItemId"),
        "open tag SQL should drive from indexed relation membership"
    )
    try expect(
        built.sql.contains("WHERE pit.tagKey=? AND pit.isFirstOccurrence=1 AND pit.isDeleted=0 AND p.deletedAt IS NULL"),
        "tag SQL must use exact BINARY relation membership predicates"
    )
    try expect(!built.sql.contains("EXISTS (SELECT 1 FROM prompt_item_tags"), "tag page must not scan prompt_items with correlated membership lookups")
    try expect(
        built.sql.contains("ORDER BY p.sortOrder ASC, p.itemCreatedAtSortKey DESC, p.itemSequence ASC"),
        "tag SQL must order by persisted prompt-item sort keys"
    )
    try expect(built.values.contains { if case .text(let value) = $0 { return value == "Foo" }; return false }, "tag names must be bound values")
    try expect(!built.sql.contains("Foo"), "tag names must never be interpolated into SQL")
}

func testLibraryQueryTagServiceGateClosedByDefault() async throws {
    let service = LibraryQueryService(executor: { _, _ in
        throw CoreUnitTestError.failure("a closed tag gate must fail before executing SQL")
    })
    do {
        _ = try await service.query(LibraryQuery.tag("Foo"))
        throw CoreUnitTestError.failure("tag service should preserve unsupportedTag until explicitly enabled")
    } catch LibraryQuerySQLBuilderError.versionSequenceNotReady {
        // Expected: the service rejects before touching its executor.
    }
}

func testLibraryQueryTagSQLPreservesExactNamesAndRefinements() throws {
    for name in ["Foo", "foo", "", "特/殊 & ?"] {
        let built = try LibraryQuerySQLBuilder.build(
            LibraryQuery(
                .tag(name),
                pageSize: 10,
                type: .image,
                modelId: "model' OR 1=1 --",
                favoriteOnly: true
            ),
            capabilities: LibraryQueryCapabilities(tagRelationsReady: true, versionSequenceReady: true, itemSequenceReady: true)
        )
        try expect(built.values.contains { if case .text(let value) = $0 { return value == name }; return false }, "exact tag name should be bound: \(name)")
        try expect(built.sql.contains("p.deletedAt IS NULL"), "tag SQL should defensively exclude deleted prompt rows")
        try expect(built.sql.contains("p.type = ?") && built.sql.contains("p.modelId = ?") && built.sql.contains("p.favorite = 1"), "tag SQL should preserve refinements")
        try expect(!built.sql.contains("model' OR 1=1 --"), "refinement values must not be interpolated")
    }
}

func testLibraryQueryTagSQLUsesRelationKeysetCursorAndMatchingCount() throws {
    let query = LibraryQuery.tag("Foo", pageSize: 300)
    let first = try LibraryQuerySQLBuilder.build(
        query,
        capabilities: LibraryQueryCapabilities(tagRelationsReady: true, versionSequenceReady: true, itemSequenceReady: true)
    )
    let cursor = LibraryQueryCursor(
        queryFingerprint: first.queryFingerprint,
        sortOrder: 7,
        createdAtSortKey: "2026-01-01T00:00:00Z",
        id: "tag-item-0007",
        itemCreatedAtSortKey: 1_767_225_600_000_000,
        itemLastUsedAtSortKey: 0,
        itemSequence: 7
    )
    let next = try LibraryQuerySQLBuilder.build(
        LibraryQuery.tag("Foo", pageSize: 300, cursor: cursor),
        capabilities: LibraryQueryCapabilities(tagRelationsReady: true, versionSequenceReady: true, itemSequenceReady: true)
    )
    try expect(next.sql.contains("p.sortOrder > ? OR (p.sortOrder = ? AND p.itemCreatedAtSortKey < ?"), "tag cursor should use persisted prompt-item sortOrder/createdAt")
    try expect(next.sql.contains("p.itemCreatedAtSortKey = ? AND p.itemSequence > ?"), "tag cursor should use persisted item sequence tie breaker")

    let count = try LibraryQuerySQLBuilder.buildCount(
        query,
        capabilities: LibraryQueryCapabilities(tagRelationsReady: true, versionSequenceReady: true, itemSequenceReady: true)
    )
    try expect(count.sql.contains("FROM prompt_item_tags pit") && count.sql.contains("JOIN prompt_items p ON p.id=pit.promptItemId"), "tag count should be driven by indexed relation membership")
    try expect(!count.sql.contains("EXISTS (SELECT 1 FROM prompt_item_tags pit"), "tag count must not scan prompt_items with a correlated membership lookup")
    try expect(!count.sql.contains("ORDER BY") && !count.sql.contains("LIMIT"), "tag count should omit cursor/order/limit")
    try expect(count.values.count == 1, "tag count should bind only the exact tag name")
}

func testLibraryQueryTagServiceReturnsExactNameOnceAndSupportsKeysetPages() async throws {
    let (libraryURL, items) = try makePhase2A2TagFixture(count: 905)
    defer { try? FileManager.default.removeItem(at: libraryURL) }
    let databaseURL = libraryURL.appendingPathComponent("database/promptstudio.sqlite")
    let readConnection = try SQLiteReadConnection(path: databaseURL.path)
    let revision = LibraryDataRevision()
    let service = LibraryQueryService(
        executor: readConnection,
        dataRevision: revision,
        capabilities: LibraryQueryCapabilities(tagRelationsReady: true, versionSequenceReady: true, itemSequenceReady: true)
    )

    let database = try SQLiteDatabase(path: databaseURL.path, mode: .existingReadWrite)
    var parityCursor: LibraryQueryCursor?
    var relationCombinedIDs: [String] = []
    var legacyCombinedIDs: [String] = []
    for pageIndex in 0..<3 {
        let query = LibraryQuery.tag("Foo", pageSize: 300, cursor: parityCursor)
        let built = try LibraryQuerySQLBuilder.build(
            query,
            capabilities: LibraryQueryCapabilities(tagRelationsReady: true, versionSequenceReady: true, itemSequenceReady: true)
        )
        let relationRows = try database.query(built.sql, values: built.values)
        let legacyRows = try database.query(legacyPromptItemsDrivenTagSQL(from: built.sql), values: built.values)
        try expect(relationRows == legacyRows, "Tag page \(pageIndex + 1) must preserve every Summary projection field and row order")
        let relationIDs = relationRows.prefix(300).compactMap { $0["id"] ?? nil }
        let legacyIDs = legacyRows.prefix(300).compactMap { $0["id"] ?? nil }
        try expect(tagPageIDHash(relationIDs) == tagPageIDHash(legacyIDs), "Tag page \(pageIndex + 1) ID hash must match the prompt_items-driven golden")
        relationCombinedIDs.append(contentsOf: relationIDs)
        legacyCombinedIDs.append(contentsOf: legacyIDs)
        let servicePage = try await service.query(query)
        try expect(servicePage.items.map(\.id) == relationIDs, "Tag page \(pageIndex + 1) decode must preserve SQL order")
        parityCursor = servicePage.nextCursor
    }
    try expect(relationCombinedIDs.count == 900, "three 300-item Tag pages must observe 900 rows")
    try expect(Set(relationCombinedIDs).count == relationCombinedIDs.count, "three-page Tag keyset must not duplicate rows")
    try expect(tagPageIDHash(relationCombinedIDs) == tagPageIDHash(legacyCombinedIDs), "combined three-page Tag ID hash must match the prompt_items-driven golden")

    let first = try await service.query(LibraryQuery.tag("Foo", pageSize: 300))
    try expect(first.items.count == 300 && first.hasMore, "Foo should return one card per first occurrence and a keyset cursor")
    try expect(Set(first.items.map(\.id)).count == first.items.count, "duplicate relation occurrences must not duplicate cards")
    try expect(first.items.allSatisfy { $0.title.hasPrefix("Tag fixture") }, "tag results should select prompt item summary fields")

    var collected = first.items.map(\.id)
    var cursor = first.nextCursor
    while let nextCursor = cursor {
        let page = try await service.query(LibraryQuery.tag("Foo", pageSize: 300, cursor: nextCursor))
        collected.append(contentsOf: page.items.map(\.id))
        cursor = page.nextCursor
    }
    try expect(Set(collected).count == collected.count, "300/301 tag keyset traversal must not duplicate or leak rows")
    try expect(collected.count == first.totalCount, "tag page traversal should cover the filter-equivalent count")

    var tenPageIDs: [String] = []
    cursor = nil
    var pageCount = 0
    repeat {
        let page = try await service.query(LibraryQuery.tag("Foo", pageSize: 30, cursor: cursor))
        tenPageIDs.append(contentsOf: page.items.map(\.id))
        cursor = page.nextCursor
        pageCount += 1
        if pageCount > 40 { throw CoreUnitTestError.failure("tag keyset pagination did not terminate") }
    } while cursor != nil
    try expect(pageCount == 31 && tenPageIDs == collected, "multi-page tag keyset traversal should preserve complete order")

    let lowercase = try await service.query(LibraryQuery.tag("foo", pageSize: 300))
    try expect(lowercase.items.count != first.items.count || lowercase.items.map(\.id) != first.items.map(\.id), "BINARY tag matching must distinguish Foo from foo")
    let empty = try await service.query(LibraryQuery.tag("", pageSize: 20))
    try expect(empty.items.map(\.id) == [items[0].id], "empty tag names should remain exact and match only the empty relation")
    let special = try await service.query(LibraryQuery.tag("x/y? &", pageSize: 20))
    try expect(special.items.map(\.id) == [items[0].id], "special tag names should be matched exactly")
    let composed = try await service.query(LibraryQuery.tag("é", pageSize: 20))
    let decomposed = try await service.query(LibraryQuery.tag("e\u{301}", pageSize: 20))
    try expect(
        composed.items.map(\.id) == decomposed.items.map(\.id) && composed.items.map(\.id) == [items[0].id],
        "SQL tag identity must preserve Swift String canonical-equivalence semantics"
    )
}

func testLibraryQueryTagServiceAppliesTypeModelFavoriteAndRevisionCursorGuard() async throws {
    let (libraryURL, _) = try makePhase2A2TagFixture(count: 301)
    defer { try? FileManager.default.removeItem(at: libraryURL) }
    let databaseURL = libraryURL.appendingPathComponent("database/promptstudio.sqlite")
    let readConnection = try SQLiteReadConnection(path: databaseURL.path)
    let revision = LibraryDataRevision()
    let service = LibraryQueryService(
        executor: readConnection,
        dataRevision: revision,
        capabilities: LibraryQueryCapabilities(tagRelationsReady: true, versionSequenceReady: true, itemSequenceReady: true)
    )

    let refined = LibraryQuery(
        .tag("Foo"),
        pageSize: 10,
        type: .image,
        modelId: "model-a",
        favoriteOnly: true
    )
    let page = try await service.query(refined)
    try expect(page.items.allSatisfy { $0.type == .image && $0.modelId == "model-a" && $0.favorite }, "tag refinements should be applied in SQL")
    guard let cursor = page.nextCursor else { return }
    _ = revision.advance()
    do {
        _ = try await service.query(LibraryQuery(.tag("Foo"), pageSize: 300, cursor: cursor, type: .image, modelId: "model-a", favoriteOnly: true))
        throw CoreUnitTestError.failure("a tag cursor must be invalid after dataRevision advances")
    } catch LibraryQueryError.cursorQueryFingerprintMismatch {
        // Expected restart behavior.
    }
}

func testLibraryQueryTagExplainUsesRelationIndexWithoutPromptItemScan() async throws {
    let (libraryURL, _) = try makePhase2A2TagFixture(count: 4)
    defer { try? FileManager.default.removeItem(at: libraryURL) }
    let databaseURL = libraryURL.appendingPathComponent("database/promptstudio.sqlite")
    let readConnection = try SQLiteReadConnection(path: databaseURL.path)
    let service = LibraryQueryService(
        executor: readConnection,
        capabilities: LibraryQueryCapabilities(tagRelationsReady: true, versionSequenceReady: true, itemSequenceReady: true)
    )
    let plan = try await service.explain(LibraryQuery.tag("Foo", pageSize: 20))
    let detailLines = plan.compactMap { $0["detail"] ?? nil }
    let details = detailLines.joined(separator: "\n")
    try expect(details.contains(phase2A2RelationIndexName), "tag EXPLAIN should use the relation ordering index: \(details)")
    try expect(
        !detailLines.contains { $0 == "SCAN p" || $0.hasPrefix("SCAN p ") },
        "tag EXPLAIN must not scan prompt_items: \(details)"
    )
    try expect(!details.localizedCaseInsensitiveContains("SCAN v"), "tag Summary hasPrompt must use the promptItemId index")
    try expect(!details.localizedCaseInsensitiveContains("json_each"), "tag EXPLAIN must not use legacy json_each")
}

func testLibraryQueryTagCursorInvalidatesAfterRepositoryTagMutation() async throws {
    let (libraryURL, _) = try makePhase2A2TagFixture(count: 301)
    defer { try? FileManager.default.removeItem(at: libraryURL) }
    let repository = try PromptRepository(libraryURL: libraryURL)
    _ = try repository.prepareTagRelationMigration()
    _ = try repository.runTagRelationBackfill(batchSize: 500)
    try expect(try repository.validateTagRelationConsistency().isConsistent, "repository relation should be ready")

    let readConnection = try SQLiteReadConnection(path: repository.databaseURL.path)
    let service = LibraryQueryService(
        executor: readConnection,
        dataRevision: repository.libraryDataRevision,
        capabilities: LibraryQueryCapabilities(
            tagRelationsReady: repository.tagRelationsReady,
            versionSequenceReady: repository.versionSequenceMigrationReady,
            itemSequenceReady: repository.itemSequenceMigrationReady
        )
    )
    let first = try await service.query(LibraryQuery.tag("Foo", pageSize: 10))
    guard let cursor = first.nextCursor else {
        throw CoreUnitTestError.failure("tag mutation test requires a continuation cursor")
    }

    let database = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    let duplicateFirstRows = try database.query(
        """
        SELECT promptItemId,tagKey
        FROM prompt_item_tags
        WHERE isFirstOccurrence=1
        GROUP BY promptItemId,tagKey
        HAVING COUNT(*) > 1;
        """
    )
    try expect(duplicateFirstRows.isEmpty, "migration must keep one first occurrence per item and relation key")

    let targetID = "tag-item-0000"
    try repository.markDeleted(itemID: targetID, deletedAt: Date(timeIntervalSince1970: 1_900_000_000))
    let deletedActiveCount = try tagRelationCount(
        database,
        sql: "SELECT COUNT(*) AS count FROM prompt_item_tags WHERE promptItemId=? AND tagKey=? AND isFirstOccurrence=1 AND isDeleted=0;",
        values: [.text(targetID), .text("Foo")]
    )
    try expect(deletedActiveCount == 0, "deleted items must not retain active first-occurrence membership")
    try repository.markDeleted(itemID: targetID, deletedAt: nil)

    guard var target = try repository.loadItems().first(where: { $0.id == targetID }) else {
        throw CoreUnitTestError.failure("writer invariant fixture item is missing")
    }
    target.tags = ["", "foo", "é", "e\u{301}"]
    try repository.saveItem(target)
    let removedCount = try tagRelationCount(
        database,
        sql: "SELECT COUNT(*) AS count FROM prompt_item_tags WHERE promptItemId=? AND tagKey=? AND isFirstOccurrence=1 AND isDeleted=0;",
        values: [.text(targetID), .text("Foo")]
    )
    try expect(removedCount == 0, "removing a Tag must remove its active first occurrence")
    target.tags = ["Foo", "Foo", "", "foo", "é", "e\u{301}"]
    try repository.saveItem(target)
    let readdedCount = try tagRelationCount(
        database,
        sql: "SELECT COUNT(*) AS count FROM prompt_item_tags WHERE promptItemId=? AND tagKey=? AND isFirstOccurrence=1 AND isDeleted=0;",
        values: [.text(targetID), .text("Foo")]
    )
    try expect(readdedCount == 1, "remove/re-add must restore exactly one active first occurrence")

    try repository.renameTag(from: "Foo", to: "Renamed Foo")
    do {
        _ = try await service.query(LibraryQuery.tag("Foo", pageSize: 10, cursor: cursor))
        throw CoreUnitTestError.failure("repository tag mutation must invalidate existing keyset cursors")
    } catch LibraryQueryError.cursorQueryFingerprintMismatch {
        // Expected: the repository advanced the shared data revision.
    }
}
