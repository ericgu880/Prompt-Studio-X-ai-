import Foundation

public enum LibraryQuerySQLBuilderError: Error, LocalizedError, Equatable, Sendable {
    case versionSequenceNotReady
    case itemSequenceNotReady

    public var errorDescription: String? {
        switch self {
        case .versionSequenceNotReady:
            "Library Summary requires a ready version-sequence migration"
        case .itemSequenceNotReady:
            "Library Summary requires a ready item-sequence migration"
        }
    }
}

public struct LibraryQuerySQL: Sendable {
    public let sql: String
    public let values: [SQLiteValue]
    public let queryFingerprint: String
    public let limit: Int
    public let usesRecentOrdering: Bool
    public let usesItemSequenceOrdering: Bool

    public init(
        sql: String,
        values: [SQLiteValue],
        queryFingerprint: String,
        limit: Int,
        usesRecentOrdering: Bool,
        usesItemSequenceOrdering: Bool = false
    ) {
        self.sql = sql
        self.values = values
        self.queryFingerprint = queryFingerprint
        self.limit = limit
        self.usesRecentOrdering = usesRecentOrdering
        self.usesItemSequenceOrdering = usesItemSequenceOrdering
    }

    public var bindings: [SQLiteValue] { values }
    public var parameters: [SQLiteValue] { values }
    public var arguments: [SQLiteValue] { values }
}

public struct LibraryQueryCountSQL: Sendable {
    public let sql: String
    public let values: [SQLiteValue]
    public let queryFingerprint: String

    public init(sql: String, values: [SQLiteValue], queryFingerprint: String) {
        self.sql = sql
        self.values = values
        self.queryFingerprint = queryFingerprint
    }

    public var bindings: [SQLiteValue] { values }
    public var parameters: [SQLiteValue] { values }
    public var arguments: [SQLiteValue] { values }
}

public enum LibraryQuerySQLBuilder {
    public static let defaultPageSize = 300

    /// Indexes used by the Phase 2A.1 query shapes. These are intentionally
    /// exposed as SQL rather than installed during repository bootstrap: a
    /// caller can opt into them after measuring an existing library.
    public static let phase2A1IndexStatements: [String] = [
        "CREATE INDEX IF NOT EXISTS idx_phase2a1_prompt_items_all ON prompt_items (sortOrder ASC, createdAt DESC, id ASC) WHERE deletedAt IS NULL;",
        "CREATE INDEX IF NOT EXISTS idx_phase2a1_prompt_items_folder ON prompt_items (folderId, sortOrder ASC, createdAt DESC, id ASC) WHERE deletedAt IS NULL;",
        "CREATE INDEX IF NOT EXISTS idx_phase2a1_prompt_items_type ON prompt_items (type, sortOrder ASC, createdAt DESC, id ASC) WHERE deletedAt IS NULL;",
        "CREATE INDEX IF NOT EXISTS idx_phase2a1_prompt_items_model ON prompt_items (modelId, sortOrder ASC, createdAt DESC, id ASC) WHERE deletedAt IS NULL;",
        "CREATE INDEX IF NOT EXISTS idx_phase2a1_prompt_items_favorite ON prompt_items (favorite, sortOrder ASC, createdAt DESC, id ASC) WHERE deletedAt IS NULL;",
        "CREATE INDEX IF NOT EXISTS idx_phase2a1_prompt_items_recent ON prompt_items (lastUsedAt DESC, createdAt DESC, id ASC) WHERE deletedAt IS NULL;",
        "CREATE INDEX IF NOT EXISTS idx_phase2a1_prompt_items_trash ON prompt_items (sortOrder ASC, createdAt DESC, id ASC) WHERE deletedAt IS NOT NULL;",
        "CREATE INDEX IF NOT EXISTS idx_phase2a1_prompt_versions_prompt_item_id ON prompt_versions (promptItemId);"
    ]

    /// Ready item-order indexes. They are installed by the item migration;
    /// this list is exposed for explain/benchmark wiring and test fixtures.
    public static let phase2A4_1ItemIndexStatements: [String] = [
        "CREATE INDEX IF NOT EXISTS idx_phase2a4_1_prompt_items_all ON prompt_items (sortOrder ASC, itemCreatedAtSortKey DESC, itemSequence ASC) WHERE deletedAt IS NULL;",
        "CREATE INDEX IF NOT EXISTS idx_phase2a4_1_prompt_items_folder ON prompt_items (folderId, sortOrder ASC, itemCreatedAtSortKey DESC, itemSequence ASC) WHERE deletedAt IS NULL;",
        "CREATE INDEX IF NOT EXISTS idx_phase2a4_1_prompt_items_type ON prompt_items (type, sortOrder ASC, itemCreatedAtSortKey DESC, itemSequence ASC) WHERE deletedAt IS NULL;",
        "CREATE INDEX IF NOT EXISTS idx_phase2a4_1_prompt_items_model ON prompt_items (modelId, sortOrder ASC, itemCreatedAtSortKey DESC, itemSequence ASC) WHERE deletedAt IS NULL;",
        "CREATE INDEX IF NOT EXISTS idx_phase2a4_1_prompt_items_favorite ON prompt_items (favorite, sortOrder ASC, itemCreatedAtSortKey DESC, itemSequence ASC) WHERE deletedAt IS NULL;",
        "CREATE INDEX IF NOT EXISTS idx_phase2a4_1_prompt_items_recent ON prompt_items (itemLastUsedAtSortKey DESC, itemCreatedAtSortKey DESC, itemSequence ASC) WHERE deletedAt IS NULL;",
        "CREATE INDEX IF NOT EXISTS idx_phase2a4_1_prompt_items_trash ON prompt_items (sortOrder ASC, itemCreatedAtSortKey DESC, itemSequence ASC) WHERE deletedAt IS NOT NULL;"
    ]

    public static var phase2A4_1ItemIndexSQL: String { phase2A4_1ItemIndexStatements.joined(separator: "\n") }

    public static var phase2A1IndexSQL: String {
        phase2A1IndexStatements.joined(separator: "\n")
    }

    public static var phase2A1InstallerSQL: String { phase2A1IndexSQL }

    /// The relation-backed tag query is opt-in because the migration owns the
    /// table lifecycle. The leading columns must stay in this exact order so
    /// the equality predicates and relation keyset ordering are indexable.
    public static let phase2A2TagIndexStatements: [String] = [
        "CREATE INDEX IF NOT EXISTS idx_phase2a2_prompt_item_tags_tag_order ON prompt_item_tags (tagKey COLLATE BINARY, isFirstOccurrence, isDeleted, sortOrder ASC, createdAt DESC, promptItemId ASC);"
    ]

    public static let phase2A2IndexStatements = phase2A2TagIndexStatements

    public static var phase2A2TagIndexSQL: String {
        phase2A2TagIndexStatements.joined(separator: "\n")
    }

    public static var phase2A2IndexSQL: String { phase2A2TagIndexSQL }

    public static var phase2A2InstallerSQL: String { phase2A2TagIndexSQL }

    /// The ready migration's latest-version semantics use a persisted Date
    /// sort key followed by the durable per-item sequence tie key.
    public static let phase2A4LatestVersionIndexStatements: [String] = [
        "CREATE INDEX IF NOT EXISTS idx_phase2a4_prompt_versions_latest ON prompt_versions (promptItemId, versionCreatedAtSortKey DESC, versionSequence DESC);"
    ]

    public static let phase2A4IndexStatements = phase2A4LatestVersionIndexStatements

    public static var phase2A4LatestVersionIndexSQL: String {
        phase2A4LatestVersionIndexStatements.joined(separator: "\n")
    }

    public static var phase2A4IndexSQL: String { phase2A4LatestVersionIndexSQL }

    public static var phase2A4InstallerSQL: String { phase2A4LatestVersionIndexSQL }

    /// Installs only the explicitly requested Phase 2A.1 indexes. This is a
    /// small opt-in installer; PromptRepository bootstrap deliberately does
    /// not call it.
    public static func installPhase2A1Indexes(using execute: (String) throws -> Void) rethrows {
        for statement in phase2A1IndexStatements {
            try execute(statement)
        }
    }

    public static func installPhase2A2TagIndex(using execute: (String) throws -> Void) rethrows {
        for statement in phase2A2TagIndexStatements {
            try execute(statement)
        }
    }

    public static func installPhase2A2Indexes(using execute: (String) throws -> Void) rethrows {
        try installPhase2A2TagIndex(using: execute)
    }

    public static func installPhase2A4LatestVersionIndex(
        using execute: (String) throws -> Void,
        versionSequenceReady: Bool = false
    ) throws {
        guard versionSequenceReady else { throw LibraryQuerySQLBuilderError.versionSequenceNotReady }
        for statement in phase2A4LatestVersionIndexStatements {
            try execute(statement)
        }
    }

    public static func installPhase2A4Index(
        using execute: (String) throws -> Void,
        versionSequenceReady: Bool = false
    ) throws {
        try installPhase2A4LatestVersionIndex(using: execute, versionSequenceReady: versionSequenceReady)
    }

    public static func installPhase2A4_1ItemIndexes(using execute: (String) throws -> Void) rethrows {
        for statement in phase2A4_1ItemIndexStatements { try execute(statement) }
    }

    public static func build(_ query: LibraryQuery) throws -> LibraryQuerySQL {
        try build(query, capabilities: .legacy)
    }

    public static func build(
        _ query: LibraryQuery,
        tagRelationsReady: Bool
    ) throws -> LibraryQuerySQL {
        try build(query, capabilities: LibraryQueryCapabilities(tagRelationsReady: tagRelationsReady))
    }

    public static func build(
        _ query: LibraryQuery,
        capabilities: LibraryQueryCapabilities
    ) throws -> LibraryQuerySQL {
        guard query.pageSize > 0 else {
            throw LibraryQueryError.invalidPageSize(query.pageSize)
        }
        guard capabilities.versionSequenceReady else {
            // The legacy lexical timestamp projection cannot reproduce the
            // Swift Date comparator for offsets, fractional strings, or
            // malformed values. Never emit a semantically unsafe fallback.
            throw LibraryQuerySQLBuilderError.versionSequenceNotReady
        }
        guard capabilities.itemSequenceReady else {
            throw LibraryQuerySQLBuilderError.itemSequenceNotReady
        }
        let normalizedCollection = normalize(query.collection)
        let isTag: Bool
        if case .tag = normalizedCollection {
            isTag = true
        } else {
            isTag = false
        }
        if isTag && !capabilities.tagRelationsReady {
            throw LibraryQueryError.unsupportedTag
        }

        let isRecent: Bool
        if case .recent = normalizedCollection {
            isRecent = true
        } else {
            isRecent = false
        }

        let fingerprint = queryFingerprint(
            for: normalizedCollection,
            isRecent: isRecent,
            type: query.type,
            modelId: query.modelId,
            favoriteOnly: query.favoriteOnly,
            dataRevision: query.dataRevision
        )
        var values: [SQLiteValue] = []
        var predicates: [String] = []

        switch normalizedCollection {
        case .all:
            predicates.append("p.deletedAt IS NULL")
        case .folder(let id):
            predicates.append("p.deletedAt IS NULL")
            predicates.append("p.folderId = ?")
            values.append(.text(id))
        case .type(let type):
            predicates.append("p.deletedAt IS NULL")
            predicates.append("p.type = ?")
            values.append(.text(type.rawValue))
        case .model(let id):
            predicates.append("p.deletedAt IS NULL")
            predicates.append("p.modelId = ?")
            values.append(.text(id))
        case .favorite, .favorites:
            predicates.append("p.deletedAt IS NULL")
            predicates.append("p.favorite = 1")
        case .recent:
            predicates.append("p.deletedAt IS NULL")
            predicates.append("p.itemLastUsedAtSortKey > ?")
            values.append(.int(dateSortKey(from: Date(timeIntervalSince1970: 0))))
        case .trash:
            predicates.append("p.deletedAt IS NOT NULL")
        case .tag(let name):
            predicates.append("pit.tagKey=?")
            predicates.append("pit.isFirstOccurrence=1")
            predicates.append("pit.isDeleted=0")
            predicates.append("p.deletedAt IS NULL")
            values.append(.text(TagIdentity.relationKey(for: name)))
        }

        let collectionType: PromptType? = {
            if case .type(let type) = normalizedCollection { return type }
            return nil
        }()
        let collectionModelID: String? = {
            if case .model(let id) = normalizedCollection { return id }
            return nil
        }()
        let collectionIsFavorite: Bool = {
            if case .favorite = normalizedCollection { return true }
            return false
        }()
        if let type = query.type, collectionType != type {
            predicates.append("p.type = ?")
            values.append(.text(type.rawValue))
        }
        if let modelId = query.modelId, collectionModelID != modelId {
            predicates.append("p.modelId = ?")
            values.append(.text(modelId))
        }
        if query.favoriteOnly && !collectionIsFavorite {
            predicates.append("p.favorite = 1")
        }

        if let cursor = query.cursor {
            guard cursor.queryFingerprint == fingerprint else {
                throw LibraryQueryError.cursorQueryFingerprintMismatch(
                    expected: fingerprint,
                    actual: cursor.queryFingerprint
                )
            }
            if isRecent {
                guard cursor.itemLastUsedAtSortKey != nil else { throw LibraryQueryError.invalidCursor }
            } else {
                guard cursor.sortOrder != nil else { throw LibraryQueryError.invalidCursor }
            }
            guard cursor.itemCreatedAtSortKey != nil, cursor.itemSequence != nil else {
                throw LibraryQueryError.invalidCursor
            }
            appendCursorPredicate(
                cursor,
                recent: isRecent,
                predicates: &predicates,
                values: &values
            )
        }

        let orderBy: String
        if isRecent {
            orderBy = "p.itemLastUsedAtSortKey DESC, p.itemCreatedAtSortKey DESC, p.itemSequence ASC"
        } else {
            orderBy = "p.sortOrder ASC, p.itemCreatedAtSortKey DESC, p.itemSequence ASC"
        }

        let fromClause = isTag
            ? "FROM prompt_item_tags pit\nJOIN prompt_items p ON p.id=pit.promptItemId"
            : "FROM prompt_items p"

        let limit = query.pageSize + 1
        let whereClause = predicates.isEmpty ? "" : "WHERE " + predicates.joined(separator: " AND ")
        let latestVersionProjection = """
            COALESCE((
                SELECT ps_trim_whitespace(v.prompt)
                FROM prompt_versions v
                WHERE v.promptItemId = p.id
                  AND v.versionCreatedAtSortKey = (
                      SELECT MAX(v2.versionCreatedAtSortKey)
                      FROM prompt_versions v2
                      WHERE v2.promptItemId = p.id
                  )
                  AND v.versionSequence = (
                      SELECT MAX(v3.versionSequence)
                      FROM prompt_versions v3
                      WHERE v3.promptItemId = p.id
                        AND v3.versionCreatedAtSortKey = v.versionCreatedAtSortKey
                  )
                LIMIT 1
            ), '') <> '' AS hasPrompt,
        """

        let itemMetadataProjection = "p.itemCreatedAtSortKey AS itemCreatedAtSortKey, p.itemLastUsedAtSortKey AS itemLastUsedAtSortKey, p.itemSequence AS itemSequence,"

        let sql = """
        SELECT
            p.id,
            p.title,
            p.type,
            p.assetKind,
            p.modelId,
            p.modelName,
            p.folderId,
            p.folderName,
            p.category,
            p.assetPath,
            p.thumbnailPath,
            p.aspectRatio,
            p.width,
            p.height,
            p.format,
            p.fileSize,
            p.favorite,
            p.pinnedAt,
            p.deletedAt,
            p.createdAt,
            p.updatedAt,
            p.lastUsedAt,
            p.sortOrder,
            \(itemMetadataProjection)
            \(latestVersionProjection)
            ps_reference_asset_count(p.referencesJSON) > 0 AS hasReferences
        \(fromClause)
        \(whereClause)
        ORDER BY \(orderBy)
        LIMIT ?;
        """
        values.append(.int(Int64(limit)))
        return LibraryQuerySQL(
            sql: sql,
            values: values,
            queryFingerprint: fingerprint,
            limit: limit,
            usesRecentOrdering: isRecent,
            usesItemSequenceOrdering: true
        )
    }

    public static func buildSQL(_ query: LibraryQuery) throws -> LibraryQuerySQL {
        try build(query)
    }

    public static func buildSQL(
        _ query: LibraryQuery,
        tagRelationsReady: Bool
    ) throws -> LibraryQuerySQL {
        try build(query, tagRelationsReady: tagRelationsReady)
    }

    public static func buildSQL(
        _ query: LibraryQuery,
        capabilities: LibraryQueryCapabilities
    ) throws -> LibraryQuerySQL {
        try build(query, capabilities: capabilities)
    }

    /// Builds the filter-equivalent COUNT query used to populate
    /// `LibraryItemPage.totalCount`. Cursor and page-size parameters are
    /// intentionally omitted so every page reports the same filtered total.
    public static func buildCount(_ query: LibraryQuery) throws -> LibraryQueryCountSQL {
        try buildCount(query, capabilities: .legacy)
    }

    public static func buildCount(
        _ query: LibraryQuery,
        tagRelationsReady: Bool
    ) throws -> LibraryQueryCountSQL {
        try buildCount(query, capabilities: LibraryQueryCapabilities(tagRelationsReady: tagRelationsReady))
    }

    public static func buildCount(
        _ query: LibraryQuery,
        capabilities: LibraryQueryCapabilities
    ) throws -> LibraryQueryCountSQL {
        var unpaged = query
        unpaged.cursor = nil
        let pageSQL = try build(unpaged, capabilities: capabilities)
        guard let fromMarkerRange = pageSQL.sql.range(of: "\nFROM ", options: .backwards),
              let orderRange = pageSQL.sql.range(of: "ORDER BY", range: fromMarkerRange.upperBound..<pageSQL.sql.endIndex) else {
            throw LibraryQueryError.malformedRow("count SQL")
        }
        let fromStart = pageSQL.sql.index(after: fromMarkerRange.lowerBound)
        let fromAndWhere = pageSQL.sql[fromStart..<orderRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let values = Array(pageSQL.values.dropLast())
        return LibraryQueryCountSQL(
            sql: "SELECT COUNT(*) AS totalCount " + fromAndWhere + ";",
            values: values,
            queryFingerprint: pageSQL.queryFingerprint
        )
    }

    public static func buildCountSQL(_ query: LibraryQuery) throws -> LibraryQueryCountSQL {
        try buildCount(query)
    }

    public static func buildCountSQL(
        _ query: LibraryQuery,
        tagRelationsReady: Bool
    ) throws -> LibraryQueryCountSQL {
        try buildCount(query, tagRelationsReady: tagRelationsReady)
    }

    public static func buildCountSQL(
        _ query: LibraryQuery,
        capabilities: LibraryQueryCapabilities
    ) throws -> LibraryQueryCountSQL {
        try buildCount(query, capabilities: capabilities)
    }

    public static func installPhase2A1Indexes(execute: (String) throws -> Void) rethrows {
        try installPhase2A1Indexes(using: execute)
    }

    public static func installPhase2A2TagIndex(execute: (String) throws -> Void) rethrows {
        try installPhase2A2TagIndex(using: execute)
    }

    public static func installPhase2A2Indexes(execute: (String) throws -> Void) rethrows {
        try installPhase2A2Indexes(using: execute)
    }

    public static func installPhase2A4LatestVersionIndex(
        execute: (String) throws -> Void,
        versionSequenceReady: Bool = false
    ) throws {
        try installPhase2A4LatestVersionIndex(using: execute, versionSequenceReady: versionSequenceReady)
    }

    public static func installPhase2A4Index(
        execute: (String) throws -> Void,
        versionSequenceReady: Bool = false
    ) throws {
        try installPhase2A4Index(using: execute, versionSequenceReady: versionSequenceReady)
    }

    private static func normalize(_ collection: LibraryQueryCollection) -> LibraryQueryCollection {
        if case .favorites = collection {
            return .favorite
        }
        return collection
    }

    private static func queryFingerprint(
        for collection: LibraryQueryCollection,
        isRecent: Bool,
        type: PromptType?,
        modelId: String?,
        favoriteOnly: Bool,
        dataRevision: UInt64
    ) -> String {
        let canonical: String
        switch collection {
        case .all:
            canonical = "all"
        case .folder(let id):
            canonical = "folder:\(id)"
        case .type(let type):
            canonical = "type:\(type.rawValue)"
        case .model(let id):
            canonical = "model:\(id)"
        case .favorite, .favorites:
            canonical = "favorite"
        case .recent:
            canonical = "recent"
        case .trash:
            canonical = "trash"
        case .tag(let name):
            canonical = "tag:\(name)"
        }
        let ordering = isRecent
            ? "lastUsedAtSortKey-desc-createdAtSortKey-desc-itemSequence-asc"
            : "sortOrder-asc-createdAtSortKey-desc-itemSequence-asc"
        let refinements = [
            "type=\(type?.rawValue ?? "")",
            "model=\(modelId ?? "")",
            "favorite=\(favoriteOnly ? "1" : "0")"
        ].joined(separator: "&")
        return stableFingerprint(canonical + "|" + refinements + "|" + ordering + "|revision=\(dataRevision)")
    }

    private static func stableFingerprint(_ value: String) -> String {
        // FNV-1a is small, deterministic across processes, and sufficient for
        // detecting a cursor accidentally reused with another query. It is not
        // intended as an authentication primitive.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    private static func appendCursorPredicate(
        _ cursor: LibraryQueryCursor,
        recent: Bool,
        predicates: inout [String],
        values: inout [SQLiteValue]
    ) {
        guard let itemCreated = cursor.itemCreatedAtSortKey,
              let sequence = cursor.itemSequence else {
            predicates.append("1 = 0")
            return
        }
        if recent {
            guard let itemLastUsed = cursor.itemLastUsedAtSortKey else {
                predicates.append("1 = 0")
                return
            }
            predicates.append("(p.itemLastUsedAtSortKey < ? OR (p.itemLastUsedAtSortKey = ? AND p.itemCreatedAtSortKey < ?) OR (p.itemLastUsedAtSortKey = ? AND p.itemCreatedAtSortKey = ? AND p.itemSequence > ?))")
            values += [.int(itemLastUsed), .int(itemLastUsed), .int(itemCreated), .int(itemLastUsed), .int(itemCreated), .int(sequence)]
        } else {
            guard let sortOrder = cursor.sortOrder else {
                predicates.append("1 = 0")
                return
            }
            predicates.append("(p.sortOrder > ? OR (p.sortOrder = ? AND p.itemCreatedAtSortKey < ?) OR (p.sortOrder = ? AND p.itemCreatedAtSortKey = ? AND p.itemSequence > ?))")
            values += [.int(Int64(sortOrder)), .int(Int64(sortOrder)), .int(itemCreated), .int(Int64(sortOrder)), .int(itemCreated), .int(sequence)]
        }
    }

    private static func dateString(from date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func dateSortKey(from date: Date) -> Int64 {
        let value = (date.timeIntervalSince1970 * 1_000_000).rounded()
        guard value.isFinite, value >= Double(Int64.min), value <= Double(Int64.max) else {
            return value.sign == .minus ? Int64.min : Int64.max
        }
        return Int64(value)
    }
}
