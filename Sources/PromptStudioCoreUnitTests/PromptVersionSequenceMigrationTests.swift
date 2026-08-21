import Foundation
import PromptStudioCore

private func sequenceISODate(_ value: String) -> String { value }

private func insertLegacySequenceVersion(
    id: String,
    itemID: String,
    prompt: String,
    createdAt: String,
    into database: SQLiteDatabase
) throws {
    try database.run(
        """
        INSERT INTO prompt_versions (
            id, promptItemId, version, prompt, negativePrompt, parametersJSON, note, createdAt
        ) VALUES (?, ?, ?, ?, '', '{}', '', ?);
        """,
        values: [
            .text(id), .text(itemID), .text(id), .text(prompt), .text(sequenceISODate(createdAt))
        ]
    )
}

private func sequenceFixtureItem(id: String, sortOrder: Int = 0) -> PromptItem {
    var item = sampleItem(title: "Sequence (id)", prompt: "seed")
    item.id = id
    item.sortOrder = sortOrder
    item.versions = []
    return item
}

private func sequenceRows(_ repository: PromptRepository, itemID: String) throws -> [[String: String?]] {
    let db = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    return try db.query(
        "SELECT id, createdAt, versionSequence, versionCreatedAtSortKey FROM prompt_versions WHERE promptItemId = ? ORDER BY versionCreatedAtSortKey ASC, versionSequence ASC;",
        values: [.text(itemID)]
    )
}

private func sequenceValue(_ row: [String: String?], _ key: String) -> String {
    guard let value = row[key] ?? nil else { return "" }
    return value
}

func testPromptVersionSequenceMigrationAddsSchemaAndGoldenOrder() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let item = sequenceFixtureItem(id: "sequence-golden")
    try repository.saveItem(item)
    let database = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    let sameDate = "2024-01-01T00:00:00Z"
    for (id, prompt) in [("z-version", ""), ("a-version", "old"), ("m-version", "latest")] {
        try insertLegacySequenceVersion(id: id, itemID: item.id, prompt: prompt, createdAt: sameDate, into: database)
    }

    let before = try repository.loadItems().first { $0.id == item.id }
    try expect(before?.currentVersion?.id == "m-version", "legacy fixture should observe insertion-order currentVersion")
    let prepared = try repository.prepareVersionSequenceMigration()
    try expect(prepared.phase != .ready, "preparing version sequence migration must remain gated until backfill completes")
    let result = try repository.runVersionSequenceMigration(batchSize: 1)
    try expect(result.completed, "version sequence migration should complete")
    try expect(repository.versionSequenceMigrationReady, "version sequence runtime gate should open only after validation")
    _ = try repository.prepareItemSequenceMigration()
    _ = try repository.runItemSequenceMigration(batchSize: 10)

    let rows = try sequenceRows(repository, itemID: item.id)
    try expect(rows.map { sequenceValue($0, "id") } == ["z-version", "a-version", "m-version"], "migration must preserve legacy equal-date order")
    try expect(rows.compactMap { Int(sequenceValue($0, "versionSequence")) } == [1, 2, 3], "migration must assign contiguous per-item sequence")
    let after = try repository.loadItems().first { $0.id == item.id }
    try expect(after?.currentVersion?.id == before?.currentVersion?.id, "migration must preserve currentVersion")
    let readySQL = try LibraryQuerySQLBuilder.build(
        LibraryQuery(pageSize: 10),
        capabilities: LibraryQueryCapabilities(versionSequenceReady: true, itemSequenceReady: true)
    )
    try expect(!readySQL.sql.contains("rowid"), "ready Summary must not use rowid")
    let summaryRows = try database.query(readySQL.sql, values: readySQL.values)
    let summary = summaryRows.first { sequenceValue($0, "id") == item.id }
    try expect(sequenceValue(summary ?? [:], "hasPrompt") == "1", "ready Summary hasPrompt must match migrated currentVersion")
    let state = try repository.versionSequenceMigrationState()
    try expect(!state.beforeFingerprint.isEmpty, "migration should record a pre-migration content fingerprint")
    try expect(state.afterFingerprint == state.beforeFingerprint, "migration must preserve version id/createdAt fingerprint")
}

func testPromptVersionSequenceMigrationResumesWithCheckpointAndIsIdempotent() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    for index in 0..<3 {
        let item = sequenceFixtureItem(id: "resume-\(index)", sortOrder: index)
        try repository.saveItem(item)
        let database = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
        try insertLegacySequenceVersion(
            id: "resume-\(index)-v1",
            itemID: item.id,
            prompt: "v1",
            createdAt: "2024-01-01T00:00:0\(index)Z",
            into: database
        )
    }

    _ = try repository.prepareVersionSequenceMigration()
    let first = try repository.runVersionSequenceMigration(batchSize: 1, maxBatches: 1)
    try expect(!first.completed, "bounded migration should expose an incomplete checkpoint")
    try expect(first.processedCount == 1, "bounded migration should persist one item checkpoint")
    let resumed = try repository.runVersionSequenceMigration(batchSize: 1)
    try expect(resumed.completed, "migration should resume from persisted checkpoint")
    let repeated = try repository.runVersionSequenceMigration(batchSize: 1)
    try expect(repeated.completed, "completed migration should be idempotent")
    try expect(repeated.processedCount == resumed.processedCount, "repeat migration must not duplicate work")
}

func testPromptVersionSequenceConcurrentPrepareCoalescesOneBackup() async throws {
    let url = try temporaryLibraryURL()
    let seed = try PromptRepository(libraryURL: url)
    try seed.saveItem(sequenceFixtureItem(id: "concurrent-prepare"))
    let repositories = try [
        PromptRepository(libraryURL: url),
        PromptRepository(libraryURL: url)
    ]
    let tasks = repositories.map { repository in
        Task.detached { try repository.prepareVersionSequenceMigration() }
    }
    let first = try await tasks[0].value
    let second = try await tasks[1].value
    try expect(first.backupPath == second.backupPath, "concurrent prepare calls must coalesce to one backup")
    try expect(first.phase == .backfilling && second.phase == .backfilling, "concurrent prepare must leave one resumable checkpoint")
}

func testPromptVersionSequenceRejectsNegativeMaxBatchesAndZeroIsNoOp() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let item = sequenceFixtureItem(id: "invalid-max-batches")
    try repository.saveItem(item)
    _ = try repository.prepareVersionSequenceMigration()
    do {
        _ = try repository.runVersionSequenceMigration(batchSize: 1, maxBatches: -1)
        throw CoreUnitTestError.failure("negative maxBatches must be rejected")
    } catch VersionSequenceMigrationError.invalidMaxBatches {
        // Expected.
    }
    let result = try repository.runVersionSequenceMigration(batchSize: 1, maxBatches: 0)
    try expect(!result.completed, "maxBatches=0 must be an explicit no-op")
    try expect(result.processedCount == 0, "maxBatches=0 must not process a batch")
}

func testPromptVersionSequenceBackfillWriterBetweenBatchesKeepsReadyMetadata() throws {
    let url = try temporaryLibraryURL()
    let repository = try PromptRepository(libraryURL: url)
    for index in 0..<3 {
        var item = sequenceFixtureItem(id: "batch-writer-\(index)", sortOrder: index)
        item.versions = [
            PromptVersion(
                id: "batch-writer-\(index)-v1",
                promptItemId: item.id,
                version: "V1",
                prompt: "before",
                createdAt: Date(timeIntervalSince1970: 1_704_067_200 + Double(index))
            )
        ]
        try repository.saveItem(item)
    }
    _ = try repository.prepareVersionSequenceMigration()
    _ = try repository.runVersionSequenceMigration(batchSize: 1, maxBatches: 1)

    let writer = try PromptRepository(libraryURL: url)
    let writerItems = try writer.loadItems()
    guard var edited = writerItems.first(where: { $0.id == "batch-writer-0" }) else {
        throw CoreUnitTestError.failure("batch writer should observe the processed item; ids=\(writerItems.map(\.id))")
    }
    edited.versions[0].prompt = "edited between migration batches"
    edited.versions.append(
        PromptVersion(
            id: "batch-writer-0-v2",
            promptItemId: edited.id,
            version: "V2",
            prompt: "new between migration batches",
            createdAt: Date(timeIntervalSince1970: 1_804_067_200)
        )
    )
    try writer.saveItem(edited)

    _ = try repository.runVersionSequenceMigration(batchSize: 1)
    try expect(repository.versionSequenceMigrationReady, "backfill writer must not leave migration with NULL metadata")
    let database = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    let missing = try database.query(
        "SELECT COUNT(*) AS count FROM prompt_versions WHERE versionSequence IS NULL OR versionCreatedAtSortKey IS NULL;"
    )
    try expect(sequenceValue(missing.first ?? [:], "count") == "0", "dual-write must reconcile all versions before ready")
}

func testPromptVersionSequenceRollbackRejectsWriterDuringBackfillAndPreservesWriter() throws {
    let libraryURL = try temporaryLibraryURL()
    do {
        let repository = try PromptRepository(libraryURL: libraryURL)
        for index in 0..<2 {
            var item = sequenceFixtureItem(id: "rollback-version-history-\(index)")
            item.versions = [
                PromptVersion(
                    id: "rollback-version-history-\(index)-v1",
                    promptItemId: item.id,
                    version: "V1",
                    prompt: "before",
                    createdAt: Date(timeIntervalSince1970: 1_704_067_200 + Double(index))
                )
            ]
            try repository.saveItem(item)
        }
        _ = try repository.prepareVersionSequenceMigration()
        _ = try repository.runVersionSequenceMigration(batchSize: 1, maxBatches: 1)
        do {
            let writer = try PromptRepository(libraryURL: libraryURL)
            guard var edited = try writer.loadItems().first(where: { $0.id == "rollback-version-history-0" }) else {
                throw CoreUnitTestError.failure("version rollback writer fixture should load")
            }
            edited.versions[0].prompt = "writer during version backfill"
            try writer.saveItem(edited)
        }
        _ = try repository.runVersionSequenceMigration(batchSize: 1)
        try expect(repository.versionSequenceMigrationReady, "version backfill writer fixture must reach ready")
    }
    do {
        _ = try PromptRepository.rollbackVersionSequenceMigration(at: libraryURL)
        throw CoreUnitTestError.failure("version rollback must fail closed after a first-party writer during backfill")
    } catch VersionSequenceMigrationError.rollbackConflict {
        let repository = try PromptRepository(libraryURL: libraryURL)
        let item = try repository.loadItems().first { $0.id == "rollback-version-history-0" }
        try expect(item?.versions.first?.prompt == "writer during version backfill", "version rollback refusal must preserve the first-party writer")
    }
}

func testPromptVersionSequenceBackfillWriterCanDeleteVersionBetweenBatches() throws {
    let url = try temporaryLibraryURL()
    let repository = try PromptRepository(libraryURL: url)
    for index in 0..<3 {
        var item = sequenceFixtureItem(id: "batch-delete-\(index)", sortOrder: index)
        item.versions = [
            PromptVersion(
                id: "batch-delete-\(index)-v1",
                promptItemId: item.id,
                version: "V1",
                prompt: "before",
                createdAt: Date(timeIntervalSince1970: 1_704_067_200 + Double(index))
            ),
            PromptVersion(
                id: "batch-delete-\(index)-v2",
                promptItemId: item.id,
                version: "V2",
                prompt: "to delete",
                createdAt: Date(timeIntervalSince1970: 1_704_067_300 + Double(index))
            )
        ]
        try repository.saveItem(item)
    }
    _ = try repository.prepareVersionSequenceMigration()
    _ = try repository.runVersionSequenceMigration(batchSize: 1, maxBatches: 1)

    let writer = try PromptRepository(libraryURL: url)
    let writerItems = try writer.loadItems()
    guard var edited = writerItems.first(where: { $0.id == "batch-delete-0" }) else {
        throw CoreUnitTestError.failure("batch delete writer should observe the processed item; ids=\(writerItems.map(\.id))")
    }
    edited.versions.removeAll { $0.id == "batch-delete-0-v2" }
    try writer.saveItem(edited)

    _ = try repository.runVersionSequenceMigration(batchSize: 1)
    try expect(repository.versionSequenceMigrationReady, "deleting a version through the repository must reconcile before ready")
    let database = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    let remaining = try database.query(
        "SELECT id, versionSequence, versionCreatedAtSortKey FROM prompt_versions WHERE promptItemId = ?;",
        values: [.text("batch-delete-0")]
    )
    try expect(remaining.count == 1, "deleted version must not be resurrected by migration")
    try expect(remaining.first?["versionSequence"] ?? nil == "1", "remaining version must retain its sequence")
}

func testPromptVersionSequenceMigrationRejectsUnreconciledExternalDrift() throws {
    let url = try temporaryLibraryURL()
    let repository = try PromptRepository(libraryURL: url)
    for index in 0..<2 {
        var item = sequenceFixtureItem(id: "fingerprint-\(index)", sortOrder: index)
        item.versions = [
            PromptVersion(
                id: "fingerprint-\(index)-v1",
                promptItemId: item.id,
                version: "V1",
                prompt: "before",
                createdAt: Date(timeIntervalSince1970: 1_704_067_200 + Double(index))
            )
        ]
        try repository.saveItem(item)
    }
    _ = try repository.prepareVersionSequenceMigration()
    _ = try repository.runVersionSequenceMigration(batchSize: 1, maxBatches: 1)
    let external = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    try external.run(
        "UPDATE prompt_versions SET prompt = ? WHERE id = ?;",
        values: [.text("unreconciled external drift"), .text("fingerprint-1-v1")]
    )
    do {
        _ = try repository.runVersionSequenceMigration(batchSize: 1)
        throw CoreUnitTestError.failure("unreconciled content drift must block ready")
    } catch VersionSequenceMigrationError.migrationFailed {
        // Expected: only writes that participate in the migration contract may reconcile the fingerprint.
    }
    try expect(!repository.versionSequenceMigrationReady, "external drift must keep the feature gate closed")
}

func testPromptVersionSequenceRollbackRejectsExternalVersionWriteAndPreservesLiveBytes() throws {
    let url = try temporaryLibraryURL()
    let repository = try PromptRepository(libraryURL: url)
    var item = sequenceFixtureItem(id: "rollback-external-version")
    item.versions = [
        PromptVersion(
            id: "rollback-external-version-v1",
            promptItemId: item.id,
            version: "V1",
            prompt: "before",
            createdAt: Date(timeIntervalSince1970: 1_704_067_200)
        )
    ]
    try repository.saveItem(item)
    _ = try repository.prepareVersionSequenceMigration()
    _ = try repository.runVersionSequenceMigration(batchSize: 10)
    let writer = try PromptRepository(libraryURL: url)
    guard var edited = try writer.loadItems().first(where: { $0.id == item.id }) else {
        throw CoreUnitTestError.failure("rollback external writer fixture should load")
    }
    edited.versions[0].prompt = "external writer edit"
    try writer.saveItem(edited)
    let livePath = repository.databaseURL.path
    let beforeBytes = try Data(contentsOf: URL(fileURLWithPath: livePath))
    do {
        _ = try PromptRepository.rollbackVersionSequenceMigration(at: url)
        throw CoreUnitTestError.failure("rollback must reject an external repository writer")
    } catch VersionSequenceMigrationError.rollbackConflict {
        // Expected: the closed-library reservation fails while either writer
        // lease is active, without touching the live database.
    }
    try expect(try Data(contentsOf: URL(fileURLWithPath: livePath)) == beforeBytes, "rejected rollback must preserve live bytes")
}

func testPromptVersionSequenceInstanceRollbackAlwaysRejectsUnsafeWholeFileRestore() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    var item = sequenceFixtureItem(id: "instance-rollback-forbidden")
    item.versions = [
        PromptVersion(
            id: "instance-rollback-v1",
            promptItemId: item.id,
            version: "V1",
            prompt: "prompt",
            createdAt: Date(timeIntervalSince1970: 1_704_067_200)
        )
    ]
    try repository.saveItem(item)
    _ = try repository.prepareVersionSequenceMigration()
    _ = try repository.runVersionSequenceMigration(batchSize: 10)
    do {
        _ = try repository.rollbackVersionSequenceMigration()
        throw CoreUnitTestError.failure("an active repository must never perform whole-file rollback")
    } catch VersionSequenceMigrationError.rollbackConflict {
        // Expected: only the static closed-library API may restore a backup.
    }
}

func testPromptVersionSequenceFinalizeRejectsPreTriggerCorruptMetadata() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    var item = sequenceFixtureItem(id: "pretrigger-corrupt")
    item.versions = [
        PromptVersion(
            id: "pretrigger-corrupt-v1",
            promptItemId: item.id,
            version: "V1",
            prompt: "prompt",
            createdAt: Date(timeIntervalSince1970: 1_704_067_200)
        )
    ]
    try repository.saveItem(item)
    _ = try repository.prepareVersionSequenceMigration()
    let database = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    // The ready triggers do not exist yet, so direct SQL can stage corrupt
    // metadata. Move the checkpoint past all item IDs to force finalization's
    // one-time full validation to inspect this row.
    try database.run(
        "UPDATE prompt_versions SET versionSequence = ?, versionCreatedAtSortKey = ? WHERE id = ?;",
        values: [.text("not-an-integer"), .text("0"), .text("pretrigger-corrupt-v1")]
    )
    try database.run(
        "UPDATE version_sequence_migration SET lastProcessedItemID = ?, processedCount = totalCount WHERE id = 1;",
        values: [.text("\u{10ffff}" )]
    )
    do {
        _ = try repository.runVersionSequenceMigration(batchSize: 10)
        throw CoreUnitTestError.failure("finalization must reject pre-trigger corrupt metadata")
    } catch VersionSequenceMigrationError.schemaNotReady {
        // Expected: full final metadata validation fails closed before ready.
    } catch VersionSequenceMigrationError.migrationFailed {
        // A future wrapper may persist the failure and surface migrationFailed.
    }
    try expect(!repository.versionSequenceMigrationReady, "corrupt pre-trigger metadata must not become ready")
}

func testPromptVersionSequenceWriterUsesDirtyMarkerWithoutRescanningFingerprint() throws {
    let url = try temporaryLibraryURL()
    let repository = try PromptRepository(libraryURL: url)
    var item = sequenceFixtureItem(id: "dirty-marker-writer")
    item.versions = [
        PromptVersion(id: "dirty-marker-v1", promptItemId: item.id, version: "V1", prompt: "before", createdAt: Date(timeIntervalSince1970: 1_704_067_200))
    ]
    try repository.saveItem(item)
    try repository.saveItem(sequenceFixtureItem(id: "dirty-marker-other", sortOrder: 1))
    _ = try repository.prepareVersionSequenceMigration()
    _ = try repository.runVersionSequenceMigration(batchSize: 1, maxBatches: 1)
    let before = try repository.versionSequenceMigrationState()
    guard var edited = try repository.loadItems().first(where: { $0.id == item.id }) else {
        throw CoreUnitTestError.failure("dirty-marker fixture should load")
    }
    edited.versions[0].prompt = "writer update"
    try repository.saveItem(edited)
    let after = try repository.versionSequenceMigrationState()
    try expect(after.reconciledFingerprint == before.reconciledFingerprint, "writer activity must use a dirty marker instead of rescanning the full fingerprint")
    try expect(after.changeCounter > before.changeCounter, "one writer transaction must bump the migration change counter")
}

func testPromptVersionSequenceReadyRejectsInvalidSequenceTypeAndRange() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    var item = sequenceFixtureItem(id: "invalid-sequence-type")
    item.versions = [PromptVersion(id: "invalid-sequence-v1", promptItemId: item.id, version: "V1", prompt: "prompt")]
    try repository.saveItem(item)
    _ = try repository.prepareVersionSequenceMigration()
    _ = try repository.runVersionSequenceMigration(batchSize: 10)
    let database = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    for value in ["not-an-integer", "0", "-1"] {
        do {
            try database.run("UPDATE prompt_versions SET versionSequence = ? WHERE id = ?;", values: [.text(value), .text("invalid-sequence-v1")])
            throw CoreUnitTestError.failure("ready sequence trigger must reject (value)")
        } catch let error as SQLiteError {
            if case .stepFailed = error { /* Expected. */ }
            else { throw error }
        }
    }
}

func testPromptVersionSequenceMigrationDetectsDeleteReinsertRowOrderDrift() throws {
    let url = try temporaryLibraryURL()
    let repository = try PromptRepository(libraryURL: url)
    for index in 0..<2 {
        var item = sequenceFixtureItem(id: "rowid-drift-\(index)", sortOrder: index)
        item.versions = [
            PromptVersion(
                id: "rowid-drift-\(index)-v1",
                promptItemId: item.id,
                version: "V1",
                prompt: "same tuple",
                createdAt: Date(timeIntervalSince1970: 1_704_067_200 + Double(index))
            )
        ]
        try repository.saveItem(item)
    }
    _ = try repository.prepareVersionSequenceMigration()
    _ = try repository.runVersionSequenceMigration(batchSize: 1, maxBatches: 1)
    let external = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    try external.run(
        "DELETE FROM prompt_versions WHERE id = ?;",
        values: [.text("rowid-drift-1-v1")]
    )
    try insertLegacySequenceVersion(
        id: "rowid-drift-1-v1",
        itemID: "rowid-drift-1",
        prompt: "same tuple",
        createdAt: "2024-01-01T00:00:01Z",
        into: external
    )
    do {
        _ = try repository.runVersionSequenceMigration(batchSize: 1)
        throw CoreUnitTestError.failure("delete/reinsert row-order drift must not silently become ready")
    } catch VersionSequenceMigrationError.migrationFailed {
        // Expected.
    }
}

func testPromptVersionSequenceMigrationAuditsNonCanonicalDatesWithoutRewritingCreatedAt() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let item = sequenceFixtureItem(id: "sequence-dates")
    try repository.saveItem(item)
    let database = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    let values = [
        ("z", "2024-01-01T00:00:00Z"),
        ("fraction-short", "2024-01-01T00:00:00.1Z"),
        ("fraction-mid", "2024-01-01T00:00:00.12Z"),
        ("fraction-long", "2024-01-01T00:00:00.123456Z"),
        ("offset", "2024-01-01T01:00:00+01:00"),
        ("legacy", "2024-01-01 00:00:00 +0000"),
        ("malformed", "not-a-date"),
        ("empty", "")
    ]
    for (id, date) in values {
        try insertLegacySequenceVersion(id: id, itemID: item.id, prompt: id, createdAt: date, into: database)
    }
    let legacyObservation = try repository.loadItems().first { $0.id == item.id }
    let legacyOrder = legacyObservation?.versions.map(\.id) ?? []
    let legacyCurrentID = legacyObservation?.currentVersion?.id
    let legacyHasPrompt = legacyObservation?.currentVersion?.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    _ = try repository.prepareVersionSequenceMigration()
    _ = try repository.runVersionSequenceMigration(batchSize: 10)
    let rows = try sequenceRows(repository, itemID: item.id)
    let createdAtByID = Dictionary(uniqueKeysWithValues: rows.map { (sequenceValue($0, "id"), sequenceValue($0, "createdAt")) })
    for (id, date) in values {
        try expect(createdAtByID[id] == date, "migration must not rewrite createdAt for (id)")
    }
    try expect(rows.allSatisfy { Int64(sequenceValue($0, "versionCreatedAtSortKey")) != nil }, "all versions need a persisted Date sort key")
    let migratedObservation = try repository.loadItems().first { $0.id == item.id }
    try expect(migratedObservation?.versions.map(\.id) == legacyOrder, "migration must preserve legacy Date observation order")
    try expect(migratedObservation?.currentVersion?.id == legacyCurrentID, "migration must preserve legacy currentVersion for invalid/fractional dates")
    let migratedHasPrompt = migratedObservation?.currentVersion?.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    try expect(migratedHasPrompt == legacyHasPrompt, "migration must preserve legacy hasPrompt semantics")
}

func testPromptVersionSequenceMigrationUsesDeterministicObservationClock() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let item = sequenceFixtureItem(id: "sequence-clock")
    try repository.saveItem(item)
    let database = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    let rawValues = [
        ("valid-old", "2024-01-01T00:00:00Z"),
        ("malformed", "not-a-date"),
        ("valid-future", "2030-01-01T00:00:00Z"),
        ("fractional", "2024-01-01T00:00:00.123456Z")
    ]
    for (id, createdAt) in rawValues {
        try insertLegacySequenceVersion(id: id, itemID: item.id, prompt: id, createdAt: createdAt, into: database)
    }
    let fallbackDates = [
        Date(timeIntervalSince1970: 2_100_000_000),
        Date(timeIntervalSince1970: 2_200_000_000)
    ]
    let clock = VersionSequenceObservationClock(dates: fallbackDates)
    _ = try repository.prepareVersionSequenceMigration()
    _ = try repository.runVersionSequenceMigration(batchSize: 10, observationClock: clock)
    let rows = try sequenceRows(repository, itemID: item.id)
    try expect(rows.map { sequenceValue($0, "id") } == ["valid-old", "valid-future", "fractional", "malformed"], "deterministic Date fallback must drive exact order")
    let expectedSortKeys = [
        "valid-old": Int64((Date(timeIntervalSince1970: 1_704_067_200).timeIntervalSince1970 * 1_000_000).rounded()),
        "valid-future": Int64((Date(timeIntervalSince1970: 1_893_456_000).timeIntervalSince1970 * 1_000_000).rounded()),
        "fractional": Int64((fallbackDates[0].timeIntervalSince1970 * 1_000_000).rounded()),
        "malformed": Int64((fallbackDates[1].timeIntervalSince1970 * 1_000_000).rounded())
    ]
    let actual = Dictionary(uniqueKeysWithValues: rows.map { (sequenceValue($0, "id"), Int64(sequenceValue($0, "versionCreatedAtSortKey")) ?? -1) })
    try expect(actual == expectedSortKeys, "persisted Date sort keys must equal injected legacy observations")
}

func testPromptVersionSequenceMigrationEnforcesUniqueSequenceAndConcurrentWrites() async throws {
    let url = try temporaryLibraryURL()
    let repository = try PromptRepository(libraryURL: url)
    let item = sequenceFixtureItem(id: "sequence-concurrency")
    try repository.saveItem(item)
    let database = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    try insertLegacySequenceVersion(id: "seed", itemID: item.id, prompt: "seed", createdAt: "2024-01-01T00:00:00Z", into: database)
    _ = try repository.prepareVersionSequenceMigration()
    _ = try repository.runVersionSequenceMigration(batchSize: 10)

    let repositories = try [
        PromptRepository(libraryURL: url),
        PromptRepository(libraryURL: url)
    ]
    var tasks: [Task<Void, Error>] = []
    for index in 0..<2 {
        let writer = repositories[index]
        tasks.append(Task.detached {
            var value = sequenceFixtureItem(id: item.id)
            value.versions = [
                PromptVersion(id: "writer-\(index)", promptItemId: item.id, version: "writer-\(index)", prompt: "writer-\(index)", createdAt: Date(timeIntervalSince1970: 1_704_067_200 + Double(index)))
            ]
            try writer.saveItem(value)
        })
    }
    var errors: [Error] = []
    for task in tasks {
        do { try await task.value } catch { errors.append(error) }
    }
    try expect(errors.isEmpty, "concurrent sequence writers should not fail with BUSY/LOCKED or uniqueness errors")
    let rows = try sequenceRows(repository, itemID: item.id)
    let sequences = rows.compactMap { Int(sequenceValue($0, "versionSequence")) }
    try expect(Set(sequences).count == sequences.count, "version sequences must be unique per item")
}

func testPromptVersionSequenceRuntimeSQLUsesPersistentKeys() throws {
    do {
        _ = try LibraryQuerySQLBuilder.build(LibraryQuery(pageSize: 5))
        throw CoreUnitTestError.failure("pre-ready Summary SQL must fail closed")
    } catch LibraryQuerySQLBuilderError.versionSequenceNotReady {
        // Expected: runtime must not emit lexical/rowid fallback SQL.
    }
    let ready = try LibraryQuerySQLBuilder.build(
        LibraryQuery(pageSize: 5),
        capabilities: LibraryQueryCapabilities(versionSequenceReady: true, itemSequenceReady: true)
    )
    try expect(ready.sql.contains("versionCreatedAtSortKey"), "ready Summary must use persisted Date sort key")
    try expect(ready.sql.contains("versionSequence"), "ready Summary must use persisted version sequence")
    try expect(!ready.sql.contains("rowid"), "runtime SQL must not depend on rowid")
    let service = LibraryQueryService(
        executor: { _, _ in [] },
        capabilities: .itemSequence
    )
    try expect(service.capabilities.versionSequenceReady, "LibraryQueryService must preserve the ready feature gate")
}

func testPromptVersionSummaryRefusesPreReadyTimestampFallbackAndMatchesReadyDateOrder() async throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let item = sequenceFixtureItem(id: "summary-timestamp-semantics")
    try repository.saveItem(item)
    let database = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    try insertLegacySequenceVersion(
        id: "offset-v1",
        itemID: item.id,
        prompt: "",
        createdAt: "2024-01-01T01:00:00+01:00",
        into: database
    )
    try insertLegacySequenceVersion(
        id: "canonical-v2",
        itemID: item.id,
        prompt: "canonical latest",
        createdAt: "2024-01-01T00:30:00Z",
        into: database
    )
    try insertLegacySequenceVersion(
        id: "fractional-v3",
        itemID: item.id,
        prompt: "fractional fallback",
        createdAt: "2024-01-01T00:30:00.1Z",
        into: database
    )
    try insertLegacySequenceVersion(
        id: "malformed-v4",
        itemID: item.id,
        prompt: "malformed fallback",
        createdAt: "not-a-date",
        into: database
    )

    guard let legacy = try repository.loadItems().first(where: { $0.id == item.id }) else {
        throw CoreUnitTestError.failure("timestamp semantics fixture should load before migration")
    }
    let legacyIDs = legacy.versions.map(\.id)
    guard let offsetIndex = legacyIDs.firstIndex(of: "offset-v1"),
          let canonicalIndex = legacyIDs.firstIndex(of: "canonical-v2") else {
        throw CoreUnitTestError.failure("timestamp semantics fixture should retain offset and canonical versions")
    }
    try expect(offsetIndex < canonicalIndex, "offset Date parsing must outrank 01:00+01:00 with 00:30Z")

    do {
        _ = try LibraryQuerySQLBuilder.build(LibraryQuery(pageSize: 10))
        throw CoreUnitTestError.failure("pre-ready Summary must refuse offset/fractional/malformed timestamp semantics")
    } catch LibraryQuerySQLBuilderError.versionSequenceNotReady {
        // Expected: lexical MAX(createdAt)+rowid is not a valid Date comparator.
    }
    let readBefore = try SQLiteReadConnection(path: repository.databaseURL.path)
    let unreadyService = LibraryQueryService(executor: readBefore)
    do {
        _ = try await unreadyService.query(LibraryQuery(pageSize: 10))
        throw CoreUnitTestError.failure("pre-ready Summary service must refuse unsafe timestamp semantics")
    } catch LibraryQuerySQLBuilderError.versionSequenceNotReady {
        // Expected.
    }

    _ = try repository.prepareVersionSequenceMigration()
    _ = try repository.runVersionSequenceMigration(
        batchSize: 10,
        observationClock: VersionSequenceObservationClock(
            dates: [Date(timeIntervalSince1970: 1_800_000_000), Date(timeIntervalSince1970: 1_800_000_001)]
        )
    )
    _ = try repository.prepareItemSequenceMigration()
    _ = try repository.runItemSequenceMigration(batchSize: 10)
    guard let ready = try repository.loadItems().first(where: { $0.id == item.id }) else {
        throw CoreUnitTestError.failure("timestamp semantics fixture should load after migration")
    }
    try expect(ready.versions.map(\.id) == legacyIDs, "ready order must preserve the legacy loader's Date/fallback order")
    try expect(ready.currentVersion?.id == legacy.currentVersion?.id, "ready migration must preserve currentVersion for offset/fractional/malformed dates")

    let readAfter = try SQLiteReadConnection(path: repository.databaseURL.path)
    let readyService = LibraryQueryService(executor: readAfter, repository: repository)
    let summaries = try await readyService.query(LibraryQuery(pageSize: 10)).items
    let summary = summaries.first { $0.id == item.id }
    try expect(summary?.hasPrompt == true, "ready Summary hasPrompt must match migrated currentVersion")
}

func testPromptVersionSequenceMigrationPreservesNoVersionSummaryProjection() async throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let item = sequenceFixtureItem(id: "sequence-no-version")
    try repository.saveItem(item)
    _ = try repository.prepareVersionSequenceMigration()
    _ = try repository.runVersionSequenceMigration(batchSize: 10)
    _ = try repository.prepareItemSequenceMigration()
    _ = try repository.runItemSequenceMigration(batchSize: 10)

    let database = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    let built = try LibraryQuerySQLBuilder.build(
        LibraryQuery(pageSize: 10),
        capabilities: LibraryQueryCapabilities(versionSequenceReady: true, itemSequenceReady: true)
    )
    let rows = try database.query(built.sql, values: built.values)
    guard let row = rows.first(where: { sequenceValue($0, "id") == item.id }) else {
        throw CoreUnitTestError.failure("ready Summary should retain no-version item")
    }
    try expect(sequenceValue(row, "hasPrompt") == "0", "no-version Summary hasPrompt should be false")
    try expect(sequenceValue(row, "hasReferences") == "0", "no-version Summary hasReferences should be false")
    try expect((try repository.loadItems().first { $0.id == item.id }?.currentVersion) == nil, "no-version currentVersion should remain nil")
}

func testPromptVersionSequenceExistingVersionEditPreservesSequenceAndCreatedAt() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    var item = sequenceFixtureItem(id: "sequence-edit")
    item.versions = [
        PromptVersion(id: "edit-v1", promptItemId: item.id, version: "V1", prompt: "before", createdAt: Date(timeIntervalSince1970: 1_704_067_200))
    ]
    try repository.saveItem(item)
    _ = try repository.prepareVersionSequenceMigration()
    _ = try repository.runVersionSequenceMigration(batchSize: 10)
    _ = try repository.prepareItemSequenceMigration()
    _ = try repository.runItemSequenceMigration(batchSize: 10)
    let before = try sequenceRows(repository, itemID: item.id).first
    item.versions[0].prompt = "after"
    item.versions[0].createdAt = Date(timeIntervalSince1970: 1_900_000_000)
    try repository.saveItem(item)
    let after = try sequenceRows(repository, itemID: item.id).first
    try expect(sequenceValue(after ?? [:], "versionSequence") == sequenceValue(before ?? [:], "versionSequence"), "editing an existing version must preserve sequence")
    try expect(sequenceValue(after ?? [:], "createdAt") == sequenceValue(before ?? [:], "createdAt"), "editing an existing version must preserve createdAt")
    try expect(sequenceValue(after ?? [:], "versionCreatedAtSortKey") == sequenceValue(before ?? [:], "versionCreatedAtSortKey"), "editing an existing version must preserve Date sort key")
}

func testPromptVersionSequencePrependingNewVersionAllocatesAfterOldMax() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    var item = sequenceFixtureItem(id: "sequence-prepend")
    item.versions = [
        PromptVersion(id: "prepend-v1", promptItemId: item.id, version: "V1", prompt: "one", createdAt: Date(timeIntervalSince1970: 1_704_067_200)),
        PromptVersion(id: "prepend-v2", promptItemId: item.id, version: "V2", prompt: "two", createdAt: Date(timeIntervalSince1970: 1_704_067_201))
    ]
    try repository.saveItem(item)
    _ = try repository.prepareVersionSequenceMigration()
    _ = try repository.runVersionSequenceMigration(batchSize: 10)
    item.versions.insert(
        PromptVersion(id: "prepend-v3", promptItemId: item.id, version: "V3", prompt: "three", createdAt: Date(timeIntervalSince1970: 1_804_067_200)),
        at: 0
    )
    try repository.saveItem(item)
    let rows = try sequenceRows(repository, itemID: item.id)
    let sequenceByID = Dictionary(uniqueKeysWithValues: rows.map { (sequenceValue($0, "id"), sequenceValue($0, "versionSequence")) })
    try expect(sequenceByID["prepend-v1"] == "1", "existing v1 sequence must remain stable")
    try expect(sequenceByID["prepend-v2"] == "2", "existing v2 sequence must remain stable")
    try expect(sequenceByID["prepend-v3"] == "3", "prepended new version must receive old MAX+1")
}

func testPromptVersionSequenceMigrationPreserves500VersionDetailOrder() async throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    var item = sequenceFixtureItem(id: "sequence-detail-500")
    item.versions = (0..<500).map { index in
        PromptVersion(
            id: "detail-v\(index)",
            promptItemId: item.id,
            version: "V\(index)",
            prompt: "prompt \(index)",
            createdAt: Date(timeIntervalSince1970: 1_704_067_200 + Double(index / 2))
        )
    }
    try repository.saveItem(item)
    let cachedBeforeMigration = try PromptItemDetailService(databaseURL: repository.databaseURL)
    _ = try repository.prepareVersionSequenceMigration()
    _ = try repository.runVersionSequenceMigration(batchSize: 100)
    guard let loaded = try repository.loadItems().first(where: { $0.id == item.id }),
          let detail = try await cachedBeforeMigration.itemDetail(id: item.id) else {
        throw CoreUnitTestError.failure("500-version migration detail fixture should load")
    }
    try expect(detail.versions.map(\.id) == loaded.versions.map(\.id), "ready Detail must preserve migrated 500-version order")
    try expect(detail.currentVersion?.id == loaded.currentVersion?.id, "ready Detail currentVersion must match migrated loader")
}

func testPromptVersionDetailCachedServiceSwitchesToPersistedOffsetAndFractionalOrder() async throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let item = sequenceFixtureItem(id: "detail-dynamic-ready")
    try repository.saveItem(item)
    let database = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    let rawValues = [
        ("detail-valid", "2024-01-01T00:00:00Z"),
        ("detail-fractional", "2024-01-01T00:00:00.1Z"),
        ("detail-offset", "2024-01-01T01:00:00+01:00"),
        ("detail-malformed", "not-a-date")
    ]
    for (id, createdAt) in rawValues {
        try insertLegacySequenceVersion(
            id: id,
            itemID: item.id,
            prompt: id,
            createdAt: createdAt,
            into: database
        )
    }
    let cachedBeforeMigration = try PromptItemDetailService(databaseURL: repository.databaseURL)
    let legacyOrder = try repository.loadItems().first { $0.id == item.id }?.versions.map(\.id) ?? []
    _ = try repository.prepareVersionSequenceMigration()
    _ = try repository.runVersionSequenceMigration(
        batchSize: 10,
        observationClock: VersionSequenceObservationClock(
            dates: [Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: 1)]
        )
    )
    let expectedOrder = try repository.loadItems().first { $0.id == item.id }?.versions.map(\.id) ?? []
    let detail = try await cachedBeforeMigration.itemDetail(id: item.id)
    try expect(detail?.versions.map(\.id) == expectedOrder, "cached Detail service must switch to persisted ready ordering")
    try expect(detail?.versions.map(\.id) != legacyOrder, "offset/fractional fallback fixture must distinguish legacy ordering")
}

func testPromptVersionDetailPreReadySuppressesMetadataAndMatchesBackfillPrependLegacyOrder() async throws {
    let url = try temporaryLibraryURL()
    let repository = try PromptRepository(libraryURL: url)
    var processed = sequenceFixtureItem(id: "a-pre-ready")
    let equalDate = Date(timeIntervalSince1970: 1_704_067_200)
    processed.versions = [
        PromptVersion(id: "pre-v1", promptItemId: processed.id, version: "V1", prompt: "one", createdAt: equalDate),
        PromptVersion(id: "pre-v2", promptItemId: processed.id, version: "V2", prompt: "two", createdAt: equalDate)
    ]
    var unprocessed = sequenceFixtureItem(id: "z-pre-ready")
    unprocessed.versions = [
        PromptVersion(id: "unprocessed-v1", promptItemId: unprocessed.id, version: "V1", prompt: "other", createdAt: equalDate)
    ]
    try repository.saveItems([processed, unprocessed])

    let cachedBeforeMigration = try PromptItemDetailService(databaseURL: repository.databaseURL)
    _ = try repository.prepareVersionSequenceMigration()
    _ = try repository.runVersionSequenceMigration(batchSize: 1, maxBatches: 1)

    let writer = try PromptRepository(libraryURL: url)
    guard var edited = try writer.loadItems().first(where: { $0.id == processed.id }) else {
        throw CoreUnitTestError.failure("processed pre-ready item should load")
    }
    edited.versions.insert(
        PromptVersion(id: "pre-v0", promptItemId: edited.id, version: "V0", prompt: "prepend", createdAt: equalDate),
        at: 0
    )
    try writer.saveItem(edited)

    guard let expected = try repository.loadItems().first(where: { $0.id == processed.id }),
          let detail = try await cachedBeforeMigration.itemDetail(id: processed.id) else {
        throw CoreUnitTestError.failure("pre-ready detail fixture should load")
    }
    try expect(detail.versions.map(\.id) == expected.versions.map(\.id), "pre-ready Detail must match legacy loader after prepend")
    try expect(
        detail.versions.allSatisfy { $0.versionSequence == nil && $0.versionCreatedAtSortKey == nil },
        "pre-ready Detail must suppress persisted sequence metadata"
    )
}

func testPromptVersionDetailReadsReadyGateOncePerRequest() async throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    var item = sequenceFixtureItem(id: "detail-gate-count")
    item.versions = [PromptVersion(id: "detail-gate-v1", promptItemId: item.id, version: "V1", prompt: "prompt")]
    try repository.saveItem(item)
    final class GateCounter: @unchecked Sendable {
        var count = 0
    }
    let counter = GateCounter()
    let service = try PromptItemDetailService(
        databaseURL: repository.databaseURL,
        versionSequenceReadyProvider: {
            counter.count += 1
            return false
        }
    )
    _ = try await service.itemDetail(id: item.id)
    try expect(counter.count == 1, "Detail must read the runtime readiness gate once per request")
}

func testPromptVersionSequenceRollbackRestoresLegacySchemaAndState() throws {
    let libraryURL = try temporaryLibraryURL()
    var before: PromptItem?
    do {
        let repository = try PromptRepository(libraryURL: libraryURL)
        let item = sequenceFixtureItem(id: "sequence-rollback")
        try repository.saveItem(item)
        do {
            let database = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
            try insertLegacySequenceVersion(id: "rollback-v1", itemID: item.id, prompt: "legacy", createdAt: "2024-01-01T00:00:00Z", into: database)
        }
        before = try repository.loadItems().first { $0.id == item.id }
        let prepared = try repository.prepareVersionSequenceMigration()
        try expect(!prepared.backupPath.isEmpty, "migration preparation should persist a rollback backup path")
        _ = try repository.runVersionSequenceMigration(batchSize: 1)
        try expect(repository.versionSequenceMigrationReady, "migration should be ready before rollback")
    }
    _ = try PromptRepository.rollbackVersionSequenceMigration(at: libraryURL)
    let restoredRepository = try PromptRepository(libraryURL: libraryURL)
    try expect(!restoredRepository.versionSequenceMigrationReady, "rollback must close the version-sequence gate")
    let after = try restoredRepository.loadItems().first { $0.id == "sequence-rollback" }
    try expect(after?.currentVersion?.id == before?.currentVersion?.id, "rollback must restore legacy currentVersion")
    let database = try SQLiteDatabase(path: restoredRepository.databaseURL.path, mode: .existingReadWrite)
    let columns = try database.query("PRAGMA table_info(prompt_versions);").compactMap { $0["name"] ?? nil }
    try expect(!columns.contains("versionSequence"), "rollback must restore the pre-migration schema")
}

func testPromptVersionSequenceRollbackRejectsTagMigrationDrift() throws {
    let url = try temporaryLibraryURL()
    let repository = try PromptRepository(libraryURL: url)
    var item = sequenceFixtureItem(id: "coexistence", sortOrder: 0)
    item.tags = ["during-version"]
    item.versions = [PromptVersion(id: "coexistence-v1", promptItemId: item.id, version: "V1", prompt: "prompt")]
    try repository.saveItem(item)
    _ = try repository.prepareVersionSequenceMigration()
    _ = try repository.runVersionSequenceMigration(batchSize: 1, maxBatches: 1)

    _ = try repository.prepareTagRelationMigration()
    item.tags = ["business-write-during-version-migration"]
    try repository.saveItem(item)
    do {
        _ = try repository.rollbackVersionSequenceMigration()
        throw CoreUnitTestError.failure("version rollback must reject when tag migration changed the backup state")
    } catch VersionSequenceMigrationError.rollbackConflict {
        // Expected: restoring the version backup would erase tag migration tables/state.
    }
    let stateDatabase = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    let relationTables = try stateDatabase.query(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'prompt_item_tags';"
    )
    try expect(!relationTables.isEmpty, "tag relation schema must survive rejected version rollback")
}

func testPromptVersionSequenceReadyRejectsSpoofedMetadata() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    var item = sequenceFixtureItem(id: "spoofed-ready")
    item.versions = [PromptVersion(id: "spoofed-ready-v1", promptItemId: item.id, version: "V1", prompt: "prompt")]
    try repository.saveItem(item)
    _ = try repository.prepareVersionSequenceMigration()
    _ = try repository.runVersionSequenceMigration(batchSize: 10)
    let database = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    try database.run("UPDATE version_sequence_migration SET version = 99 WHERE id = 1;")
    try expect(!repository.versionSequenceMigrationReady, "ready gate must reject a spoofed migration version")
    try expect(
        !PromptRepository.versionSequenceRuntimeReady(at: repository.databaseURL.path),
        "runtime readiness must reject a spoofed migration state"
    )
    try database.run(
        "UPDATE version_sequence_migration SET version = ?, afterFingerprint = ? WHERE id = 1;",
        values: [.int(Int64(PromptRepository.versionSequenceSchemaVersion)), .text("spoofed")]
    )
    try expect(!repository.versionSequenceMigrationReady, "ready gate must reject mismatched after/reconciled fingerprints")
}

func testPromptVersionSequenceReadyRejectsNonUniqueOrWrongOrderIndexes() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    var item = sequenceFixtureItem(id: "index-spoof")
    item.versions = [PromptVersion(id: "index-spoof-v1", promptItemId: item.id, version: "V1", prompt: "prompt")]
    try repository.saveItem(item)
    _ = try repository.prepareVersionSequenceMigration()
    _ = try repository.runVersionSequenceMigration(batchSize: 10)
    let database = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    try database.execute("DROP INDEX idx_phase2a4_prompt_versions_sequence_unique;")
    try database.execute("CREATE INDEX idx_phase2a4_prompt_versions_sequence_unique ON prompt_versions(promptItemId, versionSequence);")
    try expect(!repository.versionSequenceMigrationReady, "ready gate must reject a non-unique sequence index")

    try database.execute("DROP INDEX idx_phase2a4_prompt_versions_sequence_unique;")
    try database.execute("CREATE UNIQUE INDEX idx_phase2a4_prompt_versions_sequence_unique ON prompt_versions(promptItemId, versionSequence DESC);")
    try expect(!repository.versionSequenceMigrationReady, "ready gate must reject a wrong sequence index order")
}

func testSQLiteQueryPreservesEmbeddedNULText() async throws {
    let url = try temporaryLibraryURL().appendingPathComponent("nul.sqlite")
    let database = try SQLiteDatabase(path: url.path)
    let row = try database.query("SELECT 'a' || char(0) || 'b' AS value;").first
    try expect(row?["value"] ?? nil == "a\0b", "SQLite row conversion must preserve embedded NUL bytes")
    let read = try SQLiteReadConnection(path: url.path)
    let readRows = try await read.query(sql: "SELECT 'a' || char(0) || 'b' AS value;", values: [])
    try expect(readRows.first?["value"] ?? nil == "a\0b", "SQLite read connection must preserve embedded NUL bytes")
}

func testTagRelationRollbackRejectsVersionMigrationDrift() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    var item = sequenceFixtureItem(id: "reverse-coexistence", sortOrder: 0)
    item.tags = ["reverse"]
    item.versions = [PromptVersion(id: "reverse-v1", promptItemId: item.id, version: "V1", prompt: "prompt")]
    try repository.saveItem(item)
    _ = try repository.prepareTagRelationMigration()
    _ = try repository.runTagRelationBackfill(batchSize: 1, maxBatches: 1)
    _ = try repository.prepareVersionSequenceMigration()
    do {
        _ = try repository.rollbackTagRelationMigration()
        throw CoreUnitTestError.failure("tag rollback must reject when version migration state exists")
    } catch TagRelationMigrationError.rollbackConflict {
        // Expected: restoring the tag backup would erase version columns/state.
    }
}

func testTagRelationRollbackRejectsExternalBusinessWriteAndPreservesLiveBytes() throws {
    let url = try temporaryLibraryURL()
    let repository = try PromptRepository(libraryURL: url)
    var item = sequenceFixtureItem(id: "tag-rollback-external")
    item.tags = ["before"]
    try repository.saveItem(item)
    _ = try repository.prepareTagRelationMigration()
    _ = try repository.runTagRelationBackfill(batchSize: 1)
    let writer = try PromptRepository(libraryURL: url)
    var edited = try writer.loadItems().first(where: { $0.id == item.id })!
    edited.tags = ["external-write"]
    try writer.saveItem(edited)
    let livePath = repository.databaseURL.path
    let beforeBytes = try Data(contentsOf: URL(fileURLWithPath: livePath))
    do {
        _ = try PromptRepository.rollbackTagRelationMigration(at: url)
        throw CoreUnitTestError.failure("tag rollback must reject an external business writer")
    } catch TagRelationMigrationError.rollbackConflict {
        // Expected: the closed-library reservation fails while either writer
        // lease is active, without touching the live database.
    }
    try expect(try Data(contentsOf: URL(fileURLWithPath: livePath)) == beforeBytes, "rejected tag rollback must preserve live bytes")
}

func testPromptVersionSequenceReadyRejectsDirectNullMetadataAndPreReadyIndexInstall() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    var item = sequenceFixtureItem(id: "null-guard")
    item.versions = [PromptVersion(id: "null-guard-v1", promptItemId: item.id, version: "V1", prompt: "prompt")]
    try repository.saveItem(item)
    let database = try SQLiteDatabase(path: repository.databaseURL.path, mode: .existingReadWrite)
    do {
        try LibraryQuerySQLBuilder.installPhase2A4LatestVersionIndex(using: database.execute)
        throw CoreUnitTestError.failure("pre-ready latest index install must be rejected")
    } catch LibraryQuerySQLBuilderError.versionSequenceNotReady {
        // Expected.
    }
    _ = try repository.prepareVersionSequenceMigration()
    _ = try repository.runVersionSequenceMigration(batchSize: 10)
    var rejectedNullInsert = false
    do {
        try database.run(
            "INSERT INTO prompt_versions (id, promptItemId, version, prompt, negativePrompt, parametersJSON, note, createdAt, versionCreatedAtSortKey, versionSequence) VALUES (?, ?, ?, ?, '', '{}', '', ?, NULL, NULL);",
            values: [.text("null-guard-v2"), .text(item.id), .text("V2"), .text("bad"), .text("2024-01-01T00:00:00Z")]
        )
    } catch {
        rejectedNullInsert = true
    }
    try expect(rejectedNullInsert, "ready direct SQL insert with NULL metadata must be rejected")
}

func testPromptVersionSequenceFactoryAutomaticallyOpensReadyCapability() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    var item = sequenceFixtureItem(id: "factory-ready")
    item.versions = [PromptVersion(id: "factory-v1", promptItemId: item.id, version: "V1", prompt: "prompt")]
    try repository.saveItem(item)
    _ = try repository.prepareVersionSequenceMigration()
    _ = try repository.runVersionSequenceMigration(batchSize: 10)
    _ = try repository.prepareItemSequenceMigration()
    _ = try repository.runItemSequenceMigration(batchSize: 10)
    let read = try SQLiteReadConnection(path: repository.databaseURL.path)
    let service = LibraryQueryService(executor: read, repository: repository)
    try expect(service.capabilities.versionSequenceReady, "repository factory must pass ready capability automatically")
    let page = try LibraryQuerySQLBuilder.build(LibraryQuery(pageSize: 1), capabilities: service.capabilities)
    try expect(!page.sql.contains("rowid"), "factory ready runtime SQL must not use rowid")
}

func testPromptVersionSequenceMigrationFailureKeepsDatabaseOnRestoreSourceError() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    var item = sequenceFixtureItem(id: "restore-failure")
    item.versions = [PromptVersion(id: "restore-v1", promptItemId: item.id, version: "V1", prompt: "prompt")]
    try repository.saveItem(item)
    let databaseURL = repository.databaseURL
    let database = try SQLiteDatabase(path: databaseURL.path, mode: .existingReadWrite)
    let badSource = repository.libraryURL.appendingPathComponent("backups/not-a-sqlite.sqlite")
    try Data("not sqlite".utf8).write(to: badSource)
    let before = try Data(contentsOf: databaseURL)
    var failed = false
    do {
        try database.restore(fromReadOnlyPath: badSource.path)
    } catch {
        failed = true
    }
    try expect(failed, "invalid staged restore source must fail")
    try expect(try database.query("SELECT COUNT(*) AS count FROM prompt_items;").first != nil, "failed restore must leave original handle usable")
    try expect(try Data(contentsOf: databaseURL) == before, "failed restore must preserve original database bytes")
}

func testSQLiteRestoreFirstMoveFailurePreservesLiveBytes() throws {
    let root = try temporaryLibraryURL()
    let databaseURL = root.appendingPathComponent("live.sqlite")
    let backupURL = root.appendingPathComponent("backup.sqlite")
    let database = try SQLiteDatabase(path: databaseURL.path)
    try database.execute("CREATE TABLE sample(id TEXT PRIMARY KEY);")
    try database.run("INSERT INTO sample(id) VALUES ('live');")
    try SQLiteDatabase.backup(fromReadOnlyPath: databaseURL.path, to: backupURL.path)
    let before = try Data(contentsOf: databaseURL)
    var moveCount = 0
    var failed = false
    do {
        try database.restore(fromReadOnlyPath: backupURL.path, moveItem: { _, _ in
            moveCount += 1
            throw NSError(domain: "injected-move", code: 1)
        })
    } catch {
        failed = true
    }
    try expect(failed && moveCount == 1, "injected first move failure must be surfaced")
    let after = try Data(contentsOf: databaseURL)
    try expect(after == before, "first move failure must preserve live database bytes")
    try expect(try database.query("SELECT COUNT(*) AS count FROM sample;").first?["count"] ?? nil == "1", "live handle must reopen after first move failure")
}
