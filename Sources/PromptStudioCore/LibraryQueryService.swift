import Foundation

public typealias LibraryQueryExecutor = @Sendable (_ sql: String, _ values: [SQLiteValue]) async throws -> [[String: String?]]

/// Minimal read-only boundary used by the query service. A SQLite connection
/// adapter can implement this protocol without making the service own a
/// connection or a transaction.
public protocol LibraryQueryRowExecutor: Sendable {
    func query(sql: String, values: [SQLiteValue]) async throws -> [[String: String?]]
    func queryPageAndCount(
        pageSQL: String,
        pageValues: [SQLiteValue],
        countSQL: String,
        countValues: [SQLiteValue]
    ) async throws -> LibraryQueryReadBatch
}

public extension LibraryQueryRowExecutor {
    func queryPageAndCount(
        pageSQL: String,
        pageValues: [SQLiteValue],
        countSQL: String,
        countValues: [SQLiteValue]
    ) async throws -> LibraryQueryReadBatch {
        let pageRows = try await query(sql: pageSQL, values: pageValues)
        let countRows = try await query(sql: countSQL, values: countValues)
        return LibraryQueryReadBatch(pageRows: pageRows, countRows: countRows)
    }

    /// The optional explain hook keeps plan inspection explicit while allowing
    /// a tiny test executor to implement only the read operation.
    func explain(sql: String, values: [SQLiteValue]) async throws -> [[String: String?]] {
        try await query(sql: sql, values: values)
    }
}

public struct LibraryQueryReadBatch: Sendable {
    public let pageRows: [[String: String?]]
    public let countRows: [[String: String?]]

    public init(pageRows: [[String: String?]], countRows: [[String: String?]]) {
        self.pageRows = pageRows
        self.countRows = countRows
    }
}

public final class LibraryQueryService: @unchecked Sendable {
    private let executeRows: LibraryQueryExecutor
    private let executePageAndCount: @Sendable (
        _ pageSQL: String,
        _ pageValues: [SQLiteValue],
        _ countSQL: String,
        _ countValues: [SQLiteValue]
    ) async throws -> LibraryQueryReadBatch
    public let dataRevision: LibraryDataRevision
    private let capabilitiesProvider: @Sendable () -> LibraryQueryCapabilities
    public var capabilities: LibraryQueryCapabilities { capabilitiesProvider() }
    public var tagRelationsReady: Bool { capabilities.tagRelationsReady }
    private let generationLock = NSLock()
    private var generationValue: UInt64 = 0

    private init(
        executeRows: @escaping LibraryQueryExecutor,
        executePageAndCount: @escaping @Sendable (
            _ pageSQL: String,
            _ pageValues: [SQLiteValue],
            _ countSQL: String,
            _ countValues: [SQLiteValue]
        ) async throws -> LibraryQueryReadBatch,
        dataRevision: LibraryDataRevision,
        capabilitiesProvider: @escaping @Sendable () -> LibraryQueryCapabilities
    ) {
        self.executeRows = executeRows
        self.executePageAndCount = executePageAndCount
        self.dataRevision = dataRevision
        self.capabilitiesProvider = capabilitiesProvider
    }

    public convenience init(
        executor: @escaping LibraryQueryExecutor,
        dataRevision: LibraryDataRevision = LibraryDataRevision(),
        tagRelationsReady: Bool = false,
        versionSequenceReady: Bool = false,
        itemSequenceReady: Bool = false
    ) {
        let fixedCapabilities = LibraryQueryCapabilities(
            tagRelationsReady: tagRelationsReady,
            versionSequenceReady: versionSequenceReady,
            itemSequenceReady: itemSequenceReady
        )
        self.init(
            executeRows: executor,
            executePageAndCount: { pageSQL, pageValues, countSQL, countValues in
                let pageRows = try await executor(pageSQL, pageValues)
                let countRows = try await executor(countSQL, countValues)
                return LibraryQueryReadBatch(pageRows: pageRows, countRows: countRows)
            },
            dataRevision: dataRevision,
            capabilitiesProvider: { fixedCapabilities }
        )
    }

    public convenience init(
        executor: @escaping LibraryQueryExecutor,
        dataRevision: LibraryDataRevision = LibraryDataRevision(),
        capabilities: LibraryQueryCapabilities
    ) {
        self.init(
            executor: executor,
            dataRevision: dataRevision,
            tagRelationsReady: capabilities.tagRelationsReady,
            versionSequenceReady: capabilities.versionSequenceReady,
            itemSequenceReady: capabilities.itemSequenceReady
        )
    }

    public convenience init(
        executor: @escaping LibraryQueryExecutor,
        dataRevision: LibraryDataRevision = LibraryDataRevision(),
        queryCapabilities: LibraryQueryCapabilities
    ) {
        self.init(
            executor: executor,
            dataRevision: dataRevision,
            tagRelationsReady: queryCapabilities.tagRelationsReady,
            versionSequenceReady: queryCapabilities.versionSequenceReady,
            itemSequenceReady: queryCapabilities.itemSequenceReady
        )
    }

    public convenience init(
        executor: @escaping LibraryQueryExecutor,
        repository: PromptRepository,
        dataRevision: LibraryDataRevision? = nil
    ) {
        self.init(
            executor: executor,
            dataRevision: dataRevision ?? repository.libraryDataRevision,
            capabilitiesProvider: { .runtime(for: repository) }
        )
    }

    private convenience init(
        executor: @escaping LibraryQueryExecutor,
        dataRevision: LibraryDataRevision,
        capabilitiesProvider: @escaping @Sendable () -> LibraryQueryCapabilities
    ) {
        self.init(
            executeRows: executor,
            executePageAndCount: { pageSQL, pageValues, countSQL, countValues in
                let pageRows = try await executor(pageSQL, pageValues)
                let countRows = try await executor(countSQL, countValues)
                return LibraryQueryReadBatch(pageRows: pageRows, countRows: countRows)
            },
            dataRevision: dataRevision,
            capabilitiesProvider: capabilitiesProvider
        )
    }

    public convenience init(
        executor: LibraryQueryRowExecutor,
        dataRevision: LibraryDataRevision = LibraryDataRevision(),
        tagRelationsReady: Bool = false,
        versionSequenceReady: Bool = false,
        itemSequenceReady: Bool = false
    ) {
        let fixedCapabilities = LibraryQueryCapabilities(
            tagRelationsReady: tagRelationsReady,
            versionSequenceReady: versionSequenceReady,
            itemSequenceReady: itemSequenceReady
        )
        self.init(
            executeRows: { sql, values in
                try await executor.query(sql: sql, values: values)
            },
            executePageAndCount: { pageSQL, pageValues, countSQL, countValues in
                try await executor.queryPageAndCount(
                    pageSQL: pageSQL,
                    pageValues: pageValues,
                    countSQL: countSQL,
                    countValues: countValues
                )
            },
            dataRevision: dataRevision,
            capabilitiesProvider: { fixedCapabilities }
        )
    }

    public convenience init(
        executor: LibraryQueryRowExecutor,
        dataRevision: LibraryDataRevision = LibraryDataRevision(),
        capabilities: LibraryQueryCapabilities
    ) {
        self.init(
            executor: executor,
            dataRevision: dataRevision,
            tagRelationsReady: capabilities.tagRelationsReady,
            versionSequenceReady: capabilities.versionSequenceReady,
            itemSequenceReady: capabilities.itemSequenceReady
        )
    }

    public convenience init(
        executor: LibraryQueryRowExecutor,
        dataRevision: LibraryDataRevision = LibraryDataRevision(),
        queryCapabilities: LibraryQueryCapabilities
    ) {
        self.init(
            executor: executor,
            dataRevision: dataRevision,
            tagRelationsReady: queryCapabilities.tagRelationsReady,
            versionSequenceReady: queryCapabilities.versionSequenceReady,
            itemSequenceReady: queryCapabilities.itemSequenceReady
        )
    }

    public convenience init(
        executor: LibraryQueryRowExecutor,
        repository: PromptRepository,
        dataRevision: LibraryDataRevision? = nil
    ) {
        self.init(
            executor: executor,
            dataRevision: dataRevision ?? repository.libraryDataRevision,
            capabilitiesProvider: { .runtime(for: repository) }
        )
    }

    private convenience init(
        executor: LibraryQueryRowExecutor,
        dataRevision: LibraryDataRevision,
        capabilitiesProvider: @escaping @Sendable () -> LibraryQueryCapabilities
    ) {
        self.init(
            executeRows: { sql, values in
                try await executor.query(sql: sql, values: values)
            },
            executePageAndCount: { pageSQL, pageValues, countSQL, countValues in
                try await executor.queryPageAndCount(
                    pageSQL: pageSQL,
                    pageValues: pageValues,
                    countSQL: countSQL,
                    countValues: countValues
                )
            },
            dataRevision: dataRevision,
            capabilitiesProvider: capabilitiesProvider
        )
    }

    /// Advances the monotonic result generation. This does not cancel an
    /// already-running executor call; it only makes that call's eventual
    /// result stale when the service checks it after the read returns.
    @discardableResult
    public func beginGeneration() -> UInt64 {
        generationLock.lock()
        generationValue &+= 1
        let value = generationValue
        generationLock.unlock()
        return value
    }

    @discardableResult
    public func nextGeneration() -> UInt64 {
        beginGeneration()
    }

    public var currentGeneration: UInt64 {
        generationLock.lock()
        let value = generationValue
        generationLock.unlock()
        return value
    }

    public func query(_ query: LibraryQuery, generation: UInt64? = nil) async throws -> LibraryItemPage {
        let requestedRevision = dataRevision.current
        var effectiveQuery = query
        effectiveQuery.dataRevision = requestedRevision
        // Capture one readiness snapshot for the entire request.  SQL
        // construction and row decoding must agree even if migration flips a
        // gate while the asynchronous read is in flight.
        let capabilities = capabilitiesProvider()
        let built = try LibraryQuerySQLBuilder.build(effectiveQuery, capabilities: capabilities)
        let countSQL = try LibraryQuerySQLBuilder.buildCount(effectiveQuery, capabilities: capabilities)

        // Deliberately execute before checking generation. Generation is a
        // stale-result guard, not a cancellation mechanism.
        try Task.checkCancellation()
        let batch = try await executePageAndCount(
            built.sql,
            built.values,
            countSQL.sql,
            countSQL.values
        )
        try Task.checkCancellation()
        let currentRevision = dataRevision.current
        guard requestedRevision == currentRevision else {
            throw LibraryQueryError.staleDataRevision(
                requested: requestedRevision,
                current: currentRevision
            )
        }
        if let generation {
            let current = currentGeneration
            guard generation == current else {
                throw LibraryQueryError.staleResult(requested: generation, current: current)
            }
        }

        let summaries = try batch.pageRows.map { try decodeSummary($0, capabilities: capabilities) }
        let totalCount = try decodeTotalCount(batch.countRows)
        let hasMore = summaries.count > effectiveQuery.pageSize
        let visible = hasMore ? Array(summaries.prefix(effectiveQuery.pageSize)) : summaries
        guard hasMore, let last = visible.last else {
            return LibraryItemPage(items: visible, totalCount: totalCount)
        }
        let cursorRow = batch.pageRows[visible.count - 1]
        let createdAtSortKey: String
        if built.usesItemSequenceOrdering {
            guard let rawCreated = required(cursorRow, "itemCreatedAtSortKey"),
                  Int64(rawCreated) != nil else {
                throw LibraryQueryError.malformedRow("itemCreatedAtSortKey cursor sort key")
            }
            createdAtSortKey = rawCreated
        } else {
            guard let rawCreated = required(cursorRow, "createdAt"),
                  !rawCreated.isEmpty else {
                throw LibraryQueryError.malformedRow("createdAt cursor sort key")
            }
            createdAtSortKey = rawCreated
        }
        // Ready ordering uses the persisted numeric last-used key below.  Do
        // not require the legacy raw text column when creating a ready
        // cursor; it may be malformed/empty while the persisted key remains
        // authoritative.  Keep the legacy cursor token for pre-ready paths.
        let lastUsedAtSortKey: String?
        if built.usesItemSequenceOrdering {
            lastUsedAtSortKey = nil
        } else {
            lastUsedAtSortKey = required(cursorRow, "lastUsedAt")
        }

        let itemCreatedAtSortKey: Int64?
        let itemLastUsedAtSortKey: Int64?
        let itemSequence: Int64?
        if built.usesItemSequenceOrdering {
            guard let rawCreated = required(cursorRow, "itemCreatedAtSortKey"),
                  let parsedCreated = Int64(rawCreated),
                  let rawLastUsed = required(cursorRow, "itemLastUsedAtSortKey"),
                  let parsedLastUsed = Int64(rawLastUsed),
                  let rawSequence = required(cursorRow, "itemSequence"),
                  let parsedSequence = Int64(rawSequence), parsedSequence > 0 else {
                throw LibraryQueryError.malformedRow("item sequence cursor metadata")
            }
            itemCreatedAtSortKey = parsedCreated
            itemLastUsedAtSortKey = parsedLastUsed
            itemSequence = parsedSequence
        } else {
            itemCreatedAtSortKey = nil
            itemLastUsedAtSortKey = nil
            itemSequence = nil
        }

        let cursor = LibraryQueryCursor(
            queryFingerprint: built.queryFingerprint,
            sortOrder: built.usesRecentOrdering ? nil : last.sortOrder,
            lastUsedAtSortKey: built.usesRecentOrdering && !built.usesItemSequenceOrdering ? lastUsedAtSortKey : nil,
            createdAtSortKey: createdAtSortKey,
            id: last.id,
            itemCreatedAtSortKey: itemCreatedAtSortKey,
            itemLastUsedAtSortKey: itemLastUsedAtSortKey,
            itemSequence: itemSequence
        )
        return LibraryItemPage(items: visible, totalCount: totalCount, nextCursor: cursor, hasMore: true)
    }

    @discardableResult
    public func advanceDataRevision() -> UInt64 {
        dataRevision.advance()
    }

    public func fetch(_ query: LibraryQuery, generation: UInt64? = nil) async throws -> LibraryItemPage {
        try await self.query(query, generation: generation)
    }

    public func load(_ query: LibraryQuery, generation: UInt64? = nil) async throws -> LibraryItemPage {
        try await self.query(query, generation: generation)
    }

    /// Returns SQLite's query-plan rows for diagnostics and index QA without
    /// making the service own a SQLite connection.
    public func explain(_ query: LibraryQuery) async throws -> [[String: String?]] {
        var effectiveQuery = query
        effectiveQuery.dataRevision = dataRevision.current
        let capabilities = capabilitiesProvider()
        let built = try LibraryQuerySQLBuilder.build(effectiveQuery, capabilities: capabilities)
        return try await executeRows("EXPLAIN QUERY PLAN \(built.sql)", built.values)
    }

    private func decodeSummary(
        _ row: [String: String?],
        capabilities: LibraryQueryCapabilities
    ) throws -> LibraryItemSummary {
        guard let id = required(row, "id"), !id.isEmpty else {
            throw LibraryQueryError.malformedRow("id")
        }
        guard let title = required(row, "title") else {
            throw LibraryQueryError.malformedRow("title")
        }
        guard let rawType = required(row, "type"), let type = PromptType(rawValue: rawType) else {
            throw LibraryQueryError.malformedRow("type")
        }
        guard let rawAssetKind = required(row, "assetKind"), let assetKind = AssetKind(rawValue: rawAssetKind) else {
            throw LibraryQueryError.malformedRow("assetKind")
        }

        let createdAt: Date
        if capabilities.itemSequenceReady {
            guard let rawSequence = required(row, "itemSequence"),
                  let sequence = Int64(rawSequence),
                  sequence > 0,
                  let rawSortKey = required(row, "itemCreatedAtSortKey"),
                  let sortKey = Int64(rawSortKey),
                  let rawLastUsedSortKey = required(row, "itemLastUsedAtSortKey"),
                  Int64(rawLastUsedSortKey) != nil else {
                throw LibraryQueryError.malformedRow("item sequence metadata")
            }
            createdAt = PromptItemCreatedAtSupport.date(forSortKey: sortKey)
        } else {
            createdAt = try date(row, "createdAt")
        }
        let updatedAt = try date(row, "updatedAt")
        let lastUsedAt = try date(row, "lastUsedAt")
        return LibraryItemSummary(
            id: id,
            title: title,
            type: type,
            assetKind: assetKind,
            modelId: value(row, "modelId"),
            modelName: value(row, "modelName"),
            folderId: value(row, "folderId"),
            folderName: value(row, "folderName"),
            category: value(row, "category"),
            assetPath: value(row, "assetPath"),
            thumbnailPath: value(row, "thumbnailPath"),
            aspectRatio: value(row, "aspectRatio"),
            width: integer(row, "width"),
            height: integer(row, "height"),
            format: value(row, "format"),
            fileSize: integer64(row, "fileSize"),
            favorite: integer(row, "favorite") == 1,
            pinnedAt: optionalDate(row, "pinnedAt"),
            deletedAt: optionalDate(row, "deletedAt"),
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastUsedAt: lastUsedAt,
            sortOrder: integer(row, "sortOrder"),
            hasPrompt: integer(row, "hasPrompt") != 0,
            hasReferences: integer(row, "hasReferences") != 0
        )
    }

    private func decodeTotalCount(_ rows: [[String: String?]]) throws -> Int {
        guard let row = rows.first,
              let raw = row["totalCount"] ?? nil,
              let count = Int(raw), count >= 0 else {
            throw LibraryQueryError.malformedRow("totalCount")
        }
        return count
    }

    private func required(_ row: [String: String?], _ key: String) -> String? {
        guard let value = row[key] else { return nil }
        return value
    }

    private func value(_ row: [String: String?], _ key: String) -> String {
        required(row, key) ?? ""
    }

    private func integer(_ row: [String: String?], _ key: String) -> Int {
        Int(value(row, key)) ?? 0
    }

    private func integer64(_ row: [String: String?], _ key: String) -> Int64 {
        Int64(value(row, key)) ?? 0
    }

    private func date(_ row: [String: String?], _ key: String) throws -> Date {
        guard let date = optionalDate(row, key) else {
            throw LibraryQueryError.malformedRow(key)
        }
        return date
    }

    private func optionalDate(_ row: [String: String?], _ key: String) -> Date? {
        guard let string = row[key] ?? nil, !string.isEmpty else { return nil }
        if let fractional = try? Date(
            string,
            strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        ) {
            return fractional
        }
        return try? Date(string, strategy: .iso8601)
    }
}
