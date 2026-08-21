import Foundation
import PromptStudioCore

private func semanticISODate(_ value: TimeInterval) -> String {
    ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: value))
}

private func semanticVersion(
    id: String,
    itemID: String,
    prompt: String,
    createdAt: TimeInterval
) -> PromptVersion {
    PromptVersion(
        id: id,
        promptItemId: itemID,
        version: id,
        prompt: prompt,
        createdAt: Date(timeIntervalSince1970: createdAt)
    )
}

private func insertSemanticVersion(
    _ version: PromptVersion,
    into database: SQLiteDatabase
) throws {
    let parameters = "{}"
    try database.run(
        """
        INSERT INTO prompt_versions (
            id, promptItemId, version, prompt, negativePrompt, parametersJSON, note, createdAt
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """,
        values: [
            .text(version.id),
            .text(version.promptItemId),
            .text(version.version),
            .text(version.prompt),
            .text(version.negativePrompt),
            .text(parameters),
            .text(version.note),
            .text(semanticISODate(version.createdAt.timeIntervalSince1970))
        ]
    )
}

private func semanticFixtureItem(id: String, sortOrder: Int) -> PromptItem {
    var item = sampleItem(title: "Semantic \(id)", prompt: "seed")
    item.id = id
    item.sortOrder = sortOrder
    item.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    item.updatedAt = item.createdAt
    item.lastUsedAt = item.createdAt
    item.versions = []
    item.referenceAssets = []
    return item
}

private func semanticSummaryRows(
    repository: PromptRepository,
    pageSize: Int = 100
) async throws -> [LibraryItemSummary] {
    if !repository.versionSequenceMigrationReady {
        _ = try repository.prepareVersionSequenceMigration()
        _ = try repository.runVersionSequenceMigration(batchSize: 100)
    }
    if !repository.itemSequenceMigrationReady {
        _ = try repository.prepareItemSequenceMigration()
        _ = try repository.runItemSequenceMigration(batchSize: 100)
    }
    let connection = try SQLiteReadConnection(path: repository.databaseURL.path)
    let service = LibraryQueryService(executor: connection, repository: repository)
    return try await service.query(LibraryQuery(pageSize: pageSize)).items
}

func testLibraryQuerySummaryUsesLegacyCurrentVersionOnly() async throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let item = semanticFixtureItem(id: "latest-only", sortOrder: 0)
    try repository.saveItem(item)
    let database = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    try insertSemanticVersion(
        semanticVersion(id: "v1", itemID: item.id, prompt: "legacy prompt", createdAt: 1_700_000_001),
        into: database
    )
    try insertSemanticVersion(
        semanticVersion(id: "v2", itemID: item.id, prompt: " \t\r\n ", createdAt: 1_700_000_002),
        into: database
    )

    guard let loaded = try repository.loadItems().first(where: { $0.id == item.id }) else {
        throw CoreUnitTestError.failure("legacy current-version fixture should load")
    }
    try expect(loaded.currentVersion?.id == "v2", "legacy loader should select the latest version by createdAt")
    let summaries = try await semanticSummaryRows(repository: repository)
    try expect(summaries.first?.id == item.id, "summary query should return the semantic fixture")
    try expect(summaries.first?.hasPrompt == false, "hasPrompt must inspect only legacy currentVersion")
}

func testInMemoryFilteringUsesLegacyCurrentVersionAndDecodedReferences() async throws {
    var item = semanticFixtureItem(id: "in-memory", sortOrder: 0)
    item.versions = [
        semanticVersion(id: "old", itemID: item.id, prompt: "old prompt", createdAt: 1_700_000_001),
        semanticVersion(id: "latest", itemID: item.id, prompt: " \t\n ", createdAt: 1_700_000_002)
    ]
    let snapshot = LibraryFilterSnapshot(items: [item])
    let hasPromptFilter = PromptFilter(hasPromptOnly: true)
    try expect(
        PromptFiltering.apply([item], filter: hasPromptFilter).isEmpty,
        "PromptFiltering should inspect only currentVersion for hasPrompt"
    )
    let snapshotPromptIDs = try await snapshot.filter(hasPromptFilter).ids
    try expect(
        snapshotPromptIDs.isEmpty,
        "LibraryFilterSnapshot should inspect only currentVersion for hasPrompt"
    )

    item.referenceAssets = [ReferenceAsset(type: "image", path: "/tmp/ref.png", label: "ref")]
    let referenceSnapshot = LibraryFilterSnapshot(items: [item])
    let hasReferenceFilter = PromptFilter(hasReferenceOnly: true)
    try expect(
        PromptFiltering.apply([item], filter: hasReferenceFilter).map(\.id) == [item.id],
        "PromptFiltering should use decoded referenceAssets"
    )
    let snapshotReferenceIDs = try await referenceSnapshot.filter(hasReferenceFilter).ids
    try expect(
        snapshotReferenceIDs == [item.id],
        "LibraryFilterSnapshot should use decoded referenceAssets"
    )
}

func testLibraryQuerySummaryUsesSwiftWhitespaceSemantics() async throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let prompts = [
        ("empty", ""),
        ("ascii", " \t\n\r\n "),
        ("unicode", "\u{2003}\u{2002}\u{00A0}"),
        ("content", "\u{2003}prompt\u{2003}")
    ]
    for (index, pair) in prompts.enumerated() {
        let item = semanticFixtureItem(id: "whitespace-\(pair.0)", sortOrder: index)
        try repository.saveItem(item)
        let database = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
        try insertSemanticVersion(
            semanticVersion(id: "\(item.id)-v1", itemID: item.id, prompt: pair.1, createdAt: 1_700_000_100 + Double(index)),
            into: database
        )
    }

    let summaries = try await semanticSummaryRows(repository: repository)
    let byID = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0.hasPrompt) })
    try expect(byID["whitespace-empty"] == false, "empty prompt should not count")
    try expect(byID["whitespace-ascii"] == false, "ASCII whitespace should not count")
    try expect(byID["whitespace-unicode"] == false, "Unicode whitespace should match Swift trimming")
    try expect(byID["whitespace-content"] == true, "non-whitespace content should count")
}

func testLibraryQuerySummaryReferencesMatchLegacyDecodeFallback() async throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let fixtures: [(String, String)] = [
        ("empty", "[]"),
        ("one", "[{\"id\":\"r1\",\"type\":\"image\",\"path\":\"/tmp/r1.png\",\"label\":\"one\"}]"),
        ("many", "[{\"id\":\"r1\",\"type\":\"image\",\"path\":\"/tmp/r1.png\",\"label\":\"one\"},{\"id\":\"r2\",\"type\":\"document\",\"path\":\"/tmp/r2.pdf\",\"label\":\"two\"}]"),
        ("malformed", "not-json"),
        ("invalid-element", "[{\"id\":123,\"type\":\"image\",\"path\":\"/tmp/r.png\",\"label\":\"bad\"}]"),
        ("missing-field", "[{\"id\":\"r\",\"type\":\"image\",\"path\":\"/tmp/r.png\"}]")
    ]
    for (index, fixture) in fixtures.enumerated() {
        let item = semanticFixtureItem(id: "references-\(fixture.0)", sortOrder: index)
        try repository.saveItem(item)
        let database = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
        try database.run(
            "UPDATE prompt_items SET referencesJSON = ? WHERE id = ?;",
            values: [.text(fixture.1), .text(item.id)]
        )
    }

    let summaries = try await semanticSummaryRows(repository: repository)
    let byID = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0.hasReferences) })
    try expect(byID["references-empty"] == false, "empty references array should not count")
    try expect(byID["references-one"] == true, "one decodable reference should count")
    try expect(byID["references-many"] == true, "many decodable references should count")
    try expect(byID["references-malformed"] == false, "malformed references JSON should decode as []")
    try expect(byID["references-invalid-element"] == false, "invalid reference element should decode as []")
    try expect(byID["references-missing-field"] == false, "missing reference field should decode as []")
}

func testLibraryQueryCurrentVersionGoldenEqualCreatedAt() async throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let item = semanticFixtureItem(id: "equal-created-at", sortOrder: 0)
    try repository.saveItem(item)
    let reverseItem = semanticFixtureItem(id: "equal-created-at-reverse", sortOrder: 1)
    try repository.saveItem(reverseItem)
    let database = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    let tied = 1_700_001_000.0
    for version in [
        semanticVersion(id: "z-version", itemID: item.id, prompt: "", createdAt: tied),
        semanticVersion(id: "a-version", itemID: item.id, prompt: "nonempty-a", createdAt: tied),
        semanticVersion(id: "m-version", itemID: item.id, prompt: "nonempty-m", createdAt: tied)
    ] {
        try insertSemanticVersion(version, into: database)
    }
    for version in [
        semanticVersion(id: "m-version-reverse", itemID: reverseItem.id, prompt: "nonempty-m", createdAt: tied),
        semanticVersion(id: "a-version-reverse", itemID: reverseItem.id, prompt: "nonempty-a", createdAt: tied),
        semanticVersion(id: "z-version-reverse", itemID: reverseItem.id, prompt: "", createdAt: tied)
    ] {
        try insertSemanticVersion(version, into: database)
    }
    let loadedItems = try repository.loadItems()
    guard let loaded = loadedItems.first(where: { $0.id == item.id }),
          let loadedReverse = loadedItems.first(where: { $0.id == reverseItem.id }) else {
        throw CoreUnitTestError.failure("equal-createdAt fixture should load")
    }
    let rowOrder = try database.query("SELECT rowid, id FROM prompt_versions WHERE promptItemId = ? ORDER BY rowid ASC;", values: [.text(item.id)])
        .map { ($0["rowid"] ?? nil ?? "", $0["id"] ?? nil ?? "") }
    print("golden equal-createdAt rowOrder=\(rowOrder) loadedOrder=\(loaded.versions.map(\.id)) currentVersion=\(loaded.currentVersion?.id ?? "nil")")
    let summaries = try await semanticSummaryRows(repository: repository)
    print("golden equal-createdAt reverseCurrent=\(loadedReverse.currentVersion?.id ?? "nil")")
    let summaryByID = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0.hasPrompt) })
    try expect(
        summaryByID[item.id] == (loaded.currentVersion?.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            && summaryByID[reverseItem.id] == (loadedReverse.currentVersion?.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false),
        "summary latest-version tie handling must match legacy loader golden"
    )
}

func testLibraryQuerySQLBuilderSemanticFunctionsAreExplicit() throws {
    let built = try LibraryQuerySQLBuilder.build(
        LibraryQuery(pageSize: 10),
        capabilities: .itemSequence
    )
    try expect(built.sql.contains("ps_trim_whitespace"), "summary SQL should use the registered Swift-compatible trim scalar")
    try expect(built.sql.contains("ps_reference_asset_count"), "summary SQL should use the legacy ReferenceAsset decode scalar")
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let database = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    let nullRows = try database.query(
        "SELECT ps_trim_whitespace(NULL) AS trimmed, ps_reference_asset_count(NULL) AS referenceCount;"
    )
    try expect(nullRows.first?["trimmed"] ?? nil == nil, "NULL prompt input should remain NULL through the Swift trim scalar")
    try expect(nullRows.first?["referenceCount"] ?? nil == "0", "NULL references input should decode as an empty array")
    let embeddedNUL = try database.query(
        "SELECT hex(ps_trim_whitespace('a' || char(0) || 'b')) AS trimmedHex;"
    )
    try expect(
        embeddedNUL.first?["trimmedHex"] ?? nil == "610062",
        "trim scalar must preserve embedded NUL bytes instead of C-string truncation"
    )
}

func testLibraryQuerySummaryLatestVersionIndexExplain() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let item = semanticFixtureItem(id: "explain-latest", sortOrder: 0)
    try repository.saveItem(item)
    let database = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    _ = try repository.prepareVersionSequenceMigration()
    _ = try repository.runVersionSequenceMigration(batchSize: 10)
    _ = try repository.prepareItemSequenceMigration()
    _ = try repository.runItemSequenceMigration(batchSize: 10)
    try database.execute("DROP INDEX IF EXISTS idx_phase2a4_prompt_versions_latest;")
    let built = try LibraryQuerySQLBuilder.build(
        LibraryQuery(pageSize: 10),
        capabilities: LibraryQueryCapabilities(versionSequenceReady: true, itemSequenceReady: true)
    )
    try LibraryQuerySQLBuilder.installPhase2A1Indexes(using: { statement in
        try database.execute(statement)
    })

    func explainDetails() throws -> String {
        let rows = try database.query("EXPLAIN QUERY PLAN \(built.sql)", values: built.values)
        return rows.compactMap { $0["detail"] ?? nil }.joined(separator: "\n")
    }

    let before = try explainDetails()
    try expect(
        !before.contains("idx_phase2a4_prompt_versions_latest"),
        "before plan must not claim the ready composite index is available"
    )
    try expect(
        before.contains("idx_phase2a1_prompt_versions_prompt_item_id"),
        "before plan must use the legacy promptItemId lookup and remain measurably less covered"
    )
    try LibraryQuerySQLBuilder.installPhase2A4LatestVersionIndex(using: { statement in
        try database.execute(statement)
    }, versionSequenceReady: true)
    let after = try explainDetails()
    print("phase2a4 latest-version EXPLAIN before=\(before) after=\(after)")
    try expect(before != after, "installing the ready composite index must change the EXPLAIN plan")
    try expect(after.contains("idx_phase2a4_prompt_versions_latest"), "latest-version Summary should use the composite prompt_versions index")
    try expect(!after.localizedCaseInsensitiveContains("SCAN prompt_versions"), "latest-version Summary must not scan prompt_versions")
    try expect(!after.localizedCaseInsensitiveContains("SCAN v"), "latest-version Summary must not scan a prompt_versions alias")
    try expect(!after.localizedCaseInsensitiveContains("TEMP B-TREE"), "latest-version Summary must not sort into a temp B-tree")
}
