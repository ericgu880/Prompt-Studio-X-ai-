import Foundation
import SQLite3

/// Durable migration phases for the prompt-version ordering contract.
public enum VersionSequenceMigrationPhase: String, Codable, Equatable, Sendable {
    case notStarted
    case backfilling
    case ready
    case failed
}

/// Injectable observation clock used only while freezing legacy `Date()`
/// fallbacks. Production uses wall-clock time; tests can provide an exact
/// sequence of observations without depending on Date.now scheduling.
public enum ObservationClockError: Error, LocalizedError, Equatable, Sendable {
    case exhausted

    public var errorDescription: String? {
        switch self {
        case .exhausted:
            "deterministic observation clock exhausted"
        }
    }
}

public final class VersionSequenceObservationClock: @unchecked Sendable {
    private let lock = NSLock()
    private var dates: [Date]
    private var index = 0
    private let fallback: () -> Date

    public init(dates: [Date] = [], fallback: @escaping () -> Date = Date.init) {
        self.dates = dates
        self.fallback = fallback
    }

    public func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        if index < dates.count {
            defer { index += 1 }
            return dates[index]
        }
        return fallback()
    }

    /// Consumes a legacy observation while preserving production's wall-clock
    /// fallback for an ordinary empty clock. A finite injected sequence fails
    /// closed after its final value so tests and migration goldens cannot drift
    /// into an unobservable Date() call.
    public func observe() throws -> Date {
        lock.lock()
        defer { lock.unlock() }
        if index < dates.count {
            defer { index += 1 }
            return dates[index]
        }
        guard dates.isEmpty else { throw ObservationClockError.exhausted }
        return fallback()
    }
}

/// Coordinates migration preparation/rollback within one process and records
/// active repository handles so a file replacement can never race a known
/// writer. Whole-file replacement cannot be made cross-process atomic here;
/// the static rollback entry points therefore require a closed repository and
/// the active-handle check fails closed for every writer visible in-process.
enum PromptRepositoryMigrationCoordinatorError: Error, LocalizedError, Equatable {
    case activeHandles
    case libraryReserved

    var errorDescription: String? {
        switch self {
        case .activeHandles:
            "active repository handles prevent a closed-library migration reservation"
        case .libraryReserved:
            "library migration reservation is active"
        }
    }
}

final class PromptRepositoryMigrationCoordinator: @unchecked Sendable {
    static let shared = PromptRepositoryMigrationCoordinator()

    private let registryLock = NSLock()
    private var pathLocks: [String: NSLock] = [:]
    private var activeLeases: [String: Set<UUID>] = [:]
    private var reservations: Set<String> = []

    private func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func lock(for path: String) -> NSLock {
        let key = normalized(path)
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = pathLocks[key] { return existing }
        let created = NSLock()
        pathLocks[key] = created
        return created
    }

    func withMigrationLock<T>(path: String, _ body: () throws -> T) rethrows -> T {
        let mutex = lock(for: path)
        mutex.lock()
        defer { mutex.unlock() }
        return try body()
    }

    /// Serializes repository write transactions that allocate migration-owned
    /// metadata. SQLite still provides the durability/rollback boundary, but
    /// this process-wide mutex avoids avoidable BUSY retries when independent
    /// repository handles concurrently allocate item or version sequences.
    func withWriteLock<T>(path: String, _ body: () throws -> T) rethrows -> T {
        let mutex = lock(for: path)
        mutex.lock()
        defer { mutex.unlock() }
        return try body()
    }

    @discardableResult
    func register(path: String) throws -> UUID {
        let key = normalized(path)
        let mutex = lock(for: key)
        mutex.lock()
        defer { mutex.unlock() }
        let lease = UUID()
        registryLock.lock()
        guard !reservations.contains(key) else {
            registryLock.unlock()
            throw PromptRepositoryMigrationCoordinatorError.libraryReserved
        }
        activeLeases[key, default: []].insert(lease)
        registryLock.unlock()
        return lease
    }

    func unregister(path: String, lease: UUID) {
        let key = normalized(path)
        registryLock.lock()
        activeLeases[key]?.remove(lease)
        if activeLeases[key]?.isEmpty == true { activeLeases.removeValue(forKey: key) }
        registryLock.unlock()
    }

    func activeCount(path: String) -> Int {
        let key = normalized(path)
        registryLock.lock()
        let count = activeLeases[key]?.count ?? 0
        registryLock.unlock()
        return count
    }

    /// Reserves a closed library while a whole-file restore is in progress.
    /// Registration takes the same path lock, so a concurrent repository
    /// cannot pass the active-count check and register before restore starts.
    func withClosedLibraryReservation<T>(path: String, _ body: () throws -> T) throws -> T {
        let key = normalized(path)
        let mutex = lock(for: key)
        mutex.lock()
        registryLock.lock()
        guard activeLeases[key]?.isEmpty != false else {
            registryLock.unlock()
            mutex.unlock()
            throw PromptRepositoryMigrationCoordinatorError.activeHandles
        }
        reservations.insert(key)
        registryLock.unlock()
        defer {
            registryLock.lock()
            reservations.remove(key)
            registryLock.unlock()
            mutex.unlock()
        }
        return try body()
    }
}

public struct VersionSequenceMigrationState: Codable, Equatable, Sendable {
    public let version: Int
    public let migrationID: String
    public let checksum: String
    public let phase: VersionSequenceMigrationPhase
    public let lastProcessedItemID: String?
    public let processedCount: Int
    public let totalCount: Int
    public let backupPath: String
    public let beforeFingerprint: String
    public let reconciledFingerprint: String
    public let tagStateFingerprint: String
    public let changeCounter: Int64
    public let checkpointChangeCounter: Int64
    public let afterFingerprint: String?
    public let errorMessage: String?
    public let updatedAt: Date

    public init(
        version: Int = 1,
        migrationID: String = "prompt-version-sequence-v1",
        checksum: String = PromptRepository.versionSequenceMigrationChecksum,
        phase: VersionSequenceMigrationPhase = .notStarted,
        lastProcessedItemID: String? = nil,
        processedCount: Int = 0,
        totalCount: Int = 0,
        backupPath: String = "",
        beforeFingerprint: String = "",
        reconciledFingerprint: String = "",
        tagStateFingerprint: String = "",
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
        self.processedCount = processedCount
        self.totalCount = totalCount
        self.backupPath = backupPath
        self.beforeFingerprint = beforeFingerprint
        self.reconciledFingerprint = reconciledFingerprint
        self.tagStateFingerprint = tagStateFingerprint
        self.changeCounter = changeCounter
        self.checkpointChangeCounter = checkpointChangeCounter
        self.afterFingerprint = afterFingerprint
        self.errorMessage = errorMessage
        self.updatedAt = updatedAt
    }

    public var isReady: Bool { phase == .ready }
}

public struct VersionSequenceMigrationResult: Equatable, Sendable {
    public let completed: Bool
    public let processedCount: Int
    public let totalCount: Int
    public let lastProcessedItemID: String?
    public let phase: VersionSequenceMigrationPhase

    public init(
        completed: Bool,
        processedCount: Int,
        totalCount: Int,
        lastProcessedItemID: String?,
        phase: VersionSequenceMigrationPhase
    ) {
        self.completed = completed
        self.processedCount = processedCount
        self.totalCount = totalCount
        self.lastProcessedItemID = lastProcessedItemID
        self.phase = phase
    }
}

public enum VersionSequenceMigrationError: Error, LocalizedError, Equatable, Sendable {
    case notPrepared
    case migrationFailed(String)
    case invalidBatchSize
    case invalidMaxBatches
    case schemaNotReady
    case externalDrift(expected: String, actual: String)
    case rollbackConflict(String)

    public var errorDescription: String? {
        switch self {
        case .notPrepared:
            "Prompt-version sequence migration has not been prepared"
        case .migrationFailed(let message):
            "Prompt-version sequence migration failed: \(message)"
        case .invalidBatchSize:
            "Prompt-version sequence migration batch size must be greater than zero"
        case .invalidMaxBatches:
            "Prompt-version sequence migration maxBatches must be non-negative"
        case .schemaNotReady:
            "Prompt-version sequence schema is not ready"
        case .externalDrift(let expected, let actual):
            "Prompt-version migration detected unreconciled external drift (expected \(expected), actual \(actual))"
        case .rollbackConflict(let message):
            "Prompt-version migration rollback conflict: \(message)"
        }
    }
}

/// One-time persistence of the legacy loader's version ordering observation.
/// The migration is opt-in and gated: before `.ready`, all reads/writes keep
/// the legacy `createdAt` path. Once ready, runtime code relies only on the
/// persisted Date sort key plus `versionSequence`; SQLite rowid is used only
/// while observing the pre-migration row order.
public extension PromptRepository {
    static let versionSequenceMigrationID = "prompt-version-sequence-v1"
    static let versionSequenceMigrationChecksum = "prompt-version-sequence-v1:createdAt-date-micros+stable-sequence"
    static let versionSequenceSchemaVersion = 1

    /// Static rollback entry point for a closed library. Callers must release
    /// all repository/read handles (including handles owned by other
    /// processes) first; whole-file replacement has no cross-process atomic
    /// quiescence primitive. The method opens one private handle only after
    /// the process-wide active-handle check passes.
    @discardableResult
    static func rollbackVersionSequenceMigration(at libraryURL: URL) throws -> VersionSequenceMigrationState {
        let databasePath = libraryURL.appendingPathComponent("database/promptstudio.sqlite").path
        do {
            return try PromptRepositoryMigrationCoordinator.shared.withClosedLibraryReservation(path: databasePath) {
                // The reservation is held while the private handle is opened,
                // so no writer can register between the active-count check and
                // the restore. This handle intentionally does not acquire a
                // repository lease of its own.
                let repository = try PromptRepository(
                    libraryURL: libraryURL,
                    libraryDataRevision: nil,
                    itemDetailInvalidationHub: nil,
                    registerMigrationLease: false
                )
                return try repository.rollbackVersionSequenceMigrationUnlocked()
            }
        } catch PromptRepositoryMigrationCoordinatorError.activeHandles {
            throw VersionSequenceMigrationError.rollbackConflict(
                "library handles must be closed before static version rollback"
            )
        } catch PromptRepositoryMigrationCoordinatorError.libraryReserved {
            throw VersionSequenceMigrationError.rollbackConflict(
                "library migration reservation is already active"
            )
        }
    }

    var versionSequenceMigrationReady: Bool {
        guard let state = try? versionSequenceMigrationState(),
              state.isReady,
              state.version == Self.versionSequenceSchemaVersion,
              state.migrationID == Self.versionSequenceMigrationID,
              state.checksum == Self.versionSequenceMigrationChecksum,
              let afterFingerprint = state.afterFingerprint,
              !afterFingerprint.isEmpty,
              state.reconciledFingerprint == afterFingerprint,
              (try? versionSequenceSchemaIsReady()) == true else {
            return false
        }
        return true
    }

    func prepareVersionSequenceMigration() throws -> VersionSequenceMigrationState {
        try PromptRepositoryMigrationCoordinator.shared.withMigrationLock(path: databaseURL.path) {
            try prepareVersionSequenceMigrationUnlocked()
        }
    }

    private func prepareVersionSequenceMigrationUnlocked() throws -> VersionSequenceMigrationState {
        let existing = try versionSequenceMigrationState()
        switch existing.phase {
        case .ready, .backfilling:
            return existing
        case .failed:
            throw VersionSequenceMigrationError.migrationFailed(existing.errorMessage ?? "unknown failure")
        case .notStarted:
            break
        }

        let backupPath = libraryURL
            .appendingPathComponent("backups", isDirectory: true)
            .appendingPathComponent("promptstudio-version-sequence-\(UUID().uuidString).sqlite")
            .path
        let protectedTables = ["prompt_items", "prompt_versions", "tags", "model_profiles", "library_folders"]
        var expectedCounts: [String: Int] = [:]
        for table in protectedTables {
            expectedCounts[table] = Int((try database.query("SELECT COUNT(*) AS count FROM \(table);").first?["count"] ?? nil) ?? "0") ?? 0
        }
        let beforeFingerprint = try versionSequenceFingerprint()
        let tagStateFingerprint = try versionSequenceTagStateFingerprint()
        for table in ["prompt_item_tags", "tag_relation_migration", "version_sequence_migration"] {
            let tableExists = try database.query(
                "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?;",
                values: [.text(table)]
            ).isEmpty == false
            if tableExists {
                expectedCounts[table] = Int((try database.query("SELECT COUNT(*) AS count FROM \(table);").first?["count"] ?? nil) ?? "0") ?? 0
            }
        }

        // The backup is deliberately complete and occurs before ALTER TABLE,
        // metadata creation, indexes, or triggers. A failed migration can
        // therefore restore the exact pre-migration schema and tag state.
        try database.backup(to: backupPath)
        _ = try SQLiteDatabase.validateBackup(at: backupPath, expectedTableRowCounts: expectedCounts)
        let backupDatabase = try SQLiteDatabase(path: backupPath, mode: .existingReadWrite)
        guard try computeVersionSequenceTagStateFingerprint(in: backupDatabase) == tagStateFingerprint else {
            throw SQLiteError.backupFailed(
                "SQLite backup business/tag schema fingerprint mismatch",
                resultCode: SQLITE_CORRUPT,
                extendedCode: SQLITE_CORRUPT
            )
        }

        do {
            let totalCount = Int((try database.query("SELECT COUNT(*) AS count FROM prompt_items;").first?["count"] ?? nil) ?? "0") ?? 0
            try database.transaction {
                try createVersionSequenceMetadataTable()
                try ensureVersionSequenceMetadataColumns()
                try addVersionSequenceColumnsIfNeeded()
                try writeVersionSequenceMigrationState(
                    phase: .backfilling,
                    lastProcessedItemID: nil,
                    processedCount: 0,
                    totalCount: totalCount,
                    backupPath: backupPath,
                    beforeFingerprint: beforeFingerprint,
                    reconciledFingerprint: beforeFingerprint,
                    tagStateFingerprint: tagStateFingerprint,
                    afterFingerprint: nil,
                    errorMessage: nil
                )
                try reconcileItemSequenceMigrationFingerprintIfNeeded()
            }
            return try versionSequenceMigrationState()
        } catch {
            // No state is written when the transactional schema preparation
            // rolls back. The legacy gate remains closed and the backup is
            // available for an explicit rollback/repair operation.
            throw error
        }
    }

    func runVersionSequenceMigration(
        batchSize: Int = 500,
        maxBatches: Int? = nil,
        observationClock: VersionSequenceObservationClock = VersionSequenceObservationClock()
    ) throws -> VersionSequenceMigrationResult {
        guard batchSize > 0 else { throw VersionSequenceMigrationError.invalidBatchSize }
        if let maxBatches, maxBatches < 0 {
            throw VersionSequenceMigrationError.invalidMaxBatches
        }
        var state = try versionSequenceMigrationState()
        switch state.phase {
        case .notStarted:
            throw VersionSequenceMigrationError.notPrepared
        case .failed:
            throw VersionSequenceMigrationError.migrationFailed(state.errorMessage ?? "unknown failure")
        case .ready:
            return VersionSequenceMigrationResult(
                completed: true,
                processedCount: state.processedCount,
                totalCount: state.totalCount,
                lastProcessedItemID: state.lastProcessedItemID,
                phase: state.phase
            )
        case .backfilling:
            break
        }

        var batchCount = 0
        do {
            while maxBatches == nil || batchCount < maxBatches! {
                let outcome = try database.transaction { () -> (VersionSequenceMigrationState, Bool) in
                    let durableState = try versionSequenceMigrationState()
                    let observedChangeCounter = try versionSequenceChangeCounter()
                    let rows = try loadVersionSequenceItemIDs(after: durableState.lastProcessedItemID, limit: batchSize)
                    guard !rows.isEmpty else {
                        // The protected payload audit is deliberately paid once,
                        // at finalization. Repository writers bump the durable
                        // counter in their transaction; direct SQL writes do not,
                        // so an unchanged counter with a changed fingerprint is
                        // rejected as unreconciled drift.
                        let fingerprint = try versionSequenceFingerprint()
                        if observedChangeCounter == durableState.checkpointChangeCounter,
                           fingerprint != durableState.reconciledFingerprint {
                            throw VersionSequenceMigrationError.externalDrift(
                                expected: durableState.reconciledFingerprint,
                                actual: fingerprint
                            )
                        }
                        try finalizeVersionSequenceSchema()
                        try writeVersionSequenceMigrationState(
                            phase: .ready,
                            lastProcessedItemID: durableState.lastProcessedItemID,
                            processedCount: durableState.processedCount,
                            totalCount: durableState.totalCount,
                            backupPath: durableState.backupPath,
                            beforeFingerprint: durableState.beforeFingerprint,
                            reconciledFingerprint: fingerprint,
                            tagStateFingerprint: durableState.tagStateFingerprint,
                            changeCounter: observedChangeCounter,
                            checkpointChangeCounter: observedChangeCounter,
                            afterFingerprint: fingerprint,
                            errorMessage: nil
                        )
                        try reconcileItemSequenceMigrationFingerprintIfNeeded()
                        return (try versionSequenceMigrationState(), true)
                    }

                    let itemIDs = rows.map { versionSequenceRequired($0, "id") }
                    try assignVersionSequences(itemIDs: itemIDs, observationClock: observationClock)
                    try reconcileItemSequenceMigrationFingerprintIfNeeded()
                    let lastID = itemIDs.last
                    let processedCount = durableState.processedCount + rows.count
                    let hasMore = try hasVersionSequenceItems(after: lastID)
                    if hasMore {
                        try writeVersionSequenceMigrationState(
                            phase: .backfilling,
                            lastProcessedItemID: lastID,
                            processedCount: processedCount,
                            totalCount: max(durableState.totalCount, processedCount),
                            backupPath: durableState.backupPath,
                            beforeFingerprint: durableState.beforeFingerprint,
                            reconciledFingerprint: durableState.reconciledFingerprint,
                            tagStateFingerprint: durableState.tagStateFingerprint,
                            changeCounter: observedChangeCounter,
                            checkpointChangeCounter: durableState.checkpointChangeCounter,
                            afterFingerprint: nil,
                            errorMessage: nil
                        )
                        try reconcileItemSequenceMigrationFingerprintIfNeeded()
                        return (try versionSequenceMigrationState(), false)
                    }

                    let fingerprint = try versionSequenceFingerprint()
                    if observedChangeCounter == durableState.checkpointChangeCounter,
                       fingerprint != durableState.reconciledFingerprint {
                        throw VersionSequenceMigrationError.externalDrift(
                            expected: durableState.reconciledFingerprint,
                            actual: fingerprint
                        )
                    }
                    try finalizeVersionSequenceSchema()
                    try writeVersionSequenceMigrationState(
                        phase: .ready,
                        lastProcessedItemID: lastID,
                        processedCount: processedCount,
                        totalCount: max(durableState.totalCount, processedCount),
                        backupPath: durableState.backupPath,
                        beforeFingerprint: durableState.beforeFingerprint,
                        reconciledFingerprint: fingerprint,
                        tagStateFingerprint: durableState.tagStateFingerprint,
                        changeCounter: observedChangeCounter,
                        checkpointChangeCounter: observedChangeCounter,
                        afterFingerprint: fingerprint,
                        errorMessage: nil
                    )
                    try reconcileItemSequenceMigrationFingerprintIfNeeded()
                    return (try versionSequenceMigrationState(), true)
                }
                state = outcome.0
                batchCount += 1
                if outcome.1 { break }
            }
        } catch {
            try? markVersionSequenceMigrationFailed(error)
            if let migrationError = error as? VersionSequenceMigrationError,
               case .externalDrift = migrationError {
                throw VersionSequenceMigrationError.migrationFailed(error.localizedDescription)
            }
            throw error
        }

        return VersionSequenceMigrationResult(
            completed: state.phase == .ready,
            processedCount: state.processedCount,
            totalCount: state.totalCount,
            lastProcessedItemID: state.lastProcessedItemID,
            phase: state.phase
        )
    }

    /// Restores the exact pre-migration backup, including any Phase 2A.2 tag
    /// relation tables/triggers captured by the backup.
    @discardableResult
    func rollbackVersionSequenceMigration() throws -> VersionSequenceMigrationState {
        throw VersionSequenceMigrationError.rollbackConflict(
            "instance rollback is unsafe; close repositories and use static rollback"
        )
    }

    private func rollbackVersionSequenceMigrationUnlocked() throws -> VersionSequenceMigrationState {
        let state = try versionSequenceMigrationState()
        guard !state.backupPath.isEmpty else { return state }
        if let itemState = try? itemSequenceMigrationState(), itemState.phase != .notStarted {
            throw VersionSequenceMigrationError.rollbackConflict(
                "item migration state exists after the version backup; refusing whole-file restore"
            )
        }
        guard PromptRepositoryMigrationCoordinator.shared.activeCount(path: databaseURL.path) <= 1 else {
            throw VersionSequenceMigrationError.rollbackConflict(
                "active repository handles prevent an atomic version rollback"
            )
        }
        guard state.changeCounter == 0, state.checkpointChangeCounter == 0 else {
            throw VersionSequenceMigrationError.rollbackConflict(
                "first-party version/business writes occurred after the version backup; refusing whole-file restore"
            )
        }
        let expectedVersionFingerprint = state.afterFingerprint ?? state.reconciledFingerprint
        let currentVersionFingerprint = try versionSequenceFingerprint()
        guard !expectedVersionFingerprint.isEmpty,
              currentVersionFingerprint == expectedVersionFingerprint else {
            throw VersionSequenceMigrationError.rollbackConflict(
                "version payload changed after the migration checkpoint; refusing whole-file restore"
            )
        }
        let currentTagState = try versionSequenceTagStateFingerprint()
        guard currentTagState == state.tagStateFingerprint else {
            throw VersionSequenceMigrationError.rollbackConflict(
                "tag migration state changed after the version backup; refusing whole-file restore"
            )
        }
        try database.restore(fromReadOnlyPath: state.backupPath)
        return try versionSequenceMigrationState()
    }

    func versionSequenceMigrationState() throws -> VersionSequenceMigrationState {
        guard try versionSequenceMetadataTableExists(),
              let row = try database.query("SELECT * FROM version_sequence_migration WHERE id = 1;").first else {
            return VersionSequenceMigrationState()
        }
        let phase = VersionSequenceMigrationPhase(rawValue: versionSequenceRequired(row, "phase")) ?? .failed
        return VersionSequenceMigrationState(
            version: Int(versionSequenceRequired(row, "version")) ?? Self.versionSequenceSchemaVersion,
            migrationID: versionSequenceRequired(row, "migrationID"),
            checksum: versionSequenceRequired(row, "checksum"),
            phase: phase,
            lastProcessedItemID: versionSequenceOptional(row, "lastProcessedItemID"),
            processedCount: Int(versionSequenceRequired(row, "processedCount")) ?? 0,
            totalCount: Int(versionSequenceRequired(row, "totalCount")) ?? 0,
            backupPath: versionSequenceRequired(row, "backupPath"),
            beforeFingerprint: versionSequenceRequired(row, "beforeFingerprint"),
            reconciledFingerprint: versionSequenceOptional(row, "reconciledFingerprint") ?? versionSequenceRequired(row, "beforeFingerprint"),
            tagStateFingerprint: versionSequenceOptional(row, "tagStateFingerprint") ?? "",
            changeCounter: Int64(versionSequenceRequired(row, "changeCounter")) ?? 0,
            checkpointChangeCounter: Int64(versionSequenceRequired(row, "checkpointChangeCounter")) ?? 0,
            afterFingerprint: versionSequenceOptional(row, "afterFingerprint"),
            errorMessage: versionSequenceOptional(row, "errorMessage"),
            updatedAt: ISO8601DateFormatter().date(from: versionSequenceRequired(row, "updatedAt")) ?? Date(timeIntervalSince1970: 0)
        )
    }
}

extension PromptRepository {
    func versionSequenceSchemaIsReady() throws -> Bool {
        try versionSequenceSchemaContractIsReady(in: database)
    }

    public static func versionSequenceRuntimeReady(at path: String) -> Bool {
        guard let database = try? SQLiteDatabase(path: path, mode: .existingReadWrite),
              let stateRows = try? database.query("SELECT * FROM version_sequence_migration WHERE id = 1;"),
              let stateRow = stateRows.first,
              versionSequenceRequired(stateRow, "phase") == VersionSequenceMigrationPhase.ready.rawValue,
              Int(versionSequenceRequired(stateRow, "version")) == versionSequenceSchemaVersion,
              versionSequenceRequired(stateRow, "migrationID") == versionSequenceMigrationID,
              versionSequenceRequired(stateRow, "checksum") == versionSequenceMigrationChecksum,
              let afterFingerprint = versionSequenceOptional(stateRow, "afterFingerprint"),
              !afterFingerprint.isEmpty,
              versionSequenceOptional(stateRow, "reconciledFingerprint") == afterFingerprint,
              (try? versionSequenceSchemaContractIsReady(in: database)) == true else {
            return false
        }
        return true
    }

    func createVersionSequenceMetadataTable() throws {
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS version_sequence_migration (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                version INTEGER NOT NULL,
                migrationID TEXT NOT NULL,
                checksum TEXT NOT NULL,
                phase TEXT NOT NULL,
                lastProcessedItemID TEXT,
                processedCount INTEGER NOT NULL DEFAULT 0,
                totalCount INTEGER NOT NULL DEFAULT 0,
                backupPath TEXT NOT NULL DEFAULT '',
                beforeFingerprint TEXT NOT NULL DEFAULT '',
                reconciledFingerprint TEXT NOT NULL DEFAULT '',
                tagStateFingerprint TEXT NOT NULL DEFAULT '',
                changeCounter INTEGER NOT NULL DEFAULT 0,
                checkpointChangeCounter INTEGER NOT NULL DEFAULT 0,
                afterFingerprint TEXT,
                errorMessage TEXT,
                updatedAt TEXT NOT NULL
            );
            """
        )
    }

    func ensureVersionSequenceMetadataColumns() throws {
        let columns = Set(try database.query("PRAGMA table_info(version_sequence_migration);").compactMap { $0["name"] ?? nil })
        if !columns.contains("reconciledFingerprint") {
            try database.execute("ALTER TABLE version_sequence_migration ADD COLUMN reconciledFingerprint TEXT NOT NULL DEFAULT '';" )
            try database.execute("UPDATE version_sequence_migration SET reconciledFingerprint = beforeFingerprint WHERE reconciledFingerprint = '';" )
        }
        if !columns.contains("tagStateFingerprint") {
            try database.execute("ALTER TABLE version_sequence_migration ADD COLUMN tagStateFingerprint TEXT NOT NULL DEFAULT '';" )
        }
        if !columns.contains("changeCounter") {
            try database.execute("ALTER TABLE version_sequence_migration ADD COLUMN changeCounter INTEGER NOT NULL DEFAULT 0;" )
        }
        if !columns.contains("checkpointChangeCounter") {
            try database.execute("ALTER TABLE version_sequence_migration ADD COLUMN checkpointChangeCounter INTEGER NOT NULL DEFAULT 0;" )
        }
    }

    func addVersionSequenceColumnsIfNeeded() throws {
        let columns = try versionSequenceColumnNames()
        if !columns.contains("versionCreatedAtSortKey") {
            try database.execute("ALTER TABLE prompt_versions ADD COLUMN versionCreatedAtSortKey INTEGER;")
        }
        if !columns.contains("versionSequence") {
            try database.execute("ALTER TABLE prompt_versions ADD COLUMN versionSequence INTEGER;")
        }
    }

    func finalizeVersionSequenceSchema() throws {
        // This is the single O(N) finalization audit. Runtime readiness stays
        // O(1) and trusts the durable state plus these schema guards. The
        // audit intentionally runs before indexes/triggers are installed so a
        // pre-trigger writer cannot smuggle TEXT, NULL, zero, or negative
        // metadata into the ready state.
        let invalidMetadata = try database.query(
            """
            SELECT promptItemId
            FROM prompt_versions
            WHERE typeof(versionSequence) <> 'integer'
               OR versionSequence <= 0
               OR typeof(versionCreatedAtSortKey) <> 'integer';
            """
        )
        guard invalidMetadata.isEmpty else { throw VersionSequenceMigrationError.schemaNotReady }

        let duplicateSequences = try database.query(
            """
            SELECT promptItemId, versionSequence
            FROM prompt_versions
            GROUP BY promptItemId, versionSequence
            HAVING COUNT(*) > 1;
            """
        )
        guard duplicateSequences.isEmpty else { throw VersionSequenceMigrationError.schemaNotReady }

        let nonContiguousSequences = try database.query(
            """
            SELECT promptItemId
            FROM prompt_versions
            GROUP BY promptItemId
            HAVING MIN(versionSequence) <> 1
                OR MAX(versionSequence) <> COUNT(*);
            """
        )
        guard nonContiguousSequences.isEmpty else { throw VersionSequenceMigrationError.schemaNotReady }

        try database.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_phase2a4_prompt_versions_sequence_unique ON prompt_versions(promptItemId, versionSequence);"
        )
        // A previous Phase 2A.4 candidate used this same name for a
        // createdAt-only index. Replace it explicitly so the ready contract
        // never accidentally inherits the old shape.
        try database.execute("DROP INDEX IF EXISTS idx_phase2a4_prompt_versions_latest;")
        try database.execute(
            "CREATE INDEX idx_phase2a4_prompt_versions_latest ON prompt_versions(promptItemId, versionCreatedAtSortKey DESC, versionSequence DESC);"
        )
        try database.execute(
            """
            DROP TRIGGER IF EXISTS prompt_versions_require_sequence_insert;
            DROP TRIGGER IF EXISTS prompt_versions_require_sequence_update;
            CREATE TRIGGER prompt_versions_require_sequence_insert
            BEFORE INSERT ON prompt_versions
            WHEN typeof(NEW.versionSequence) <> 'integer'
              OR NEW.versionSequence <= 0
              OR typeof(NEW.versionCreatedAtSortKey) <> 'integer'
            BEGIN
                SELECT RAISE(ABORT, 'versionSequence and versionCreatedAtSortKey must be integer metadata');
            END;
            CREATE TRIGGER prompt_versions_require_sequence_update
            BEFORE UPDATE OF versionSequence, versionCreatedAtSortKey ON prompt_versions
            WHEN typeof(NEW.versionSequence) <> 'integer'
              OR NEW.versionSequence <= 0
              OR typeof(NEW.versionCreatedAtSortKey) <> 'integer'
            BEGIN
                SELECT RAISE(ABORT, 'versionSequence and versionCreatedAtSortKey must be integer metadata');
            END;
            """
        )
    }

    func loadVersionSequenceItemIDs(after lastID: String?, limit: Int) throws -> [[String: String?]] {
        var sql = "SELECT id FROM prompt_items"
        var values: [SQLiteValue] = []
        if let lastID {
            sql += " WHERE id COLLATE BINARY > ?"
            values.append(.text(lastID))
        }
        sql += " ORDER BY id COLLATE BINARY ASC LIMIT ?;"
        values.append(.int(Int64(limit)))
        return try database.query(sql, values: values)
    }

    func hasVersionSequenceItems(after lastID: String?) throws -> Bool {
        try !loadVersionSequenceItemIDs(after: lastID, limit: 1).isEmpty
    }

    /// Observes the exact legacy SQL row order first, then applies the old
    /// Swift Date comparator. Equal parsed dates preserve that observed order;
    /// invalid/fractional strings call the legacy Date() fallback once per
    /// row and persist that observation as the durable sort key.
    func assignVersionSequences(itemID: String, observationClock: VersionSequenceObservationClock = VersionSequenceObservationClock()) throws {
        try assignVersionSequences(itemIDs: [itemID], observationClock: observationClock)
    }

    func assignVersionSequences(itemIDs: [String], observationClock: VersionSequenceObservationClock = VersionSequenceObservationClock()) throws {
        guard !itemIDs.isEmpty else { return }
        if itemIDs.count > 500 {
            for start in stride(from: 0, to: itemIDs.count, by: 500) {
                let end = min(start + 500, itemIDs.count)
                try assignVersionSequences(itemIDs: Array(itemIDs[start..<end]), observationClock: observationClock)
            }
            return
        }
        let placeholders = Array(repeating: "?", count: itemIDs.count).joined(separator: ",")
        let rows = try database.query(
            "SELECT rowid, id, promptItemId, createdAt FROM prompt_versions WHERE promptItemId IN (\(placeholders)) ORDER BY promptItemId COLLATE BINARY ASC, createdAt ASC, rowid ASC;",
            values: itemIDs.map(SQLiteValue.text)
        )
        var rowsByItem: [String: [[String: String?]]] = [:]
        for row in rows {
            rowsByItem[versionSequenceRequired(row, "promptItemId"), default: []].append(row)
        }
        for itemID in itemIDs {
            let rows = rowsByItem[itemID] ?? []
            let observed: [(offset: Int, versionID: String, sortKey: Int64)] = rows.enumerated().map { offset, row in
                let rawDate = versionSequenceRequired(row, "createdAt")
                let parsed = VersionSequenceTimestampSupport.date(from: rawDate)
                // Keep the old `date(...) ?? Date()` behavior exactly: each
                // malformed/fractional row gets its own observation instant,
                // then the resulting Date value is persisted for stability.
                let sortKey = parsed.map(VersionSequenceTimestampSupport.sortKey(for:))
                    ?? VersionSequenceTimestampSupport.sortKey(for: observationClock.now())
                return (offset: offset, versionID: versionSequenceRequired(row, "id"), sortKey: sortKey)
            }
            let ordered = observed.sorted { lhs, rhs in
                if lhs.sortKey != rhs.sortKey { return lhs.sortKey < rhs.sortKey }
                return lhs.offset < rhs.offset
            }
            for (index, row) in ordered.enumerated() {
                try database.run(
                    "UPDATE prompt_versions SET versionCreatedAtSortKey = ?, versionSequence = ? WHERE id = ? AND promptItemId = ?;",
                    values: [.int(row.sortKey), .int(Int64(index + 1)), .text(row.versionID), .text(itemID)]
                )
            }
        }
    }

    func writeVersionSequenceMigrationState(
        phase: VersionSequenceMigrationPhase,
        lastProcessedItemID: String?,
        processedCount: Int,
        totalCount: Int,
        backupPath: String,
        beforeFingerprint: String,
        reconciledFingerprint: String? = nil,
        tagStateFingerprint: String? = nil,
        changeCounter: Int64 = 0,
        checkpointChangeCounter: Int64 = 0,
        afterFingerprint: String?,
        errorMessage: String?
    ) throws {
        try database.run(
            """
            INSERT INTO version_sequence_migration (
                id, version, migrationID, checksum, phase, lastProcessedItemID,
                processedCount, totalCount, backupPath, beforeFingerprint,
                reconciledFingerprint, tagStateFingerprint, changeCounter,
                checkpointChangeCounter, afterFingerprint, errorMessage, updatedAt
            ) VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                version = excluded.version,
                migrationID = excluded.migrationID,
                checksum = excluded.checksum,
                phase = excluded.phase,
                lastProcessedItemID = excluded.lastProcessedItemID,
                processedCount = excluded.processedCount,
                totalCount = excluded.totalCount,
                backupPath = excluded.backupPath,
                beforeFingerprint = excluded.beforeFingerprint,
                reconciledFingerprint = excluded.reconciledFingerprint,
                tagStateFingerprint = excluded.tagStateFingerprint,
                changeCounter = excluded.changeCounter,
                checkpointChangeCounter = excluded.checkpointChangeCounter,
                afterFingerprint = excluded.afterFingerprint,
                errorMessage = excluded.errorMessage,
                updatedAt = excluded.updatedAt;
            """,
            values: [
                .int(Int64(Self.versionSequenceSchemaVersion)),
                .text(Self.versionSequenceMigrationID),
                .text(Self.versionSequenceMigrationChecksum),
                .text(phase.rawValue),
                lastProcessedItemID.map { .text($0) } ?? .null,
                .int(Int64(processedCount)),
                .int(Int64(totalCount)),
                .text(backupPath),
                .text(beforeFingerprint),
                .text(reconciledFingerprint ?? beforeFingerprint),
                .text(tagStateFingerprint ?? ""),
                .int(changeCounter),
                .int(checkpointChangeCounter),
                afterFingerprint.map { .text($0) } ?? .null,
                errorMessage.map { .text($0) } ?? .null,
                .text(Self.versionSequenceTimestamp())
            ]
        )
    }

    func markVersionSequenceMigrationFailed(_ error: Error) throws {
        guard (try? versionSequenceMetadataTableExists()) == true else { return }
        let state = try versionSequenceMigrationState()
        try database.transaction {
            try writeVersionSequenceMigrationState(
                phase: .failed,
                lastProcessedItemID: state.lastProcessedItemID,
                processedCount: state.processedCount,
                totalCount: state.totalCount,
                backupPath: state.backupPath,
                beforeFingerprint: state.beforeFingerprint,
                reconciledFingerprint: state.reconciledFingerprint,
                tagStateFingerprint: state.tagStateFingerprint,
                afterFingerprint: state.afterFingerprint,
                errorMessage: error.localizedDescription
            )
        }
    }

    func versionSequenceMetadataTableExists() throws -> Bool {
        !(try database.query(
            "SELECT 1 AS present FROM sqlite_master WHERE type = 'table' AND name = 'version_sequence_migration' LIMIT 1;"
        )).isEmpty
    }

    func versionSequenceColumnNames() throws -> Set<String> {
        Set(try database.query("PRAGMA table_info(prompt_versions);").compactMap { $0["name"] ?? nil })
    }

    func versionSequenceFingerprint() throws -> String {
        try computeVersionSequenceFingerprint(in: database)
    }

    func versionSequenceChangeCounter() throws -> Int64 {
        guard try versionSequenceMetadataTableExists() else { return 0 }
        return Int64(
            (try database.query("SELECT changeCounter FROM version_sequence_migration WHERE id = 1;").first?["changeCounter"] ?? nil) ?? "0"
        ) ?? 0
    }

    /// Fingerprints the Phase 2A.2 relation schema/state so a version backup
    /// can never restore over tag migration progress made after that backup.
    /// This is migration coordination metadata; runtime query ordering never
    /// depends on rowid.
    func versionSequenceTagStateFingerprint() throws -> String {
        try computeVersionSequenceTagStateFingerprint(in: database)
    }

    func versionSequenceTagBusinessFingerprint() throws -> String {
        try computeVersionSequenceTagStateFingerprint(in: database, includeRelationState: false)
    }
}

private func computeVersionSequenceFingerprint(in database: SQLiteDatabase) throws -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    func feed(_ string: String) {
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        hash ^= 0x1f
        hash &*= 1_099_511_628_211
    }
    let rows = try database.query(
        "SELECT rowid, id, promptItemId, version, prompt, negativePrompt, parametersJSON, note, createdAt FROM prompt_versions ORDER BY promptItemId COLLATE BINARY ASC, id COLLATE BINARY ASC, rowid ASC;"
    )
    feed("prompt_versions.count")
    feed(String(rows.count))
    let fields = ["rowid", "id", "promptItemId", "version", "prompt", "negativePrompt", "parametersJSON", "note", "createdAt"]
    for row in rows {
        for field in fields { feed(versionSequenceRequired(row, field)) }
    }
    return String(format: "%016llx", hash)
}

private func versionSequenceSchemaContractIsReady(in database: SQLiteDatabase) throws -> Bool {
    let columns = Set(try database.query("PRAGMA table_info(prompt_versions);").compactMap { $0["name"] ?? nil })
    guard columns.contains("versionSequence"), columns.contains("versionCreatedAtSortKey") else { return false }

    let indexRows = try database.query(
        "SELECT name, sql FROM sqlite_master WHERE type = 'index' AND name IN ('idx_phase2a4_prompt_versions_sequence_unique', 'idx_phase2a4_prompt_versions_latest');"
    )
    let indexSQL = Dictionary(uniqueKeysWithValues: indexRows.map {
        (versionSequenceRequired($0, "name"), versionSequenceRequired($0, "sql"))
    })
    guard indexSQL.keys.contains("idx_phase2a4_prompt_versions_sequence_unique"),
          indexSQL.keys.contains("idx_phase2a4_prompt_versions_latest") else { return false }
    let uniqueColumns = try database.query(
        "PRAGMA index_info('idx_phase2a4_prompt_versions_sequence_unique');"
    ).sorted { Int(versionSequenceRequired($0, "seq")) ?? 0 < Int(versionSequenceRequired($1, "seq")) ?? 0 }
        .map { versionSequenceRequired($0, "name") }
    let latestColumns = try database.query(
        "PRAGMA index_info('idx_phase2a4_prompt_versions_latest');"
    ).sorted { Int(versionSequenceRequired($0, "seq")) ?? 0 < Int(versionSequenceRequired($1, "seq")) ?? 0 }
        .map { versionSequenceRequired($0, "name") }
    guard uniqueColumns == ["promptItemId", "versionSequence"],
          latestColumns == ["promptItemId", "versionCreatedAtSortKey", "versionSequence"],
          indexSQL["idx_phase2a4_prompt_versions_latest"]?.contains("versionCreatedAtSortKey DESC") == true,
          indexSQL["idx_phase2a4_prompt_versions_latest"]?.contains("versionSequence DESC") == true else {
        return false
    }

    // Ready runtime reads may trust the persisted key contract only when the
    // sequence index is genuinely UNIQUE and both index column directions are
    // the migration's declared shape. SQL text alone does not encode the
    // unique flag or reliably preserve descending metadata.
    let indexList = try database.query("PRAGMA index_list('prompt_versions');")
    guard let uniqueIndexRow = indexList.first(where: {
              ($0["name"] ?? nil) == "idx_phase2a4_prompt_versions_sequence_unique"
          }),
          let latestIndexRow = indexList.first(where: {
              ($0["name"] ?? nil) == "idx_phase2a4_prompt_versions_latest"
          }),
          versionSequenceRequired(uniqueIndexRow, "unique") == "1",
          versionSequenceRequired(latestIndexRow, "unique") == "0" else {
        return false
    }
    func indexShape(_ name: String) throws -> [(String, Bool)] {
        try database.query("PRAGMA index_xinfo('\(name)');")
            .filter { versionSequenceRequired($0, "key") == "1" }
            .sorted { Int(versionSequenceRequired($0, "seqno")) ?? 0 < Int(versionSequenceRequired($1, "seqno")) ?? 0 }
            .map { (versionSequenceRequired($0, "name"), versionSequenceRequired($0, "desc") == "1") }
    }
    let uniqueShape = try indexShape("idx_phase2a4_prompt_versions_sequence_unique")
    let latestShape = try indexShape("idx_phase2a4_prompt_versions_latest")
    guard uniqueShape.count == 2,
          uniqueShape[0].0 == "promptItemId", uniqueShape[0].1 == false,
          uniqueShape[1].0 == "versionSequence", uniqueShape[1].1 == false,
          latestShape.count == 3,
          latestShape[0].0 == "promptItemId", latestShape[0].1 == false,
          latestShape[1].0 == "versionCreatedAtSortKey", latestShape[1].1 == true,
          latestShape[2].0 == "versionSequence", latestShape[2].1 == true else {
        return false
    }

    let triggerRows = try database.query(
        "SELECT name, sql FROM sqlite_master WHERE type = 'trigger' AND name IN ('prompt_versions_require_sequence_insert', 'prompt_versions_require_sequence_update');"
    )
    let triggerSQL = Dictionary(uniqueKeysWithValues: triggerRows.map {
        (versionSequenceRequired($0, "name"), versionSequenceRequired($0, "sql").lowercased())
    })
    guard let insertSQL = triggerSQL["prompt_versions_require_sequence_insert"],
          let updateSQL = triggerSQL["prompt_versions_require_sequence_update"],
          insertSQL.contains("before insert"),
          updateSQL.contains("before update"),
          insertSQL.contains("typeof(new.versionsequence) <> 'integer'"),
          updateSQL.contains("typeof(new.versionsequence) <> 'integer'"),
          insertSQL.contains("new.versionsequence <= 0"),
          updateSQL.contains("new.versionsequence <= 0"),
          insertSQL.contains("typeof(new.versioncreatedatsortkey) <> 'integer'"),
          updateSQL.contains("typeof(new.versioncreatedatsortkey) <> 'integer'") else {
        return false
    }
    return true
}

private func computeVersionSequenceTagStateFingerprint(
    in database: SQLiteDatabase,
    includeRelationState: Bool = true
) throws -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    func feed(_ string: String) {
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        hash ^= 0x1f
        hash &*= 1_099_511_628_211
    }
    let allSchemaRows = try database.query(
        """
        SELECT type, name, sql FROM sqlite_master
        WHERE name IN (
            'prompt_item_tags', 'tags', 'prompt_items',
            'model_profiles', 'library_folders', 'tag_relation_migration',
            'idx_phase2a2_prompt_item_tags_tag_order', 'prompt_item_tags_mirror_prompt_metadata'
        )
        ORDER BY type ASC, name ASC;
        """
    )
    let relationSchemaNames: Set<String> = [
        "prompt_item_tags",
        "idx_phase2a2_prompt_item_tags_tag_order",
        "prompt_item_tags_mirror_prompt_metadata",
        "tag_relation_migration"
    ]
    let schemaRows = includeRelationState
        ? allSchemaRows
        : allSchemaRows.filter { !relationSchemaNames.contains(versionSequenceRequired($0, "name")) }
    feed("business-schema.count")
    feed(String(schemaRows.count))
    for row in schemaRows {
        feed(versionSequenceRequired(row, "type"))
        feed(versionSequenceRequired(row, "name"))
        feed(versionSequenceRequired(row, "sql"))
    }
    let names = Set(schemaRows.compactMap { $0["name"] ?? nil })
    if names.contains("prompt_items") {
        let rows = try database.query(
            "SELECT id, title, type, assetKind, modelId, modelName, folderId, folderName, category, assetPath, thumbnailPath, aspectRatio, width, height, format, fileSize, favorite, pinnedAt, deletedAt, createdAt, updatedAt, lastUsedAt, sortOrder, tagsJSON, referencesJSON, description, captureId, captureSourceJSON FROM prompt_items ORDER BY id COLLATE BINARY ASC;"
        )
        feed("prompt_items.count")
        feed(String(rows.count))
        for row in rows {
            for field in ["id", "title", "type", "assetKind", "modelId", "modelName", "folderId", "folderName", "category", "assetPath", "thumbnailPath", "aspectRatio", "width", "height", "format", "fileSize", "favorite", "pinnedAt", "deletedAt", "createdAt", "updatedAt", "lastUsedAt", "sortOrder", "tagsJSON", "referencesJSON", "description", "captureId", "captureSourceJSON"] {
                feed(versionSequenceRequired(row, field))
            }
        }
    }
    if names.contains("tags") {
        let rows = try database.query("SELECT id, name, color, count FROM tags ORDER BY id COLLATE BINARY ASC;")
        feed("tags.count")
        feed(String(rows.count))
        for row in rows {
            for field in ["id", "name", "color", "count"] { feed(versionSequenceRequired(row, field)) }
        }
    }
    if names.contains("model_profiles") {
        let rows = try database.query("SELECT id, name, type, parametersJSON, defaultNegativePrompt FROM model_profiles ORDER BY id COLLATE BINARY ASC;")
        for row in rows {
            for field in ["id", "name", "type", "parametersJSON", "defaultNegativePrompt"] { feed(versionSequenceRequired(row, field)) }
        }
    }
    if names.contains("library_folders") {
        let rows = try database.query("SELECT id, name, parentId, type, count, sortOrder, createdAt FROM library_folders ORDER BY id COLLATE BINARY ASC;")
        for row in rows {
            for field in ["id", "name", "parentId", "type", "count", "sortOrder", "createdAt"] { feed(versionSequenceRequired(row, field)) }
        }
    }
    if includeRelationState, names.contains("tag_relation_migration") {
        let rows = try database.query("SELECT * FROM tag_relation_migration ORDER BY id ASC;")
        feed("tag_relation_migration.count")
        feed(String(rows.count))
        for row in rows {
            for field in ["id", "version", "phase", "lastProcessedItemID", "processedCount", "totalCount", "backupPath", "protectedFingerprint", "errorMessage", "updatedAt"] {
                feed(versionSequenceRequired(row, field))
            }
        }
    }
    if includeRelationState, names.contains("prompt_item_tags") {
        let rows = try database.query("SELECT promptItemId, ordinal, tagName, tagKey, isFirstOccurrence, isDeleted, sortOrder, createdAt, lastUsedAt FROM prompt_item_tags ORDER BY promptItemId COLLATE BINARY ASC, ordinal ASC;")
        feed("prompt_item_tags.count")
        feed(String(rows.count))
        for row in rows {
            for field in ["promptItemId", "ordinal", "tagName", "tagKey", "isFirstOccurrence", "isDeleted", "sortOrder", "createdAt", "lastUsedAt"] { feed(versionSequenceRequired(row, field)) }
        }
    }
    return String(format: "%016llx", hash)
}

enum VersionSequenceTimestampSupport {
    static func date(from raw: String) -> Date? {
        guard !raw.isEmpty else { return nil }
        return ISO8601DateFormatter().date(from: raw)
    }

    static func sortKey(for date: Date) -> Int64 {
        let value = (date.timeIntervalSince1970 * 1_000_000).rounded()
        guard value.isFinite,
              value >= Double(Int64.min),
              value <= Double(Int64.max) else {
            return value.sign == .minus ? Int64.min : Int64.max
        }
        return Int64(value)
    }
}

private func versionSequenceRequired(_ row: [String: String?], _ key: String) -> String {
    guard let value = row[key] ?? nil else { return "" }
    return value
}

private func versionSequenceOptional(_ row: [String: String?], _ key: String) -> String? {
    guard let value = row[key] ?? nil, !value.isEmpty else { return nil }
    return value
}

private extension PromptRepository {
    static func versionSequenceTimestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
