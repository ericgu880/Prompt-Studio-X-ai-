import Foundation
import CryptoKit
import PromptStudioCore

private func itemSequenceFixture(id: String, createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> PromptItem {
    var item = sampleItem(title: "Item sequence \(id)", prompt: "prompt")
    item.id = id
    item.createdAt = createdAt
    item.updatedAt = createdAt
    item.lastUsedAt = createdAt
    item.sortOrder = 0
    item.versions = []
    return item
}

private func itemSequenceValue(_ row: [String: String?], _ key: String) -> String {
    guard let value = row[key] ?? nil else { return "" }
    return value
}

private final class ItemSequenceErrorState: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Error] = []

    func append(_ error: Error) {
        lock.lock()
        values.append(error)
        lock.unlock()
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return values.isEmpty
    }
}

private final class ReentrantMigrationWriterState: @unchecked Sendable {
    private let lock = NSLock()
    private var didWriteValue = false
    private var errorValue: Error?

    func markDidWrite() {
        lock.withLock { didWriteValue = true }
    }

    func record(_ error: Error) {
        lock.withLock { errorValue = error }
    }

    var didWrite: Bool {
        lock.withLock { didWriteValue }
    }

    var error: Error? {
        lock.withLock { errorValue }
    }
}

private final class InvalidationEventState: @unchecked Sendable {
    private let lock = NSLock()
    private var fullInvalidationCountValue = 0

    func append(_ event: ItemDetailInvalidationEvent) {
        guard event.invalidateAll else { return }
        lock.withLock { fullInvalidationCountValue += 1 }
    }

    var fullInvalidationCount: Int {
        lock.withLock { fullInvalidationCountValue }
    }
}

func testItemSequenceSummaryFailsClosedBeforeReady() throws {
    do {
        _ = try LibraryQuerySQLBuilder.build(
            LibraryQuery(pageSize: 10),
            capabilities: LibraryQueryCapabilities(versionSequenceReady: true, itemSequenceReady: false)
        )
        throw CoreUnitTestError.failure("Summary must fail closed before item-sequence readiness")
    } catch LibraryQuerySQLBuilderError.itemSequenceNotReady {
        return
    }
}

func testItemSequenceMigrationPreservesEqualKeyInsertionOrder() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    try repository.saveItems([
        itemSequenceFixture(id: "z", createdAt: date),
        itemSequenceFixture(id: "a", createdAt: date),
        itemSequenceFixture(id: "m", createdAt: date)
    ])
    let prepared = try repository.prepareItemSequenceMigration()
    try expect(prepared.phase == .backfilling, "item migration must remain gated during preparation")
    let result = try repository.runItemSequenceMigration(batchSize: 2)
    try expect(result.completed, "item migration should complete")
    try expect(repository.itemSequenceMigrationReady, "item migration gate should open after finalization")
    let database = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    let rows = try database.query("SELECT id, itemSequence, itemCreatedAtSortKey FROM prompt_items ORDER BY sortOrder ASC, itemCreatedAtSortKey DESC, itemSequence ASC;")
    try expect(rows.map { itemSequenceValue($0, "id") } == ["z", "a", "m"], "equal keys must preserve insertion order")
    try expect(rows.compactMap { Int(itemSequenceValue($0, "itemSequence")) } == [1, 2, 3], "item sequence must be contiguous")
    let original = try database.query("SELECT createdAt FROM prompt_items WHERE id = 'z';").first?["createdAt"] ?? nil
    try expect(original == "2023-11-14T22:13:20Z", "migration must not rewrite raw createdAt")
}

func testItemSequenceMigrationPreservesReverseEqualKeyInsertionOrder() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    try repository.saveItems([
        itemSequenceFixture(id: "m-reverse", createdAt: date),
        itemSequenceFixture(id: "a-reverse", createdAt: date),
        itemSequenceFixture(id: "z-reverse", createdAt: date)
    ])
    _ = try repository.prepareItemSequenceMigration()
    _ = try repository.runItemSequenceMigration(batchSize: 1)
    let database = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    let rows = try database.query("SELECT id, itemSequence FROM prompt_items ORDER BY itemCreatedAtSortKey DESC, itemSequence ASC;")
    try expect(rows.map { itemSequenceValue($0, "id") } == ["m-reverse", "a-reverse", "z-reverse"], "reverse equal keys must preserve insertion order")
    try expect(rows.compactMap { Int(itemSequenceValue($0, "itemSequence")) } == [1, 2, 3], "reverse equal keys must use ascending sequence tie order")
}

func testItemSequenceMigrationPublishesInvalidationAfterLockForReentrantWriter() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    try repository.saveItem(itemSequenceFixture(id: "migration-reentrant-source"))
    let state = ReentrantMigrationWriterState()
    let finished = DispatchSemaphore(value: 0)
    let subscription = repository.itemDetailInvalidationHub.subscribe { event in
        guard event.invalidateAll else { return }
        do {
            try repository.saveItem(itemSequenceFixture(id: "migration-reentrant-write"))
            state.markDidWrite()
        } catch {
            state.record(error)
        }
    }
    DispatchQueue.global(qos: .userInitiated).async {
        do {
            _ = try repository.prepareItemSequenceMigration()
            _ = try repository.runItemSequenceMigration(batchSize: 50)
        } catch {
            state.record(error)
        }
        finished.signal()
    }

    try expect(
        finished.wait(timeout: .now() + .seconds(3)) == .success,
        "item migration must finish when invalidateAll subscribers perform a repository write"
    )
    try expect(state.error == nil, "reentrant migration writer must not fail: \(String(describing: state.error))")
    try expect(state.didWrite, "invalidation callback must be able to write after migration lock release")
    subscription.cancel()
}

func testItemSequenceStaticRollbackInvalidatesHubAfterClosedReservationReleases() throws {
    let libraryURL = try temporaryLibraryURL()
    let hub = ItemDetailInvalidationHub.shared(for: libraryURL)
    let events = InvalidationEventState()
    let subscription = hub.subscribe { events.append($0) }
    do {
        let repository = try PromptRepository(libraryURL: libraryURL)
        try repository.saveItem(itemSequenceFixture(id: "rollback-hub"))
        _ = try repository.prepareVersionSequenceMigration()
        _ = try repository.runVersionSequenceMigration(batchSize: 10)
        _ = try repository.prepareItemSequenceMigration()
        _ = try repository.runItemSequenceMigration(batchSize: 10)
    }

    let beforeRollbackCount = events.fullInvalidationCount
    _ = try PromptRepository.rollbackItemSequenceMigration(at: libraryURL)
    try expect(
        events.fullInvalidationCount == beforeRollbackCount + 1,
        "successful static rollback must invalidate live hub caches after reservation release"
    )
    subscription.cancel()
}

func testItemSequenceStaticRollbackRejectsLiveCustomHubRepository() throws {
    let libraryURL = try temporaryLibraryURL()
    let customHub = ItemDetailInvalidationHub(libraryURL: libraryURL)
    let repository = try PromptRepository(libraryURL: libraryURL, itemDetailInvalidationHub: customHub)
    try repository.saveItem(itemSequenceFixture(id: "rollback-custom-hub"))
    _ = try repository.prepareVersionSequenceMigration()
    _ = try repository.runVersionSequenceMigration(batchSize: 10)
    _ = try repository.prepareItemSequenceMigration()
    _ = try repository.runItemSequenceMigration(batchSize: 10)

    do {
        _ = try PromptRepository.rollbackItemSequenceMigration(at: libraryURL)
        throw CoreUnitTestError.failure("static rollback must reject a live repository with an injected custom hub")
    } catch ItemSequenceMigrationError.rollbackConflict {
        // The repository lease protects its custom hub/controller owner.  A
        // live custom hub therefore cannot outlive the closed-library restore;
        // callers must close it before static rollback can publish the shared
        // post-reservation invalidation.
    }
}

func testItemSequenceTimestampFallbackIsPersisted() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let item = itemSequenceFixture(id: "malformed")
    try repository.saveItem(item)
    let database = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    try database.run("UPDATE prompt_items SET createdAt = ? WHERE id = ?;", values: [.text("legacy-date"), .text(item.id)])
    let fallback = Date(timeIntervalSince1970: 42)
    _ = try repository.prepareItemSequenceMigration()
    _ = try repository.runItemSequenceMigration(observationClock: ItemSequenceObservationClock(dates: [fallback]))
    let row = try database.query("SELECT createdAt, itemCreatedAtSortKey FROM prompt_items WHERE id = ?;", values: [.text(item.id)]).first ?? [:]
    try expect(itemSequenceValue(row, "createdAt") == "legacy-date", "malformed raw createdAt must remain unchanged")
    try expect(Int64(itemSequenceValue(row, "itemCreatedAtSortKey")) == 42_000_000, "fallback Date must be persisted as microseconds")
}

func testItemSequenceTimestampOraclePreservesDateSemanticsAndRawFields() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let rawCreated: [(String, String)] = [
        ("oracle-offset", "2024-01-01T01:00:00+01:00"),
        ("oracle-z", "2024-01-01T00:00:00Z"),
        ("oracle-fraction-short", "2024-01-01T00:00:00.1Z"),
        ("oracle-fraction-medium", "2024-01-01T00:00:00.12Z"),
        ("oracle-fraction-long", "2024-01-01T00:00:00.123456Z"),
        ("oracle-malformed", "not-a-date"),
        ("oracle-empty", "")
    ]
    try repository.saveItems(rawCreated.map { itemSequenceFixture(id: $0.0) })
    let database = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    for (id, raw) in rawCreated {
        try database.run(
            "UPDATE prompt_items SET createdAt = ?, lastUsedAt = ? WHERE id = ?;",
            values: [.text(raw), .text(raw), .text(id)]
        )
    }
    _ = try repository.prepareVersionSequenceMigration()
    _ = try repository.runVersionSequenceMigration(batchSize: 50)
    let fallbackDates = (0..<5).map { Date(timeIntervalSince1970: 2_000_000_000 + Double($0)) }
    _ = try repository.prepareItemSequenceMigration()
    _ = try repository.runItemSequenceMigration(
        batchSize: 50,
        observationClock: ItemSequenceObservationClock(dates: fallbackDates)
    )

    let rows = try database.query("SELECT id,createdAt,lastUsedAt,itemCreatedAtSortKey,itemLastUsedAtSortKey,itemSequence FROM prompt_items ORDER BY itemCreatedAtSortKey DESC,itemSequence ASC;")
    var fallbackIndex = 0
    let expectedKeys = rawCreated.enumerated().map { (index, pair) -> (String, Int64, Int) in
        let parsed = PromptItemCreatedAtSupport.date(from: pair.1)
        let date = parsed ?? fallbackDates[fallbackIndex]
        if parsed == nil { fallbackIndex += 1 }
        return (pair.0, Int64((date.timeIntervalSince1970 * 1_000_000).rounded()), index)
    }.sorted { lhs, rhs in lhs.1 != rhs.1 ? lhs.1 > rhs.1 : lhs.2 < rhs.2 }
    try expect(rows.map { itemSequenceValue($0, "id") } == expectedKeys.map(\.0), "persisted timestamp order must match the legacy Date parser plus deterministic fallback")
    for (id, raw) in rawCreated {
        guard let row = rows.first(where: { itemSequenceValue($0, "id") == id }) else {
            throw CoreUnitTestError.failure("timestamp oracle row missing: \(id)")
        }
        try expect(itemSequenceValue(row, "createdAt") == raw && itemSequenceValue(row, "lastUsedAt") == raw, "raw date strings must remain untouched for \(id)")
        let expected = expectedKeys.first { $0.0 == id }?.1 ?? 0
        try expect(Int64(itemSequenceValue(row, "itemCreatedAtSortKey")) == expected, "createdAt sort key mismatch for \(id)")
        let expectedLast = ISO8601DateFormatter().date(from: raw).map(PromptItemCreatedAtSupport.sortKey) ?? 0
        try expect(Int64(itemSequenceValue(row, "itemLastUsedAtSortKey")) == expectedLast, "last-used sort key mismatch for \(id)")
    }
    let readySQL = try LibraryQuerySQLBuilder.build(LibraryQuery(pageSize: 20), capabilities: .itemSequence)
    let readyRows = try database.query(readySQL.sql, values: readySQL.values)
    try expect(readyRows.map { itemSequenceValue($0, "id") } == expectedKeys.map(\.0), "ready Summary order must use the persisted timestamp oracle")
}

func testItemSequenceWritersPreserveAndAllocateGlobalOrder() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    try repository.saveItems([
        itemSequenceFixture(id: "first"),
        itemSequenceFixture(id: "second")
    ])
    _ = try repository.prepareItemSequenceMigration()
    _ = try repository.runItemSequenceMigration()
    let database = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    let initial = try database.query("SELECT id,itemSequence FROM prompt_items ORDER BY itemSequence ASC;")
    try expect(initial.compactMap { Int(itemSequenceValue($0, "itemSequence")) } == [1, 2], "initial global sequence should be contiguous")

    var edited = itemSequenceFixture(id: "first", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
    edited.title = "edited"
    try repository.saveItem(edited)
    let editedSequence = try database.query("SELECT itemSequence FROM prompt_items WHERE id='first';").first.map { Int(itemSequenceValue($0, "itemSequence")) } ?? nil
    try expect(editedSequence == 1, "upsert must preserve an existing item sequence")

    try repository.saveItems([
        itemSequenceFixture(id: "batch-z"),
        itemSequenceFixture(id: "batch-a"),
        itemSequenceFixture(id: "batch-m")
    ])
    let batch = try database.query("SELECT id,itemSequence FROM prompt_items WHERE id LIKE 'batch-%' ORDER BY itemSequence ASC;")
    try expect(batch.map { itemSequenceValue($0, "id") } == ["batch-z", "batch-a", "batch-m"], "batch input order must allocate global sequences")
    try repository.permanentlyDelete(itemID: "second")
    try repository.saveItem(itemSequenceFixture(id: "after-delete"))
    let newSequence = try database.query("SELECT itemSequence FROM prompt_items WHERE id='after-delete';").first.map { Int(itemSequenceValue($0, "itemSequence")) } ?? nil
    try expect((newSequence ?? 0) > 5, "hard delete must not recycle a global sequence")

    try repository.updateLastUsed(itemID: "first", at: Date(timeIntervalSince1970: 1_900_000_000))
    let lastUsed = try database.query("SELECT itemLastUsedAtSortKey FROM prompt_items WHERE id='first';").first.map { Int64(itemSequenceValue($0, "itemLastUsedAtSortKey")) } ?? nil
    try expect(lastUsed == 1_900_000_000_000_000, "recent writer must update persisted last-used sort key")
}

func testItemSequenceMigrationResumesAfterWriterAndIsIdempotent() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    try repository.saveItems([
        itemSequenceFixture(id: "resume-a"),
        itemSequenceFixture(id: "resume-b"),
        itemSequenceFixture(id: "resume-c")
    ])
    _ = try repository.prepareItemSequenceMigration()
    let first = try repository.runItemSequenceMigration(batchSize: 1, maxBatches: 1)
    try expect(!first.completed && first.processedCount == 1, "bounded item migration must persist one-row checkpoint")
    let metadata = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    let provisionalBefore = itemSequenceValue(try metadata.query("SELECT provisionalNextSequence FROM item_sequence_migration WHERE id=1;").first ?? [:], "provisionalNextSequence")
    try repository.saveItem(itemSequenceFixture(id: "resume-writer"))
    let provisionalAfter = itemSequenceValue(try metadata.query("SELECT provisionalNextSequence FROM item_sequence_migration WHERE id=1;").first ?? [:], "provisionalNextSequence")
    try expect(Int64(provisionalAfter) == (Int64(provisionalBefore) ?? PromptRepository.itemSequenceProvisionalInitial) + 1, "backfill writer must allocate from the durable provisional metadata counter")
    try repository.markDeleted(itemID: "resume-b", deletedAt: Date(timeIntervalSince1970: 1_701_000_000))
    _ = try repository.runItemSequenceMigration(batchSize: 1)
    try expect(repository.itemSequenceMigrationReady, "resumed item migration must open readiness")
    let database = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    let before = try database.query("SELECT id,itemSequence,itemCreatedAtSortKey,itemLastUsedAtSortKey FROM prompt_items ORDER BY itemSequence ASC;")
    let repeated = try repository.runItemSequenceMigration(batchSize: 1)
    try expect(repeated.completed, "completed item migration must be idempotent")
    let after = try database.query("SELECT id,itemSequence,itemCreatedAtSortKey,itemLastUsedAtSortKey FROM prompt_items ORDER BY itemSequence ASC;")
    try expect(before.map { itemSequenceValue($0, "id") } == after.map { itemSequenceValue($0, "id") }, "repeat migration must preserve row order")
    try expect(after.map { itemSequenceValue($0, "id") } == ["resume-a", "resume-b", "resume-c", "resume-writer"], "historical rows must remain ahead of a writer inserted during backfill")
}

func testItemSequenceBackfillKeepsLegacyLoaderAndFilterOrderUntilReady() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    try repository.saveItems([
        itemSequenceFixture(id: "pre-ready-z", createdAt: date),
        itemSequenceFixture(id: "pre-ready-a", createdAt: date),
        itemSequenceFixture(id: "pre-ready-m", createdAt: date)
    ])
    _ = try repository.prepareItemSequenceMigration()
    _ = try repository.runItemSequenceMigration(batchSize: 1, maxBatches: 1)
    let partial = try repository.loadItems()
    try expect(partial.map(\.id) == ["pre-ready-z", "pre-ready-a", "pre-ready-m"], "pre-ready loadItems must retain legacy row traversal order")
    try expect(partial.allSatisfy { $0.itemSequence == nil && $0.itemCreatedAtSortKey == nil && $0.itemLastUsedAtSortKey == nil }, "pre-ready loadItems must suppress partial item metadata")
    try expect(PromptFiltering.apply(partial, filter: PromptFilter()).map(\.id) == partial.map(\.id), "pre-ready PromptFiltering must retain legacy ordering")
    let partialSnapshot = LibraryFilterSnapshot(items: partial)
    try expect(partialSnapshot.filterSynchronously(PromptFilter()).ids == partial.map(\.id), "pre-ready filter snapshot must retain legacy ordering")

    _ = try repository.runItemSequenceMigration(batchSize: 1)
    let ready = try repository.loadItems()
    try expect(ready.allSatisfy { $0.itemSequence != nil && $0.itemCreatedAtSortKey != nil && $0.itemLastUsedAtSortKey != nil }, "ready loadItems must expose persisted item metadata")
    try expect(ready.map(\.id) == ["pre-ready-z", "pre-ready-a", "pre-ready-m"], "ready loadItems must retain the persisted sequence order")
}

func testItemSequenceMigrationReconcilesLegitimateRelatedTagMutationBetweenBatches() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    try repository.saveItems([
        itemSequenceFixture(id: "related-a"),
        itemSequenceFixture(id: "related-b")
    ])
    _ = try repository.prepareItemSequenceMigration()
    let first = try repository.runItemSequenceMigration(batchSize: 1, maxBatches: 1)
    try expect(!first.completed, "related-fingerprint fixture must remain in backfill after one batch")
    let database = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    let beforeRelated = itemSequenceValue(try database.query("SELECT relatedMigrationFingerprint FROM item_sequence_migration WHERE id=1;").first ?? [:], "relatedMigrationFingerprint")
    try repository.saveTag(Tag(id: "related-tag", name: "related-tag", color: "#fff", count: 1))
    try expect(Int(itemSequenceValue(try database.query("SELECT COUNT(*) AS count FROM tags WHERE id='related-tag';").first ?? [:], "count")) == 1, "tag mutation must persist during item backfill")
    let afterRelated = itemSequenceValue(try database.query("SELECT relatedMigrationFingerprint FROM item_sequence_migration WHERE id=1;").first ?? [:], "relatedMigrationFingerprint")
    try expect(beforeRelated == afterRelated, "checkpoint related fingerprint should remain until migration boundary")
    _ = try repository.runItemSequenceMigration(batchSize: 1)
    try expect(repository.itemSequenceMigrationReady, "legitimate tag mutation must reconcile at the next migration checkpoint")
}

func testItemSequenceMigrationRejectsDirectSQLDriftAfterCheckpointReconciliation() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    try repository.saveItems([
        itemSequenceFixture(id: "drift-a"),
        itemSequenceFixture(id: "drift-b"),
        itemSequenceFixture(id: "drift-c")
    ])
    _ = try repository.prepareItemSequenceMigration()
    _ = try repository.runItemSequenceMigration(batchSize: 1, maxBatches: 1)
    // A first-party writer advances the marker; the next locked batch accepts
    // that complete state as the new checkpoint.
    try repository.saveTag(Tag(id: "drift-tag", name: "drift-tag", color: "#fff", count: 1))
    _ = try repository.runItemSequenceMigration(batchSize: 1, maxBatches: 1)
    let database = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    try database.run("UPDATE prompt_items SET title = 'unmarked SQL drift' WHERE id = 'drift-c';")
    do {
        _ = try repository.runItemSequenceMigration(batchSize: 1)
        throw CoreUnitTestError.failure("direct SQL drift after checkpoint reconciliation must fail closed")
    } catch ItemSequenceMigrationError.migrationFailed {
        // Expected: the marker did not move with the direct SQL write.
    }
}

func testItemSequenceConcurrentRepositoriesAllocateUniqueGlobalSequences() throws {
    let libraryURL = try temporaryLibraryURL()
    let seed = try PromptRepository(libraryURL: libraryURL)
    try seed.saveItems((0..<4).map { itemSequenceFixture(id: "concurrent-seed-\($0)") })
    _ = try seed.prepareItemSequenceMigration()
    _ = try seed.runItemSequenceMigration()
    let repositories = try [PromptRepository(libraryURL: libraryURL), PromptRepository(libraryURL: libraryURL)]
    let errors = ItemSequenceErrorState()
    DispatchQueue.concurrentPerform(iterations: 40) { index in
        do {
            let repository = repositories[index % repositories.count]
            try repository.saveItem(itemSequenceFixture(id: "concurrent-write-\(index)"))
        } catch {
            errors.append(error)
        }
    }
    try expect(errors.isEmpty, "concurrent repositories must allocate without SQLITE busy/constraint failures")
    let database = try SQLiteDatabase(path: seed.databaseURL.path, mode: .existingReadWrite)
    let rows = try database.query("SELECT itemSequence FROM prompt_items;")
    let sequences = rows.compactMap { Int64(itemSequenceValue($0, "itemSequence")) }
    try expect(sequences.count == 44 && Set(sequences).count == sequences.count, "global item sequences must remain unique across repositories")
}

func testItemSequenceConcurrentPrepareCoalescesOneBackup() async throws {
    let libraryURL = try temporaryLibraryURL()
    let seed = try PromptRepository(libraryURL: libraryURL)
    try seed.saveItem(itemSequenceFixture(id: "concurrent-prepare-item"))
    let repositories = try [
        PromptRepository(libraryURL: libraryURL),
        PromptRepository(libraryURL: libraryURL)
    ]
    let tasks = repositories.map { repository in
        Task.detached { try repository.prepareItemSequenceMigration() }
    }
    let first = try await tasks[0].value
    let second = try await tasks[1].value
    try expect(first.backupPath == second.backupPath, "concurrent item prepare calls must coalesce to one backup")
    try expect(first.phase == .backfilling && second.phase == .backfilling, "concurrent item prepare must leave one resumable checkpoint")
    try expect(FileManager.default.fileExists(atPath: first.backupPath), "coalesced item prepare must retain its rollback backup")
}

func testItemSequenceFingerprintScansAreBoundedAcrossManyBatches() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    try repository.saveItems((0..<40).map { itemSequenceFixture(id: "scan-bound-\($0)") })
    _ = try repository.prepareItemSequenceMigration()
    let database = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    try expect(Int(itemSequenceValue(try database.query("SELECT COUNT(*) AS count FROM prompt_items;").first ?? [:], "count")) == 40, "bounded fingerprint fixture must contain 40 rows")
    let before = Int64(itemSequenceValue(try database.query("SELECT fingerprintScanCount FROM item_sequence_migration WHERE id=1;").first ?? [:], "fingerprintScanCount")) ?? 0
    for _ in 0..<40 {
        _ = try repository.runItemSequenceMigration(batchSize: 1, maxBatches: 1)
    }
    let after = Int64(itemSequenceValue(try database.query("SELECT fingerprintScanCount FROM item_sequence_migration WHERE id=1;").first ?? [:], "fingerprintScanCount")) ?? 0
    try expect(after - before <= 2, "ordinary item backfill batches must perform only one final item/related fingerprint pair")

    let dirtyRepository = try PromptRepository(libraryURL: temporaryLibraryURL())
    try dirtyRepository.saveItems((0..<8).map { itemSequenceFixture(id: "scan-dirty-\($0)") })
    _ = try dirtyRepository.prepareItemSequenceMigration()
    let dirtyDatabase = try SQLiteDatabase(path: dirtyRepository.databaseURL.path, mode: .existingReadWrite)
    try expect(Int(itemSequenceValue(try dirtyDatabase.query("SELECT COUNT(*) AS count FROM prompt_items;").first ?? [:], "count")) == 8, "dirty fingerprint fixture must contain 8 rows")
    _ = try dirtyRepository.runItemSequenceMigration(batchSize: 1, maxBatches: 1)
    try dirtyRepository.saveTag(Tag(id: "scan-dirty-tag", name: "scan-dirty-tag", color: "#fff", count: 1))
    _ = try dirtyRepository.runItemSequenceMigration(batchSize: 1, maxBatches: 1)
    while !dirtyRepository.itemSequenceMigrationReady {
        _ = try dirtyRepository.runItemSequenceMigration(batchSize: 1, maxBatches: 1)
    }
    let dirtyCount = Int64(itemSequenceValue(try dirtyDatabase.query("SELECT fingerprintScanCount FROM item_sequence_migration WHERE id=1;").first ?? [:], "fingerprintScanCount")) ?? 0
    try expect(dirtyCount <= 6, "each dirty writer epoch must trigger at most one item/related fingerprint pair")
}

func testItemSequenceHistoricalMaxScanCountIsBoundedAcrossBatches() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    try repository.saveItems((0..<40).map { itemSequenceFixture(id: "historical-max-\($0)") })
    _ = try repository.prepareItemSequenceMigration()
    let database = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    let before = Int64(itemSequenceValue(try database.query("SELECT historicalMaxScanCount FROM item_sequence_migration WHERE id=1;").first ?? [:], "historicalMaxScanCount")) ?? 0
    try expect(before == 1, "prepare should perform exactly one historical MAX scan")
    for _ in 0..<40 {
        _ = try repository.runItemSequenceMigration(batchSize: 1, maxBatches: 1)
    }
    let after = Int64(itemSequenceValue(try database.query("SELECT historicalMaxScanCount FROM item_sequence_migration WHERE id=1;").first ?? [:], "historicalMaxScanCount")) ?? 0
    try expect(after == before, "historical MAX scan count must remain bounded across backfill batches")
}

func testItemSequenceReadinessRejectsMissingIndexAndTriggerContract() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    try repository.saveItem(itemSequenceFixture(id: "contract-corruption"))
    _ = try repository.prepareItemSequenceMigration()
    _ = try repository.runItemSequenceMigration()
    let database = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    try database.execute("DROP INDEX idx_phase2a4_1_prompt_items_item_sequence_unique; CREATE UNIQUE INDEX idx_phase2a4_1_prompt_items_item_sequence_unique ON prompt_items(itemSequence) WHERE itemSequence IS NOT NULL;")
    try expect(!repository.itemSequenceMigrationReady, "ready gate must reject a forged partial global sequence index")
    try database.execute("DROP INDEX idx_phase2a4_1_prompt_items_item_sequence_unique; CREATE UNIQUE INDEX idx_phase2a4_1_prompt_items_item_sequence_unique ON prompt_items(itemSequence);")
    try database.execute("DROP INDEX idx_phase2a4_1_prompt_items_recent;")
    try expect(!repository.itemSequenceMigrationReady, "ready gate must close when the recent persisted index is missing")
    try database.execute("CREATE INDEX idx_phase2a4_1_prompt_items_recent ON prompt_items(itemLastUsedAtSortKey DESC,itemCreatedAtSortKey DESC,itemSequence ASC);")
    try expect(!repository.itemSequenceMigrationReady, "ready gate must reject a forged recent index without the deletedAt partial predicate")
    try database.execute("DROP INDEX idx_phase2a4_1_prompt_items_recent; CREATE INDEX idx_phase2a4_1_prompt_items_recent ON prompt_items(itemLastUsedAtSortKey ASC,itemCreatedAtSortKey DESC,itemSequence ASC) WHERE deletedAt IS NULL;")
    try expect(!repository.itemSequenceMigrationReady, "ready gate must reject a wrong recent index direction")
    try database.execute("DROP INDEX idx_phase2a4_1_prompt_items_recent; DROP TRIGGER prompt_items_require_sequence_update; CREATE TRIGGER prompt_items_require_sequence_update BEFORE UPDATE OF itemSequence,itemCreatedAtSortKey,itemLastUsedAtSortKey ON prompt_items WHEN typeof(NEW.itemSequence)<>'integer' OR typeof(NEW.itemCreatedAtSortKey)<>'integer' OR typeof(NEW.itemLastUsedAtSortKey)<>'integer' BEGIN SELECT RAISE(ABORT,'forged trigger'); END;")
    try expect(!repository.itemSequenceMigrationReady, "ready gate must reject a forged trigger without positive sequence semantics")
    try database.execute("DROP TRIGGER prompt_items_require_sequence_update;")
    try expect(!repository.itemSequenceMigrationReady, "ready gate must close when the sequence update trigger is missing")
}

func testItemSequenceReadinessRejectsExtraIndexPredicateAndTriggerSemantics() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    try repository.saveItem(itemSequenceFixture(id: "contract-extra-predicate"))
    _ = try repository.prepareItemSequenceMigration()
    _ = try repository.runItemSequenceMigration()
    let databasePath = repository.databaseURL.path
    let database = try SQLiteDatabase(path: databasePath, mode: .existingReadWrite)

    let indexes: [(name: String, valid: String, forged: String)] = [
        (
            "idx_phase2a4_1_prompt_items_all",
            "CREATE INDEX idx_phase2a4_1_prompt_items_all ON prompt_items(sortOrder ASC,itemCreatedAtSortKey DESC,itemSequence ASC) WHERE deletedAt IS NULL;",
            "CREATE INDEX idx_phase2a4_1_prompt_items_all ON prompt_items(sortOrder ASC,itemCreatedAtSortKey DESC,itemSequence ASC) WHERE deletedAt IS NULL AND 1=0;"
        ),
        (
            "idx_phase2a4_1_prompt_items_folder",
            "CREATE INDEX idx_phase2a4_1_prompt_items_folder ON prompt_items(folderId,sortOrder ASC,itemCreatedAtSortKey DESC,itemSequence ASC) WHERE deletedAt IS NULL;",
            "CREATE INDEX idx_phase2a4_1_prompt_items_folder ON prompt_items(folderId,sortOrder ASC,itemCreatedAtSortKey DESC,itemSequence ASC) WHERE deletedAt IS NULL AND 1=0;"
        ),
        (
            "idx_phase2a4_1_prompt_items_recent",
            "CREATE INDEX idx_phase2a4_1_prompt_items_recent ON prompt_items(itemLastUsedAtSortKey DESC,itemCreatedAtSortKey DESC,itemSequence ASC) WHERE deletedAt IS NULL;",
            "CREATE INDEX idx_phase2a4_1_prompt_items_recent ON prompt_items(itemLastUsedAtSortKey DESC,itemCreatedAtSortKey DESC,itemSequence ASC) WHERE deletedAt IS NULL AND 1=0;"
        ),
        (
            "idx_phase2a4_1_prompt_items_trash",
            "CREATE INDEX idx_phase2a4_1_prompt_items_trash ON prompt_items(sortOrder ASC,itemCreatedAtSortKey DESC,itemSequence ASC) WHERE deletedAt IS NOT NULL;",
            "CREATE INDEX idx_phase2a4_1_prompt_items_trash ON prompt_items(sortOrder ASC,itemCreatedAtSortKey DESC,itemSequence ASC) WHERE deletedAt IS NOT NULL AND 1=0;"
        )
    ]
    for index in indexes {
        try database.execute("DROP INDEX \(index.name); \(index.forged)")
        try expect(!PromptRepository.itemSequenceRuntimeReady(at: databasePath), "runtime readiness must reject extra predicate on \(index.name)")
        try expect(!repository.itemSequenceMigrationReady, "repository readiness must reject extra predicate on \(index.name)")
        try database.execute("DROP INDEX \(index.name); \(index.valid)")
    }

    let forgedQuotedAll = "CREATE INDEX idx_phase2a4_1_prompt_items_all ON prompt_items(sortOrder ASC,itemCreatedAtSortKey DESC,itemSequence ASC) WHERE deletedAt IS \"NULL\";"
    let validAll = indexes[0].valid
    try database.execute("DROP INDEX idx_phase2a4_1_prompt_items_all; \(forgedQuotedAll)")
    try expect(!PromptRepository.itemSequenceRuntimeReady(at: databasePath), "runtime readiness must reject a quoted string literal in the all predicate")
    try expect(!repository.itemSequenceMigrationReady, "repository readiness must reject a quoted string literal in the all predicate")
    try database.execute("DROP INDEX idx_phase2a4_1_prompt_items_all; \(validAll)")

    let validInsert = "CREATE TRIGGER prompt_items_require_sequence_insert BEFORE INSERT ON prompt_items WHEN typeof(NEW.itemSequence)<>'integer' OR NEW.itemSequence<=0 OR typeof(NEW.itemCreatedAtSortKey)<>'integer' OR typeof(NEW.itemLastUsedAtSortKey)<>'integer' BEGIN SELECT RAISE(ABORT,'item sequence/date metadata must be integer'); END;"
    let forgedInsert = "CREATE TRIGGER prompt_items_require_sequence_insert BEFORE INSERT ON prompt_items WHEN (typeof(NEW.itemSequence)<>'integer' OR NEW.itemSequence<=0 OR typeof(NEW.itemCreatedAtSortKey)<>'integer' OR typeof(NEW.itemLastUsedAtSortKey)<>'integer') AND 1=0 BEGIN SELECT RAISE(ABORT,'item sequence/date metadata must be integer'); END;"
    try database.execute("DROP TRIGGER prompt_items_require_sequence_insert; \(forgedInsert)")
    try expect(!PromptRepository.itemSequenceRuntimeReady(at: databasePath), "runtime readiness must reject an insert trigger with an extra condition")
    try expect(!repository.itemSequenceMigrationReady, "repository readiness must reject an insert trigger with an extra condition")
    try database.execute("DROP TRIGGER prompt_items_require_sequence_insert; \(validInsert)")

    let validUpdate = "CREATE TRIGGER prompt_items_require_sequence_update BEFORE UPDATE OF itemSequence,itemCreatedAtSortKey,itemLastUsedAtSortKey ON prompt_items WHEN typeof(NEW.itemSequence)<>'integer' OR NEW.itemSequence<=0 OR typeof(NEW.itemCreatedAtSortKey)<>'integer' OR typeof(NEW.itemLastUsedAtSortKey)<>'integer' BEGIN SELECT RAISE(ABORT,'item sequence/date metadata must be integer'); END;"
    let forgedUpdate = "CREATE TRIGGER prompt_items_require_sequence_update BEFORE UPDATE OF itemSequence,itemCreatedAtSortKey,itemLastUsedAtSortKey ON prompt_items WHEN (typeof(NEW.itemSequence)<>'integer' OR NEW.itemSequence<=0 OR typeof(NEW.itemCreatedAtSortKey)<>'integer' OR typeof(NEW.itemLastUsedAtSortKey)<>'integer') AND 1=0 BEGIN SELECT RAISE(ABORT,'item sequence/date metadata must be integer'); END;"
    try database.execute("DROP TRIGGER prompt_items_require_sequence_update; \(forgedUpdate)")
    try expect(!PromptRepository.itemSequenceRuntimeReady(at: databasePath), "runtime readiness must reject an update trigger with an extra condition")
    try expect(!repository.itemSequenceMigrationReady, "repository readiness must reject an update trigger with an extra condition")
    try database.execute("DROP TRIGGER prompt_items_require_sequence_update; \(validUpdate)")

    let forgedBodyUpdate = "CREATE TRIGGER prompt_items_require_sequence_update BEFORE UPDATE OF itemSequence,itemCreatedAtSortKey,itemLastUsedAtSortKey ON prompt_items WHEN typeof(NEW.itemSequence)<>'integer' OR NEW.itemSequence<=0 OR typeof(NEW.itemCreatedAtSortKey)<>'integer' OR typeof(NEW.itemLastUsedAtSortKey)<>'integer' BEGIN SELECT RAISE(ABORT,'item sequence/date metadata must be integer]'); END;"
    try database.execute("DROP TRIGGER prompt_items_require_sequence_update; \(forgedBodyUpdate)")
    try expect(!PromptRepository.itemSequenceRuntimeReady(at: databasePath), "runtime readiness must reject a trigger with an altered RAISE body")
    try expect(!repository.itemSequenceMigrationReady, "repository readiness must reject a trigger with an altered RAISE body")
    try database.execute("DROP TRIGGER prompt_items_require_sequence_update; \(validUpdate)")
}

func testItemSequenceFinalizeRejectsCorruptMetadata() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    try repository.saveItems([
        itemSequenceFixture(id: "corrupt-a"),
        itemSequenceFixture(id: "corrupt-b")
    ])
    _ = try repository.prepareItemSequenceMigration()
    _ = try repository.runItemSequenceMigration(batchSize: 1, maxBatches: 1)
    let database = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    try database.run("UPDATE prompt_items SET itemCreatedAtSortKey = NULL WHERE id = ?;", values: [.text("corrupt-a")])
    do {
        _ = try repository.runItemSequenceMigration(batchSize: 1)
        throw CoreUnitTestError.failure("finalization must reject NULL persisted item metadata")
    } catch ItemSequenceMigrationError.migrationFailed, ItemSequenceMigrationError.schemaNotReady {
        // Expected: the migration remains gated and records failure.
    }
}

func testItemSequenceReadySurvivesReopenVacuumAndRuntimeProbe() throws {
    let libraryURL = try temporaryLibraryURL()
    let databasePath = libraryURL.appendingPathComponent("database/promptstudio.sqlite").path
    do {
        let repository = try PromptRepository(libraryURL: libraryURL)
        try repository.saveItems((0..<5).map { itemSequenceFixture(id: "vacuum-\($0)") })
        _ = try repository.prepareItemSequenceMigration()
        _ = try repository.runItemSequenceMigration(batchSize: 2)
        try expect(repository.itemSequenceMigrationReady, "item migration should be ready before VACUUM")
    }
    let database = try SQLiteDatabase(path: databasePath, mode: .existingReadWrite)
    try database.execute("VACUUM;")
    try expect(PromptRepository.itemSequenceRuntimeReady(at: databasePath), "runtime probe should remain ready after VACUUM")
    let reopened = try PromptRepository(libraryURL: libraryURL)
    let rows = try database.query("SELECT id,itemSequence FROM prompt_items ORDER BY itemSequence ASC;")
    try expect(rows.map { itemSequenceValue($0, "id") } == (0..<5).map { "vacuum-\($0)" }, "VACUUM/reopen must preserve persisted sequence order")
    try expect(reopened.itemSequenceMigrationReady, "reopened repository should retain item readiness")
}

func testItemSequenceReadyLegacyLoaderAndFilterSnapshotUsePersistedOrderAfterReopen() throws {
    let libraryURL = try temporaryLibraryURL()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    do {
        let repository = try PromptRepository(libraryURL: libraryURL)
        try repository.saveItems([
            itemSequenceFixture(id: "loader-z", createdAt: date),
            itemSequenceFixture(id: "loader-a", createdAt: date),
            itemSequenceFixture(id: "loader-m", createdAt: date)
        ])
        _ = try repository.prepareItemSequenceMigration()
        _ = try repository.runItemSequenceMigration(batchSize: 1)
    }
    let database = try SQLiteDatabase(path: libraryURL.appendingPathComponent("database/promptstudio.sqlite").path, mode: .existingReadWrite)
    try database.execute("VACUUM;")
    let reopened = try PromptRepository(libraryURL: libraryURL)
    let expected = ["loader-z", "loader-a", "loader-m"]
    let loaded = try reopened.loadItems()
    try expect(loaded.map(\.id) == expected, "ready loadItems must use persisted sortOrder/createdAt/itemSequence after VACUUM")
    try expect(loaded.allSatisfy { $0.itemSequence != nil && $0.itemCreatedAtSortKey != nil && $0.itemLastUsedAtSortKey != nil }, "ready PromptItem values must carry persisted order metadata")
    try expect(PromptFiltering.apply(loaded, filter: PromptFilter()).map(\.id) == expected, "legacy filtering must preserve persisted equal-key order")
    let snapshot = LibraryFilterSnapshot(items: loaded)
    try expect(snapshot.filterSynchronously(PromptFilter()).ids == expected, "filter snapshot must preserve persisted equal-key order")
}

func testItemSequenceReadyComparatorsIgnoreRawDateWhenPersistedKeysTie() throws {
    var first = itemSequenceFixture(id: "comparator-first", createdAt: Date(timeIntervalSince1970: 1_000))
    first.itemSequence = 1
    first.itemCreatedAtSortKey = 2_000_000
    first.itemLastUsedAtSortKey = 0
    var second = itemSequenceFixture(id: "comparator-second", createdAt: Date(timeIntervalSince1970: 9_000))
    second.itemSequence = 2
    second.itemCreatedAtSortKey = 2_000_000
    second.itemLastUsedAtSortKey = 0
    let items = [second, first]
    let expected = ["comparator-first", "comparator-second"]
    try expect(PromptFiltering.apply(items, filter: PromptFilter()).map(\.id) == expected, "persisted createdAt tie must advance directly to itemSequence")
    let snapshot = LibraryFilterSnapshot(items: items)
    try expect(snapshot.filterSynchronously(PromptFilter()).ids == expected, "snapshot persisted createdAt tie must advance directly to itemSequence")
}

func testItemSequenceAllocatorFailsClosedAtInt64Maximum() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    _ = try repository.prepareItemSequenceMigration()
    _ = try repository.runItemSequenceMigration()
    let database = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    try database.run("UPDATE item_sequence_migration SET nextSequence = ? WHERE id = 1;", values: [.int(Int64.max)])
    do {
        try repository.saveItem(itemSequenceFixture(id: "overflow-item"))
        throw CoreUnitTestError.failure("allocator must reject Int64.max without inserting a row")
    } catch SQLiteError.stepFailed {
        // Expected: sequence exhaustion is fail-closed at the writer boundary.
    }
    try expect(try database.query("SELECT 1 FROM prompt_items WHERE id='overflow-item';").isEmpty, "overflow rejection must not leave a prompt row")
    try expect(itemSequenceValue(try database.query("SELECT nextSequence FROM item_sequence_migration WHERE id=1;").first ?? [:], "nextSequence") == String(Int64.max), "overflow rejection must not advance metadata")
}

func testItemSequenceProvisionalAllocatorFailsClosedAtInt64Maximum() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    try repository.saveItem(itemSequenceFixture(id: "provisional-seed"))
    _ = try repository.prepareItemSequenceMigration()
    let database = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    try database.run("UPDATE item_sequence_migration SET provisionalNextSequence = ? WHERE id = 1;", values: [.int(Int64.max)])
    do {
        try repository.saveItem(itemSequenceFixture(id: "provisional-overflow"))
        throw CoreUnitTestError.failure("provisional allocator must reject Int64.max without inserting a row")
    } catch SQLiteError.stepFailed {
        // Expected: the durable provisional counter is bounded fail-closed.
    }
    try expect(try database.query("SELECT 1 FROM prompt_items WHERE id='provisional-overflow';").isEmpty, "provisional overflow must not leave a prompt row")
    try expect(itemSequenceValue(try database.query("SELECT provisionalNextSequence FROM item_sequence_migration WHERE id=1;").first ?? [:], "provisionalNextSequence") == String(Int64.max), "provisional overflow must not advance metadata")
}

func testItemSequenceRollbackRejectsPostBackupBusinessAndRelatedMutations() throws {
    let libraryURL = try temporaryLibraryURL()
    do {
        let repository = try PromptRepository(libraryURL: libraryURL)
        try repository.saveItem(itemSequenceFixture(id: "rollback-coexistence"))
        _ = try repository.prepareVersionSequenceMigration()
        _ = try repository.runVersionSequenceMigration(batchSize: 10)
        _ = try repository.prepareItemSequenceMigration()
        _ = try repository.runItemSequenceMigration(batchSize: 10)
    }
    do {
        let repository = try PromptRepository(libraryURL: libraryURL)
        try repository.saveTag(Tag(id: "rollback-related", name: "rollback-related", color: "#fff", count: 1))
        var edited = itemSequenceFixture(id: "rollback-coexistence")
        edited.title = "post-backup business mutation"
        try repository.saveItem(edited)
    }
    do {
        _ = try PromptRepository.rollbackItemSequenceMigration(at: libraryURL)
        throw CoreUnitTestError.failure("item rollback must reject tag/business mutations after backup")
    } catch ItemSequenceMigrationError.rollbackConflict {
        // Expected: whole-file restore is closed once any related/business
        // payload changed after the item backup.
    }
}

func testItemSequenceRollbackRejectsWriterDuringBackfillAndPreservesWriter() throws {
    let libraryURL = try temporaryLibraryURL()
    do {
        let repository = try PromptRepository(libraryURL: libraryURL)
        try repository.saveItems([
            itemSequenceFixture(id: "rollback-writer-history-a"),
            itemSequenceFixture(id: "rollback-writer-history-b")
        ])
        _ = try repository.prepareItemSequenceMigration()
        _ = try repository.runItemSequenceMigration(batchSize: 1, maxBatches: 1)
        try repository.saveItem(itemSequenceFixture(id: "rollback-writer-during-backfill"))
        try repository.saveTag(Tag(id: "rollback-writer-tag", name: "rollback-writer-tag", color: "#fff", count: 1))
        _ = try repository.runItemSequenceMigration(batchSize: 1)
        try expect(repository.itemSequenceMigrationReady, "backfill writer fixture must reach ready")
    }
    do {
        _ = try PromptRepository.rollbackItemSequenceMigration(at: libraryURL)
        throw CoreUnitTestError.failure("rollback must fail closed after a first-party writer during backfill")
    } catch ItemSequenceMigrationError.rollbackConflict {
        let repository = try PromptRepository(libraryURL: libraryURL)
        let rows = try repository.loadItems()
        try expect(rows.contains { $0.id == "rollback-writer-during-backfill" }, "rollback refusal must preserve the backfill writer row")
        try expect(try repository.loadTags().contains { $0.id == "rollback-writer-tag" }, "rollback refusal must preserve the related writer mutation")
    }

    let directDriftURL = try temporaryLibraryURL()
    do {
        let repository = try PromptRepository(libraryURL: directDriftURL)
        try repository.saveItem(itemSequenceFixture(id: "rollback-direct-drift"))
        _ = try repository.prepareItemSequenceMigration()
        _ = try repository.runItemSequenceMigration(batchSize: 10)
    }
    let directDatabase = try SQLiteDatabase(path: directDriftURL.appendingPathComponent("database/promptstudio.sqlite").path, mode: .existingReadWrite)
    try directDatabase.run("UPDATE prompt_items SET title='direct drift after ready' WHERE id='rollback-direct-drift';")
    do {
        _ = try PromptRepository.rollbackItemSequenceMigration(at: directDriftURL)
        throw CoreUnitTestError.failure("rollback must fail closed after direct SQL drift")
    } catch ItemSequenceMigrationError.rollbackConflict {
        let preserved = try directDatabase.query("SELECT title FROM prompt_items WHERE id='rollback-direct-drift';").first?["title"] ?? nil
        try expect(preserved == "direct drift after ready", "rollback refusal must preserve direct SQL drift")
    }
}

func testItemSequenceBackfillMutationMatrixReconcilesWritersAndFields() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    try repository.saveItems([
        itemSequenceFixture(id: "matrix-a", createdAt: date),
        itemSequenceFixture(id: "matrix-b", createdAt: date),
        itemSequenceFixture(id: "matrix-c", createdAt: date),
        itemSequenceFixture(id: "matrix-d", createdAt: date)
    ])
    _ = try repository.prepareItemSequenceMigration()
    _ = try repository.runItemSequenceMigration(batchSize: 1, maxBatches: 1)

    var captured = itemSequenceFixture(id: "matrix-capture", createdAt: date)
    captured.captureID = "matrix-capture-token"
    let winner = try repository.saveCapturedItem(captured)
    let retry = try repository.saveCapturedItem(captured)
    try expect(winner.id == retry.id, "capture retry must return the original winner")

    try repository.saveItems([
        itemSequenceFixture(id: "matrix-batch-z", createdAt: date),
        itemSequenceFixture(id: "matrix-batch-a", createdAt: date)
    ])
    var moved = itemSequenceFixture(id: "matrix-a", createdAt: date)
    moved.folderId = "matrix-folder"
    moved.folderName = "Matrix"
    try repository.updateItemFolders([moved])
    try repository.updateSortOrders([(id: "matrix-b", sortOrder: -4)])
    var favorited = itemSequenceFixture(id: "matrix-c", createdAt: date)
    favorited.favorite = true
    favorited.tags = ["matrix-tag"]
    try repository.saveItem(favorited)
    try repository.updateLastUsed(itemID: "matrix-c", at: Date(timeIntervalSince1970: 1_900_000_000))
    try repository.markDeleted(itemID: "matrix-d", deletedAt: Date(timeIntervalSince1970: 1_901_000_000))
    try repository.markDeleted(itemID: "matrix-d", deletedAt: nil)
    try repository.permanentlyDelete(itemID: "matrix-batch-a")

    _ = try repository.runItemSequenceMigration(batchSize: 1)
    try expect(repository.itemSequenceMigrationReady, "backfill mutation matrix must reach ready")
    let database = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    let rows = try database.query("SELECT id,itemSequence,itemCreatedAtSortKey,itemLastUsedAtSortKey,favorite,folderId,tagsJSON,deletedAt FROM prompt_items ORDER BY itemSequence ASC;")
    try expect(rows.allSatisfy {
        Int64(itemSequenceValue($0, "itemSequence")) != nil
            && Int64(itemSequenceValue($0, "itemCreatedAtSortKey")) != nil
            && Int64(itemSequenceValue($0, "itemLastUsedAtSortKey")) != nil
            && itemSequenceValue($0, "itemSequence") != ""
    }, "writer matrix must leave no NULL sequence/date metadata")
    let sequences = rows.compactMap { Int64(itemSequenceValue($0, "itemSequence")) }
    try expect(sequences == Array(1...Int64(rows.count)), "writer matrix sequences must be contiguous and unique")
    try expect(itemSequenceValue(rows.first { itemSequenceValue($0, "id") == "matrix-a" } ?? [:], "folderId") == "matrix-folder", "move mutation must survive backfill")
    try expect(itemSequenceValue(rows.first { itemSequenceValue($0, "id") == "matrix-c" } ?? [:], "favorite") == "1", "favorite/tag mutation must survive backfill")
    try expect(itemSequenceValue(rows.first { itemSequenceValue($0, "id") == "matrix-c" } ?? [:], "tagsJSON").contains("matrix-tag"), "tag occurrence mutation must survive backfill")
    try expect(rows.first { itemSequenceValue($0, "id") == "matrix-batch-a" } == nil, "permanent delete must remain deleted")
}

func testItemSequenceReadyExplainMatrixUsesPersistedIndexesForPageAndCount() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    var item = itemSequenceFixture(id: "explain-shape")
    item.tags = ["explain-tag"]
    try repository.saveItem(item)
    _ = try repository.prepareVersionSequenceMigration()
    _ = try repository.runVersionSequenceMigration(batchSize: 10)
    _ = try repository.prepareTagRelationMigration()
    _ = try repository.runTagRelationBackfill(batchSize: 10)
    _ = try repository.prepareItemSequenceMigration()
    _ = try repository.runItemSequenceMigration(batchSize: 10)
    let database = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    let capabilities = LibraryQueryCapabilities(tagRelationsReady: true, versionSequenceReady: true, itemSequenceReady: true)
    let shapes: [LibraryQuery] = [
        .all(), .folder(""), .tag("explain-tag"), .type(.image), .model(""), .favorite(), .recent(), .trash(),
        LibraryQuery(.all, type: .image, modelId: "", favoriteOnly: true)
    ]
    for shape in shapes {
        let page = try LibraryQuerySQLBuilder.build(shape, capabilities: capabilities)
        let count = try LibraryQuerySQLBuilder.buildCount(shape, capabilities: capabilities)
        let pagePlan = try database.query("EXPLAIN QUERY PLAN \(page.sql)", values: page.values)
        let countPlan = try database.query("EXPLAIN QUERY PLAN \(count.sql)", values: count.values)
        let pageDetails = pagePlan.map { itemSequenceValue($0, "detail") }.joined(separator: "\n")
        let countDetails = countPlan.map { itemSequenceValue($0, "detail") }.joined(separator: "\n")
        try expect(!countDetails.localizedCaseInsensitiveContains("TEMP B-TREE"), "(shape.collection) count must avoid a temporary sort")
        if case .tag = shape.collection {
            try expect(pageDetails.contains("idx_phase2a2_prompt_item_tags_tag_order"), "tag page must use the persisted relation index")
            let scansPromptItems = pagePlan.contains {
                let detail = itemSequenceValue($0, "detail")
                return detail == "SCAN p" || detail.hasPrefix("SCAN p ")
            }
            try expect(!scansPromptItems, "tag page must not scan prompt_items")
            try expect(countDetails.contains("idx_phase2a2_prompt_item_tags_tag_order"), "tag count must use the persisted relation index")
            try expect(!countDetails.localizedCaseInsensitiveContains("SCAN p"), "tag count must not scan prompt_items")
        } else {
            try expect(!pageDetails.localizedCaseInsensitiveContains("TEMP B-TREE"), "(shape.collection) page must avoid a temporary sort")
            try expect(pageDetails.contains("idx_phase2a4_1_prompt_items_"), "(shape.collection) page must use a persisted item index")
            try expect(countDetails.contains("idx_phase2a4_1_prompt_items_"), "(shape.collection) count must use a persisted item index")
        }
    }
}

func testItemSequenceOnlineBackupClonePreservesReadyOrder() throws {
    let libraryURL = try temporaryLibraryURL()
    let clonePath = libraryURL.appendingPathComponent("backups/ready-clone.sqlite").path
    let digest: ([[String: String?]], [[String: String?]]) -> String = { rows, schema in
        var components: [String] = []
        for row in rows + schema {
            for key in row.keys.sorted() {
                components.append(key)
                let value = row[key] ?? nil
                components.append(value ?? "<NULL>")
            }
            components.append("<ROW>")
        }
        let bytes = SHA256.hash(data: Data(components.joined(separator: "\u{1f}").utf8))
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
    var sourceRows: [[String: String?]] = []
    var sourceSchema: [[String: String?]] = []
    var sourceDigest = ""
    do {
        let repository = try PromptRepository(libraryURL: libraryURL)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try repository.saveItems([
            itemSequenceFixture(id: "backup-z", createdAt: date),
            itemSequenceFixture(id: "backup-a", createdAt: date),
            itemSequenceFixture(id: "backup-m", createdAt: date)
        ])
        _ = try repository.prepareVersionSequenceMigration()
        _ = try repository.runVersionSequenceMigration(batchSize: 10)
        _ = try repository.prepareItemSequenceMigration()
        _ = try repository.runItemSequenceMigration(batchSize: 10)
        let source = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
        try source.backup(to: clonePath)
        try expect(FileManager.default.fileExists(atPath: clonePath), "online backup must leave a clone file before source handles close")
        sourceRows = try source.query("SELECT * FROM prompt_items ORDER BY rowid ASC;")
        sourceSchema = try source.query("SELECT type,name,sql FROM sqlite_master WHERE name IN ('prompt_items','item_sequence_migration','idx_phase2a4_1_prompt_items_item_sequence_unique','idx_phase2a4_1_prompt_items_all','idx_phase2a4_1_prompt_items_recent') ORDER BY type,name;")
        sourceDigest = digest(sourceRows, sourceSchema)
    }
    do {
        let clone = try SQLiteDatabase(path: clonePath, mode: .existingReadWrite)
        let cloneRows = try clone.query("SELECT * FROM prompt_items ORDER BY rowid ASC;")
        let cloneSchema = try clone.query("SELECT type,name,sql FROM sqlite_master WHERE name IN ('prompt_items','item_sequence_migration','idx_phase2a4_1_prompt_items_item_sequence_unique','idx_phase2a4_1_prompt_items_all','idx_phase2a4_1_prompt_items_recent') ORDER BY type,name;")
        try expect(cloneRows == sourceRows, "online backup clone must preserve all prompt-item order and metadata")
        try expect(digest(cloneRows, cloneSchema) == sourceDigest, "online backup clone must preserve the full persisted metadata hash")
        try expect(try clone.query("PRAGMA integrity_check;").first?["integrity_check"] ?? nil == "ok", "online backup clone must pass integrity_check")
    }

    // Reopen the copied database through the first-party repository path, not
    // just a raw SQLite handle, so readiness and loader behavior are verified
    // across the restore/restart boundary.
    let reopenedLibraryURL = try temporaryLibraryURL()
    let reopenedDatabasePath = reopenedLibraryURL.appendingPathComponent("database/promptstudio.sqlite")
    try expect(FileManager.default.fileExists(atPath: clonePath), "online backup must create a reopenable clone file")
    try FileManager.default.createDirectory(at: reopenedDatabasePath.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(atPath: clonePath, toPath: reopenedDatabasePath.path)
    let reopened = try PromptRepository(libraryURL: reopenedLibraryURL)
    try expect(reopened.itemSequenceMigrationReady, "reopened backup repository must retain item readiness")
    try expect(PromptRepository.itemSequenceRuntimeReady(at: reopened.databaseURL.path), "reopened backup runtime probe must retain item readiness")
    let loaded = try reopened.loadItems()
    try expect(loaded.map(\.id) == ["backup-z", "backup-a", "backup-m"], "reopened backup loader must preserve persisted order")
    try expect(loaded.allSatisfy { $0.itemSequence != nil && $0.itemCreatedAtSortKey != nil && $0.itemLastUsedAtSortKey != nil }, "reopened backup loader must retain persisted metadata")
}

func testItemSequenceRollbackRejectsLaterVersionOrTagMigrationState() throws {
    let versionAfterItemURL = try temporaryLibraryURL()
    do {
        let repository = try PromptRepository(libraryURL: versionAfterItemURL)
        try repository.saveItem(itemSequenceFixture(id: "rollback-version-after-item"))
        _ = try repository.prepareItemSequenceMigration()
        _ = try repository.runItemSequenceMigration(batchSize: 10)
        _ = try repository.prepareVersionSequenceMigration()
        _ = try repository.runVersionSequenceMigration(batchSize: 10)
    }
    do {
        _ = try PromptRepository.rollbackItemSequenceMigration(at: versionAfterItemURL)
        throw CoreUnitTestError.failure("item rollback must reject a later version migration state")
    } catch ItemSequenceMigrationError.rollbackConflict {
        // Expected.
    }

    let tagAfterItemURL = try temporaryLibraryURL()
    do {
        let repository = try PromptRepository(libraryURL: tagAfterItemURL)
        var item = itemSequenceFixture(id: "rollback-tag-after-item")
        item.tags = ["rollback-tag-after-item"]
        try repository.saveItem(item)
        _ = try repository.prepareItemSequenceMigration()
        _ = try repository.runItemSequenceMigration(batchSize: 10)
        _ = try repository.prepareTagRelationMigration()
        _ = try repository.runTagRelationBackfill(batchSize: 10)
    }
    do {
        _ = try PromptRepository.rollbackItemSequenceMigration(at: tagAfterItemURL)
        throw CoreUnitTestError.failure("item rollback must reject a later tag migration state")
    } catch ItemSequenceMigrationError.rollbackConflict {
        // Expected.
    }

    let versionBeforeItemURL = try temporaryLibraryURL()
    do {
        let repository = try PromptRepository(libraryURL: versionBeforeItemURL)
        try repository.saveItem(itemSequenceFixture(id: "rollback-item-after-version"))
        _ = try repository.prepareVersionSequenceMigration()
        _ = try repository.runVersionSequenceMigration(batchSize: 10)
        _ = try repository.prepareItemSequenceMigration()
        _ = try repository.runItemSequenceMigration(batchSize: 10)
    }
    do {
        _ = try PromptRepository.rollbackVersionSequenceMigration(at: versionBeforeItemURL)
        throw CoreUnitTestError.failure("version rollback must reject a later item migration state")
    } catch VersionSequenceMigrationError.rollbackConflict {
        // Expected.
    }

    let tagBeforeItemURL = try temporaryLibraryURL()
    do {
        let repository = try PromptRepository(libraryURL: tagBeforeItemURL)
        try repository.saveItem(itemSequenceFixture(id: "rollback-item-after-tag"))
        _ = try repository.prepareTagRelationMigration()
        _ = try repository.runTagRelationBackfill(batchSize: 10)
        _ = try repository.prepareItemSequenceMigration()
        _ = try repository.runItemSequenceMigration(batchSize: 10)
    }
    do {
        _ = try PromptRepository.rollbackTagRelationMigration(at: tagBeforeItemURL)
        throw CoreUnitTestError.failure("tag rollback must reject a later item migration state")
    } catch TagRelationMigrationError.rollbackConflict {
        // Expected.
    }
}

func testItemSequenceRecentOrderingMatchesLegacyDateOracleForNoncanonicalRawValues() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    try repository.saveItems([
        itemSequenceFixture(id: "recent-z", createdAt: date),
        itemSequenceFixture(id: "recent-a", createdAt: date),
        itemSequenceFixture(id: "recent-fraction", createdAt: date)
    ])
    let database = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    try database.run("UPDATE prompt_items SET lastUsedAt = ? WHERE id = 'recent-z';", values: [.text("2024-01-01T00:00:00Z")])
    try database.run("UPDATE prompt_items SET lastUsedAt = ? WHERE id = 'recent-a';", values: [.text("2024-01-01T01:00:00+01:00")])
    try database.run("UPDATE prompt_items SET lastUsedAt = ? WHERE id = 'recent-fraction';", values: [.text("2024-01-01T00:00:00.1Z")])
    _ = try repository.prepareVersionSequenceMigration()
    _ = try repository.runVersionSequenceMigration(batchSize: 10)
    _ = try repository.prepareItemSequenceMigration()
    _ = try repository.runItemSequenceMigration(batchSize: 10)
    let loaded = try repository.loadItems()
    let legacyRecent = PromptFiltering.apply(loaded, filter: PromptFilter(collection: .recent)).map(\.id)
    let capabilities = LibraryQueryCapabilities(tagRelationsReady: true, versionSequenceReady: true, itemSequenceReady: true)
    let recentSQL = try LibraryQuerySQLBuilder.build(.recent(), capabilities: capabilities)
    let sqlRecent = try database.query(recentSQL.sql, values: recentSQL.values).map { itemSequenceValue($0, "id") }
    try expect(legacyRecent == ["recent-z", "recent-a"], "recent filter must preserve the existing last-used Date oracle")
    try expect(sqlRecent == legacyRecent, "ready Recent SQL must match persisted last-used Date oracle")
}

func testItemSequenceReadySQLNeverEmitsLegacyTieOrdering() throws {
    let capabilities = LibraryQueryCapabilities(tagRelationsReady: true, versionSequenceReady: true, itemSequenceReady: true)
    let queries: [LibraryQuery] = [
        .all(), .folder("folder"), .type(.image), .model("model"), .favorite(),
        .recent(), .trash(), .tag("tag"),
        LibraryQuery(.all, type: .image, modelId: "model", favoriteOnly: true)
    ]
    for query in queries {
        let built = try LibraryQuerySQLBuilder.build(query, capabilities: capabilities)
        try expect(!built.sql.contains("rowid"), "ready (query.collection) SQL must not mention rowid")
        try expect(!built.sql.contains("p.id ASC") && !built.sql.contains("pit.promptItemId ASC"), "ready \(query.collection) SQL must not use id tie ordering")
        try expect(built.sql.contains("p.itemSequence ASC"), "ready \(query.collection) SQL must use persisted item sequence")
    }
}

func testItemSequenceCapabilityMustBeExplicit() throws {
    do {
        _ = try LibraryQuerySQLBuilder.build(
            LibraryQuery(pageSize: 10),
            capabilities: LibraryQueryCapabilities(versionSequenceReady: true)
        )
        throw CoreUnitTestError.failure("version readiness alone must not open item Summary SQL")
    } catch LibraryQuerySQLBuilderError.itemSequenceNotReady {
        return
    }
}

func testItemSequenceReadyIndexesAndTagOrderContract() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    try repository.saveItem(itemSequenceFixture(id: "index-contract"))
    _ = try repository.prepareItemSequenceMigration()
    _ = try repository.runItemSequenceMigration()
    let database = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    let recentIndex = try database.query("SELECT sql FROM sqlite_master WHERE type='index' AND name='idx_phase2a4_1_prompt_items_recent';").first
    try expect(itemSequenceValue(recentIndex ?? [:], "sql").contains("itemLastUsedAtSortKey DESC"), "recent index must use persisted last-used sort key")
    let recentInfo = try database.query("PRAGMA index_xinfo('idx_phase2a4_1_prompt_items_recent');")
        .filter { itemSequenceValue($0, "key") == "1" }
        .sorted { (Int(itemSequenceValue($0, "seqno")) ?? 0) < (Int(itemSequenceValue($1, "seqno")) ?? 0) }
    try expect(recentInfo.map { itemSequenceValue($0, "name") } == ["itemLastUsedAtSortKey", "itemCreatedAtSortKey", "itemSequence"], "recent index columns must be exact and persisted")
    try expect(recentInfo.map { itemSequenceValue($0, "desc") } == ["1", "1", "0"], "recent index directions must be DESC/DESC/ASC")
    let recentIndexStatement = LibraryQuerySQLBuilder.phase2A4_1ItemIndexStatements.first { $0.contains("idx_phase2a4_1_prompt_items_recent") } ?? ""
    try expect(recentIndexStatement.contains("itemLastUsedAtSortKey DESC") && !recentIndexStatement.contains("lastUsedAtSortKey DESC"), "published recent index contract must use itemLastUsedAtSortKey")

    let capabilities = LibraryQueryCapabilities(tagRelationsReady: true, versionSequenceReady: true, itemSequenceReady: true)
    let tagSQL = try LibraryQuerySQLBuilder.build(.tag("tag"), capabilities: capabilities)
    try expect(tagSQL.sql.contains("ORDER BY p.sortOrder ASC, p.itemCreatedAtSortKey DESC, p.itemSequence ASC"), "ready tag SQL must use persisted prompt-item order")
    try expect(!tagSQL.sql.contains("ORDER BY pit.sortOrder") && !tagSQL.sql.contains("p.id ASC"), "ready tag SQL must not use relation/id tie order")
}

func testItemSequenceRollbackRejectsIndependentReadConnectionLease() throws {
    let libraryURL = try temporaryLibraryURL()
    let databasePath = libraryURL.appendingPathComponent("database/promptstudio.sqlite").path
    do {
        let repository = try PromptRepository(libraryURL: libraryURL)
        try repository.saveItem(itemSequenceFixture(id: "read-lease"))
        _ = try repository.prepareItemSequenceMigration()
        _ = try repository.runItemSequenceMigration()
    }
    var readConnection: SQLiteReadConnection? = try SQLiteReadConnection(
        path: libraryURL.appendingPathComponent("database/promptstudio.sqlite").path
    )
    _ = readConnection
    do {
        _ = try PromptRepository.rollbackItemSequenceMigration(at: libraryURL)
        throw CoreUnitTestError.failure("item rollback must reject an independent read connection lease")
    } catch ItemSequenceMigrationError.rollbackConflict {
        // Expected: a read connection can open independent handles later, so
        // its lease must participate in closed-library quiescence.
    }
    readConnection = nil
    _ = try PromptRepository.rollbackItemSequenceMigration(at: libraryURL)
    let restored = try SQLiteDatabase(path: databasePath, mode: .existingReadWrite)
    let columns = Set(try restored.query("PRAGMA table_info(prompt_items);").compactMap { $0["name"] ?? nil })
    try expect(!columns.contains("itemSequence") && !columns.contains("itemCreatedAtSortKey"), "successful item rollback must restore the pre-schema columns")
    let restoredRow = try restored.query("SELECT id,createdAt FROM prompt_items WHERE id='read-lease';").first ?? [:]
    try expect(itemSequenceValue(restoredRow, "id") == "read-lease", "successful item rollback must restore the original row")
}
