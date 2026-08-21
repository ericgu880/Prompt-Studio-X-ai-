import Foundation

/// Errors raised when the point query itself does not contain a required
/// persisted column. JSON/date values intentionally retain the legacy
/// `loadItems()` fallback semantics for shadow consistency.
public enum PromptItemDetailError: Error, LocalizedError, Equatable, Sendable {
    case malformedRow(field: String)

    public var errorDescription: String? {
        switch self {
        case .malformedRow(let field):
            "Prompt detail row is missing \(field)"
        }
    }
}

/// Minimal injection boundary for an item-detail owner. Implementations must
/// return nil for an unknown ID and throw for read or required-row failures.
public protocol ItemDetailLoading: Sendable {
    func itemDetail(id: String) async throws -> PromptItem?
}

/// Loads one prompt item and its versions through an independent read-only
/// SQLite connection. The two SELECTs run in one deferred read transaction,
/// so the item and version graph always comes from one SQLite snapshot.
public final class PromptItemDetailService: @unchecked Sendable, ItemDetailLoading {
    public let databaseURL: URL

    private let readConnection: SQLiteReadConnection
    private let versionSequenceReadyProvider: @Sendable () -> Bool
    private let itemSequenceReadyProvider: @Sendable () -> Bool

    public init(
        databaseURL: URL,
        readConnection: SQLiteReadConnection? = nil,
        versionSequenceReadyProvider: (@Sendable () -> Bool)? = nil,
        itemSequenceReadyProvider: (@Sendable () -> Bool)? = nil
    ) throws {
        self.databaseURL = databaseURL
        if let readConnection {
            self.readConnection = readConnection
        } else {
            self.readConnection = try SQLiteReadConnection(url: databaseURL)
        }
        self.versionSequenceReadyProvider = versionSequenceReadyProvider ?? {
            PromptRepository.versionSequenceRuntimeReady(at: databaseURL.path)
        }
        self.itemSequenceReadyProvider = itemSequenceReadyProvider ?? {
            PromptRepository.itemSequenceRuntimeReady(at: databaseURL.path)
        }
    }

    public func itemDetail(id: String) async throws -> PromptItem? {
        try await itemDetail(id: id, cancellationToken: nil)
    }

    /// The optional token is useful to owners that coordinate cancellation
    /// across a detail request and other work. Swift task cancellation is
    /// always observed as well.
    public func itemDetail(
        id: String,
        cancellationToken: SQLiteQueryCancellation?
    ) async throws -> PromptItem? {
        try checkCancellation(cancellationToken)

        let versionSequenceReady = versionSequenceReadyProvider()
        let itemSequenceReady = itemSequenceReadyProvider()
        let versionsSQL = versionSequenceReady
            ? "SELECT * FROM prompt_versions WHERE promptItemId = ? ORDER BY versionCreatedAtSortKey ASC, versionSequence ASC;"
            : "SELECT * FROM prompt_versions WHERE promptItemId = ? ORDER BY createdAt ASC;"
        let batch = try await readConnection.queryReadBatch(
            firstSQL: "SELECT * FROM prompt_items WHERE id = ? LIMIT 1;",
            firstValues: [.text(id)],
            secondSQL: versionsSQL,
            secondValues: [.text(id)],
            cancellationToken: cancellationToken
        )
        try checkCancellation(cancellationToken)

        guard let row = batch.pageRows.first else {
            // A missing item is the only valid empty result. A dangling
            // version row cannot be surfaced because the item query won.
            return nil
        }

        try checkCancellation(cancellationToken)
        let itemWithoutVersions = try decodeItem(
            row,
            itemSequenceReady: itemSequenceReady,
            cancellationToken: cancellationToken
        )
        try checkCancellation(cancellationToken)
        let versions = try decodeVersions(
            batch.countRows,
            versionSequenceReady: versionSequenceReady,
            cancellationToken: cancellationToken
        )
        try checkCancellation(cancellationToken)

        var item = itemWithoutVersions
        item.versions = versions
        return item
    }

    private func decodeItem(
        _ row: [String: String?],
        itemSequenceReady: Bool,
        cancellationToken: SQLiteQueryCancellation?
    ) throws -> PromptItem {
        try checkCancellation(cancellationToken)

        let id = try required(row, "id")
        let tagsJSON = try required(row, "tagsJSON")
        let referencesJSON = try required(row, "referencesJSON")
        let tags = decode([String].self, from: tagsJSON, fallback: [])
        try checkCancellation(cancellationToken)
        let references = decode([ReferenceAsset].self, from: referencesJSON, fallback: [])
        try checkCancellation(cancellationToken)

        let capturedSource: CapturedSource?
        if let raw = row["captureSourceJSON"] ?? nil, !raw.isEmpty {
            capturedSource = decodeOptional(CapturedSource.self, from: raw)
        } else {
            capturedSource = nil
        }
        try checkCancellation(cancellationToken)

        let createdAt: Date
        let itemSequenceMetadata: (sequence: Int64, createdAtSortKey: Int64, lastUsedAtSortKey: Int64)?
        if itemSequenceReady {
            guard let sequence = integer64Optional(row, "itemSequence"), sequence > 0 else {
                throw PromptItemDetailError.malformedRow(field: "itemSequence")
            }
            guard let sortKey = integer64Optional(row, "itemCreatedAtSortKey") else {
                throw PromptItemDetailError.malformedRow(field: "itemCreatedAtSortKey")
            }
            guard let lastUsedSortKey = integer64Optional(row, "itemLastUsedAtSortKey") else {
                throw PromptItemDetailError.malformedRow(field: "itemLastUsedAtSortKey")
            }
            createdAt = PromptItemCreatedAtSupport.date(forSortKey: sortKey)
            itemSequenceMetadata = (sequence, sortKey, lastUsedSortKey)
        } else {
            // The pre-ready detail path is intentionally legacy-only.  It may
            // parse raw text/fallback while the Summary path remains gated.
            createdAt = date(row, "createdAt", fallback: Date())
            itemSequenceMetadata = nil
        }
        let updatedAt = date(row, "updatedAt", fallback: Date())
        let lastUsedAt = date(row, "lastUsedAt", fallback: Date(timeIntervalSince1970: 0))
        try checkCancellation(cancellationToken)

        return PromptItem(
            id: id,
            title: try required(row, "title"),
            type: PromptType(rawValue: try required(row, "type")) ?? .image,
            assetKind: AssetKind(rawValue: try required(row, "assetKind")) ?? .unknown,
            modelId: try required(row, "modelId"),
            modelName: try required(row, "modelName"),
            folderId: try required(row, "folderId"),
            folderName: try required(row, "folderName"),
            category: try required(row, "category"),
            assetPath: try required(row, "assetPath"),
            thumbnailPath: try required(row, "thumbnailPath"),
            aspectRatio: try required(row, "aspectRatio"),
            width: integer(row, "width"),
            height: integer(row, "height"),
            format: try required(row, "format"),
            fileSize: integer64(row, "fileSize"),
            favorite: integer(row, "favorite") == 1,
            pinnedAt: optionalDate(row, "pinnedAt"),
            deletedAt: optionalDate(row, "deletedAt"),
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastUsedAt: lastUsedAt,
            sortOrder: integer(row, "sortOrder"),
            itemSequence: itemSequenceMetadata?.sequence,
            itemCreatedAtSortKey: itemSequenceMetadata?.createdAtSortKey,
            itemLastUsedAtSortKey: itemSequenceMetadata?.lastUsedAtSortKey,
            tags: tags,
            referenceAssets: references,
            versions: [],
            description: try required(row, "description"),
            captureID: row["captureId"] ?? nil,
            capturedSource: capturedSource
        )
    }

    private func decodeVersions(
        _ rows: [[String: String?]],
        versionSequenceReady: Bool,
        cancellationToken: SQLiteQueryCancellation?
    ) throws -> [PromptVersion] {
        var versions: [PromptVersion] = []
        versions.reserveCapacity(rows.count)
        for row in rows {
            try checkCancellation(cancellationToken)
            let parametersJSON = try required(row, "parametersJSON")
            let parameters = decode([String: String].self, from: parametersJSON, fallback: [:])
            let version = PromptVersion(
                id: try required(row, "id"),
                promptItemId: try required(row, "promptItemId"),
                version: try required(row, "version"),
                prompt: try required(row, "prompt"),
                negativePrompt: try required(row, "negativePrompt"),
                parameters: parameters,
                note: try required(row, "note"),
                createdAt: date(row, "createdAt", fallback: Date()),
                versionSequence: versionSequenceReady
                    ? integer64Optional(row, "versionSequence")
                    : nil,
                versionCreatedAtSortKey: versionSequenceReady
                    ? integer64Optional(row, "versionCreatedAtSortKey")
                    : nil
            )
            versions.append(version)
            try checkCancellation(cancellationToken)
        }
        return versions
    }

    private func decode<T: Decodable>(
        _ type: T.Type,
        from string: String,
        fallback: T
    ) -> T {
        guard let data = string.data(using: .utf8) else { return fallback }
        return (try? Self.makeDecoder().decode(type, from: data)) ?? fallback
    }

    private func decodeOptional<T: Decodable>(_ type: T.Type, from string: String) -> T? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? Self.makeDecoder().decode(type, from: data)
    }

    private func required(_ row: [String: String?], _ key: String) throws -> String {
        guard let value = row[key], let value else {
            throw PromptItemDetailError.malformedRow(field: key)
        }
        return value
    }

    private func date(_ row: [String: String?], _ key: String, fallback: Date) -> Date {
        guard let value = row[key] ?? nil,
              let date = Self.parseDate(value) else {
            return fallback
        }
        return date
    }

    private func optionalDate(_ row: [String: String?], _ key: String) -> Date? {
        guard let value = row[key] ?? nil, !value.isEmpty else { return nil }
        return Self.parseDate(value)
    }

    private func integer(_ row: [String: String?], _ key: String) -> Int {
        guard let value = row[key] ?? nil else { return 0 }
        return Int(value) ?? 0
    }

    private func integer64(_ row: [String: String?], _ key: String) -> Int64 {
        guard let value = row[key] ?? nil else { return 0 }
        return Int64(value) ?? 0
    }

    private func integer64Optional(_ row: [String: String?], _ key: String) -> Int64? {
        guard let value = row[key] ?? nil else { return nil }
        return Int64(value)
    }

    private func checkCancellation(_ token: SQLiteQueryCancellation?) throws {
        try Task.checkCancellation()
        try token?.throwIfCancelled()
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func parseDate(_ string: String) -> Date? {
        guard !string.isEmpty else { return nil }
        return ISO8601DateFormatter().date(from: string)
    }
}

/// Short spelling retained for callers that refer to the service by its
/// feature name rather than its PromptStudio type prefix.
public typealias ItemDetailService = PromptItemDetailService

public extension PromptRepository {
    func itemDetail(id: String) async throws -> PromptItem? {
        let service = try sharedItemDetailService()
        return try await service.itemDetail(id: id)
    }

    func itemDetail(
        id: String,
        cancellationToken: SQLiteQueryCancellation
    ) async throws -> PromptItem? {
        let service = try sharedItemDetailService()
        return try await service.itemDetail(id: id, cancellationToken: cancellationToken)
    }
}

extension PromptRepository: ItemDetailLoading {}
extension PromptRepository: ItemDetailInvalidationProviding {}

@MainActor
public extension PromptRepository {
    /// Builds the UI-facing detail owner from the repository's shared loader
    /// and invalidation source. Initializing the shared read service here keeps
    /// startup failures throwable while the controller observes committed
    /// repository mutations through the library-scoped hub.
    func makeItemDetailController(
        cache: ItemDetailCache = ItemDetailCache()
    ) throws -> ItemDetailController {
        _ = try sharedItemDetailService()
        return ItemDetailController(
            loader: self,
            cache: cache,
            revisionProvider: { [weak self] id in
                self?.itemDetailInvalidationHub.itemRevision(for: id) ?? 0
            }
        )
    }
}
