import Foundation
import SQLite3

public enum ItemSequenceMigrationPhase: String, Codable, Equatable, Sendable {
    case notStarted
    case backfilling
    case ready
    case failed
}

public typealias ItemSequenceObservationClock = VersionSequenceObservationClock

public struct ItemSequenceMigrationState: Codable, Equatable, Sendable {
    public let version: Int
    public let migrationID: String
    public let checksum: String
    public let phase: ItemSequenceMigrationPhase
    public let lastProcessedItemID: String?
    public let lastProcessedRowID: Int64?
    public let processedCount: Int
    public let totalCount: Int
    public let nextSequence: Int64
    public let backupPath: String
    public let beforeFingerprint: String
    public let reconciledFingerprint: String
    public let relatedMigrationFingerprint: String
    public let changeCounter: Int64
    public let checkpointChangeCounter: Int64
    public let afterFingerprint: String?
    public let errorMessage: String?
    public let updatedAt: Date

    public init(
        version: Int = 1,
        migrationID: String = PromptRepository.itemSequenceMigrationID,
        checksum: String = PromptRepository.itemSequenceMigrationChecksum,
        phase: ItemSequenceMigrationPhase = .notStarted,
        lastProcessedItemID: String? = nil,
        lastProcessedRowID: Int64? = nil,
        processedCount: Int = 0,
        totalCount: Int = 0,
        nextSequence: Int64 = 0,
        backupPath: String = "",
        beforeFingerprint: String = "",
        reconciledFingerprint: String = "",
        relatedMigrationFingerprint: String = "",
        changeCounter: Int64 = 0,
        checkpointChangeCounter: Int64 = 0,
        afterFingerprint: String? = nil,
        errorMessage: String? = nil,
        updatedAt: Date = Date(timeIntervalSince1970: 0)
    ) {
        self.version = version
        self.migrationID = migrationID
        self.checksum = checksum
        self.phase = phase
        self.lastProcessedItemID = lastProcessedItemID
        self.lastProcessedRowID = lastProcessedRowID
        self.processedCount = processedCount
        self.totalCount = totalCount
        self.nextSequence = nextSequence
        self.backupPath = backupPath
        self.beforeFingerprint = beforeFingerprint
        self.reconciledFingerprint = reconciledFingerprint
        self.relatedMigrationFingerprint = relatedMigrationFingerprint
        self.changeCounter = changeCounter
        self.checkpointChangeCounter = checkpointChangeCounter
        self.afterFingerprint = afterFingerprint
        self.errorMessage = errorMessage
        self.updatedAt = updatedAt
    }

    public var isReady: Bool { phase == .ready }
}

public struct ItemSequenceMigrationResult: Equatable, Sendable {
    public let completed: Bool
    public let processedCount: Int
    public let totalCount: Int
    public let lastProcessedItemID: String?
    public let phase: ItemSequenceMigrationPhase

    public init(completed: Bool, processedCount: Int, totalCount: Int, lastProcessedItemID: String?, phase: ItemSequenceMigrationPhase) {
        self.completed = completed
        self.processedCount = processedCount
        self.totalCount = totalCount
        self.lastProcessedItemID = lastProcessedItemID
        self.phase = phase
    }
}

public enum ItemSequenceMigrationError: Error, LocalizedError, Equatable, Sendable {
    case notPrepared
    case migrationFailed(String)
    case invalidBatchSize
    case invalidMaxBatches
    case schemaNotReady
    case externalDrift(expected: String, actual: String)
    case rollbackConflict(String)

    public var errorDescription: String? {
        switch self {
        case .notPrepared: "Prompt-item sequence migration has not been prepared"
        case .migrationFailed(let message): "Prompt-item sequence migration failed: \(message)"
        case .invalidBatchSize: "Prompt-item sequence migration batch size must be greater than zero"
        case .invalidMaxBatches: "Prompt-item sequence migration maxBatches must be non-negative"
        case .schemaNotReady: "Prompt-item sequence schema is not ready"
        case .externalDrift(let expected, let actual): "Prompt-item migration detected unreconciled external drift (expected \(expected), actual \(actual))"
        case .rollbackConflict(let message): "Prompt-item migration rollback conflict: \(message)"
        }
    }
}

public extension PromptRepository {
    static let itemSequenceMigrationID = "prompt-item-sequence-v1"
    static let itemSequenceMigrationChecksum = "prompt-item-sequence-v1:createdAt-date-micros+global-sequence"
    static let itemSequenceSchemaVersion = 1
    /// Sequences allocated by ordinary writers while the historical backfill
    /// is still running live above this range.  The backfill later assigns all
    /// history (including those rows) in observation order, so a concurrent
    /// writer can never interleave before an unprocessed legacy row.
    static let itemSequenceProvisionalBase: Int64 = 4_000_000_000_000_000_000
    /// Durable counter seed for the provisional writer range.  The counter is
    /// incremented in migration metadata under the repository write lock so a
    /// writer never needs to scan prompt_items for MAX(itemSequence).
    static let itemSequenceProvisionalInitial: Int64 = itemSequenceProvisionalBase - 1

    @discardableResult
    static func rollbackItemSequenceMigration(at libraryURL: URL) throws -> ItemSequenceMigrationState {
        let path = libraryURL.appendingPathComponent("database/promptstudio.sqlite").path
        let hub = ItemDetailInvalidationHub.shared(for: libraryURL)
        var restored = false
        do {
            let state = try PromptRepositoryMigrationCoordinator.shared.withClosedLibraryReservation(path: path) {
                let repository = try PromptRepository(libraryURL: libraryURL, libraryDataRevision: nil, itemDetailInvalidationHub: nil, registerMigrationLease: false)
                let before = try repository.itemSequenceMigrationState()
                let state = try repository.rollbackItemSequenceMigrationUnlocked()
                restored = !before.backupPath.isEmpty
                return state
            }
            // Whole-file restore cannot notify while the reservation is held:
            // subscribers may re-enter a repository writer.  Publish only
            // after the closed-library reservation has released its mutex.
            // A live repository with an injected custom hub is rejected by
            // the same lease check, so no live custom-hub controller can
            // coexist with this restore; the shared hub is sufficient here.
            if restored { _ = hub.invalidateAll() }
            return state
        } catch PromptRepositoryMigrationCoordinatorError.activeHandles {
            throw ItemSequenceMigrationError.rollbackConflict("library handles must be closed before static item rollback")
        } catch PromptRepositoryMigrationCoordinatorError.libraryReserved {
            throw ItemSequenceMigrationError.rollbackConflict("library migration reservation is already active")
        }
    }

    var itemSequenceMigrationReady: Bool {
        guard let state = try? itemSequenceMigrationState(), state.isReady,
              state.version == Self.itemSequenceSchemaVersion,
              state.migrationID == Self.itemSequenceMigrationID,
              state.checksum == Self.itemSequenceMigrationChecksum,
              let after = state.afterFingerprint, !after.isEmpty,
              state.reconciledFingerprint == after,
              (try? itemSequenceSchemaIsReady()) == true else { return false }
        return true
    }

    static func itemSequenceRuntimeReady(at path: String) -> Bool {
        guard let database = try? SQLiteDatabase(path: path, mode: .existingReadWrite),
              let rows = try? database.query("SELECT * FROM item_sequence_migration WHERE id = 1;"),
              let row = rows.first,
              itemSequenceRequired(row, "phase") == ItemSequenceMigrationPhase.ready.rawValue,
              Int(itemSequenceRequired(row, "version")) == itemSequenceSchemaVersion,
              itemSequenceRequired(row, "migrationID") == itemSequenceMigrationID,
              itemSequenceRequired(row, "checksum") == itemSequenceMigrationChecksum,
              let after = itemSequenceOptional(row, "afterFingerprint"), !after.isEmpty,
              itemSequenceOptional(row, "reconciledFingerprint") == after,
              (try? itemSequenceSchemaContractIsReady(in: database)) == true else { return false }
        return true
    }

    func prepareItemSequenceMigration() throws -> ItemSequenceMigrationState {
        try PromptRepositoryMigrationCoordinator.shared.withMigrationLock(path: databaseURL.path) {
            try prepareItemSequenceMigrationUnlocked()
        }
    }

    private func prepareItemSequenceMigrationUnlocked() throws -> ItemSequenceMigrationState {
        let existing = try itemSequenceMigrationState()
        switch existing.phase {
        case .ready, .backfilling: return existing
        case .failed: throw ItemSequenceMigrationError.migrationFailed(existing.errorMessage ?? "unknown failure")
        case .notStarted: break
        }

        let backupPath = libraryURL.appendingPathComponent("backups", isDirectory: true)
            .appendingPathComponent("promptstudio-item-sequence-\(UUID().uuidString).sqlite").path
        let tables = ["prompt_items", "prompt_versions", "tags", "model_profiles", "library_folders"]
        var counts: [String: Int] = [:]
        for table in tables {
            counts[table] = Int((try database.query("SELECT COUNT(*) AS count FROM \(table);").first?["count"] ?? nil) ?? "0") ?? 0
        }
        for table in ["prompt_item_tags", "tag_relation_migration", "version_sequence_migration"] {
            let exists = !(try database.query("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?;", values: [.text(table)])).isEmpty
            if exists { counts[table] = Int((try database.query("SELECT COUNT(*) AS count FROM \(table);").first?["count"] ?? nil) ?? "0") ?? 0 }
        }
        let before = try itemSequenceFingerprint()
        let related = try itemSequenceRelatedMigrationFingerprint()
        try database.backup(to: backupPath)
        _ = try SQLiteDatabase.validateBackup(at: backupPath, expectedTableRowCounts: counts)
        let backupDatabase = try SQLiteDatabase(path: backupPath, mode: .existingReadWrite)
        guard try computeItemSequenceFingerprint(in: backupDatabase) == before else {
            throw SQLiteError.backupFailed(
                "SQLite backup item payload fingerprint mismatch",
                resultCode: SQLITE_CORRUPT,
                extendedCode: SQLITE_CORRUPT
            )
        }

        let total = Int((try database.query("SELECT COUNT(*) AS count FROM prompt_items;").first?["count"] ?? nil) ?? "0") ?? 0
        try database.transaction {
            try createItemSequenceMetadataTable()
            try ensureItemSequenceMetadataColumns()
            try addItemSequenceColumnsIfNeeded()
            let maxSequence = try itemSequenceHistoricalMax()
            try writeItemSequenceMigrationState(phase: .backfilling, lastProcessedItemID: nil, lastProcessedRowID: nil, processedCount: 0, totalCount: total, nextSequence: maxSequence, backupPath: backupPath, beforeFingerprint: before, reconciledFingerprint: before, relatedMigrationFingerprint: related, changeCounter: 0, checkpointChangeCounter: 0, afterFingerprint: nil, errorMessage: nil)
            try database.run(
                "UPDATE item_sequence_migration SET historicalMaxScanCount=historicalMaxScanCount+1 WHERE id=1;"
            )
            try database.run(
                "UPDATE item_sequence_migration SET provisionalNextSequence=? WHERE id=1;",
                values: [.int(Self.itemSequenceProvisionalInitial)]
            )
        }
        return try itemSequenceMigrationState()
    }

    func runItemSequenceMigration(batchSize: Int = 500, maxBatches: Int? = nil, observationClock: ItemSequenceObservationClock = ItemSequenceObservationClock()) throws -> ItemSequenceMigrationResult {
        guard batchSize > 0 else { throw ItemSequenceMigrationError.invalidBatchSize }
        if let maxBatches, maxBatches < 0 { throw ItemSequenceMigrationError.invalidMaxBatches }
        var transitionedToReady = false
        let result = try PromptRepositoryMigrationCoordinator.shared.withMigrationLock(path: databaseURL.path) {
            let wasReady = try itemSequenceMigrationState().phase == .ready
            let result = try runItemSequenceMigrationUnlocked(batchSize: batchSize, maxBatches: maxBatches, observationClock: observationClock)
            transitionedToReady = !wasReady && result.phase == .ready
            return result
        }
        // Invalidation handlers are synchronous and can perform writes.  The
        // migration lock must be released before publishing the committed
        // ready transition so a re-entrant writer cannot deadlock.
        if transitionedToReady {
            _ = itemDetailInvalidationHub.invalidateAll()
        }
        return result
    }

    private func runItemSequenceMigrationUnlocked(batchSize: Int, maxBatches: Int?, observationClock: ItemSequenceObservationClock) throws -> ItemSequenceMigrationResult {
        var state = try itemSequenceMigrationState()
        switch state.phase {
        case .notStarted: throw ItemSequenceMigrationError.notPrepared
        case .failed: throw ItemSequenceMigrationError.migrationFailed(state.errorMessage ?? "unknown failure")
        case .ready: return ItemSequenceMigrationResult(completed: true, processedCount: state.processedCount, totalCount: state.totalCount, lastProcessedItemID: state.lastProcessedItemID, phase: state.phase)
        case .backfilling: break
        }
        var batches = 0
        do {
            while maxBatches == nil || batches < maxBatches! {
                let outcome = try database.transaction { () -> (ItemSequenceMigrationState, Bool) in
                    let durable = try itemSequenceMigrationState()
                    let changeCounter = try itemSequenceChangeCounter()
                    // Writers mark the durable counter while this migration is
                    // paused between batches.  At the next locked boundary,
                    // reconcile both payload fingerprints once and advance the
                    // checkpoint.  Any later SQL drift without a marker then
                    // remains visible to the final guard.
                    var checkpointFingerprint = durable.reconciledFingerprint
                    var checkpointRelatedFingerprint = durable.relatedMigrationFingerprint
                    var checkpointCounter = durable.checkpointChangeCounter
                    if changeCounter != durable.checkpointChangeCounter {
                        checkpointFingerprint = try itemSequenceFingerprint()
                        checkpointRelatedFingerprint = try itemSequenceRelatedMigrationFingerprint()
                        checkpointCounter = changeCounter
                    }
                    let rows = try loadItemSequenceRows(afterRowID: durable.lastProcessedRowID, limit: batchSize)
                    if rows.isEmpty {
                        let fingerprint = try itemSequenceFingerprint()
                        if fingerprint != checkpointFingerprint {
                            throw ItemSequenceMigrationError.externalDrift(expected: checkpointFingerprint, actual: fingerprint)
                        }
                        let related = try itemSequenceRelatedMigrationFingerprint()
                        guard related == checkpointRelatedFingerprint else {
                            throw ItemSequenceMigrationError.externalDrift(expected: checkpointRelatedFingerprint, actual: related)
                        }
                        try finalizeItemSequenceSchema()
                        let count = try itemSequenceItemCount()
                        try writeItemSequenceMigrationState(phase: .ready, lastProcessedItemID: durable.lastProcessedItemID, lastProcessedRowID: durable.lastProcessedRowID, processedCount: count, totalCount: max(count, durable.totalCount), nextSequence: try itemSequenceMax(), backupPath: durable.backupPath, beforeFingerprint: durable.beforeFingerprint, reconciledFingerprint: checkpointFingerprint, relatedMigrationFingerprint: checkpointRelatedFingerprint, changeCounter: changeCounter, checkpointChangeCounter: checkpointCounter, afterFingerprint: checkpointFingerprint, errorMessage: nil)
                        return (try itemSequenceMigrationState(), true)
                    }

                    // `nextSequence` is persisted at prepare and advanced by
                    // migration-owned allocation. Re-scanning prompt_items for
                    // MAX(itemSequence) here would make batch imports O(N*B).
                    var nextSequence = durable.nextSequence
                    var lastID: String?
                    var lastRowID: Int64?
                    for row in rows {
                        let rowID = Int64(itemSequenceRequired(row, "rowid")) ?? 0
                        let id = itemSequenceRequired(row, "id")
                        lastID = id; lastRowID = rowID
                        let existing = try database.query("SELECT itemSequence, itemCreatedAtSortKey FROM prompt_items WHERE id=?;", values: [.text(id)]).first
                        let sequence: Int64
                        if let raw = existing?["itemSequence"] ?? nil,
                           let parsed = Int64(raw), parsed > 0,
                           parsed < Self.itemSequenceProvisionalBase {
                            sequence = parsed; nextSequence = max(nextSequence, parsed)
                        } else {
                            guard nextSequence < Int64.max else {
                                throw SQLiteError.stepFailed("item sequence exhausted during historical backfill", resultCode: SQLITE_FULL, extendedCode: SQLITE_FULL)
                            }
                            nextSequence += 1; sequence = nextSequence
                        }
                        let rawDate = itemSequenceRequired(row, "createdAt")
                        let sortKey: Int64
                        if let raw = existing?["itemCreatedAtSortKey"] ?? nil, let parsed = Int64(raw) { sortKey = parsed }
                        else if let observation = PromptItemCreatedAtSupport.legacyObservation(from: rawDate) { sortKey = observation.sortKey }
                        else { sortKey = ItemSequenceTimestampSupport.sortKey(for: try observationClock.observe()) }
                        let lastUsedRaw = itemSequenceRequired(row, "lastUsedAt")
                        // The createdAt compatibility freeze intentionally
                        // applies only to item creation.  Keep the existing
                        // last-used parser/ordering contract unchanged.
                        let lastUsedSortKey = ItemSequenceTimestampSupport.sortKey(for: ItemSequenceTimestampSupport.legacyDate(from: lastUsedRaw) ?? Date(timeIntervalSince1970: 0))
                        try database.run("UPDATE prompt_items SET itemCreatedAtSortKey=?, itemLastUsedAtSortKey=?, itemSequence=? WHERE id=?;", values: [.int(sortKey), .int(lastUsedSortKey), .int(sequence), .text(id)])
                    }
                    let processed = durable.processedCount + rows.count
                    let hasMore = !(try loadItemSequenceRows(afterRowID: lastRowID, limit: 1)).isEmpty
                    if hasMore {
                        // Ordinary checkpoints carry the last reconciled
                        // fingerprints.  Avoid rescanning all business tables
                        // on every batch; the final boundary performs the full
                        // verification, while a changed marker is reconciled
                        // once at the next batch start above.
                        try writeItemSequenceMigrationState(phase: .backfilling, lastProcessedItemID: lastID, lastProcessedRowID: lastRowID, processedCount: processed, totalCount: max(processed, durable.totalCount), nextSequence: nextSequence, backupPath: durable.backupPath, beforeFingerprint: durable.beforeFingerprint, reconciledFingerprint: checkpointFingerprint, relatedMigrationFingerprint: checkpointRelatedFingerprint, changeCounter: changeCounter, checkpointChangeCounter: checkpointCounter, afterFingerprint: nil, errorMessage: nil)
                        return (try itemSequenceMigrationState(), false)
                    }
                    let fingerprint = try itemSequenceFingerprint()
                    if fingerprint != checkpointFingerprint {
                        throw ItemSequenceMigrationError.externalDrift(expected: checkpointFingerprint, actual: fingerprint)
                    }
                    let related = try itemSequenceRelatedMigrationFingerprint()
                    if related != checkpointRelatedFingerprint {
                        throw ItemSequenceMigrationError.externalDrift(expected: checkpointRelatedFingerprint, actual: related)
                    }
                    try finalizeItemSequenceSchema()
                    let count = try itemSequenceItemCount()
                    try writeItemSequenceMigrationState(phase: .ready, lastProcessedItemID: lastID, lastProcessedRowID: lastRowID, processedCount: count, totalCount: max(count, durable.totalCount), nextSequence: try itemSequenceMax(), backupPath: durable.backupPath, beforeFingerprint: durable.beforeFingerprint, reconciledFingerprint: checkpointFingerprint, relatedMigrationFingerprint: checkpointRelatedFingerprint, changeCounter: changeCounter, checkpointChangeCounter: checkpointCounter, afterFingerprint: checkpointFingerprint, errorMessage: nil)
                    return (try itemSequenceMigrationState(), true)
                }
                state = outcome.0; batches += 1
                if outcome.1 {
                    break
                }
            }
        } catch {
            try? markItemSequenceMigrationFailed(error)
            if let migrationError = error as? ItemSequenceMigrationError, case .externalDrift = migrationError {
                throw ItemSequenceMigrationError.migrationFailed(error.localizedDescription)
            }
            throw error
        }
        return ItemSequenceMigrationResult(completed: state.phase == .ready, processedCount: state.processedCount, totalCount: state.totalCount, lastProcessedItemID: state.lastProcessedItemID, phase: state.phase)
    }

    @discardableResult
    func rollbackItemSequenceMigration() throws -> ItemSequenceMigrationState {
        throw ItemSequenceMigrationError.rollbackConflict("instance rollback is unsafe; close repositories and use static rollback")
    }

    private func rollbackItemSequenceMigrationUnlocked() throws -> ItemSequenceMigrationState {
        let state = try itemSequenceMigrationState()
        guard !state.backupPath.isEmpty else { return state }
        guard PromptRepositoryMigrationCoordinator.shared.activeCount(path: databaseURL.path) <= 1 else { throw ItemSequenceMigrationError.rollbackConflict("active repository handles prevent an atomic item rollback") }
        guard state.changeCounter == 0, state.checkpointChangeCounter == 0 else {
            throw ItemSequenceMigrationError.rollbackConflict("first-party business or related writes occurred after the item backup; refusing whole-file restore")
        }
        let expected = state.afterFingerprint ?? state.reconciledFingerprint
        guard !expected.isEmpty, try itemSequenceFingerprint() == expected else { throw ItemSequenceMigrationError.rollbackConflict("item payload changed after the migration checkpoint; refusing whole-file restore") }
        guard try itemSequenceRelatedMigrationFingerprint() == state.relatedMigrationFingerprint else { throw ItemSequenceMigrationError.rollbackConflict("tag/version migration state changed after the item backup; refusing whole-file restore") }
        try database.restore(fromReadOnlyPath: state.backupPath)
        return try itemSequenceMigrationState()
    }
}

extension PromptRepository {
    func itemSequenceMigrationState() throws -> ItemSequenceMigrationState {
        guard try itemSequenceMetadataTableExists(), let row = try database.query("SELECT * FROM item_sequence_migration WHERE id=1;").first else { return ItemSequenceMigrationState() }
        return ItemSequenceMigrationState(version: Int(itemSequenceRequired(row, "version")) ?? Self.itemSequenceSchemaVersion, migrationID: itemSequenceRequired(row, "migrationID"), checksum: itemSequenceRequired(row, "checksum"), phase: ItemSequenceMigrationPhase(rawValue: itemSequenceRequired(row, "phase")) ?? .failed, lastProcessedItemID: itemSequenceOptional(row, "lastProcessedItemID"), lastProcessedRowID: itemSequenceOptional(row, "lastProcessedRowID").flatMap(Int64.init), processedCount: Int(itemSequenceRequired(row, "processedCount")) ?? 0, totalCount: Int(itemSequenceRequired(row, "totalCount")) ?? 0, nextSequence: Int64(itemSequenceRequired(row, "nextSequence")) ?? 0, backupPath: itemSequenceRequired(row, "backupPath"), beforeFingerprint: itemSequenceRequired(row, "beforeFingerprint"), reconciledFingerprint: itemSequenceOptional(row, "reconciledFingerprint") ?? itemSequenceRequired(row, "beforeFingerprint"), relatedMigrationFingerprint: itemSequenceOptional(row, "relatedMigrationFingerprint") ?? "", changeCounter: Int64(itemSequenceRequired(row, "changeCounter")) ?? 0, checkpointChangeCounter: Int64(itemSequenceRequired(row, "checkpointChangeCounter")) ?? 0, afterFingerprint: itemSequenceOptional(row, "afterFingerprint"), errorMessage: itemSequenceOptional(row, "errorMessage"), updatedAt: ISO8601DateFormatter().date(from: itemSequenceRequired(row, "updatedAt")) ?? Date(timeIntervalSince1970: 0))
    }

    func itemSequenceStorageAvailable() -> Bool {
        guard let names = try? itemSequenceColumnNames() else { return false }
        return names.contains("itemSequence") && names.contains("itemCreatedAtSortKey") && names.contains("itemLastUsedAtSortKey")
    }

    func nextItemSequence() throws -> Int64 {
        if try itemSequenceMetadataTableExists() {
            let phase = try itemSequenceMigrationState().phase
            if phase == .backfilling {
                // The caller already holds the repository write path lock and
                // transaction. Increment the durable metadata counter in
                // place; unlike MAX(prompt_items.itemSequence), this remains
                // O(1) regardless of the historical row count.
                let changed = try database.runAndReturnChanges(
                    "UPDATE item_sequence_migration SET provisionalNextSequence=provisionalNextSequence+1, updatedAt=? WHERE id=1 AND phase=? AND typeof(provisionalNextSequence)='integer' AND provisionalNextSequence>=? AND provisionalNextSequence < ?;",
                    values: [.text(Self.itemSequenceTimestamp()), .text(ItemSequenceMigrationPhase.backfilling.rawValue), .int(Self.itemSequenceProvisionalInitial), .int(Int64.max)]
                )
                guard changed == 1 else {
                    throw SQLiteError.stepFailed("item sequence provisional range exhausted", resultCode: SQLITE_FULL, extendedCode: SQLITE_FULL)
                }
                let row = try database.query("SELECT provisionalNextSequence FROM item_sequence_migration WHERE id=1;").first
                guard let raw = row?["provisionalNextSequence"] ?? nil,
                      let sequence = Int64(raw), sequence >= Self.itemSequenceProvisionalBase else {
                    throw SQLiteError.stepFailed("item sequence provisional counter is invalid", resultCode: SQLITE_CORRUPT, extendedCode: SQLITE_CORRUPT)
                }
                return sequence
            }
            let row = try database.query("SELECT nextSequence, typeof(nextSequence) AS sequenceType FROM item_sequence_migration WHERE id=1;").first ?? [:]
            let raw = row["nextSequence"] ?? nil
            let type = row["sequenceType"] ?? nil
            guard type == "integer", let current = raw.flatMap(Int64.init), current >= 0, current < Int64.max else {
                throw SQLiteError.stepFailed("item sequence exhausted", resultCode: SQLITE_FULL, extendedCode: SQLITE_FULL)
            }
            try database.run(
                "UPDATE item_sequence_migration SET nextSequence=nextSequence+1, updatedAt=? WHERE id=1 AND typeof(nextSequence)='integer' AND nextSequence < ?;",
                values: [.text(Self.itemSequenceTimestamp()), .int(Int64.max)]
            )
            let changed = Int((try database.query("SELECT changes() AS changed;").first?["changed"] ?? nil) ?? "0") ?? 0
            guard changed == 1 else {
                throw SQLiteError.stepFailed("item sequence exhausted", resultCode: SQLITE_FULL, extendedCode: SQLITE_FULL)
            }
            return current + 1
        }
        let row = try database.query("SELECT MAX(itemSequence) AS maxSequence, typeof(MAX(itemSequence)) AS sequenceType FROM prompt_items;").first ?? [:]
        let raw = row["maxSequence"] ?? nil
        let type = row["sequenceType"] ?? nil
        let current: Int64
        if let raw {
            guard type == "integer", let parsed = Int64(raw), parsed >= 0, parsed < Int64.max else {
                throw SQLiteError.stepFailed("item sequence exhausted", resultCode: SQLITE_FULL, extendedCode: SQLITE_FULL)
            }
            current = parsed
        } else {
            current = 0
        }
        guard current < Int64.max else {
            throw SQLiteError.stepFailed("item sequence exhausted", resultCode: SQLITE_FULL, extendedCode: SQLITE_FULL)
        }
        return current + 1
    }

    func itemSequenceSortKey(for rawCreatedAt: String) -> Int64 {
        itemSequenceSortKey(for: rawCreatedAt, fallback: Date())
    }

    func itemSequenceSortKey(for rawCreatedAt: String, fallback: Date) -> Int64 {
        PromptItemCreatedAtSupport.sortKey(from: rawCreatedAt) ?? PromptItemCreatedAtSupport.sortKey(for: fallback)
    }

    func reconcileItemSequenceMigrationFingerprintIfNeeded() throws {
        guard (try? itemSequenceMetadataTableExists()) == true else { return }
        let state = try itemSequenceMigrationState()
        guard state.phase == .backfilling else { return }
        try database.run(
            "UPDATE item_sequence_migration SET changeCounter=changeCounter+1, updatedAt=? WHERE id=1;",
            values: [.text(Self.itemSequenceTimestamp())]
        )
    }

    private func createItemSequenceMetadataTable() throws {
        try database.execute("""
            CREATE TABLE IF NOT EXISTS item_sequence_migration (
                id INTEGER PRIMARY KEY CHECK(id=1), version INTEGER NOT NULL, migrationID TEXT NOT NULL, checksum TEXT NOT NULL, phase TEXT NOT NULL,
                lastProcessedItemID TEXT, lastProcessedRowID INTEGER, processedCount INTEGER NOT NULL DEFAULT 0, totalCount INTEGER NOT NULL DEFAULT 0,
                nextSequence INTEGER NOT NULL DEFAULT 0, provisionalNextSequence INTEGER NOT NULL DEFAULT \(Self.itemSequenceProvisionalInitial), backupPath TEXT NOT NULL DEFAULT '', beforeFingerprint TEXT NOT NULL DEFAULT '', reconciledFingerprint TEXT NOT NULL DEFAULT '',
                relatedMigrationFingerprint TEXT NOT NULL DEFAULT '', changeCounter INTEGER NOT NULL DEFAULT 0, checkpointChangeCounter INTEGER NOT NULL DEFAULT 0, fingerprintScanCount INTEGER NOT NULL DEFAULT 0, historicalMaxScanCount INTEGER NOT NULL DEFAULT 0,
                afterFingerprint TEXT, errorMessage TEXT, updatedAt TEXT NOT NULL
            );
            """)
    }

    private func ensureItemSequenceMetadataColumns() throws {
        let names = Set(try database.query("PRAGMA table_info(item_sequence_migration);").compactMap { $0["name"] ?? nil })
        if !names.contains("lastProcessedRowID") { try database.execute("ALTER TABLE item_sequence_migration ADD COLUMN lastProcessedRowID INTEGER;") }
        if !names.contains("nextSequence") { try database.execute("ALTER TABLE item_sequence_migration ADD COLUMN nextSequence INTEGER NOT NULL DEFAULT 0;") }
        if !names.contains("provisionalNextSequence") { try database.execute("ALTER TABLE item_sequence_migration ADD COLUMN provisionalNextSequence INTEGER NOT NULL DEFAULT \(Self.itemSequenceProvisionalInitial);") }
        if !names.contains("reconciledFingerprint") { try database.execute("ALTER TABLE item_sequence_migration ADD COLUMN reconciledFingerprint TEXT NOT NULL DEFAULT '';"); try database.execute("UPDATE item_sequence_migration SET reconciledFingerprint=beforeFingerprint WHERE reconciledFingerprint='';") }
        if !names.contains("relatedMigrationFingerprint") { try database.execute("ALTER TABLE item_sequence_migration ADD COLUMN relatedMigrationFingerprint TEXT NOT NULL DEFAULT '';") }
        if !names.contains("changeCounter") { try database.execute("ALTER TABLE item_sequence_migration ADD COLUMN changeCounter INTEGER NOT NULL DEFAULT 0;") }
        if !names.contains("checkpointChangeCounter") { try database.execute("ALTER TABLE item_sequence_migration ADD COLUMN checkpointChangeCounter INTEGER NOT NULL DEFAULT 0;") }
        if !names.contains("fingerprintScanCount") { try database.execute("ALTER TABLE item_sequence_migration ADD COLUMN fingerprintScanCount INTEGER NOT NULL DEFAULT 0;") }
        if !names.contains("historicalMaxScanCount") { try database.execute("ALTER TABLE item_sequence_migration ADD COLUMN historicalMaxScanCount INTEGER NOT NULL DEFAULT 0;") }
    }

    private func addItemSequenceColumnsIfNeeded() throws {
        let names = try itemSequenceColumnNames()
        if !names.contains("itemCreatedAtSortKey") { try database.execute("ALTER TABLE prompt_items ADD COLUMN itemCreatedAtSortKey INTEGER;") }
        if !names.contains("itemLastUsedAtSortKey") { try database.execute("ALTER TABLE prompt_items ADD COLUMN itemLastUsedAtSortKey INTEGER;") }
        if !names.contains("itemSequence") { try database.execute("ALTER TABLE prompt_items ADD COLUMN itemSequence INTEGER;") }
    }

    private func writeItemSequenceMigrationState(phase: ItemSequenceMigrationPhase, lastProcessedItemID: String?, lastProcessedRowID: Int64?, processedCount: Int, totalCount: Int, nextSequence: Int64, backupPath: String, beforeFingerprint: String, reconciledFingerprint: String, relatedMigrationFingerprint: String, changeCounter: Int64, checkpointChangeCounter: Int64, afterFingerprint: String?, errorMessage: String?) throws {
        try database.run("""
            INSERT INTO item_sequence_migration (id,version,migrationID,checksum,phase,lastProcessedItemID,lastProcessedRowID,processedCount,totalCount,nextSequence,backupPath,beforeFingerprint,reconciledFingerprint,relatedMigrationFingerprint,changeCounter,checkpointChangeCounter,afterFingerprint,errorMessage,updatedAt)
            VALUES (1,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET version=excluded.version,migrationID=excluded.migrationID,checksum=excluded.checksum,phase=excluded.phase,lastProcessedItemID=excluded.lastProcessedItemID,lastProcessedRowID=excluded.lastProcessedRowID,processedCount=excluded.processedCount,totalCount=excluded.totalCount,nextSequence=excluded.nextSequence,backupPath=excluded.backupPath,beforeFingerprint=excluded.beforeFingerprint,reconciledFingerprint=excluded.reconciledFingerprint,relatedMigrationFingerprint=excluded.relatedMigrationFingerprint,changeCounter=excluded.changeCounter,checkpointChangeCounter=excluded.checkpointChangeCounter,afterFingerprint=excluded.afterFingerprint,errorMessage=excluded.errorMessage,updatedAt=excluded.updatedAt;
            """, values: [.int(Int64(Self.itemSequenceSchemaVersion)), .text(Self.itemSequenceMigrationID), .text(Self.itemSequenceMigrationChecksum), .text(phase.rawValue), lastProcessedItemID.map { .text($0) } ?? .null, lastProcessedRowID.map { .int($0) } ?? .null, .int(Int64(processedCount)), .int(Int64(totalCount)), .int(nextSequence), .text(backupPath), .text(beforeFingerprint), .text(reconciledFingerprint), .text(relatedMigrationFingerprint), .int(changeCounter), .int(checkpointChangeCounter), afterFingerprint.map { .text($0) } ?? .null, errorMessage.map { .text($0) } ?? .null, .text(Self.itemSequenceTimestamp())])
    }

    private func markItemSequenceMigrationFailed(_ error: Error) throws {
        guard (try? itemSequenceMetadataTableExists()) == true else { return }
        let state = try itemSequenceMigrationState()
        try database.transaction { try writeItemSequenceMigrationState(phase: .failed, lastProcessedItemID: state.lastProcessedItemID, lastProcessedRowID: state.lastProcessedRowID, processedCount: state.processedCount, totalCount: state.totalCount, nextSequence: state.nextSequence, backupPath: state.backupPath, beforeFingerprint: state.beforeFingerprint, reconciledFingerprint: state.reconciledFingerprint, relatedMigrationFingerprint: state.relatedMigrationFingerprint, changeCounter: state.changeCounter, checkpointChangeCounter: state.checkpointChangeCounter, afterFingerprint: state.afterFingerprint, errorMessage: error.localizedDescription) }
    }

    private func itemSequenceMetadataTableExists() throws -> Bool {
        !(try database.query("SELECT 1 FROM sqlite_master WHERE type='table' AND name='item_sequence_migration' LIMIT 1;")).isEmpty
    }

    private func itemSequenceColumnNames() throws -> Set<String> {
        Set(try database.query("PRAGMA table_info(prompt_items);").compactMap { $0["name"] ?? nil })
    }

    private func loadItemSequenceRows(afterRowID: Int64?, limit: Int) throws -> [[String: String?]] {
        var sql = "SELECT rowid,id,createdAt,lastUsedAt FROM prompt_items"; var values: [SQLiteValue] = []
        if let afterRowID { sql += " WHERE rowid>?"; values.append(.int(afterRowID)) }
        sql += " ORDER BY rowid ASC LIMIT ?;"; values.append(.int(Int64(limit)))
        return try database.query(sql, values: values)
    }

    private func itemSequenceChangeCounter() throws -> Int64 {
        guard try itemSequenceMetadataTableExists() else { return 0 }
        return Int64((try database.query("SELECT changeCounter FROM item_sequence_migration WHERE id=1;").first?["changeCounter"] ?? nil) ?? "0") ?? 0
    }

    private func itemSequenceItemCount() throws -> Int {
        Int((try database.query("SELECT COUNT(*) AS count FROM prompt_items;").first?["count"] ?? nil) ?? "0") ?? 0
    }

    private func itemSequenceMax() throws -> Int64 {
        Int64((try database.query("SELECT COALESCE(MAX(itemSequence),0) AS maxSequence FROM prompt_items;").first?["maxSequence"] ?? nil) ?? "0") ?? 0
    }

    private func itemSequenceHistoricalMax() throws -> Int64 {
        Int64((try database.query(
            "SELECT COALESCE(MAX(itemSequence),0) AS maxSequence FROM prompt_items WHERE typeof(itemSequence)='integer' AND itemSequence>0 AND itemSequence<?;",
            values: [.int(Self.itemSequenceProvisionalBase)]
        ).first?["maxSequence"] ?? nil) ?? "0") ?? 0
    }

    private func finalizeItemSequenceSchema() throws {
        let invalid = try database.query("SELECT id FROM prompt_items WHERE typeof(itemSequence)<>'integer' OR itemSequence<=0 OR typeof(itemCreatedAtSortKey)<>'integer' OR typeof(itemLastUsedAtSortKey)<>'integer';")
        guard invalid.isEmpty else { throw ItemSequenceMigrationError.schemaNotReady }
        let ordered = try database.query("SELECT id FROM prompt_items ORDER BY itemSequence ASC, rowid ASC;")
        let offset = Int64(ordered.count) + 1_000_000_000
        for (index, row) in ordered.enumerated() { try database.run("UPDATE prompt_items SET itemSequence=? WHERE id=?;", values: [.int(offset + Int64(index)), .text(itemSequenceRequired(row, "id"))]) }
        for (index, row) in ordered.enumerated() { try database.run("UPDATE prompt_items SET itemSequence=? WHERE id=?;", values: [.int(Int64(index + 1)), .text(itemSequenceRequired(row, "id"))]) }
        try database.execute("DROP INDEX IF EXISTS idx_phase2a4_1_prompt_items_item_sequence_unique; CREATE UNIQUE INDEX idx_phase2a4_1_prompt_items_item_sequence_unique ON prompt_items(itemSequence);")
        for sql in [
            "CREATE INDEX IF NOT EXISTS idx_phase2a4_1_prompt_items_all ON prompt_items(sortOrder ASC,itemCreatedAtSortKey DESC,itemSequence ASC) WHERE deletedAt IS NULL;",
            "CREATE INDEX IF NOT EXISTS idx_phase2a4_1_prompt_items_folder ON prompt_items(folderId,sortOrder ASC,itemCreatedAtSortKey DESC,itemSequence ASC) WHERE deletedAt IS NULL;",
            "CREATE INDEX IF NOT EXISTS idx_phase2a4_1_prompt_items_type ON prompt_items(type,sortOrder ASC,itemCreatedAtSortKey DESC,itemSequence ASC) WHERE deletedAt IS NULL;",
            "CREATE INDEX IF NOT EXISTS idx_phase2a4_1_prompt_items_model ON prompt_items(modelId,sortOrder ASC,itemCreatedAtSortKey DESC,itemSequence ASC) WHERE deletedAt IS NULL;",
            "CREATE INDEX IF NOT EXISTS idx_phase2a4_1_prompt_items_favorite ON prompt_items(favorite,sortOrder ASC,itemCreatedAtSortKey DESC,itemSequence ASC) WHERE deletedAt IS NULL;",
            "CREATE INDEX IF NOT EXISTS idx_phase2a4_1_prompt_items_recent ON prompt_items(itemLastUsedAtSortKey DESC,itemCreatedAtSortKey DESC,itemSequence ASC) WHERE deletedAt IS NULL;",
            "CREATE INDEX IF NOT EXISTS idx_phase2a4_1_prompt_items_trash ON prompt_items(sortOrder ASC,itemCreatedAtSortKey DESC,itemSequence ASC) WHERE deletedAt IS NOT NULL;"
        ] { try database.execute(sql) }
        try database.execute("""
            DROP TRIGGER IF EXISTS prompt_items_require_sequence_insert;
            DROP TRIGGER IF EXISTS prompt_items_require_sequence_update;
            CREATE TRIGGER prompt_items_require_sequence_insert BEFORE INSERT ON prompt_items WHEN typeof(NEW.itemSequence)<>'integer' OR NEW.itemSequence<=0 OR typeof(NEW.itemCreatedAtSortKey)<>'integer' OR typeof(NEW.itemLastUsedAtSortKey)<>'integer' BEGIN SELECT RAISE(ABORT,'item sequence/date metadata must be integer'); END;
            CREATE TRIGGER prompt_items_require_sequence_update BEFORE UPDATE OF itemSequence,itemCreatedAtSortKey,itemLastUsedAtSortKey ON prompt_items WHEN typeof(NEW.itemSequence)<>'integer' OR NEW.itemSequence<=0 OR typeof(NEW.itemCreatedAtSortKey)<>'integer' OR typeof(NEW.itemLastUsedAtSortKey)<>'integer' BEGIN SELECT RAISE(ABORT,'item sequence/date metadata must be integer'); END;
            """)
        guard try itemSequenceDataIsContiguous(in: database) else { throw ItemSequenceMigrationError.schemaNotReady }
    }

    private func itemSequenceSchemaIsReady() throws -> Bool {
        try itemSequenceSchemaContractIsReady(in: database)
    }
}

private func itemSequenceSchemaContractIsReady(in database: SQLiteDatabase) throws -> Bool {
    let columns = Set(try database.query("PRAGMA table_info(prompt_items);").compactMap { $0["name"] ?? nil })
    guard columns.contains("itemSequence"), columns.contains("itemCreatedAtSortKey"), columns.contains("itemLastUsedAtSortKey") else { return false }
    let indexes = try database.query("PRAGMA index_list('prompt_items');")
    guard let unique = indexes.first(where: { itemSequenceRequired($0, "name") == "idx_phase2a4_1_prompt_items_item_sequence_unique" }), itemSequenceRequired(unique, "unique") == "1", itemSequenceRequired(unique, "partial") == "0" else { return false }
    let info = try database.query("PRAGMA index_info('idx_phase2a4_1_prompt_items_item_sequence_unique');").sorted { (Int(itemSequenceRequired($0, "seq")) ?? 0) < (Int(itemSequenceRequired($1, "seq")) ?? 0) }
    guard (info.map { itemSequenceRequired($0, "name") }) == ["itemSequence"] else { return false }
    func canonicalSchemaSQL(_ raw: String) -> String {
        // Keep every quote character. SQLite's DQS compatibility means
        // `IS "NULL"` is a string comparison, not the same predicate as
        // `IS NULL`; stripping quotes would open the readiness gate for an
        // unusable index. Whitespace outside quoted literals and the optional
        // trailing statement terminator are the only normalization allowed.
        let lowercased = raw.lowercased()
        var result = ""
        var index = lowercased.startIndex
        var quote: Character?
        while index < lowercased.endIndex {
            let character = lowercased[index]
            index = lowercased.index(after: index)
            if let activeQuote = quote {
                result.append(character)
                if character == activeQuote {
                    if index < lowercased.endIndex, lowercased[index] == activeQuote {
                        result.append(lowercased[index])
                        index = lowercased.index(after: index)
                    } else {
                        quote = nil
                    }
                }
            } else if character == "'" || character == "\"" || character == "`" {
                quote = character
                result.append(character)
            } else if character == "[" {
                quote = "]"
                result.append(character)
            } else if !character.isWhitespace {
                result.append(character)
            }
        }
        while result.last == ";" {
            result.removeLast()
        }
        return result
    }
    func hasIndex(_ name: String, columns: [String], directions: [String], predicate: String? = nil, firstAscendingExplicit: Bool = true) throws -> Bool {
        guard indexes.contains(where: { itemSequenceRequired($0, "name") == name }) else { return false }
        let details = try database.query("PRAGMA index_xinfo('\(name)');")
            .filter { itemSequenceRequired($0, "key") == "1" }
            .sorted { (Int(itemSequenceRequired($0, "seqno")) ?? 0) < (Int(itemSequenceRequired($1, "seqno")) ?? 0) }
        guard details.map({ itemSequenceRequired($0, "name") }) == columns,
              details.map({ itemSequenceRequired($0, "desc") }) == directions else { return false }
        guard let predicate else {
            // The global sequence index must cover every row.  A partial
            // UNIQUE index would silently allow duplicate NULL/unmatched rows.
            guard itemSequenceRequired(indexes.first(where: { itemSequenceRequired($0, "name") == name }) ?? [:], "partial") == "0" else { return false }
            return true
        }
        guard let schema = try database.query("SELECT sql FROM sqlite_master WHERE type='index' AND name=?;", values: [.text(name)]).first else { return false }
        let sql = canonicalSchemaSQL(itemSequenceRequired(schema, "sql"))
        let terms = zip(columns, directions).enumerated().map { index, pair in
            let (column, direction) = pair
            if direction == "0", index == 0, !firstAscendingExplicit {
                return column
            }
            return "\(column) \(direction == "1" ? "DESC" : "ASC")"
        }.joined(separator: ",")
        let expected = canonicalSchemaSQL("CREATE INDEX \(name) ON prompt_items(\(terms)) \(predicate);")
        return sql == expected
    }
    guard try hasIndex("idx_phase2a4_1_prompt_items_all", columns: ["sortOrder", "itemCreatedAtSortKey", "itemSequence"], directions: ["0", "1", "0"], predicate: "WHERE deletedAt IS NULL"),
          try hasIndex("idx_phase2a4_1_prompt_items_folder", columns: ["folderId", "sortOrder", "itemCreatedAtSortKey", "itemSequence"], directions: ["0", "0", "1", "0"], predicate: "WHERE deletedAt IS NULL", firstAscendingExplicit: false),
          try hasIndex("idx_phase2a4_1_prompt_items_type", columns: ["type", "sortOrder", "itemCreatedAtSortKey", "itemSequence"], directions: ["0", "0", "1", "0"], predicate: "WHERE deletedAt IS NULL", firstAscendingExplicit: false),
          try hasIndex("idx_phase2a4_1_prompt_items_model", columns: ["modelId", "sortOrder", "itemCreatedAtSortKey", "itemSequence"], directions: ["0", "0", "1", "0"], predicate: "WHERE deletedAt IS NULL", firstAscendingExplicit: false),
          try hasIndex("idx_phase2a4_1_prompt_items_favorite", columns: ["favorite", "sortOrder", "itemCreatedAtSortKey", "itemSequence"], directions: ["0", "0", "1", "0"], predicate: "WHERE deletedAt IS NULL", firstAscendingExplicit: false),
          try hasIndex("idx_phase2a4_1_prompt_items_recent", columns: ["itemLastUsedAtSortKey", "itemCreatedAtSortKey", "itemSequence"], directions: ["1", "1", "0"], predicate: "WHERE deletedAt IS NULL"),
          try hasIndex("idx_phase2a4_1_prompt_items_trash", columns: ["sortOrder", "itemCreatedAtSortKey", "itemSequence"], directions: ["0", "1", "0"], predicate: "WHERE deletedAt IS NOT NULL") else { return false }
    let rows = try database.query("SELECT name,sql FROM sqlite_master WHERE type='trigger' AND name IN ('prompt_items_require_sequence_insert','prompt_items_require_sequence_update');")
    let sql = Dictionary(uniqueKeysWithValues: rows.map { (itemSequenceRequired($0, "name"), canonicalSchemaSQL(itemSequenceRequired($0, "sql"))) })
    let expectedInsert = canonicalSchemaSQL("CREATE TRIGGER prompt_items_require_sequence_insert BEFORE INSERT ON prompt_items WHEN typeof(NEW.itemSequence)<>'integer' OR NEW.itemSequence<=0 OR typeof(NEW.itemCreatedAtSortKey)<>'integer' OR typeof(NEW.itemLastUsedAtSortKey)<>'integer' BEGIN SELECT RAISE(ABORT,'item sequence/date metadata must be integer'); END;")
    let expectedUpdate = canonicalSchemaSQL("CREATE TRIGGER prompt_items_require_sequence_update BEFORE UPDATE OF itemSequence,itemCreatedAtSortKey,itemLastUsedAtSortKey ON prompt_items WHEN typeof(NEW.itemSequence)<>'integer' OR NEW.itemSequence<=0 OR typeof(NEW.itemCreatedAtSortKey)<>'integer' OR typeof(NEW.itemLastUsedAtSortKey)<>'integer' BEGIN SELECT RAISE(ABORT,'item sequence/date metadata must be integer'); END;")
    guard sql["prompt_items_require_sequence_insert"] == expectedInsert,
          sql["prompt_items_require_sequence_update"] == expectedUpdate else { return false }
    return true
}

private func itemSequenceDataIsContiguous(in database: SQLiteDatabase) throws -> Bool {
    guard try database.query("SELECT 1 FROM prompt_items WHERE typeof(itemSequence)<>'integer' OR itemSequence<=0 OR typeof(itemCreatedAtSortKey)<>'integer' OR typeof(itemLastUsedAtSortKey)<>'integer' LIMIT 1;").isEmpty else { return false }
    guard try database.query("SELECT itemSequence FROM prompt_items GROUP BY itemSequence HAVING COUNT(*)>1 LIMIT 1;").isEmpty else { return false }
    let row = try database.query("SELECT COUNT(*) AS count,COALESCE(MIN(itemSequence),0) AS minSequence,COALESCE(MAX(itemSequence),0) AS maxSequence FROM prompt_items;").first ?? [:]
    let count = Int(itemSequenceRequired(row, "count")) ?? 0
    let minValue = Int64(itemSequenceRequired(row, "minSequence")) ?? 0
    let maxValue = Int64(itemSequenceRequired(row, "maxSequence")) ?? 0
    return count == 0 ? minValue == 0 && maxValue == 0 : minValue == 1 && maxValue == Int64(count)
}

private func computeItemSequenceFingerprint(in database: SQLiteDatabase) throws -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    func feed(_ value: String) { for byte in value.utf8 { hash ^= UInt64(byte); hash &*= 1_099_511_628_211 }; hash ^= 0x1f; hash &*= 1_099_511_628_211 }
    let rows = try database.query("SELECT rowid,id,title,type,assetKind,modelId,modelName,folderId,folderName,category,assetPath,thumbnailPath,aspectRatio,width,height,format,fileSize,favorite,pinnedAt,deletedAt,createdAt,updatedAt,lastUsedAt,sortOrder,tagsJSON,referencesJSON,description,captureId,captureSourceJSON FROM prompt_items ORDER BY rowid ASC;")
    feed("prompt_items.count"); feed(String(rows.count))
    let fields = ["rowid","id","title","type","assetKind","modelId","modelName","folderId","folderName","category","assetPath","thumbnailPath","aspectRatio","width","height","format","fileSize","favorite","pinnedAt","deletedAt","createdAt","updatedAt","lastUsedAt","sortOrder","tagsJSON","referencesJSON","description","captureId","captureSourceJSON"]
    for row in rows { for field in fields { feed(itemSequenceRequired(row, field)) } }
    return String(format: "%016llx", hash)
}

private func computeItemSequenceRelatedMigrationFingerprint(in database: SQLiteDatabase) throws -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    func feed(_ value: String) { for byte in value.utf8 { hash ^= UInt64(byte); hash &*= 1_099_511_628_211 }; hash ^= 0x1f; hash &*= 1_099_511_628_211 }
    let names = ["prompt_versions","tags","model_profiles","library_folders","prompt_item_tags","tag_relation_migration","version_sequence_migration"]
    for name in names {
        guard !(try database.query("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?;", values: [.text(name)])).isEmpty else { continue }
        let schema = try database.query("SELECT type,name,sql FROM sqlite_master WHERE name=?;", values: [.text(name)])
        for row in schema { feed(itemSequenceRequired(row, "type")); feed(itemSequenceRequired(row, "name")); feed(itemSequenceRequired(row, "sql")) }
        let rows: [[String: String?]]
        if name == "prompt_item_tags" {
            rows = try database.query("SELECT * FROM prompt_item_tags ORDER BY promptItemId COLLATE BINARY ASC, ordinal ASC;")
        } else {
            rows = try database.query("SELECT * FROM \(name) ORDER BY rowid ASC;")
        }
        feed(name); feed(String(rows.count))
        for row in rows { for key in row.keys.sorted() { feed(key); feed(itemSequenceRequired(row, key)) } }
    }
    return String(format: "%016llx", hash)
}

private enum ItemSequenceTimestampSupport {
    static func date(from raw: String) -> Date? {
        PromptItemCreatedAtSupport.date(from: raw)
    }
    static func legacyDate(from raw: String) -> Date? {
        guard !raw.isEmpty else { return nil }
        return ISO8601DateFormatter().date(from: raw)
    }
    static func sortKey(for date: Date) -> Int64 {
        PromptItemCreatedAtSupport.sortKey(for: date)
    }
}

private func itemSequenceRequired(_ row: [String: String?], _ key: String) -> String {
    guard let value = row[key] ?? nil else { return "" }; return value
}

private func itemSequenceOptional(_ row: [String: String?], _ key: String) -> String? {
    guard let value = row[key] ?? nil, !value.isEmpty else { return nil }; return value
}

private extension PromptRepository {
    private func recordItemSequenceFingerprintScan() throws {
        guard (try? itemSequenceMetadataTableExists()) == true else { return }
        try database.run("UPDATE item_sequence_migration SET fingerprintScanCount=fingerprintScanCount+1 WHERE id=1;")
    }

    func itemSequenceFingerprint() throws -> String {
        try recordItemSequenceFingerprintScan()
        return try computeItemSequenceFingerprint(in: database)
    }

    func itemSequenceRelatedMigrationFingerprint() throws -> String {
        try recordItemSequenceFingerprintScan()
        return try computeItemSequenceRelatedMigrationFingerprint(in: database)
    }
    static func itemSequenceTimestamp() -> String { ISO8601DateFormatter().string(from: Date()) }
}
