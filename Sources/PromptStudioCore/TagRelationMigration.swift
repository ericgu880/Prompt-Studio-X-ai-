import Foundation

public enum TagIdentity {
    /// Swift String equality treats canonically equivalent Unicode spellings
    /// as one value. The raw tagName remains untouched for JSON/display.
    public static func relationKey(for tagName: String) -> String {
        tagName.precomposedStringWithCanonicalMapping
    }
}

public enum TagRelationMigrationPhase: String, Codable, Equatable, Sendable {
    case notStarted
    case backfilling
    case backfilled
    case ready
    case failed
}

public struct TagRelationMigrationState: Codable, Equatable, Sendable {
    public let version: Int
    public let phase: TagRelationMigrationPhase
    public let lastProcessedItemID: String?
    public let processedCount: Int
    public let totalCount: Int
    public let backupPath: String
    public let protectedFingerprint: String
    public let errorMessage: String?
    public let updatedAt: Date

    public init(
        version: Int = 1,
        phase: TagRelationMigrationPhase = .notStarted,
        lastProcessedItemID: String? = nil,
        processedCount: Int = 0,
        totalCount: Int = 0,
        backupPath: String = "",
        protectedFingerprint: String = "",
        errorMessage: String? = nil,
        updatedAt: Date = Date(timeIntervalSince1970: 0)
    ) {
        self.version = version
        self.phase = phase
        self.lastProcessedItemID = lastProcessedItemID
        self.processedCount = processedCount
        self.totalCount = totalCount
        self.backupPath = backupPath
        self.protectedFingerprint = protectedFingerprint
        self.errorMessage = errorMessage
        self.updatedAt = updatedAt
    }

    public var isComplete: Bool {
        phase == .backfilled || phase == .ready
    }

    public var isReady: Bool {
        phase == .ready
    }
}

public struct TagRelationBackfillResult: Equatable, Sendable {
    public let completed: Bool
    public let processedCount: Int
    public let totalCount: Int
    public let lastProcessedItemID: String?
    public let phase: TagRelationMigrationPhase

    public init(
        completed: Bool,
        processedCount: Int,
        totalCount: Int,
        lastProcessedItemID: String? = nil,
        phase: TagRelationMigrationPhase = .backfilling
    ) {
        self.completed = completed
        self.processedCount = processedCount
        self.totalCount = totalCount
        self.lastProcessedItemID = lastProcessedItemID
        self.phase = phase
    }
}

public struct TagRelationConsistencyReport: Equatable, Sendable {
    public let isConsistent: Bool
    public let duplicateJSONEntryCount: Int
    public let emptyTagCount: Int
    public let distinctRelationTagNames: Set<String>
    public let deletedItemRelationCount: Int
    public let relationCount: Int
    public let jsonOccurrenceCount: Int
    public let mismatchedItemIDs: [String]
    public let malformedJSONItemIDs: [String]
    public let orphanRelationCount: Int

    public init(
        isConsistent: Bool,
        duplicateJSONEntryCount: Int = 0,
        emptyTagCount: Int = 0,
        distinctRelationTagNames: Set<String> = [],
        deletedItemRelationCount: Int = 0,
        relationCount: Int = 0,
        jsonOccurrenceCount: Int = 0,
        mismatchedItemIDs: [String] = [],
        malformedJSONItemIDs: [String] = [],
        orphanRelationCount: Int = 0
    ) {
        self.isConsistent = isConsistent
        self.duplicateJSONEntryCount = duplicateJSONEntryCount
        self.emptyTagCount = emptyTagCount
        self.distinctRelationTagNames = distinctRelationTagNames
        self.deletedItemRelationCount = deletedItemRelationCount
        self.relationCount = relationCount
        self.jsonOccurrenceCount = jsonOccurrenceCount
        self.mismatchedItemIDs = mismatchedItemIDs
        self.malformedJSONItemIDs = malformedJSONItemIDs
        self.orphanRelationCount = orphanRelationCount
    }
}

public enum TagRelationMigrationError: Error, LocalizedError, Equatable, Sendable {
    case notPrepared
    case migrationFailed(String)
    case malformedTagsJSON(itemID: String, reason: String)
    case invalidBatchSize
    case invalidMaxBatches
    case rollbackConflict(String)

    public var errorDescription: String? {
        switch self {
        case .notPrepared:
            "Tag relation migration has not been prepared"
        case .migrationFailed(let message):
            "Tag relation migration failed: \(message)"
        case .malformedTagsJSON(let itemID, let reason):
            "Malformed tagsJSON for item \(itemID): \(reason)"
        case .invalidBatchSize:
            "Tag relation migration batch size must be greater than zero"
        case .invalidMaxBatches:
            "Tag relation migration maxBatches must be non-negative"
        case .rollbackConflict(let message):
            "Tag relation migration rollback conflict: \(message)"
        }
    }
}

public extension PromptRepository {
    @discardableResult
    static func rollbackTagRelationMigration(at libraryURL: URL) throws -> TagRelationMigrationState {
        // Cross-process callers must quiesce/close their repository handles;
        // whole-file replacement cannot provide an atomic external-writer
        // barrier. The coordinator reservation closes the check/register
        // race before opening the private restore handle.
        let databasePath = libraryURL.appendingPathComponent("database/promptstudio.sqlite").path
        do {
            return try PromptRepositoryMigrationCoordinator.shared.withClosedLibraryReservation(path: databasePath) {
                let repository = try PromptRepository(
                    libraryURL: libraryURL,
                    libraryDataRevision: nil,
                    itemDetailInvalidationHub: nil,
                    registerMigrationLease: false
                )
                return try repository.rollbackTagRelationMigrationUnlocked()
            }
        } catch PromptRepositoryMigrationCoordinatorError.activeHandles {
            throw TagRelationMigrationError.rollbackConflict(
                "library handles must be closed before static tag rollback"
            )
        } catch PromptRepositoryMigrationCoordinatorError.libraryReserved {
            throw TagRelationMigrationError.rollbackConflict(
                "library migration reservation is already active"
            )
        }
    }

    /// Restores the tag migration backup only when no version-sequence
    /// migration has been prepared after it. This prevents a tag rollback
    /// from erasing version columns/state introduced later.
    @discardableResult
    func rollbackTagRelationMigration() throws -> TagRelationMigrationState {
        throw TagRelationMigrationError.rollbackConflict(
            "instance rollback is unsafe; close repositories and use static rollback"
        )
    }

    private func rollbackTagRelationMigrationUnlocked() throws -> TagRelationMigrationState {
        let state = try tagRelationMigrationState()
        guard !state.backupPath.isEmpty else { return state }
        guard PromptRepositoryMigrationCoordinator.shared.activeCount(path: databaseURL.path) <= 1 else {
            throw TagRelationMigrationError.rollbackConflict(
                "active repository handles prevent an atomic tag rollback"
            )
        }
        let currentProtectedFingerprint = try versionSequenceTagBusinessFingerprint()
        guard !state.protectedFingerprint.isEmpty,
              currentProtectedFingerprint == state.protectedFingerprint else {
            throw TagRelationMigrationError.rollbackConflict(
                "business/tag payload changed after the tag backup; refusing whole-file restore"
            )
        }
        if (try? versionSequenceMetadataTableExists()) == true {
            let versionState = try versionSequenceMigrationState()
            if versionState.phase != .notStarted {
                throw TagRelationMigrationError.rollbackConflict(
                    "version migration state exists after the tag backup; refusing whole-file restore"
                )
            }
        }
        if let itemState = try? itemSequenceMigrationState(), itemState.phase != .notStarted {
            throw TagRelationMigrationError.rollbackConflict(
                "item migration state exists after the tag backup; refusing whole-file restore"
            )
        }
        try database.restore(fromReadOnlyPath: state.backupPath)
        return try tagRelationMigrationState()
    }

    /// Prepares the opt-in migration and returns durable state. Preparation
    /// creates a WAL-safe online backup before any schema DDL is committed.
    func prepareTagRelationMigration() throws -> TagRelationMigrationState {
        try PromptRepositoryMigrationCoordinator.shared.withMigrationLock(path: databaseURL.path) {
            try prepareTagRelationMigrationUnlocked()
        }
    }

    private func prepareTagRelationMigrationUnlocked() throws -> TagRelationMigrationState {
        let existing = try tagRelationMigrationState()
        if existing.phase == .backfilling || existing.phase == .backfilled || existing.phase == .ready,
           try tagRelationTableExists(), try migrationMetadataTableExists() {
            return existing
        }

        let backupPath = libraryURL
            .appendingPathComponent("backups", isDirectory: true)
            .appendingPathComponent("promptstudio-tag-relations-\(UUID().uuidString).sqlite")
            .path
        let protectedFingerprint = try versionSequenceTagBusinessFingerprint()

        let protectedTables = [
            "prompt_items",
            "prompt_versions",
            "tags",
            "model_profiles",
            "library_folders"
        ]
        var expectedBackupCounts: [String: Int] = [:]
        for table in protectedTables {
            let count = try database.query("SELECT COUNT(*) AS count FROM \(table);").first
                .map { Int(tagRelationRequired($0, "count")) ?? 0 } ?? 0
            expectedBackupCounts[table] = count
        }
        // Existing relation metadata is part of the rollback contract too.
        // Include row counts when a prior/partial relation migration exists so
        // backup validation cannot silently accept a schema-only copy.
        for table in [Self.tagRelationMetadataTable, "prompt_item_tags", "version_sequence_migration"] {
            let exists = try database.query(
                "SELECT 1 AS present FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;",
                values: [.text(table)]
            ).isEmpty == false
            if exists {
                expectedBackupCounts[table] = Int(
                    (try database.query("SELECT COUNT(*) AS count FROM \(table);").first?["count"] ?? nil) ?? "0"
                ) ?? 0
            }
        }

        // The backup must happen before CREATE TABLE/CREATE TRIGGER so a
        // failed DDL attempt always leaves a recoverable pre-migration copy.
        try database.backup(to: backupPath)
        _ = try SQLiteDatabase.validateBackup(
            at: backupPath,
            expectedTableRowCounts: expectedBackupCounts
        )

        do {
            let totalCount = try database.query("SELECT COUNT(*) AS count FROM prompt_items;").first
                .map { Int(tagRelationRequired($0, "count")) ?? 0 } ?? 0
            let now = Self.tagRelationTimestamp()
            try database.transaction {
                try createTagRelationSchema()
                try ensureTagRelationMetadataColumns()
                try database.run("DELETE FROM prompt_item_tags;")
                try writeTagRelationMigrationState(
                    phase: .backfilling,
                    lastProcessedItemID: nil,
                    processedCount: 0,
                    totalCount: totalCount,
                    backupPath: backupPath,
                    protectedFingerprint: protectedFingerprint,
                    errorMessage: nil,
                    updatedAt: now
                )
                try reconcileItemSequenceMigrationFingerprintIfNeeded()
            }
            return try tagRelationMigrationState()
        } catch {
            if (try? migrationMetadataTableExists()) == true {
                try? database.transaction {
                    try writeTagRelationMigrationState(
                        phase: .failed,
                        lastProcessedItemID: nil,
                        processedCount: 0,
                        totalCount: 0,
                        backupPath: backupPath,
                        errorMessage: error.localizedDescription,
                        updatedAt: Self.tagRelationTimestamp()
                    )
                    try dropTagRelationTriggers()
                }
            }
            throw error
        }
    }

    /// Runs a resumable, keyset-paginated backfill. Every batch writes its
    /// relation rows and checkpoint in one transaction, making interruption
    /// safe and repeated calls idempotent.
    func runTagRelationBackfill(
        batchSize: Int = 500,
        maxBatches: Int? = nil
    ) throws -> TagRelationBackfillResult {
        guard batchSize > 0 else { throw TagRelationMigrationError.invalidBatchSize }
        if let maxBatches, maxBatches < 0 {
            throw TagRelationMigrationError.invalidMaxBatches
        }
        var state = try tagRelationMigrationState()
        switch state.phase {
        case .notStarted:
            throw TagRelationMigrationError.notPrepared
        case .failed:
            throw TagRelationMigrationError.migrationFailed(state.errorMessage ?? "unknown failure")
        case .ready, .backfilled:
            return TagRelationBackfillResult(
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
                let outcome = try database.transaction { () -> (state: TagRelationMigrationState, completed: Bool) in
                    let rows = try loadTagRelationBackfillRows(
                        after: state.lastProcessedItemID,
                        limit: batchSize
                    )
                    guard !rows.isEmpty else {
                        try writeTagRelationMigrationState(
                            phase: .backfilled,
                            lastProcessedItemID: state.lastProcessedItemID,
                            processedCount: state.processedCount,
                            totalCount: state.totalCount,
                            backupPath: state.backupPath,
                            errorMessage: nil,
                            updatedAt: Self.tagRelationTimestamp()
                        )
                        let completedState = try tagRelationMigrationState()
                        return (completedState, true)
                    }

                    var lastID: String?
                    for row in rows {
                        let itemID = tagRelationRequired(row, "id")
                        let tagsJSON = tagRelationRequired(row, "tagsJSON")
                        let tags = try decodeTagArray(tagsJSON, itemID: itemID)
                        try replaceTagRelationRows(
                            itemID: itemID,
                            tags: tags,
                            deletedAt: tagRelationOptional(row, "deletedAt"),
                            sortOrder: Int(tagRelationRequired(row, "sortOrder")) ?? 0,
                            createdAt: tagRelationRequired(row, "createdAt"),
                            lastUsedAt: tagRelationRequired(row, "lastUsedAt")
                        )
                        lastID = itemID
                    }
                    try reconcileItemSequenceMigrationFingerprintIfNeeded()

                    let processedCount = state.processedCount + rows.count
                    let hasMore = try hasTagRelationBackfillRows(after: lastID)
                    let nextPhase: TagRelationMigrationPhase = hasMore ? .backfilling : .backfilled
                    try writeTagRelationMigrationState(
                        phase: nextPhase,
                        lastProcessedItemID: lastID,
                        processedCount: processedCount,
                        totalCount: max(state.totalCount, processedCount),
                        backupPath: state.backupPath,
                        errorMessage: nil,
                        updatedAt: Self.tagRelationTimestamp()
                    )
                    let nextState = try tagRelationMigrationState()
                    return (nextState, !hasMore)
                }
                state = outcome.state
                batchCount += 1
                if outcome.completed { break }
            }
        } catch {
            try markTagRelationMigrationFailed(error)
            throw error
        }

        return TagRelationBackfillResult(
            completed: state.phase == .backfilled || state.phase == .ready,
            processedCount: state.processedCount,
            totalCount: state.totalCount,
            lastProcessedItemID: state.lastProcessedItemID,
            phase: state.phase
        )
    }

    /// Compares every JSON occurrence with its ordinal relation row. A
    /// malformed or non-array tagsJSON is a hard consistency failure.
    func validateTagRelationConsistency() throws -> TagRelationConsistencyReport {
        guard try tagRelationTableExists() else {
            return TagRelationConsistencyReport(isConsistent: false)
        }

        let itemRows = try database.query(
            "SELECT id, tagsJSON, deletedAt, sortOrder, createdAt, lastUsedAt FROM prompt_items ORDER BY id COLLATE BINARY ASC;"
        )
        let relationRows = try database.query(
            "SELECT promptItemId, ordinal, tagName, tagKey, isFirstOccurrence, isDeleted, sortOrder, createdAt, lastUsedAt FROM prompt_item_tags ORDER BY promptItemId COLLATE BINARY ASC, ordinal ASC;"
        )
        var relationsByItem: [String: [[String: String?]]] = [:]
        for row in relationRows {
            relationsByItem[tagRelationRequired(row, "promptItemId"), default: []].append(row)
        }

        var isConsistent = true
        var duplicateJSONEntryCount = 0
        var emptyTagCount = 0
        var deletedItemRelationCount = 0
        var jsonOccurrenceCount = 0
        var mismatchedIDs: [String] = []
        var malformedIDs: [String] = []
        var itemIDs = Set<String>()

        for item in itemRows {
            let itemID = tagRelationRequired(item, "id")
            itemIDs.insert(itemID)
            let json = tagRelationRequired(item, "tagsJSON")
            let tags: [String]
            do {
                tags = try decodeTagArray(json, itemID: itemID)
            } catch {
                malformedIDs.append(itemID)
                isConsistent = false
                continue
            }
            jsonOccurrenceCount += tags.count
            var counts: [String: Int] = [:]
            for tag in tags {
                counts[tag, default: 0] += 1
                if tag.isEmpty { emptyTagCount += 1 }
            }
            duplicateJSONEntryCount += counts.values.reduce(into: 0) { result, count in
                result += max(0, count - 1)
            }

            let relations = relationsByItem[itemID] ?? []
            if relations.count != tags.count {
                isConsistent = false
                mismatchedIDs.append(itemID)
            }
            let deleted = tagRelationOptional(item, "deletedAt") != nil
            for (ordinal, tag) in tags.enumerated() {
                guard ordinal < relations.count else { break }
                let relation = relations[ordinal]
                let tagKey = TagIdentity.relationKey(for: tag)
                let firstOccurrence = tags[..<ordinal].contains(tag) ? 0 : 1
                let metadataMatches =
                    tagRelationRequired(relation, "ordinal") == String(ordinal)
                    && tagRelationRequired(relation, "tagName") == tag
                    && tagRelationRequired(relation, "tagKey") == tagKey
                    && tagRelationRequired(relation, "isFirstOccurrence") == String(firstOccurrence)
                    && tagRelationRequired(relation, "isDeleted") == (deleted ? "1" : "0")
                    && tagRelationRequired(relation, "sortOrder") == tagRelationRequired(item, "sortOrder")
                    && tagRelationRequired(relation, "createdAt") == tagRelationRequired(item, "createdAt")
                    && tagRelationRequired(relation, "lastUsedAt") == tagRelationRequired(item, "lastUsedAt")
                if !metadataMatches {
                    isConsistent = false
                    if !mismatchedIDs.contains(itemID) { mismatchedIDs.append(itemID) }
                }
            }
        }

        for row in relationRows where tagRelationRequired(row, "isDeleted") == "1"
            && tagRelationRequired(row, "isFirstOccurrence") == "1" {
            deletedItemRelationCount += 1
        }
        let orphanRelationCount = relationRows.reduce(into: 0) { result, row in
            if !itemIDs.contains(tagRelationRequired(row, "promptItemId")) { result += 1 }
        }
        if orphanRelationCount > 0 { isConsistent = false }

        var distinctNames = Set<String>()
        for row in relationRows { distinctNames.insert(tagRelationRequired(row, "tagName")) }

        let report = TagRelationConsistencyReport(
            isConsistent: isConsistent,
            duplicateJSONEntryCount: duplicateJSONEntryCount,
            emptyTagCount: emptyTagCount,
            distinctRelationTagNames: distinctNames,
            deletedItemRelationCount: deletedItemRelationCount,
            relationCount: relationRows.count,
            jsonOccurrenceCount: jsonOccurrenceCount,
            mismatchedItemIDs: mismatchedIDs,
            malformedJSONItemIDs: malformedIDs,
            orphanRelationCount: orphanRelationCount
        )

        if report.isConsistent, try tagRelationStructureIsValid() {
            let state = try tagRelationMigrationState()
            let hasMore = try hasTagRelationBackfillRows(after: state.lastProcessedItemID)
            if state.phase == .backfilling && !hasMore {
                try database.transaction {
                    try writeTagRelationMigrationState(
                        phase: .backfilled,
                        lastProcessedItemID: state.lastProcessedItemID,
                        processedCount: state.processedCount,
                        totalCount: state.totalCount,
                        backupPath: state.backupPath,
                        errorMessage: nil,
                        updatedAt: Self.tagRelationTimestamp()
                    )
                }
            }
            let latest = try tagRelationMigrationState()
            if latest.phase == .backfilled {
                try database.transaction {
                    try writeTagRelationMigrationState(
                        phase: .ready,
                        lastProcessedItemID: latest.lastProcessedItemID,
                        processedCount: latest.processedCount,
                        totalCount: latest.totalCount,
                        backupPath: latest.backupPath,
                        errorMessage: nil,
                        updatedAt: Self.tagRelationTimestamp()
                    )
                }
            }
        }
        return report
    }

    var tagRelationsReady: Bool {
        guard (try? tagRelationMigrationState().phase == .ready) == true else { return false }
        return (try? tagRelationStructureIsReady()) == true
    }

    /// Renames exact tag occurrences in source JSON and mirrors relation rows
    /// without trimming, lowercasing, or otherwise normalizing names.
    func renameTag(from: String, to: String) throws {
        guard from != to else { return }
        try mutateExactTagOccurrences { tags in
            tags.map { $0 == from ? to : $0 }
        }
    }

    /// Removes every exact occurrence from source JSON and its relation rows.
    func deleteTag(named: String) throws {
        try mutateExactTagOccurrences { tags in
            tags.filter { $0 != named }
        }
    }
}

extension PromptRepository {
    static let tagRelationMetadataTable = "tag_relation_migration"
    static let tagRelationSchemaVersion = 1

    static func tagRelationTimestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    func migrationMetadataTableExists() throws -> Bool {
        try database.query(
            "SELECT 1 AS present FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;",
            values: [.text(Self.tagRelationMetadataTable)]
        ).isEmpty == false
    }

    func tagRelationTableExists() throws -> Bool {
        try database.query(
            "SELECT 1 AS present FROM sqlite_master WHERE type = 'table' AND name = 'prompt_item_tags' LIMIT 1;"
        ).isEmpty == false
    }

    func createTagRelationSchema() throws {
        let metadataTableName = Self.tagRelationMetadataTable
        let sql = "CREATE TABLE IF NOT EXISTS " + metadataTableName + " (" + """
                id INTEGER PRIMARY KEY CHECK (id = 1),
                version INTEGER NOT NULL,
                phase TEXT NOT NULL,
                lastProcessedItemID TEXT,
                processedCount INTEGER NOT NULL DEFAULT 0,
                totalCount INTEGER NOT NULL DEFAULT 0,
                backupPath TEXT NOT NULL DEFAULT '',
                protectedFingerprint TEXT NOT NULL DEFAULT '',
                errorMessage TEXT,
                updatedAt TEXT NOT NULL
            );

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
                PRIMARY KEY(promptItemId, ordinal),
                FOREIGN KEY(promptItemId) REFERENCES prompt_items(id) ON DELETE CASCADE
            ) WITHOUT ROWID;

            CREATE INDEX IF NOT EXISTS idx_phase2a2_prompt_item_tags_tag_order
            ON prompt_item_tags(tagKey COLLATE BINARY, isFirstOccurrence, isDeleted, sortOrder ASC, createdAt DESC, promptItemId ASC);

            CREATE INDEX IF NOT EXISTS idx_phase2a1_prompt_versions_prompt_item_id
            ON prompt_versions(promptItemId);

            CREATE TRIGGER IF NOT EXISTS prompt_item_tags_mirror_prompt_metadata
            AFTER UPDATE OF sortOrder, createdAt, lastUsedAt, deletedAt ON prompt_items
            BEGIN
                UPDATE prompt_item_tags
                SET sortOrder = NEW.sortOrder,
                    createdAt = NEW.createdAt,
                    lastUsedAt = NEW.lastUsedAt,
                    isDeleted = CASE WHEN NEW.deletedAt IS NULL THEN 0 ELSE 1 END
                WHERE promptItemId = NEW.id;
            END;
            """
        try database.execute(sql)
    }

    func ensureTagRelationMetadataColumns() throws {
        let columns = Set(try database.query("PRAGMA table_info(\(Self.tagRelationMetadataTable));").compactMap { $0["name"] ?? nil })
        guard !columns.contains("protectedFingerprint") else { return }
        try database.execute("ALTER TABLE \(Self.tagRelationMetadataTable) ADD COLUMN protectedFingerprint TEXT NOT NULL DEFAULT '';" )
    }

    func dropTagRelationTriggers() throws {
        try database.execute("DROP TRIGGER IF EXISTS prompt_item_tags_mirror_prompt_metadata;")
    }

    func writeTagRelationMigrationState(
        phase: TagRelationMigrationPhase,
        lastProcessedItemID: String?,
        processedCount: Int,
        totalCount: Int,
        backupPath: String,
        protectedFingerprint: String = "",
        errorMessage: String?,
        updatedAt: String
    ) throws {
        let tableName = Self.tagRelationMetadataTable
        let values: [SQLiteValue] = [
            .int(Int64(Self.tagRelationSchemaVersion)),
            .text(phase.rawValue),
            lastProcessedItemID.map { .text($0) } ?? .null,
            .int(Int64(processedCount)),
            .int(Int64(totalCount)),
            .text(backupPath),
            .text(protectedFingerprint),
            errorMessage.map { .text($0) } ?? .null,
            .text(updatedAt)
        ]
        let sql = """
            INSERT INTO \(tableName)
                (id, version, phase, lastProcessedItemID, processedCount, totalCount, backupPath, protectedFingerprint, errorMessage, updatedAt)
            VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                version = excluded.version,
                phase = excluded.phase,
                lastProcessedItemID = excluded.lastProcessedItemID,
                processedCount = excluded.processedCount,
                totalCount = excluded.totalCount,
                backupPath = excluded.backupPath,
                protectedFingerprint = CASE WHEN excluded.protectedFingerprint = '' THEN protectedFingerprint ELSE excluded.protectedFingerprint END,
                errorMessage = excluded.errorMessage,
                updatedAt = excluded.updatedAt;
            """
        try database.run(
            sql,
            values: values
        )
    }

    public func tagRelationMigrationState() throws -> TagRelationMigrationState {
        let tableName = Self.tagRelationMetadataTable
        guard try migrationMetadataTableExists(),
              let row = try database.query("SELECT * FROM \(tableName) WHERE id = 1;").first else {
            return TagRelationMigrationState()
        }
        let phase = TagRelationMigrationPhase(rawValue: tagRelationRequired(row, "phase")) ?? .failed
        let updatedAt = ISO8601DateFormatter().date(from: tagRelationRequired(row, "updatedAt")) ?? Date(timeIntervalSince1970: 0)
        return TagRelationMigrationState(
            version: Int(tagRelationRequired(row, "version")) ?? Self.tagRelationSchemaVersion,
            phase: phase,
            lastProcessedItemID: tagRelationOptional(row, "lastProcessedItemID"),
            processedCount: Int(tagRelationRequired(row, "processedCount")) ?? 0,
            totalCount: Int(tagRelationRequired(row, "totalCount")) ?? 0,
            backupPath: tagRelationRequired(row, "backupPath"),
            protectedFingerprint: tagRelationOptional(row, "protectedFingerprint") ?? "",
            errorMessage: tagRelationOptional(row, "errorMessage"),
            updatedAt: updatedAt
        )
    }

    func markTagRelationMigrationFailed(_ error: Error) throws {
        guard (try? migrationMetadataTableExists()) == true else { return }
        let state = try tagRelationMigrationState()
        try database.transaction {
            try writeTagRelationMigrationState(
                phase: .failed,
                lastProcessedItemID: state.lastProcessedItemID,
                processedCount: state.processedCount,
                totalCount: state.totalCount,
                backupPath: state.backupPath,
                errorMessage: error.localizedDescription,
                updatedAt: Self.tagRelationTimestamp()
            )
            try dropTagRelationTriggers()
        }
    }

    func loadTagRelationBackfillRows(after lastID: String?, limit: Int) throws -> [[String: String?]] {
        var sql = "SELECT id, tagsJSON, deletedAt, sortOrder, createdAt, lastUsedAt FROM prompt_items"
        var values: [SQLiteValue] = []
        if let lastID {
            sql += " WHERE id COLLATE BINARY > ?"
            values.append(.text(lastID))
        }
        sql += " ORDER BY id COLLATE BINARY ASC LIMIT ?;"
        values.append(.int(Int64(limit)))
        return try database.query(sql, values: values)
    }

    func hasTagRelationBackfillRows(after lastID: String?) throws -> Bool {
        var sql = "SELECT 1 AS present FROM prompt_items"
        var values: [SQLiteValue] = []
        if let lastID {
            sql += " WHERE id COLLATE BINARY > ?"
            values.append(.text(lastID))
        }
        sql += " ORDER BY id COLLATE BINARY ASC LIMIT 1;"
        return try database.query(sql, values: values).isEmpty == false
    }

    func decodeTagArray(_ json: String, itemID: String) throws -> [String] {
        guard let data = json.data(using: .utf8) else {
            throw TagRelationMigrationError.malformedTagsJSON(itemID: itemID, reason: "not UTF-8")
        }
        do {
            return try JSONDecoder().decode([String].self, from: data)
        } catch {
            throw TagRelationMigrationError.malformedTagsJSON(itemID: itemID, reason: error.localizedDescription)
        }
    }

    func replaceTagRelationRows(
        itemID: String,
        tags: [String],
        deletedAt: String?,
        sortOrder: Int,
        createdAt: String,
        lastUsedAt: String
    ) throws {
        try database.run("DELETE FROM prompt_item_tags WHERE promptItemId = ?;", values: [.text(itemID)])
        var firstOccurrences = Set<String>()
        for (ordinal, tag) in tags.enumerated() {
            let tagKey = TagIdentity.relationKey(for: tag)
            let isFirst = firstOccurrences.insert(tagKey).inserted
            try database.run(
                """
                INSERT INTO prompt_item_tags
                    (promptItemId, ordinal, tagName, tagKey, isFirstOccurrence, isDeleted, sortOrder, createdAt, lastUsedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
                """,
                values: [
                    .text(itemID),
                    .int(Int64(ordinal)),
                    .text(tag),
                    .text(tagKey),
                    .int(isFirst ? 1 : 0),
                    .int(deletedAt == nil ? 0 : 1),
                    .int(Int64(sortOrder)),
                    .text(createdAt),
                    .text(lastUsedAt)
                ]
            )
        }
    }

    internal func dualWriteTagRelationsIfAvailable(item: PromptItem, rawCreatedAt: String? = nil) throws {
        guard (try? tagRelationTableExists()) == true,
              let state = try? tagRelationMigrationState(), state.phase != .failed else { return }
        try replaceTagRelationRows(
            itemID: item.id,
            tags: item.tags,
            deletedAt: item.deletedAt.map { Self.tagRelationDateString($0) },
            sortOrder: item.sortOrder,
            createdAt: rawCreatedAt ?? Self.tagRelationDateString(item.createdAt),
            lastUsedAt: Self.tagRelationDateString(item.lastUsedAt)
        )
    }

    static func tagRelationDateString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    func tagRelationStructureIsValid() throws -> Bool {
        guard try tagRelationStructureIsReady() else { return false }
        let integrityOK = try database.query("PRAGMA integrity_check;").first
            .flatMap { tagRelationOptional($0, "integrity_check") } == "ok"
        guard integrityOK else { return false }
        return try database.query("PRAGMA foreign_key_check;").isEmpty
    }

    /// Lightweight startup gate.  It checks only migration state and the
    /// schema objects required by tag queries; deep integrity/FK scans remain
    /// opt-in diagnostics used by migration and repair paths.
    func tagRelationStructureIsReady() throws -> Bool {
        let requiredObjects = try database.query(
            """
            SELECT type, name FROM sqlite_master
            WHERE (type = 'table' AND name IN ('prompt_item_tags', 'tag_relation_migration'))
               OR (type = 'index' AND name = 'idx_phase2a2_prompt_item_tags_tag_order')
               OR (type = 'index' AND name = 'idx_phase2a1_prompt_versions_prompt_item_id')
               OR (type = 'trigger' AND name = 'prompt_item_tags_mirror_prompt_metadata');
            """
        )
        let objectNames = Set(requiredObjects.compactMap { tagRelationOptional($0, "name") })
        guard objectNames.isSuperset(of: [
            "prompt_item_tags",
            "tag_relation_migration",
            "idx_phase2a2_prompt_item_tags_tag_order",
            "idx_phase2a1_prompt_versions_prompt_item_id",
            "prompt_item_tags_mirror_prompt_metadata"
        ]) else { return false }
        let requiredColumns: [String: Set<String>] = [
            "prompt_item_tags": [
                "promptItemId", "ordinal", "tagName", "tagKey", "isFirstOccurrence",
                "isDeleted", "sortOrder", "createdAt", "lastUsedAt"
            ],
            Self.tagRelationMetadataTable: [
                "id", "version", "phase", "lastProcessedItemID", "processedCount",
                "totalCount", "backupPath", "errorMessage", "updatedAt"
            ]
        ]
        for (table, expected) in requiredColumns {
            let columns = try database.query("PRAGMA table_info(\(table));")
            let names = Set(columns.compactMap { tagRelationOptional($0, "name") })
            guard expected.isSubset(of: names) else { return false }
        }
        return true
    }

    func mutateExactTagOccurrences(_ transform: ([String]) -> [String]) throws {
        var changedItemIDs: Set<String> = []
        try PromptRepositoryMigrationCoordinator.shared.withWriteLock(path: databaseURL.path) {
            try database.transaction {
                let rows = try database.query("SELECT id, tagsJSON, deletedAt, sortOrder, createdAt, lastUsedAt FROM prompt_items ORDER BY id COLLATE BINARY ASC;")
                for row in rows {
                    let itemID = tagRelationRequired(row, "id")
                    let tags = try decodeTagArray(tagRelationRequired(row, "tagsJSON"), itemID: itemID)
                    let transformed = transform(tags)
                    guard transformed != tags else { continue }
                    let encoded = try JSONEncoder().encode(transformed)
                    guard let json = String(data: encoded, encoding: .utf8) else { continue }
                    try database.run(
                        "UPDATE prompt_items SET tagsJSON = ?, updatedAt = ? WHERE id = ?;",
                        values: [.text(json), .text(Self.tagRelationTimestamp()), .text(itemID)]
                    )
                    changedItemIDs.insert(itemID)
                    if (try? tagRelationTableExists()) == true,
                       (try? tagRelationMigrationState().phase != .failed) == true {
                        try replaceTagRelationRows(
                            itemID: itemID,
                            tags: transformed,
                            deletedAt: tagRelationOptional(row, "deletedAt"),
                            sortOrder: Int(tagRelationRequired(row, "sortOrder")) ?? 0,
                            createdAt: tagRelationRequired(row, "createdAt"),
                            lastUsedAt: tagRelationRequired(row, "lastUsedAt")
                        )
                    }
                }
                try refreshTagsAfterMutation()
                try reconcileItemSequenceMigrationFingerprintIfNeeded()
            }
        }
        _ = itemDetailInvalidationHub.publish(changedItemIDs: changedItemIDs)
    }

    /// Refreshes the derived catalog without materializing the prompt graph
    /// once the relation migration is fully validated. During backfill, the
    /// JSON source remains authoritative because relation rows are incomplete.
    internal func refreshTagsAfterMutation() throws {
        guard (try? tagRelationTableExists()) == true,
              (try? tagRelationMigrationState().phase == .ready) == true else {
            try refreshTags(from: try loadItems())
            return
        }

        let rows = try database.query(
            "SELECT tagKey, MIN(tagName) AS tagName, COUNT(*) AS count FROM prompt_item_tags WHERE isDeleted = 0 GROUP BY tagKey;"
        )
        var namesWithCounts: [String: Int] = [:]
        for row in rows {
            namesWithCounts[tagRelationRequired(row, "tagName")] = Int(tagRelationRequired(row, "count")) ?? 0
        }
        for (name, count) in namesWithCounts {
            try database.run(
                "INSERT INTO tags (id, name, color, count) VALUES (?, ?, ?, ?) ON CONFLICT(name) DO UPDATE SET count = excluded.count;",
                values: [.text(UUID().uuidString), .text(name), .text("#3B82F6"), .int(Int64(count))]
            )
        }
        let existingRows = try database.query("SELECT name FROM tags;")
        for name in existingRows.map({ tagRelationRequired($0, "name") }) where namesWithCounts[name] == nil {
            try database.run("DELETE FROM tags WHERE name = ?;", values: [.text(name)])
        }
    }
}

private func tagRelationRequired(_ row: [String: String?], _ key: String) -> String {
    guard let value = row[key] else { return "" }
    return value ?? ""
}

private func tagRelationOptional(_ row: [String: String?], _ key: String) -> String? {
    row[key] ?? nil
}
