import Foundation
import PromptStudioCore

private struct CreatedAtFixtureRow: Sendable {
    let id: String
    let rawCreatedAt: String
    let deleted: Bool
    let folderID: String
}

private let createdAtFixtureRows: [CreatedAtFixtureRow] = [
    .init(id: "created-z", rawCreatedAt: "2026-01-01T00:00:00Z", deleted: false, folderID: "folder-moved"),
    .init(id: "created-short-fraction", rawCreatedAt: "2026-01-01T00:00:00.1Z", deleted: false, folderID: "folder-moved"),
    .init(id: "created-long-fraction", rawCreatedAt: "2026-01-01T00:00:00.123456Z", deleted: false, folderID: "folder-moved"),
    .init(id: "created-offset", rawCreatedAt: "2025-12-31T19:00:00-05:00", deleted: false, folderID: "folder-moved"),
    .init(id: "created-empty", rawCreatedAt: "", deleted: false, folderID: "folder-moved"),
    .init(id: "created-malformed", rawCreatedAt: "not-a-date", deleted: true, folderID: "folder-trash")
]

private func createdAtCompatibilityRepository(
    legacyObservationClock: ItemSequenceObservationClock? = nil
) throws -> (PromptRepository, SQLiteDatabase) {
    let repository = try PromptRepository(
        libraryURL: temporaryLibraryURL(),
        legacyObservationClock: legacyObservationClock
    )
    let items = createdAtFixtureRows.enumerated().map { index, fixture in
        var item = sampleItem(title: fixture.id, prompt: "created-at (fixture.id)")
        item.id = fixture.id
        item.folderId = fixture.folderID
        item.folderName = fixture.folderID == "folder-trash" ? "Trash" : "Moved"
        item.createdAt = Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
        item.updatedAt = item.createdAt
        item.lastUsedAt = item.createdAt
        item.sortOrder = index
        item.deletedAt = fixture.deleted ? Date(timeIntervalSince1970: 1_800_000_000) : nil
        item.captureID = fixture.id == "created-long-fraction" ? "capture-created-long" : nil
        item.versions = []
        return item
    }
    try repository.saveItems(items)
    let database = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    for fixture in createdAtFixtureRows {
        try database.run(
            "UPDATE prompt_items SET createdAt = ? WHERE id = ?;",
            values: [.text(fixture.rawCreatedAt), .text(fixture.id)]
        )
    }
    return (repository, database)
}

private func runCreatedAtMigrations(
    _ repository: PromptRepository,
    fallbackDates: [Date] = [
        Date(timeIntervalSince1970: 2_000_000_000),
        Date(timeIntervalSince1970: 2_000_000_001)
    ]
) throws {
    _ = try repository.prepareVersionSequenceMigration()
    _ = try repository.runVersionSequenceMigration(batchSize: 50)
    _ = try repository.prepareItemSequenceMigration()
    _ = try repository.runItemSequenceMigration(
        batchSize: 50,
        observationClock: ItemSequenceObservationClock(dates: fallbackDates)
    )
}

private func createdAtRowValue(_ row: [String: String?], _ key: String) -> String {
    guard let value = row[key] ?? nil else { return "" }
    return value
}

private final class CreatedAtReadinessGate: @unchecked Sendable {
    private let lock = NSLock()
    private var ready = false
    private var reads = 0

    func setReady() {
        lock.lock()
        ready = true
        lock.unlock()
    }

    func read() -> Bool {
        lock.lock()
        reads += 1
        let value = ready
        lock.unlock()
        return value
    }

    var readCount: Int {
        lock.lock()
        let value = reads
        lock.unlock()
        return value
    }
}

private final class CreatedAtHubDetailLoader: ItemDetailLoading, ItemDetailInvalidationProviding, @unchecked Sendable {
    let itemDetailInvalidationHub: ItemDetailInvalidationHub
    private let lock = NSLock()
    private let stale: PromptItem
    private let fresh: PromptItem
    private var requestCount = 0

    init(stale: PromptItem, fresh: PromptItem) {
        self.itemDetailInvalidationHub = ItemDetailInvalidationHub(
            libraryURL: URL(fileURLWithPath: "/private/tmp/created-at-hub-(UUID().uuidString)")
        )
        self.stale = stale
        self.fresh = fresh
    }

    var requests: Int {
        lock.withLock { requestCount }
    }

    func itemDetail(id: String) async throws -> PromptItem? {
        lock.withLock {
            requestCount += 1
            return requestCount == 1 ? stale : fresh
        }
    }
}

func testItemCreatedAtCompatibilityFreezeReadySummaryUsesPersistedDate() async throws {
    let (repository, database) = try createdAtCompatibilityRepository()
    try runCreatedAtMigrations(repository)

    let service = LibraryQueryService(
        executor: try SQLiteReadConnection(path: repository.databaseURL.path),
        repository: repository
    )
    let active = try await service.query(LibraryQuery(.all, pageSize: 20)).items
    let trash = try await service.query(LibraryQuery(.trash, pageSize: 20)).items
    let summaries = active + trash
    try expect(summaries.count == createdAtFixtureRows.count, "ready Summary must traverse canonical, fractional, offset, empty, malformed, and trash rows")

    for summary in summaries {
        guard let row = try database.query(
            "SELECT itemCreatedAtSortKey FROM prompt_items WHERE id = ?;",
            values: [.text(summary.id)]
        ).first else {
            throw CoreUnitTestError.failure("persisted sort-key row missing for \(summary.id)")
        }
        guard let key = Int64(createdAtRowValue(row, "itemCreatedAtSortKey")) else {
            throw CoreUnitTestError.failure("persisted sort-key is malformed for \(summary.id)")
        }
        let persistedDate = Date(timeIntervalSince1970: Double(key) / 1_000_000)
        try expect(summary.createdAt == persistedDate, "ready Summary createdAt must decode only itemCreatedAtSortKey for \(summary.id)")
    }

    let loaded = try repository.loadItems()
    guard let loadedLong = loaded.first(where: { $0.id == "created-long-fraction" }),
          let summaryLong = summaries.first(where: { $0.id == "created-long-fraction" }) else {
        throw CoreUnitTestError.failure("ready full-item fixture should be present")
    }
    try expect(loadedLong.createdAt == summaryLong.createdAt, "ready legacy full-item loader must use the persisted item date key")
    try expect(
        try repository.findItem(captureID: "capture-created-long")?.createdAt == summaryLong.createdAt,
        "ready capture point lookup must inherit the persisted item date key"
    )
    let automation = PromptStudioAutomationService(repository: repository)
    try expect(try automation.item(id: "created-long-fraction").createdAt == summaryLong.createdAt, "ready automation point projection must use the persisted item date key")
    try expect(try automation.listItems().first(where: { $0.id == "created-long-fraction" })?.createdAt == summaryLong.createdAt, "ready automation list projection must use the persisted item date key")
}

func testItemCreatedAtCompatibilityFreezeSummaryMatchesDetail() async throws {
    let (repository, _) = try createdAtCompatibilityRepository()
    try runCreatedAtMigrations(repository)
    let service = LibraryQueryService(
        executor: try SQLiteReadConnection(path: repository.databaseURL.path),
        repository: repository
    )
    let summaries = try await service.query(LibraryQuery(.all, pageSize: 20)).items
    for summary in summaries {
        guard let detail = try await repository.itemDetail(id: summary.id) else {
            throw CoreUnitTestError.failure("ready detail missing for \(summary.id)")
        }
        try expect(summary.createdAt == detail.createdAt, "Summary and itemDetail(id:).createdAt must be identical for \(summary.id)")
    }
}

func testItemCreatedAtCompatibilityFreezeDetailGateSwitchesOnSameService() async throws {
    let (repository, database) = try createdAtCompatibilityRepository()
    _ = try repository.prepareVersionSequenceMigration()
    _ = try repository.runVersionSequenceMigration(batchSize: 50)
    let gate = CreatedAtReadinessGate()
    let service = try PromptItemDetailService(
        databaseURL: repository.databaseURL,
        versionSequenceReadyProvider: { true },
        itemSequenceReadyProvider: { gate.read() }
    )

    let preReady = try await service.itemDetail(id: "created-long-fraction")
    try expect(preReady?.itemCreatedAtSortKey == nil, "pre-ready detail may retain the legacy raw parser without persisted metadata")

    try runCreatedAtMigrations(repository)
    gate.setReady()
    let ready = try await service.itemDetail(id: "created-long-fraction")
    guard let key = Int64(createdAtRowValue(
        try database.query("SELECT itemCreatedAtSortKey FROM prompt_items WHERE id = ?;", values: [.text("created-long-fraction")]).first ?? [:],
        "itemCreatedAtSortKey"
    )) else {
        throw CoreUnitTestError.failure("ready detail fixture should have a persisted itemCreatedAtSortKey")
    }
    try expect(ready?.createdAt == Date(timeIntervalSince1970: Double(key) / 1_000_000), "same detail service must switch to persisted item date after readiness")
    try expect(gate.readCount == 2, "item readiness provider must be read once per detail request")
}

@MainActor
func testItemCreatedAtCompatibilityFreezeControllerDropsPreReadyCache() async throws {
    let (repository, database) = try createdAtCompatibilityRepository()
    _ = try repository.prepareVersionSequenceMigration()
    _ = try repository.runVersionSequenceMigration(batchSize: 50)
    let cache = ItemDetailCache()
    let controller = ItemDetailController(loader: repository, cache: cache)
    controller.select(id: "created-long-fraction")
    try await Task.sleep(nanoseconds: 120_000_000)
    await Task.yield()
    try expect(controller.currentDetail?.itemCreatedAtSortKey == nil, "pre-ready controller detail should not expose persisted item date metadata")
    try expect(cache.get(id: "created-long-fraction", revision: 0) != nil, "pre-ready detail should be cached before migration")

    try runCreatedAtMigrations(repository)
    try await Task.sleep(nanoseconds: 120_000_000)
    await Task.yield()
    // The migration event itself must invalidate and reload the selected item;
    // callers should not need to reselect it manually.
    try await Task.sleep(nanoseconds: 120_000_000)
    await Task.yield()
    guard let key = Int64(createdAtRowValue(
        try database.query("SELECT itemCreatedAtSortKey FROM prompt_items WHERE id = ?;", values: [.text("created-long-fraction")]).first ?? [:],
        "itemCreatedAtSortKey"
    )) else {
        throw CoreUnitTestError.failure("controller ready fixture should have a persisted itemCreatedAtSortKey")
    }
    try expect(controller.currentDetail?.itemCreatedAtSortKey == key, "controller must reload ready detail after migration invalidation")
}

@MainActor
func testItemCreatedAtCompatibilityFreezeControllerReloadsSelectedHubEvent() async throws {
    let id = "created-selected-event"
    var stale = sampleItem(title: "stale", prompt: "stale")
    var fresh = stale
    stale.id = id
    fresh.id = id
    fresh.title = "fresh"
    let loader = CreatedAtHubDetailLoader(stale: stale, fresh: fresh)
    let controller = ItemDetailController(loader: loader)
    controller.select(id: id)
    try await Task.sleep(nanoseconds: 120_000_000)
    try expect(controller.currentDetail?.title == "stale", "selected-ID event fixture should load stale detail first")

    _ = loader.itemDetailInvalidationHub.publish(changedItemIDs: [id])
    try await Task.sleep(nanoseconds: 120_000_000)
    await Task.yield()
    try expect(loader.requests == 2, "selected-ID invalidation event should reload the selected detail")
    try expect(controller.currentDetail?.title == "fresh", "selected-ID invalidation event should publish the fresh detail")
}

func testItemCreatedAtCompatibilityFreezeReadyEditPreservesRawCreatedAtAndSortKey() throws {
    let (repository, database) = try createdAtCompatibilityRepository()
    try runCreatedAtMigrations(repository)
    let before = try database.query(
        "SELECT id, createdAt, itemCreatedAtSortKey FROM prompt_items ORDER BY id COLLATE BINARY ASC;"
    )

    for id in ["created-long-fraction", "created-offset", "created-empty", "created-malformed"] {
        guard var item = try repository.loadItems().first(where: { $0.id == id }) else {
            throw CoreUnitTestError.failure("ready edit fixture missing: \(id)")
        }
        item.title = "edited \(id)"
        try repository.saveItem(item)
    }

    let after = try database.query(
        "SELECT id, createdAt, itemCreatedAtSortKey FROM prompt_items ORDER BY id COLLATE BINARY ASC;"
    )
    try expect(before == after, "ready unrelated edits must preserve raw createdAt bytes and persisted itemCreatedAtSortKey")
}

func testItemCreatedAtCompatibilityFreezeReadyEditPreservesTagRelationRawCreatedAt() throws {
    let (repository, _) = try createdAtCompatibilityRepository()
    try runCreatedAtMigrations(repository)
    _ = try repository.prepareTagRelationMigration()
    _ = try repository.runTagRelationBackfill(batchSize: 500)
    try expect(try repository.validateTagRelationConsistency().isConsistent, "createdAt fixture relations should be consistent before ready edits")

    for id in ["created-long-fraction", "created-offset", "created-empty", "created-malformed"] {
        guard var item = try repository.loadItems().first(where: { $0.id == id }) else {
            throw CoreUnitTestError.failure("ready tag relation edit fixture missing: \(id)")
        }
        item.title = "edited relation \(id)"
        try repository.saveItem(item)
        try expect(
            try repository.validateTagRelationConsistency().isConsistent,
            "ready title edit must preserve exact raw createdAt in tag relations for \(id)"
        )
    }
}

func testItemCreatedAtCompatibilityFreezeParserRequiresStrictRFC3339FullMatch() throws {
    let valid = [
        "2026-01-01T00:00:00Z",
        "2026-01-01T00:00:00.1Z",
        "2026-01-01T00:00:00.123456Z",
        "2025-12-31T19:00:00-05:00",
        "2026-01-01T05:30:00+05:30",
        "2026-01-01T00:00:00+18:01",
        "2026-01-01T00:00:00+23:59",
        "2026-01-01T00:00:00-23:59"
    ]
    for raw in valid {
        try expect(PromptItemCreatedAtSupport.date(from: raw) != nil, "strict parser must accept \(raw)")
    }

    let invalid = [
        "",
        " 2026-01-01T00:00:00Z",
        "2026-01-01T00:00:00Z ",
        "2026-01-01T00:00:00Z\n",
        "2026-01-01T00:00:00.123456Zjunk",
        "2026-01-01T00:00:00.123456+05:30[foo]",
        "2026-01-01T00:00:00+99:99",
        "0000-01-01T00:00:00Z",
        "2026-02-29T00:00:00Z",
        "2026-01-01T24:00:00Z",
        "2026-01-01T00:00:00.Z"
    ]
    for raw in invalid {
        try expect(PromptItemCreatedAtSupport.date(from: raw) == nil, "strict parser must reject \(raw.debugDescription)")
    }
}

func testItemCreatedAtCompatibilityFreezeExactFractionSortKeyRounding() throws {
    let cases: [(raw: String, expected: Int64)] = [
        ("2026-01-01T00:00:00.1234563Z", 1_767_225_600_123_456),
        ("2026-01-01T00:00:00.1234565Z", 1_767_225_600_123_457),
        ("2026-01-01T00:00:00.9999994Z", 1_767_225_600_999_999),
        ("2026-01-01T00:00:00.9999995Z", 1_767_225_601_000_000),
        ("2026-01-01T00:00:00.1234565-05:00", 1_767_243_600_123_457),
        ("1969-12-31T23:59:59.1234563Z", -876_544),
        ("1969-12-31T23:59:59.1234565Z", -876_544),
        ("1969-12-31T23:59:59.1234567Z", -876_543),
        ("1969-12-31T23:59:59.0000005Z", -1_000_000),
        ("1969-12-31T23:59:59.1234565+01:00", -3_600_876_544),
        ("1969-12-30T22:59:59.1234565-05:00", -72_000_876_544),
        ("2026-01-01T00:00:00.1234565+18:01", 1_767_160_740_123_457),
        ("2026-01-01T00:00:00.1234565+23:59", 1_767_139_260_123_457),
        ("2026-01-01T00:00:00.1234565-23:59", 1_767_311_940_123_457)
    ]
    for entry in cases {
        try expect(
            PromptItemCreatedAtSupport.sortKey(from: entry.raw) == entry.expected,
            "exact createdAt sort-key rounding mismatch for \(entry.raw)"
        )
    }

    let negativeDateConsistencyCases = cases.filter { $0.raw.hasPrefix("1969-") }
    for entry in negativeDateConsistencyCases {
        guard let date = PromptItemCreatedAtSupport.date(from: entry.raw) else {
            throw CoreUnitTestError.failure("date(from:) must accept negative timestamp \(entry.raw)")
        }
        try expect(
            PromptItemCreatedAtSupport.sortKey(for: date) == entry.expected,
            "raw and Date createdAt sort-key rounding must agree for \(entry.raw)"
        )
    }

    let (repository, database) = try createdAtCompatibilityRepository()
    let migrationCases: [(id: String, raw: String, expected: Int64)] = [
        ("created-z", "2026-01-01T00:00:00.1234563Z", 1_767_225_600_123_456),
        ("created-short-fraction", "2026-01-01T00:00:00.1234565Z", 1_767_225_600_123_457),
        ("created-long-fraction", "2026-01-01T00:00:00.9999994Z", 1_767_225_600_999_999),
        ("created-offset", "2026-01-01T00:00:00.9999995-05:00", 1_767_243_601_000_000),
        ("created-empty", "1969-12-31T23:59:59.1234565Z", -876_544),
        ("created-malformed", "1969-12-30T22:59:59.1234565-05:00", -72_000_876_544)
    ]
    for entry in migrationCases {
        try database.run(
            "UPDATE prompt_items SET createdAt = ? WHERE id = ?;",
            values: [.text(entry.raw), .text(entry.id)]
        )
    }
    try runCreatedAtMigrations(repository)
    for entry in migrationCases {
        let row = try database.query(
            "SELECT itemCreatedAtSortKey FROM prompt_items WHERE id = ?;",
            values: [.text(entry.id)]
        ).first ?? [:]
        try expect(
            Int64(createdAtRowValue(row, "itemCreatedAtSortKey")) == entry.expected,
            "item migration must persist exact decimal createdAt sort-key rounding for \(entry.id)"
        )
    }
}

private func readySummaryMetadataRow(
    sequence: String? = "1",
    createdKey: String? = "1767225600000000",
    lastUsedKey: String? = "1767225600000000",
    id: String = "ready-summary-1"
) -> [String: String?] {
    [
        "id": id,
        "title": "Ready summary",
        "type": PromptType.image.rawValue,
        "assetKind": AssetKind.image.rawValue,
        "modelId": "model",
        "modelName": "Model",
        "folderId": "folder",
        "folderName": "Folder",
        "category": "图片",
        "assetPath": "/tmp/ready.png",
        "thumbnailPath": "/tmp/ready.thumb.png",
        "aspectRatio": "16:9",
        "width": "1920",
        "height": "1080",
        "format": "PNG",
        "fileSize": "1",
        "favorite": "0",
        "pinnedAt": nil,
        "deletedAt": nil,
        "createdAt": "2026-01-01T00:00:00Z",
        "updatedAt": "2026-01-01T00:00:00Z",
        "lastUsedAt": "2026-01-01T00:00:00Z",
        "sortOrder": "0",
        "itemSequence": sequence,
        "itemCreatedAtSortKey": createdKey,
        "itemLastUsedAtSortKey": lastUsedKey,
        "hasPrompt": "1",
        "hasReferences": "0"
    ]
}

func testItemCreatedAtCompatibilityFreezeReadySummaryFailsClosedOnEveryMetadataField() async throws {
    for field in ["itemSequence", "itemCreatedAtSortKey", "itemLastUsedAtSortKey"] {
        let service = LibraryQueryService(
            executor: { sql, _ in
                if sql.contains("COUNT(*)") {
                    return [["totalCount": "1"]]
                }
                var row = readySummaryMetadataRow()
                row[field] = field == "itemSequence" ? "0" : "not-an-int64"
                return [row]
            },
            capabilities: .itemSequence
        )
        do {
            _ = try await service.query(LibraryQuery(.all, pageSize: 1))
            throw CoreUnitTestError.failure("ready Summary must fail closed for malformed \(field)")
        } catch LibraryQueryError.malformedRow {
            // Expected: every ready row requires all three persisted metadata fields.
        }
    }

    let service = LibraryQueryService(
        executor: { sql, _ in
            if sql.contains("COUNT(*)") {
                return [["totalCount": "2"]]
            }
            var malformed = readySummaryMetadataRow(id: "ready-summary-1")
            malformed["itemLastUsedAtSortKey"] = "bad"
            return [readySummaryMetadataRow(id: "ready-summary-0"), malformed]
        },
        capabilities: .itemSequence
    )
    do {
        _ = try await service.query(LibraryQuery(.all, pageSize: 2))
        throw CoreUnitTestError.failure("ready Summary must validate non-cursor rows on an exact page")
    } catch LibraryQueryError.malformedRow {
        // Expected: an exact page cannot bypass metadata validation.
    }
}

func testItemCreatedAtCompatibilityFreezeRepositoryQueryServiceRefreshesCapabilitiesAfterMigration() async throws {
    let (repository, _) = try createdAtCompatibilityRepository()
    _ = try repository.prepareVersionSequenceMigration()
    _ = try repository.runVersionSequenceMigration(batchSize: 50)
    let connection = try SQLiteReadConnection(path: repository.databaseURL.path)
    let service = LibraryQueryService(executor: connection, repository: repository)

    do {
        _ = try await service.query(LibraryQuery(.all, pageSize: 20))
        throw CoreUnitTestError.failure("pre-ready repository query service must fail closed")
    } catch LibraryQuerySQLBuilderError.itemSequenceNotReady {
        // Expected before the item migration opens its gate.
    }

    _ = try repository.prepareItemSequenceMigration()
    _ = try repository.runItemSequenceMigration(batchSize: 50)
    let page = try await service.query(LibraryQuery(.all, pageSize: 20))
    try expect(page.items.count == createdAtFixtureRows.count - 1, "the same repository query service must observe item readiness after migration")
}

func testItemCreatedAtCompatibilityFreezeUsesDeterministicObservationClockAndPreservesRawFields() async throws {
    let (repository, database) = try createdAtCompatibilityRepository()
    let before = try database.query(
        "SELECT id, title, createdAt, updatedAt, lastUsedAt, tagsJSON, referencesJSON, description, captureId, captureSourceJSON FROM prompt_items ORDER BY rowid ASC;"
    )
    let firstFallback = Date(timeIntervalSince1970: 2_100_000_000)
    let secondFallback = Date(timeIntervalSince1970: 2_100_000_001)
    try runCreatedAtMigrations(repository, fallbackDates: [firstFallback, secondFallback])

    let after = try database.query(
        "SELECT id, title, createdAt, updatedAt, lastUsedAt, tagsJSON, referencesJSON, description, captureId, captureSourceJSON FROM prompt_items ORDER BY rowid ASC;"
    )
    try expect(before == after, "item migration must not rewrite raw createdAt or other business fields")

    let service = LibraryQueryService(
        executor: try SQLiteReadConnection(path: repository.databaseURL.path),
        repository: repository
    )
    let summaries = try await service.query(LibraryQuery(.all, pageSize: 20)).items
    let emptySummary = summaries.first { $0.id == "created-empty" }
    let malformedSummary = summaries.first { $0.id == "created-malformed" }
    try expect(emptySummary != nil && malformedSummary == nil, "trash rows must stay out of the active Summary collection")

    let trashSummary = try await service.query(LibraryQuery(.trash, pageSize: 20)).items.first { $0.id == "created-malformed" }
    try expect(trashSummary?.createdAt == secondFallback, "empty/malformed migration fallback must use the deterministic observation clock")
    let emptyDetail = try await repository.itemDetail(id: "created-empty")
    let malformedDetail = try await repository.itemDetail(id: "created-malformed")
    try expect(emptyDetail?.createdAt == firstFallback, "empty createdAt fallback must consume the first deterministic clock observation")
    try expect(malformedDetail?.createdAt == secondFallback, "malformed createdAt fallback must be persisted and reused by ready detail")
}

func testPromptRepositoryLegacyObservationClockControlsPreReadyLoadItemsAndMatchesMigration() throws {
    let firstFallback = Date(timeIntervalSince1970: 2_200_000_000)
    let secondFallback = Date(timeIntervalSince1970: 2_200_000_001)
    let fallbackDates = [firstFallback, secondFallback]
    let (repository, database) = try createdAtCompatibilityRepository(
        legacyObservationClock: ItemSequenceObservationClock(dates: fallbackDates)
    )

    let preReady = try repository.loadItems()
    try expect(
        preReady.map(\.id) == createdAtFixtureRows.map(\.id),
        "pre-ready loadItems must retain SELECT observation order"
    )
    for fixture in createdAtFixtureRows {
        guard let loaded = preReady.first(where: { $0.id == fixture.id }) else {
            throw CoreUnitTestError.failure("pre-ready fixture missing \(fixture.id)")
        }
        if fixture.id == "created-empty" {
            try expect(loaded.createdAt == firstFallback, "empty createdAt must consume the first legacy observation")
        } else if fixture.id == "created-malformed" {
            try expect(loaded.createdAt == secondFallback, "malformed createdAt must consume the second legacy observation")
        } else {
            guard let expected = PromptItemCreatedAtSupport.date(from: fixture.rawCreatedAt) else {
                throw CoreUnitTestError.failure("valid fixture unexpectedly rejected: \(fixture.rawCreatedAt)")
            }
            try expect(loaded.createdAt == expected, "valid createdAt must parse without consuming the observation clock")
        }
    }

    _ = try repository.prepareVersionSequenceMigration()
    _ = try repository.runVersionSequenceMigration(batchSize: 50)
    _ = try repository.prepareItemSequenceMigration()
    _ = try repository.runItemSequenceMigration(
        batchSize: 50,
        observationClock: ItemSequenceObservationClock(dates: fallbackDates)
    )

    let rows = try database.query(
        "SELECT id, itemCreatedAtSortKey FROM prompt_items ORDER BY rowid ASC;"
    )
    let persistedKeys = Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (String, Int64)? in
        guard let id = row["id"] ?? nil,
              let rawKey = row["itemCreatedAtSortKey"] ?? nil,
              let key = Int64(rawKey) else { return nil }
        return (id, key)
    })
    for fixture in createdAtFixtureRows {
        let expectedDate: Date
        if fixture.id == "created-empty" {
            expectedDate = firstFallback
        } else if fixture.id == "created-malformed" {
            expectedDate = secondFallback
        } else {
            guard let parsed = PromptItemCreatedAtSupport.date(from: fixture.rawCreatedAt) else {
                throw CoreUnitTestError.failure("valid fixture unexpectedly rejected during migration: \(fixture.rawCreatedAt)")
            }
            expectedDate = parsed
        }
        try expect(
            persistedKeys[fixture.id] == PromptItemCreatedAtSupport.sortKey(for: expectedDate),
            "migration persisted key must equal the pre-ready legacy observation for \(fixture.id)"
        )
    }

    let ready = try repository.loadItems()
    for fixture in createdAtFixtureRows {
        guard let loaded = ready.first(where: { $0.id == fixture.id }) else {
            throw CoreUnitTestError.failure("ready fixture missing \(fixture.id)")
        }
        let expectedKey = persistedKeys[fixture.id]!
        try expect(
            loaded.createdAt == PromptItemCreatedAtSupport.date(forSortKey: expectedKey),
            "ready loadItems must decode the persisted itemCreatedAtSortKey for \(fixture.id)"
        )
    }

    let reopened = try PromptRepository(
        libraryURL: repository.libraryURL,
        legacyObservationClock: ItemSequenceObservationClock(dates: [Date(timeIntervalSince1970: 2_400_000_000)])
    )
    let restarted = try reopened.loadItems()
    for fixture in createdAtFixtureRows {
        guard let beforeRestart = ready.first(where: { $0.id == fixture.id }),
              let afterRestart = restarted.first(where: { $0.id == fixture.id }) else {
            throw CoreUnitTestError.failure("restart fixture missing \(fixture.id)")
        }
        try expect(
            afterRestart.createdAt == beforeRestart.createdAt,
            "ready restart must retain persisted createdAt without consulting the injected clock for \(fixture.id)"
        )
    }
}

func testPromptRepositoryLegacyObservationClockExhaustionFailsClosedAndInstancesDoNotShare() throws {
    let firstFallback = Date(timeIntervalSince1970: 2_300_000_000)
    let secondFallback = Date(timeIntervalSince1970: 2_300_000_001)
    let (repository, _) = try createdAtCompatibilityRepository(
        legacyObservationClock: ItemSequenceObservationClock(dates: [firstFallback])
    )
    do {
        _ = try repository.loadItems()
        throw CoreUnitTestError.failure("legacy observation clock exhaustion must fail closed")
    } catch ObservationClockError.exhausted {
        // Expected: never consult wall-clock Date() after a deterministic sequence ends.
    }

    let firstURL = try temporaryLibraryURL()
    let secondURL = try temporaryLibraryURL()
    let first = try PromptRepository(
        libraryURL: firstURL,
        legacyObservationClock: ItemSequenceObservationClock(dates: [firstFallback])
    )
    let second = try PromptRepository(
        libraryURL: secondURL,
        legacyObservationClock: ItemSequenceObservationClock(dates: [secondFallback])
    )
    var firstItem = sampleItem(title: "first-clock", prompt: "first-clock")
    firstItem.id = "first-clock"
    firstItem.versions = []
    var secondItem = sampleItem(title: "second-clock", prompt: "second-clock")
    secondItem.id = "second-clock"
    secondItem.versions = []
    try first.saveItem(firstItem)
    try second.saveItem(secondItem)
    let firstDatabase = try SQLiteDatabase(path: first.databaseURL.path, mode: .existingReadWrite)
    let secondDatabase = try SQLiteDatabase(path: second.databaseURL.path, mode: .existingReadWrite)
    try firstDatabase.run("UPDATE prompt_items SET createdAt = '' WHERE id = 'first-clock';")
    try secondDatabase.run("UPDATE prompt_items SET createdAt = 'not-a-date' WHERE id = 'second-clock';")
    try expect(try first.loadItems().first?.createdAt == firstFallback, "first repository must use only its own clock")
    try expect(try second.loadItems().first?.createdAt == secondFallback, "second repository must use only its own clock")
}

func testPromptRepositoryLegacyObservationClassificationMatchesItemMigration() throws {
    let legacyRows: [(id: String, raw: String)] = [
        ("created-z", "2026-01-01T00:00:00+0000"),
        ("created-short-fraction", "2026-01-01T00:00:00-0500"),
        ("created-long-fraction", "2026-01-01T00:00:00 UTC"),
        ("created-offset", "2026-01-01T00:00:00.123456Z"),
        ("created-empty", ""),
        ("created-malformed", "not-a-date")
    ]
    let firstFallback = Date(timeIntervalSince1970: 2_500_000_000)
    let secondFallback = Date(timeIntervalSince1970: 2_500_000_001)
    let fallbackDates = [firstFallback, secondFallback]
    let (repository, database) = try createdAtCompatibilityRepository(
        legacyObservationClock: ItemSequenceObservationClock(dates: fallbackDates)
    )
    for row in legacyRows {
        try database.run(
            "UPDATE prompt_items SET createdAt = ? WHERE id = ?;",
            values: [.text(row.raw), .text(row.id)]
        )
    }

    let legacyFormatter = ISO8601DateFormatter()
    for row in legacyRows.prefix(4) {
        try expect(
            PromptItemCreatedAtSupport.date(from: row.raw) != nil || legacyFormatter.date(from: row.raw) != nil,
            "fixture must be accepted by the canonical or historical parser: \(row.raw.debugDescription)"
        )
    }
    let preReady = try repository.loadItems()
    let preReadyDates = Dictionary(uniqueKeysWithValues: preReady.map { ($0.id, $0.createdAt) })
    for row in legacyRows.prefix(4) {
        guard let expected = PromptItemCreatedAtSupport.date(from: row.raw)
            ?? legacyFormatter.date(from: row.raw) else {
            throw CoreUnitTestError.failure("legacy parser unexpectedly rejected \(row.raw.debugDescription)")
        }
        try expect(
            preReadyDates[row.id] == expected,
            "legacy ISO-only createdAt must parse without consuming fallback: \(row.raw.debugDescription)"
        )
    }
    try expect(preReadyDates["created-empty"] == firstFallback, "empty legacy createdAt must consume fallback index zero")
    try expect(preReadyDates["created-malformed"] == secondFallback, "malformed legacy createdAt must consume fallback index one")

    _ = try repository.prepareVersionSequenceMigration()
    _ = try repository.runVersionSequenceMigration(batchSize: 50)
    _ = try repository.prepareItemSequenceMigration()
    _ = try repository.runItemSequenceMigration(
        batchSize: 50,
        observationClock: ItemSequenceObservationClock(dates: fallbackDates)
    )
    let persisted = try database.query("SELECT id, itemCreatedAtSortKey FROM prompt_items;")
    let persistedKeys = Dictionary(uniqueKeysWithValues: persisted.compactMap { row -> (String, Int64)? in
        guard let id = row["id"] ?? nil,
              let rawKey = row["itemCreatedAtSortKey"] ?? nil,
              let key = Int64(rawKey) else { return nil }
        return (id, key)
    })
    for row in legacyRows {
        let expectedDate: Date
        if let parsed = PromptItemCreatedAtSupport.date(from: row.raw)
            ?? legacyFormatter.date(from: row.raw) {
            expectedDate = parsed
        } else if row.id == "created-empty" {
            expectedDate = firstFallback
        } else {
            expectedDate = secondFallback
        }
        try expect(
            persistedKeys[row.id] == PromptItemCreatedAtSupport.sortKey(for: expectedDate),
            "migration and pre-ready loader must classify raw createdAt identically: \(row.raw.debugDescription)"
        )
    }
}

func testPromptRepositoryLegacyLenientCreatedAtValuesStayMigrationCompatible() throws {
    let legacyRows: [(id: String, raw: String)] = [
        ("created-z", "2026-01-01T00:00:00+24:00"),
        ("created-short-fraction", "0000-01-01T00:00:00Z"),
        ("created-long-fraction", "2026-01-01T00:00:00Z\n"),
        ("created-offset", "2026-01-01T00:00:00+0000"),
        ("created-empty", ""),
        ("created-malformed", "not-a-date")
    ]
    let firstFallback = Date(timeIntervalSince1970: 2_600_000_000)
    let secondFallback = Date(timeIntervalSince1970: 2_600_000_001)
    let fallbackDates = [firstFallback, secondFallback]
    let (repository, database) = try createdAtCompatibilityRepository(
        legacyObservationClock: ItemSequenceObservationClock(dates: fallbackDates)
    )
    for row in legacyRows {
        try database.run(
            "UPDATE prompt_items SET createdAt = ? WHERE id = ?;",
            values: [.text(row.raw), .text(row.id)]
        )
    }

    let formatter = ISO8601DateFormatter()
    let accepted = legacyRows.prefix(4).map { row in formatter.date(from: row.raw) }
    try expect(accepted.allSatisfy { $0 != nil }, "legacy formatter must retain the historical lenient values")
    let preReady = try repository.loadItems()
    for (row, expected) in zip(legacyRows.prefix(4), accepted) {
        try expect(
            preReady.first(where: { $0.id == row.id })?.createdAt == expected,
            "pre-ready loader must retain the legacy Date interpretation for \(row.raw.debugDescription)"
        )
    }
    try expect(preReady.first(where: { $0.id == "created-empty" })?.createdAt == firstFallback, "empty value must consume fallback index zero")
    try expect(preReady.first(where: { $0.id == "created-malformed" })?.createdAt == secondFallback, "malformed value must consume fallback index one")

    _ = try repository.prepareVersionSequenceMigration()
    _ = try repository.runVersionSequenceMigration(batchSize: 50)
    _ = try repository.prepareItemSequenceMigration()
    _ = try repository.runItemSequenceMigration(
        batchSize: 50,
        observationClock: ItemSequenceObservationClock(dates: fallbackDates)
    )
    let persisted = try database.query("SELECT id, itemCreatedAtSortKey FROM prompt_items;")
    let persistedKeys = Dictionary(uniqueKeysWithValues: persisted.compactMap { row -> (String, Int64)? in
        guard let id = row["id"] ?? nil,
              let rawKey = row["itemCreatedAtSortKey"] ?? nil,
              let key = Int64(rawKey) else { return nil }
        return (id, key)
    })
    for (row, expected) in zip(legacyRows.prefix(4), accepted) {
        guard let expected else { throw CoreUnitTestError.failure("missing legacy date for \(row.raw.debugDescription)") }
        try expect(
            persistedKeys[row.id] == PromptItemCreatedAtSupport.sortKey(for: expected),
            "migration must preserve legacy Date interpretation for \(row.raw.debugDescription)"
        )
    }
}

func testItemCreatedAtCompatibilityFreezePreReadySummaryFailsClosed() async throws {
    let (repository, _) = try createdAtCompatibilityRepository()
    let connection = try SQLiteReadConnection(path: repository.databaseURL.path)
    let service = LibraryQueryService(executor: connection, repository: repository)
    do {
        _ = try await service.query(LibraryQuery(.all, pageSize: 20))
        throw CoreUnitTestError.failure("pre-ready Summary must fail closed before item date keys are durable")
    } catch LibraryQuerySQLBuilderError.versionSequenceNotReady, LibraryQuerySQLBuilderError.itemSequenceNotReady {
        // Expected: no pre-ready Summary/paged fallback is allowed.
    }
}

func testItemCreatedAtCompatibilityFreezeMicrosecondRoundTripAndOrdering() async throws {
    let (repository, database) = try createdAtCompatibilityRepository()
    try runCreatedAtMigrations(repository)
    let rows = try database.query(
        "SELECT id, itemCreatedAtSortKey FROM prompt_items ORDER BY itemCreatedAtSortKey DESC, itemSequence ASC;"
    )
    let keys = rows.reduce(into: [String: Int64]()) { result, row in
        if let key = Int64(createdAtRowValue(row, "itemCreatedAtSortKey")) {
            result[createdAtRowValue(row, "id")] = key
        }
    }
    try expect(keys["created-long-fraction"] == 1_767_225_600_123_456, "fractional ISO8601 must retain epoch microseconds")
    try expect(keys["created-short-fraction"] == 1_767_225_600_100_000, "short fractional ISO8601 must retain epoch microseconds")
    let detail = try await repository.itemDetail(id: "created-long-fraction")
    let expected = Date(timeIntervalSince1970: 1_767_225_600.123456)
    guard let actual = detail?.createdAt else {
        throw CoreUnitTestError.failure("fractional detail should be present")
    }
    let error = abs(actual.timeIntervalSince(expected))
    try expect(error <= 0.5e-6, "Date→microseconds→Date quantization error must be at most half a microsecond, got \(error)")
    try expect(
        rows.map { createdAtRowValue($0, "id") }.contains("created-offset"),
        "offset timestamps must remain in persisted ordering rather than falling back"
    )
}

func testItemCreatedAtCompatibilityFreezeMicrosecondHelperRangeAndPrecision() throws {
    let productRangeDates = [
        Date(timeIntervalSince1970: -2_208_988_800.123456), // 1900
        Date(timeIntervalSince1970: 0.000001),
        Date(timeIntervalSince1970: 1_767_225_600.123456), // 2026
        Date(timeIntervalSince1970: 4_102_444_800.654321) // 2100
    ]
    for original in productRangeDates {
        let key = PromptItemCreatedAtSupport.sortKey(for: original)
        let roundTripped = PromptItemCreatedAtSupport.date(forSortKey: key)
        try expect(
            PromptItemCreatedAtSupport.quantizationError(for: original) <= 0.5e-6,
            "epoch microsecond round-trip must stay within half a microsecond"
        )
        try expect(roundTripped == PromptItemCreatedAtSupport.date(forSortKey: key), "persisted key decoding must be deterministic")
    }

    let maxRangeDate = Date(timeIntervalSince1970: Double(Int64.max) / 1_000_000)
    let minRangeDate = Date(timeIntervalSince1970: Double(Int64.min) / 1_000_000)
    try expect(PromptItemCreatedAtSupport.sortKey(for: maxRangeDate) == Int64.max, "positive epoch-microsecond overflow must clamp")
    try expect(PromptItemCreatedAtSupport.sortKey(for: minRangeDate) == Int64.min, "negative epoch-microsecond overflow must clamp")

    let base = Date(timeIntervalSince1970: 1_767_225_600)
    let first = base.addingTimeInterval(0.10e-6)
    let second = base.addingTimeInterval(0.40e-6)
    let firstKey = PromptItemCreatedAtSupport.sortKey(for: first)
    let secondKey = PromptItemCreatedAtSupport.sortKey(for: second)
    if first != second && firstKey == secondKey {
        try expect(
            PromptItemCreatedAtSupport.quantizationError(for: first) > 0 || PromptItemCreatedAtSupport.quantizationError(for: second) > 0,
            "sub-microsecond values that fold to one key must report quantization error"
        )
    }
}
