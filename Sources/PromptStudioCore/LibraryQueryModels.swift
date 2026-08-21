import Foundation

/// The small, card-oriented representation returned by a library query.
///
/// Prompt/version text, references, and long-form metadata deliberately stay
/// out of this value. Callers that need those fields can load the full item by
/// ID after a card has been selected.
public struct LibraryItemSummary: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let type: PromptType
    public let assetKind: AssetKind
    public let modelId: String
    public let modelName: String
    public let folderId: String
    public let folderName: String
    public let category: String
    public let assetPath: String
    public let thumbnailPath: String
    public let aspectRatio: String
    public let width: Int
    public let height: Int
    public let format: String
    public let fileSize: Int64
    public let favorite: Bool
    public let pinnedAt: Date?
    public let deletedAt: Date?
    public let createdAt: Date
    public let updatedAt: Date
    public let lastUsedAt: Date
    public let sortOrder: Int
    public let hasPrompt: Bool
    public let hasReferences: Bool

    public init(
        id: String,
        title: String,
        type: PromptType,
        assetKind: AssetKind,
        modelId: String,
        modelName: String,
        folderId: String,
        folderName: String,
        category: String,
        assetPath: String,
        thumbnailPath: String,
        aspectRatio: String,
        width: Int,
        height: Int,
        format: String,
        fileSize: Int64,
        favorite: Bool,
        pinnedAt: Date?,
        deletedAt: Date?,
        createdAt: Date,
        updatedAt: Date,
        lastUsedAt: Date,
        sortOrder: Int,
        hasPrompt: Bool,
        hasReferences: Bool
    ) {
        self.id = id
        self.title = title
        self.type = type
        self.assetKind = assetKind
        self.modelId = modelId
        self.modelName = modelName
        self.folderId = folderId
        self.folderName = folderName
        self.category = category
        self.assetPath = assetPath
        self.thumbnailPath = thumbnailPath
        self.aspectRatio = aspectRatio
        self.width = width
        self.height = height
        self.format = format
        self.fileSize = fileSize
        self.favorite = favorite
        self.pinnedAt = pinnedAt
        self.deletedAt = deletedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastUsedAt = lastUsedAt
        self.sortOrder = sortOrder
        self.hasPrompt = hasPrompt
        self.hasReferences = hasReferences
    }
}

public enum LibraryQueryCollection: Equatable, Codable, Sendable {
    case all
    case folder(String)
    case type(PromptType)
    case model(String)
    case favorite
    /// Kept as an input alias for clients that use the plural sidebar label.
    case favorites
    case recent
    case trash
    case tag(String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    private enum Kind: String, Codable {
        case all
        case folder
        case type
        case model
        case favorite
        case favorites
        case recent
        case trash
        case tag
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .all:
            try container.encode(Kind.all, forKey: .kind)
        case .folder(let id):
            try container.encode(Kind.folder, forKey: .kind)
            try container.encode(id, forKey: .value)
        case .type(let type):
            try container.encode(Kind.type, forKey: .kind)
            try container.encode(type.rawValue, forKey: .value)
        case .model(let id):
            try container.encode(Kind.model, forKey: .kind)
            try container.encode(id, forKey: .value)
        case .favorite:
            try container.encode(Kind.favorite, forKey: .kind)
        case .favorites:
            try container.encode(Kind.favorites, forKey: .kind)
        case .recent:
            try container.encode(Kind.recent, forKey: .kind)
        case .trash:
            try container.encode(Kind.trash, forKey: .kind)
        case .tag(let value):
            try container.encode(Kind.tag, forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .all:
            self = .all
        case .folder:
            self = .folder(try container.decode(String.self, forKey: .value))
        case .type:
            let rawValue = try container.decode(String.self, forKey: .value)
            guard let type = PromptType(rawValue: rawValue) else {
                throw DecodingError.dataCorruptedError(forKey: .value, in: container, debugDescription: "unknown prompt type")
            }
            self = .type(type)
        case .model:
            self = .model(try container.decode(String.self, forKey: .value))
        case .favorite:
            self = .favorite
        case .favorites:
            self = .favorites
        case .recent:
            self = .recent
        case .trash:
            self = .trash
        case .tag:
            self = .tag(try container.decode(String.self, forKey: .value))
        }
    }
}

public typealias LibraryQueryScope = LibraryQueryCollection

/// Capabilities that must be explicitly enabled before a query can use a
/// schema-dependent fast path. A version-ordering capability is mandatory for
/// all runtime summaries: callers against a pre-migration database fail closed
/// instead of silently using a lexical timestamp/rowid projection.
public struct LibraryQueryCapabilities: Equatable, Sendable {
    public let tagRelationsReady: Bool
    /// Opt-in gate for persisted prompt-version ordering. Summary queries fail
    /// closed until this migration is ready; no legacy ordering projection runs.
    public let versionSequenceReady: Bool
    /// Explicit gate for the persistent item ordering/date-key contract.
    public let itemSequenceReady: Bool

    public init(tagRelationsReady: Bool = false, versionSequenceReady: Bool = false, itemSequenceReady: Bool = false) {
        self.tagRelationsReady = tagRelationsReady
        self.versionSequenceReady = versionSequenceReady
        self.itemSequenceReady = itemSequenceReady
    }

    public static let legacy = LibraryQueryCapabilities()
    public static let tagRelations = LibraryQueryCapabilities(tagRelationsReady: true)
    public static let tagRelationsReady = LibraryQueryCapabilities(tagRelationsReady: true)
    public static let versionSequence = LibraryQueryCapabilities(versionSequenceReady: true, itemSequenceReady: false)
    public static let itemSequence = LibraryQueryCapabilities(versionSequenceReady: true, itemSequenceReady: true)

    public static func runtime(for repository: PromptRepository) -> LibraryQueryCapabilities {
        LibraryQueryCapabilities(
            tagRelationsReady: repository.tagRelationsReady,
            versionSequenceReady: repository.versionSequenceMigrationReady,
            itemSequenceReady: repository.itemSequenceMigrationReady
        )
    }
}

public typealias LibraryQueryCapability = LibraryQueryCapabilities

public struct LibraryQueryCursor: Codable, Equatable, Sendable {
    public let queryFingerprint: String
    public let sortOrder: Int?
    public let lastUsedAtSortKey: String?
    public let createdAtSortKey: String
    public let id: String
    /// Persisted numeric keys used by the item-sequence ready contract.
    /// `createdAtSortKey` remains for source compatibility with legacy tokens.
    public let itemCreatedAtSortKey: Int64?
    public let itemLastUsedAtSortKey: Int64?
    public let itemSequence: Int64?

    public init(
        queryFingerprint: String,
        sortOrder: Int? = nil,
        lastUsedAtSortKey: String? = nil,
        createdAtSortKey: String,
        id: String,
        itemCreatedAtSortKey: Int64? = nil,
        itemLastUsedAtSortKey: Int64? = nil,
        itemSequence: Int64? = nil
    ) {
        self.queryFingerprint = queryFingerprint
        self.sortOrder = sortOrder
        self.lastUsedAtSortKey = lastUsedAtSortKey
        self.createdAtSortKey = createdAtSortKey
        self.id = id
        self.itemCreatedAtSortKey = itemCreatedAtSortKey
        self.itemLastUsedAtSortKey = itemLastUsedAtSortKey
        self.itemSequence = itemSequence
    }

    public init(
        queryFingerprint: String,
        sortOrder: Int? = nil,
        lastUsedAt: Date? = nil,
        createdAt: Date,
        id: String,
        itemCreatedAtSortKey: Int64? = nil,
        itemLastUsedAtSortKey: Int64? = nil,
        itemSequence: Int64? = nil
    ) {
        let formatter = ISO8601DateFormatter()
        self.init(
            queryFingerprint: queryFingerprint,
            sortOrder: sortOrder,
            lastUsedAtSortKey: lastUsedAt.map(formatter.string(from:)),
            createdAtSortKey: formatter.string(from: createdAt),
            id: id,
            itemCreatedAtSortKey: itemCreatedAtSortKey,
            itemLastUsedAtSortKey: itemLastUsedAtSortKey,
            itemSequence: itemSequence
        )
    }

    public init(encoded token: String) throws {
        self = try Self.decode(token)
    }

    /// Encodes the cursor as URL-safe base64 over deterministic JSON.
    public func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        return data
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    public func encode() throws -> String {
        try encoded()
    }

    public static func decode(_ token: String) throws -> LibraryQueryCursor {
        guard !token.isEmpty else { throw LibraryQueryError.invalidCursor }
        var base64 = token
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else {
            throw LibraryQueryError.invalidCursor
        }
        do {
            let cursor = try JSONDecoder().decode(LibraryQueryCursor.self, from: data)
            guard !cursor.queryFingerprint.isEmpty,
                  !cursor.createdAtSortKey.isEmpty,
                  !cursor.id.isEmpty else {
                throw LibraryQueryError.invalidCursor
            }
            return cursor
        } catch let error as LibraryQueryError {
            throw error
        } catch {
            throw LibraryQueryError.invalidCursor
        }
    }
}

public typealias LibraryItemCursor = LibraryQueryCursor

/// Shared monotonic revision for writes that can change query membership or
/// keyset ordering. Query services bind cursors to the current value so a
/// caller cannot accidentally continue paging through a mutated dataset.
public final class LibraryDataRevision: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64

    public init(initialValue: UInt64 = 0) {
        value = initialValue
    }

    public var current: UInt64 {
        lock.withLock { value }
    }

    @discardableResult
    public func advance() -> UInt64 {
        lock.withLock {
            value &+= 1
            return value
        }
    }
}

public struct LibraryQuery: Equatable, Sendable {
    public typealias Scope = LibraryQueryCollection
    public var collection: LibraryQueryCollection
    /// Optional refinements are composable with the collection scope. The
    /// `type`, `model`, and `favorite` convenience scopes below populate the
    /// same fields while retaining their collection labels for compatibility.
    public var type: PromptType?
    public var modelId: String?
    public var favoriteOnly: Bool
    public var pageSize: Int
    public var cursor: LibraryItemCursor?
    /// Changes whenever writes can invalidate keyset ordering or membership.
    public var dataRevision: UInt64

    public var scope: LibraryQueryCollection {
        get { collection }
        set { collection = newValue }
    }

    public var model: String? {
        get { modelId }
        set { modelId = newValue }
    }

    public var favorite: Bool {
        get { favoriteOnly }
        set { favoriteOnly = newValue }
    }

    public init(
        _ collection: LibraryQueryCollection = .all,
        pageSize: Int = 300,
        cursor: LibraryItemCursor? = nil,
        dataRevision: UInt64 = 0,
        type: PromptType? = nil,
        modelId: String? = nil,
        favoriteOnly: Bool = false
    ) {
        self.collection = collection
        self.type = type
        self.modelId = modelId
        self.favoriteOnly = favoriteOnly
        self.pageSize = pageSize
        self.cursor = cursor
        self.dataRevision = dataRevision
    }

    public init(
        collection: LibraryQueryCollection,
        pageSize: Int = 300,
        cursor: LibraryItemCursor? = nil,
        dataRevision: UInt64 = 0,
        type: PromptType? = nil,
        modelId: String? = nil,
        favoriteOnly: Bool = false
    ) {
        self.init(collection, pageSize: pageSize, cursor: cursor, dataRevision: dataRevision, type: type, modelId: modelId, favoriteOnly: favoriteOnly)
    }

    public init(
        scope: LibraryQueryCollection,
        pageSize: Int = 300,
        cursor: LibraryItemCursor? = nil,
        dataRevision: UInt64 = 0,
        type: PromptType? = nil,
        modelId: String? = nil,
        favoriteOnly: Bool = false
    ) {
        self.init(scope, pageSize: pageSize, cursor: cursor, dataRevision: dataRevision, type: type, modelId: modelId, favoriteOnly: favoriteOnly)
    }

    public static var all: LibraryQuery { LibraryQuery(.all) }
    public static func all(pageSize: Int = 300, cursor: LibraryItemCursor? = nil, type: PromptType? = nil, modelId: String? = nil, favoriteOnly: Bool = false) -> LibraryQuery {
        LibraryQuery(.all, pageSize: pageSize, cursor: cursor, type: type, modelId: modelId, favoriteOnly: favoriteOnly)
    }

    public static func folder(_ id: String, pageSize: Int = 300, cursor: LibraryItemCursor? = nil, type: PromptType? = nil, modelId: String? = nil, favoriteOnly: Bool = false) -> LibraryQuery {
        LibraryQuery(.folder(id), pageSize: pageSize, cursor: cursor, type: type, modelId: modelId, favoriteOnly: favoriteOnly)
    }

    public static func type(_ type: PromptType, pageSize: Int = 300, cursor: LibraryItemCursor? = nil, modelId: String? = nil, favoriteOnly: Bool = false) -> LibraryQuery {
        LibraryQuery(.type(type), pageSize: pageSize, cursor: cursor, type: type, modelId: modelId, favoriteOnly: favoriteOnly)
    }

    public static func model(_ id: String, pageSize: Int = 300, cursor: LibraryItemCursor? = nil, type: PromptType? = nil, favoriteOnly: Bool = false) -> LibraryQuery {
        LibraryQuery(.model(id), pageSize: pageSize, cursor: cursor, type: type, modelId: id, favoriteOnly: favoriteOnly)
    }

    public static var favorite: LibraryQuery { LibraryQuery(.favorite, favoriteOnly: true) }
    public static func favorite(pageSize: Int = 300, cursor: LibraryItemCursor? = nil, type: PromptType? = nil, modelId: String? = nil) -> LibraryQuery {
        LibraryQuery(.favorite, pageSize: pageSize, cursor: cursor, type: type, modelId: modelId, favoriteOnly: true)
    }

    public static var favorites: LibraryQuery { LibraryQuery(.favorites, favoriteOnly: true) }
    public static func favorites(pageSize: Int = 300, cursor: LibraryItemCursor? = nil, type: PromptType? = nil, modelId: String? = nil) -> LibraryQuery {
        LibraryQuery(.favorites, pageSize: pageSize, cursor: cursor, type: type, modelId: modelId, favoriteOnly: true)
    }

    public static var recent: LibraryQuery { LibraryQuery(.recent) }
    public static func recent(pageSize: Int = 300, cursor: LibraryItemCursor? = nil, type: PromptType? = nil, modelId: String? = nil, favoriteOnly: Bool = false) -> LibraryQuery {
        LibraryQuery(.recent, pageSize: pageSize, cursor: cursor, type: type, modelId: modelId, favoriteOnly: favoriteOnly)
    }

    public static var trash: LibraryQuery { LibraryQuery(.trash) }
    public static func trash(pageSize: Int = 300, cursor: LibraryItemCursor? = nil, type: PromptType? = nil, modelId: String? = nil, favoriteOnly: Bool = false) -> LibraryQuery {
        LibraryQuery(.trash, pageSize: pageSize, cursor: cursor, type: type, modelId: modelId, favoriteOnly: favoriteOnly)
    }

    public static func tag(
        _ name: String,
        pageSize: Int = 300,
        cursor: LibraryItemCursor? = nil,
        type: PromptType? = nil,
        modelId: String? = nil,
        favoriteOnly: Bool = false
    ) -> LibraryQuery {
        LibraryQuery(
            .tag(name),
            pageSize: pageSize,
            cursor: cursor,
            type: type,
            modelId: modelId,
            favoriteOnly: favoriteOnly
        )
    }
}

public struct LibraryItemPage: Equatable, Sendable {
    public let items: [LibraryItemSummary]
    public let totalCount: Int
    public let previousCursor: LibraryItemCursor?
    public let nextCursor: LibraryItemCursor?
    public let hasMore: Bool

    public init(
        items: [LibraryItemSummary],
        totalCount: Int? = nil,
        previousCursor: LibraryItemCursor? = nil,
        nextCursor: LibraryItemCursor? = nil,
        hasMore: Bool = false
    ) {
        self.items = items
        self.totalCount = totalCount ?? items.count
        self.previousCursor = previousCursor
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }

    public var nextPageCursor: LibraryItemCursor? { nextCursor }
}

public typealias LibraryQueryPage = LibraryItemPage

public enum LibraryQueryError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedTag
    case invalidPageSize(Int)
    case invalidCursor
    case cursorQueryFingerprintMismatch(expected: String, actual: String)
    case staleResult(requested: UInt64, current: UInt64)
    case staleDataRevision(requested: UInt64, current: UInt64)
    case malformedRow(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedTag:
            "tag queries are not supported by the SQL query path"
        case .invalidPageSize(let size):
            "library query page size must be positive (got \(size))"
        case .invalidCursor:
            "library query cursor is invalid"
        case .cursorQueryFingerprintMismatch(let expected, let actual):
            "library query cursor belongs to another query (expected \(expected), got \(actual))"
        case .staleResult(let requested, let current):
            "library query result is stale (generation \(requested), current \(current))"
        case .staleDataRevision(let requested, let current):
            "library data changed during query (revision \(requested), current \(current))"
        case .malformedRow(let field):
            "library query row is missing or malformed: \(field)"
        }
    }
}
