import Foundation
import SQLite3

public enum PromptRepositoryValidationError: Error, LocalizedError {
    case notDirectory(String)
    case missingDatabase(String)
    case incompatibleSchema(String)

    public var errorDescription: String? {
        switch self {
        case .notDirectory(let path):
            "选择的不是资料库目录：\(path)"
        case .missingDatabase(let path):
            "找不到资料库数据库：\(path)"
        case .incompatibleSchema(let message):
            "资料库结构不兼容：\(message)"
        }
    }
}

public enum PromptRepositoryFolderMutationError: Error, LocalizedError, Equatable, Sendable {
    case folderNotFound(String)
    case affectedRowsMismatch(folderID: String, expected: Int, actual: Int)

    public var code: String {
        switch self {
        case .folderNotFound:
            "folder_mutation.folder_missing"
        case .affectedRowsMismatch:
            "folder_mutation.affected_rows_mismatch"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .folderNotFound(let folderID):
            "文件夹不存在：\(folderID)"
        case .affectedRowsMismatch(let folderID, let expected, let actual):
            "文件夹更新行数异常（\(folderID)：应为 \(expected)，实际为 \(actual)）"
        }
    }
}

/// A single candidate that could not be migrated. The migration continues
/// with later candidates after isolating this item's file/database changes.
public struct PromptPlaceholderMigrationFailure: Equatable, Sendable {
    public let itemID: String
    public let reason: String

    public init(itemID: String, reason: String) {
        self.itemID = itemID
        self.reason = reason
    }
}

/// Result returned by the explicit, opt-in placeholder migration.
public struct PromptPlaceholderMigrationResult: Equatable, Sendable {
    public let candidateCount: Int
    public let migratedCount: Int
    public let migratedItemIDs: [String]
    public let failedCount: Int
    public let failures: [PromptPlaceholderMigrationFailure]

    public init(
        candidateCount: Int,
        migratedCount: Int,
        migratedItemIDs: [String],
        failedCount: Int = 0,
        failures: [PromptPlaceholderMigrationFailure] = []
    ) {
        self.candidateCount = candidateCount
        self.migratedCount = migratedCount
        self.migratedItemIDs = migratedItemIDs
        self.failedCount = failedCount
        self.failures = failures
    }

    public var count: Int { migratedCount }
    public var updatedCount: Int { migratedCount }
    public var failureCount: Int { failedCount }
    public var failureReasons: [String] { failures.map(\.reason) }
}

public final class PromptRepository: @unchecked Sendable {
    public let libraryURL: URL
    public let databaseURL: URL
    public let itemDetailInvalidationHub: ItemDetailInvalidationHub
    public let libraryDataRevision: LibraryDataRevision
    let database: SQLiteDatabase
    private let captureInsertLock = NSLock()
    private let itemDetailServiceLock = NSLock()
    private let legacyObservationClock: ItemSequenceObservationClock
    private var itemDetailServiceValue: PromptItemDetailService?
    private var migrationLeaseID: UUID?

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public convenience init(
        libraryURL: URL,
        libraryDataRevision: LibraryDataRevision? = nil,
        itemDetailInvalidationHub: ItemDetailInvalidationHub? = nil,
        legacyObservationClock: ItemSequenceObservationClock? = nil
    ) throws {
        try self.init(
            libraryURL: libraryURL,
            libraryDataRevision: libraryDataRevision,
            itemDetailInvalidationHub: itemDetailInvalidationHub,
            registerMigrationLease: true,
            legacyObservationClock: legacyObservationClock
        )
    }

    // Internal designated initializer used only by the closed-library
    // migration rollback path.  It deliberately skips the repository lease
    // because the coordinator's exclusive reservation already proves that
    // no repository handle is active while the restore runs.
    init(
        libraryURL: URL,
        libraryDataRevision: LibraryDataRevision?,
        itemDetailInvalidationHub: ItemDetailInvalidationHub?,
        registerMigrationLease: Bool,
        legacyObservationClock: ItemSequenceObservationClock? = nil
    ) throws {
        self.libraryURL = libraryURL
        self.databaseURL = libraryURL.appendingPathComponent("database/promptstudio.sqlite")
        let hub = itemDetailInvalidationHub
            ?? ItemDetailInvalidationHub.shared(for: libraryURL, revision: libraryDataRevision)
        self.itemDetailInvalidationHub = hub
        self.libraryDataRevision = hub.revision
        self.legacyObservationClock = legacyObservationClock ?? ItemSequenceObservationClock()
        // Acquire the process-wide lease before touching the database.  This
        // closes the reservation/init window used by whole-file rollback: a
        // new repository cannot open, bootstrap, or write the live file while
        // rollback owns the path reservation.  Failed initialization releases
        // the preflight lease before propagating the original error.
        let preflightLease = registerMigrationLease
            ? try PromptRepositoryMigrationCoordinator.shared.register(path: databaseURL.path)
            : nil
        do {
            try Self.createLibraryDirectories(at: libraryURL)
            self.database = try SQLiteDatabase(path: databaseURL.path)
            try bootstrap()
        } catch {
            if let preflightLease {
                PromptRepositoryMigrationCoordinator.shared.unregister(path: databaseURL.path, lease: preflightLease)
            }
            throw error
        }
        self.migrationLeaseID = preflightLease
    }

    deinit {
        if let migrationLeaseID {
            PromptRepositoryMigrationCoordinator.shared.unregister(path: databaseURL.path, lease: migrationLeaseID)
        }
    }

    /// Aliases keep the shared invalidation source discoverable to detail
    /// services without coupling them to one property spelling.
    public var detailInvalidationHub: ItemDetailInvalidationHub {
        itemDetailInvalidationHub
    }

    public var invalidationHub: ItemDetailInvalidationHub {
        itemDetailInvalidationHub
    }

    public var itemDetailInvalidation: ItemDetailInvalidationHub {
        itemDetailInvalidationHub
    }

    public var revision: LibraryDataRevision {
        libraryDataRevision
    }

    public static func defaultLibraryURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("PromptStudio Library")
    }

    public static func resolvedLibraryURL(
        arguments: [String] = Array(CommandLine.arguments.dropFirst()),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        var tokens = arguments
        while let first = tokens.first {
            if first == "--library", tokens.count >= 2 {
                return URL(fileURLWithPath: tokens[1])
            }
            if first.hasPrefix("--library=") {
                return URL(fileURLWithPath: String(first.dropFirst("--library=".count)))
            }
            tokens.removeFirst()
        }
        if let path = environment["PROMPTSTUDIO_LIBRARY_PATH"],
           !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: path)
        }
        return defaultLibraryURL()
    }

    public static func createLibraryDirectories(at url: URL) throws {
        let paths = [
            url,
            url.appendingPathComponent("assets/images"),
            url.appendingPathComponent("assets/videos"),
            url.appendingPathComponent("assets/audio"),
            url.appendingPathComponent("assets/documents"),
            url.appendingPathComponent("assets/data"),
            url.appendingPathComponent("assets/sources"),
            url.appendingPathComponent("assets/raw"),
            url.appendingPathComponent("assets/three_d"),
            url.appendingPathComponent("assets/textures"),
            url.appendingPathComponent("assets/fonts"),
            url.appendingPathComponent("assets/web"),
            url.appendingPathComponent("assets/references"),
            url.appendingPathComponent("thumbnails"),
            url.appendingPathComponent("database"),
            url.appendingPathComponent("exports"),
            url.appendingPathComponent("backups")
        ]
        for path in paths {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
    }

    public static func validateExistingLibrary(at libraryURL: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: libraryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw PromptRepositoryValidationError.notDirectory(libraryURL.path)
        }

        let databaseURL = libraryURL.appendingPathComponent("database/promptstudio.sqlite")
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw PromptRepositoryValidationError.missingDatabase(databaseURL.path)
        }

        let database = try SQLiteDatabase(path: databaseURL.path, mode: .existingReadWrite)
        let requiredTables = Set(["prompt_items", "prompt_versions", "tags", "model_profiles", "library_folders"])
        let rows = try database.query(
            """
            SELECT name FROM sqlite_master
            WHERE type = 'table' AND name IN ('prompt_items', 'prompt_versions', 'tags', 'model_profiles', 'library_folders');
            """
        )
        let tableNames = Set(rows.compactMap { $0["name"] ?? nil })
        guard requiredTables.isSubset(of: tableNames) else {
            let missing = requiredTables.subtracting(tableNames).sorted().joined(separator: ", ")
            throw PromptRepositoryValidationError.incompatibleSchema("缺少数据表：\(missing)")
        }

        try database.transaction {
            try database.run("UPDATE prompt_items SET updatedAt = updatedAt WHERE 0;")
        }
    }

    public func bootstrap() throws {
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS prompt_items (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                type TEXT NOT NULL,
                assetKind TEXT NOT NULL DEFAULT 'image',
                modelId TEXT NOT NULL,
                modelName TEXT NOT NULL,
                folderId TEXT NOT NULL DEFAULT '',
                folderName TEXT NOT NULL,
                category TEXT NOT NULL,
                assetPath TEXT NOT NULL,
                thumbnailPath TEXT NOT NULL,
                aspectRatio TEXT NOT NULL,
                width INTEGER NOT NULL,
                height INTEGER NOT NULL,
                format TEXT NOT NULL,
                fileSize INTEGER NOT NULL,
                favorite INTEGER NOT NULL,
                pinnedAt TEXT,
                deletedAt TEXT,
                createdAt TEXT NOT NULL,
                updatedAt TEXT NOT NULL,
                lastUsedAt TEXT NOT NULL,
                sortOrder INTEGER NOT NULL DEFAULT 0,
                tagsJSON TEXT NOT NULL,
                referencesJSON TEXT NOT NULL,
                description TEXT NOT NULL,
                captureId TEXT,
                captureSourceJSON TEXT
            );

            CREATE TABLE IF NOT EXISTS prompt_versions (
                id TEXT PRIMARY KEY,
                promptItemId TEXT NOT NULL,
                version TEXT NOT NULL,
                prompt TEXT NOT NULL,
                negativePrompt TEXT NOT NULL,
                parametersJSON TEXT NOT NULL,
                note TEXT NOT NULL,
                createdAt TEXT NOT NULL,
                FOREIGN KEY(promptItemId) REFERENCES prompt_items(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS tags (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL UNIQUE,
                color TEXT NOT NULL,
                count INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS model_profiles (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                type TEXT NOT NULL,
                parametersJSON TEXT NOT NULL,
                defaultNegativePrompt TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS library_folders (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                parentId TEXT,
                type TEXT,
                count INTEGER NOT NULL,
                sortOrder INTEGER NOT NULL,
                createdAt TEXT NOT NULL
            );
            """
        )
        try database.transaction {
            try migratePromptItemsSchema()
            try migrateLibraryFoldersSchema()
        }
    }

    public func loadItems() throws -> [PromptItem] {
        let itemSequenceReady = itemSequenceMigrationReady
        let rows = try database.query(
            itemSequenceReady
                ? "SELECT * FROM prompt_items ORDER BY sortOrder ASC, itemCreatedAtSortKey DESC, itemSequence ASC;"
                : "SELECT * FROM prompt_items;"
        )
        let versionSequenceReady = versionSequenceMigrationReady
        let versions = try loadVersions(versionSequenceReady: versionSequenceReady)
        return try rows.map { row in
            let id = required(row, "id")
            let itemVersions: [PromptVersion]
            if versionSequenceReady {
                itemVersions = versions[id, default: []].sorted { lhs, rhs in
                    let leftKey = lhs.versionCreatedAtSortKey ?? Int64((lhs.createdAt.timeIntervalSince1970 * 1_000_000).rounded())
                    let rightKey = rhs.versionCreatedAtSortKey ?? Int64((rhs.createdAt.timeIntervalSince1970 * 1_000_000).rounded())
                    if leftKey != rightKey { return leftKey < rightKey }
                    switch (lhs.versionSequence, rhs.versionSequence) {
                    case let (left?, right?): return left < right
                    case (nil, _?): return true
                    case (_?, nil): return false
                    default: return lhs.createdAt < rhs.createdAt
                    }
                }
            } else {
                itemVersions = versions[id, default: []].sorted { $0.createdAt < $1.createdAt }
            }
            // During an in-flight backfill the newly added columns contain a
            // mixture of NULL, historical, and provisional values.  Keep the
            // legacy model/comparator contract until the readiness gate is
            // fully open; exposing partial metadata here would silently switch
            // filtering order before the migration has finalized.
            let loadedItemSequence = itemSequenceReady ? (row["itemSequence"] ?? nil).flatMap(Int64.init) : nil
            let loadedItemCreatedAtSortKey = itemSequenceReady ? (row["itemCreatedAtSortKey"] ?? nil).flatMap(Int64.init) : nil
            let loadedItemLastUsedAtSortKey = itemSequenceReady ? (row["itemLastUsedAtSortKey"] ?? nil).flatMap(Int64.init) : nil
            let itemCreatedAt: Date
            if itemSequenceReady {
                // Once the migration gate is open, item creation time is
                // decoded exclusively from the persisted microsecond key.
                guard let itemSequence = loadedItemSequence,
                      itemSequence > 0,
                      let itemCreatedAtSortKey = loadedItemCreatedAtSortKey,
                      loadedItemLastUsedAtSortKey != nil else {
                    throw PromptRepositoryValidationError.incompatibleSchema("ready item date/sequence metadata is malformed")
                }
                itemCreatedAt = PromptItemCreatedAtSupport.date(forSortKey: itemCreatedAtSortKey)
            } else {
                itemCreatedAt = try legacyCreatedAt(required(row, "createdAt"))
            }
            return PromptItem(
                id: id,
                title: required(row, "title"),
                type: PromptType(rawValue: required(row, "type")) ?? .image,
                assetKind: AssetKind(rawValue: required(row, "assetKind")) ?? .unknown,
                modelId: required(row, "modelId"),
                modelName: required(row, "modelName"),
                folderId: required(row, "folderId"),
                folderName: required(row, "folderName"),
                category: required(row, "category"),
                assetPath: required(row, "assetPath"),
                thumbnailPath: required(row, "thumbnailPath"),
                aspectRatio: required(row, "aspectRatio"),
                width: int(row, "width"),
                height: int(row, "height"),
                format: required(row, "format"),
                fileSize: int64(row, "fileSize"),
                favorite: int(row, "favorite") == 1,
                pinnedAt: date(row["pinnedAt"] ?? nil),
                deletedAt: date(row["deletedAt"] ?? nil),
                createdAt: itemCreatedAt,
                updatedAt: date(required(row, "updatedAt")) ?? Date(),
                lastUsedAt: date(required(row, "lastUsedAt")) ?? Date(timeIntervalSince1970: 0),
                sortOrder: int(row, "sortOrder"),
                itemSequence: loadedItemSequence,
                itemCreatedAtSortKey: loadedItemCreatedAtSortKey,
                itemLastUsedAtSortKey: loadedItemLastUsedAtSortKey,
                tags: decode([String].self, from: required(row, "tagsJSON"), fallback: []),
                referenceAssets: decode([ReferenceAsset].self, from: required(row, "referencesJSON"), fallback: []),
                versions: itemVersions,
                description: required(row, "description"),
                captureID: row["captureId"] ?? nil,
                capturedSource: decodeOptional(CapturedSource.self, from: row["captureSourceJSON"] ?? nil)
            )
        }
    }

    /// Lazily creates one independent read service and reuses it across detail
    /// requests. The service/connection are internally synchronized so this
    /// lock only protects first-use initialization.
    func sharedItemDetailService() throws -> PromptItemDetailService {
        itemDetailServiceLock.lock()
        defer { itemDetailServiceLock.unlock() }
        if let itemDetailServiceValue {
            return itemDetailServiceValue
        }
        let service = try PromptItemDetailService(databaseURL: databaseURL)
        itemDetailServiceValue = service
        return service
    }

    /// Loads sidebar statistics directly in SQLite without materializing the
    /// complete prompt/version/reference graph.
    public func loadLibraryStatistics() throws -> LibraryStatistics {
        let aggregate = try database.query(
            """
            SELECT
                COALESCE(SUM(CASE WHEN deletedAt IS NULL THEN 1 ELSE 0 END), 0) AS activeCount,
                COALESCE(SUM(CASE WHEN deletedAt IS NULL AND favorite = 1 THEN 1 ELSE 0 END), 0) AS favoriteCount,
                COALESCE(SUM(CASE WHEN deletedAt IS NULL AND lastUsedAt > ? THEN 1 ELSE 0 END), 0) AS recentCount,
                COALESCE(SUM(CASE WHEN deletedAt IS NOT NULL THEN 1 ELSE 0 END), 0) AS trashCount
            FROM prompt_items;
            """,
            values: [.text(Self.string(from: Date(timeIntervalSince1970: 0)))]
        ).first ?? [:]

        let folderRows = try database.query(
            """
            SELECT folderId, COUNT(*) AS itemCount
            FROM prompt_items
            WHERE deletedAt IS NULL
            GROUP BY folderId;
            """
        )
        var folderCounts: [String: Int] = [:]
        for row in folderRows {
            folderCounts[required(row, "folderId")] = int(row, "itemCount")
        }

        return LibraryStatistics(
            activeCount: int(aggregate, "activeCount"),
            favoriteCount: int(aggregate, "favoriteCount"),
            recentCount: int(aggregate, "recentCount"),
            trashCount: int(aggregate, "trashCount"),
            folderCounts: folderCounts
        )
    }

    public func loadStatistics() throws -> LibraryStatistics {
        try loadLibraryStatistics()
    }

    /// Returns the prompt recorded for a browser capture ID, when one exists.
    public func findItem(captureID: String) throws -> PromptItem? {
        let normalized = captureID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        guard let row = try database.query(
            "SELECT id FROM prompt_items WHERE captureId = ? LIMIT 1;",
            values: [.text(normalized)]
        ).first else {
            return nil
        }
        let id = required(row, "id")
        return try loadItems().first(where: { $0.id == id })
    }

    public func seedIfNeeded(items: [PromptItem], models: [ModelProfile], tags: [Tag]) throws {
        if try loadItems().isEmpty {
            for model in models {
                try saveModelProfile(model)
            }
            for tag in tags {
                try saveTag(tag)
            }
            for item in items {
                try saveItem(item)
            }
        }
    }

    public func seedFoldersIfNeeded(_ folders: [LibraryFolder]) throws {
        guard try loadFolders().isEmpty else { return }
        for folder in folders {
            try saveFolder(folder)
        }
    }

    /// Canonicalizes legacy prompt-only placeholder rows without touching any
    /// record that already points at a real asset. This migration is explicit:
    /// callers decide when to run it after Core initialization.
    public func migratePromptPlaceholders() throws -> PromptPlaceholderMigrationResult {
        let candidates = try loadItems().filter { item in
            item.assetPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && ["PROMPT", "TEXT"].contains(item.format.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
        }
        guard !candidates.isEmpty else {
            return PromptPlaceholderMigrationResult(candidateCount: 0, migratedCount: 0, migratedItemIDs: [])
        }

        var migratedIDs: [String] = []
        var failures: [PromptPlaceholderMigrationFailure] = []
        for item in candidates {
            var createdAsset: URL?
            do {
                let didMigrate = try PromptRepositoryMigrationCoordinator.shared.withWriteLock(path: databaseURL.path) {
                    try database.transaction {
                        let text = item.currentVersion?.prompt ?? ""
                        let type = PromptTypeClassifier.classify(text: text)
                        let assetKind: AssetKind
                        let format: String
                        let category: String
                        let assetPath: String
                        let thumbnailPath: String
                        let fileSize: Int64
                        switch type {
                        case .image:
                            assetKind = .image
                            format = ""
                            category = AssetKind.image.displayName
                            assetPath = ""
                            thumbnailPath = ""
                            fileSize = 0
                        case .video:
                            assetKind = .video
                            format = ""
                            category = AssetKind.video.displayName
                            assetPath = ""
                            thumbnailPath = ""
                            fileSize = 0
                        case .audio:
                            assetKind = .audio
                            format = ""
                            category = AssetKind.audio.displayName
                            assetPath = ""
                            thumbnailPath = ""
                            fileSize = 0
                        case .text:
                            assetKind = .markdown
                            format = "MD"
                            category = AssetKind.markdown.displayName
                            let markdownURL = try writeMarkdownPromptAsset(
                                promptID: item.id,
                                title: item.title,
                                prompt: text,
                                negativePrompt: item.currentVersion?.negativePrompt ?? ""
                            )
                            createdAsset = markdownURL
                            assetPath = markdownURL.path
                            thumbnailPath = markdownURL.path
                            let values = try markdownURL.resourceValues(forKeys: [.fileSizeKey])
                            fileSize = Int64(values.fileSize ?? 0)
                        }
                        let changed = try database.runAndReturnChanges(
                            """
                            UPDATE prompt_items
                            SET type = ?, assetKind = ?, category = ?, assetPath = ?, thumbnailPath = ?, format = ?, fileSize = ?, updatedAt = ?
                            WHERE id = ?
                              AND trim(assetPath) = ''
                              AND upper(trim(format)) IN ('PROMPT', 'TEXT');
                            """,
                            values: [
                                .text(type.rawValue),
                                .text(assetKind.rawValue),
                                .text(category),
                                .text(assetPath),
                                .text(thumbnailPath),
                                .text(format),
                                .int(fileSize),
                                .text(Self.string(from: Date())),
                                .text(item.id)
                            ]
                        )
                        try reconcileItemSequenceMigrationFingerprintIfNeeded()
                        return changed == 1
                    }
                }
                if didMigrate {
                    migratedIDs.append(item.id)
                } else if let createdAsset {
                    try? FileManager.default.removeItem(at: createdAsset)
                }
            } catch {
                if let createdAsset {
                    try? FileManager.default.removeItem(at: createdAsset)
                }
                failures.append(
                    PromptPlaceholderMigrationFailure(itemID: item.id, reason: error.localizedDescription)
                )
            }
        }
        _ = itemDetailInvalidationHub.publish(changedItemIDs: migratedIDs)
        return PromptPlaceholderMigrationResult(
            candidateCount: candidates.count,
            migratedCount: migratedIDs.count,
            migratedItemIDs: migratedIDs,
            failedCount: failures.count,
            failures: failures
        )
    }

    public func repairSeedAssetPaths(from seedItems: [PromptItem]) throws {
        let seedsByKey = Dictionary(uniqueKeysWithValues: seedItems.map { (seedKey($0), $0) })
        for item in try loadItems() {
            guard let seed = seedsByKey[seedKey(item)] else { continue }
            guard !FileManager.default.fileExists(atPath: item.assetPath),
                  FileManager.default.fileExists(atPath: seed.assetPath) else {
                continue
            }
            var repaired = item
            repaired.assetPath = seed.assetPath
            repaired.thumbnailPath = seed.thumbnailPath
            repaired.width = seed.width
            repaired.height = seed.height
            repaired.format = seed.format
            repaired.fileSize = seed.fileSize
            repaired.aspectRatio = seed.aspectRatio
            try saveItem(repaired)
        }
    }

    public func saveItem(_ item: PromptItem) throws {
        try PromptRepositoryMigrationCoordinator.shared.withWriteLock(path: databaseURL.path) {
            try database.transaction {
                try saveItemRecord(item)
                try refreshTagsAfterMutation()
                try reconcileVersionSequenceMigrationFingerprintIfNeeded()
                try reconcileItemSequenceMigrationFingerprintIfNeeded()
            }
        }
        _ = itemDetailInvalidationHub.publish(changedItemIDs: [item.id])
    }

    /// Inserts a captured item exactly once and returns the row that won the capture ID race.
    /// The operation is serialized by SQLite's write transaction and never replaces an existing
    /// row, so its prompt versions and metadata remain intact on retries.
    public func saveCapturedItem(_ item: PromptItem) throws -> PromptItem {
        guard let captureID = item.captureID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !captureID.isEmpty else {
            throw SQLiteError.stepFailed("capture ID is required", resultCode: SQLITE_CONSTRAINT, extendedCode: SQLITE_CONSTRAINT)
        }

        var normalizedItem = item
        normalizedItem.captureID = captureID

        let outcome: (item: PromptItem, inserted: Bool)
        do {
            captureInsertLock.lock()
            defer { captureInsertLock.unlock() }
            outcome = try PromptRepositoryMigrationCoordinator.shared.withWriteLock(path: databaseURL.path) {
                try database.transaction { () -> (item: PromptItem, inserted: Bool) in
                    if let existing = try findItem(captureID: captureID) {
                        return (existing, false)
                    }

                    let inserted = try saveItemRecord(normalizedItem, conflict: .ignoreExistingCapture)
                    if inserted {
                        try refreshTagsAfterMutation()
                        try reconcileVersionSequenceMigrationFingerprintIfNeeded()
                        try reconcileItemSequenceMigrationFingerprintIfNeeded()
                    }
                    return (try findItem(captureID: captureID) ?? normalizedItem, inserted)
                }
            }
        }
        if outcome.inserted {
            _ = itemDetailInvalidationHub.publish(changedItemIDs: [outcome.item.id])
        }
        return outcome.item
    }

    public func saveItems(_ items: [PromptItem]) throws {
        guard !items.isEmpty else { return }
        let requestedIDs = Set(items.map(\.id))
        try PromptRepositoryMigrationCoordinator.shared.withWriteLock(path: databaseURL.path) {
            try database.transaction {
                for item in items {
                    try saveItemRecord(item)
                }
                try refreshTagsAfterMutation()
                try reconcileVersionSequenceMigrationFingerprintIfNeeded()
                try reconcileItemSequenceMigrationFingerprintIfNeeded()
            }
        }
        _ = itemDetailInvalidationHub.publish(changedItemIDs: requestedIDs)
    }

    public func updateItemFolders(_ items: [PromptItem]) throws {
        guard !items.isEmpty else { return }
        var changedItemIDs: Set<String> = []
        try PromptRepositoryMigrationCoordinator.shared.withWriteLock(path: databaseURL.path) {
            try database.transaction {
                for item in items {
                    let changed = try database.runAndReturnChanges(
                        """
                        UPDATE prompt_items
                        SET folderId = ?, folderName = ?, category = ?, updatedAt = ?
                        WHERE id = ? AND deletedAt IS NULL
                          AND (folderId <> ? OR folderName <> ? OR category <> ? OR updatedAt <> ?);
                        """,
                        values: [
                            .text(item.folderId),
                            .text(item.folderName),
                            .text(item.category),
                            .text(Self.string(from: item.updatedAt)),
                            .text(item.id),
                            .text(item.folderId),
                            .text(item.folderName),
                            .text(item.category),
                            .text(Self.string(from: item.updatedAt))
                        ]
                    )
                    if changed == 1 { changedItemIDs.insert(item.id) }
                }
                try reconcileItemSequenceMigrationFingerprintIfNeeded()
            }
        }
        _ = itemDetailInvalidationHub.publish(changedItemIDs: changedItemIDs)
    }

    public func markDeleted(itemID: String, deletedAt: Date?) throws {
        try markDeleted(itemIDs: [itemID], deletedAt: deletedAt)
    }

    public func markDeleted(itemIDs: [String], deletedAt: Date?) throws {
        let ids = PromptItemDragPayload(itemIDs: itemIDs).itemIDs
        guard !ids.isEmpty else { return }
        var changedItemIDs: Set<String> = []
        try PromptRepositoryMigrationCoordinator.shared.withWriteLock(path: databaseURL.path) {
            try database.transaction {
                let updatedAt = Self.string(from: Date())
                for itemID in ids {
                    let changed = try database.runAndReturnChanges(
                        "UPDATE prompt_items SET deletedAt = ?, updatedAt = ? WHERE id = ? AND deletedAt IS NOT ?;",
                        values: [
                            deletedAt.map { .text(Self.string(from: $0)) } ?? .null,
                            .text(updatedAt),
                            .text(itemID),
                            deletedAt.map { .text(Self.string(from: $0)) } ?? .null
                        ]
                    )
                    if changed == 1 { changedItemIDs.insert(itemID) }
                }
                try refreshTagsAfterMutation()
                try reconcileItemSequenceMigrationFingerprintIfNeeded()
            }
        }
        _ = itemDetailInvalidationHub.publish(changedItemIDs: changedItemIDs)
    }

    public func permanentlyDelete(itemID: String) throws {
        try permanentlyDelete(itemIDs: [itemID])
    }

    public func permanentlyDelete(itemIDs: [String]) throws {
        let ids = PromptItemDragPayload(itemIDs: itemIDs).itemIDs
        guard !ids.isEmpty else { return }
        var removedItemIDs: Set<String> = []
        try PromptRepositoryMigrationCoordinator.shared.withWriteLock(path: databaseURL.path) {
            try database.transaction {
                for itemID in ids {
                    let changed = try database.runAndReturnChanges(
                        "DELETE FROM prompt_items WHERE id = ?;",
                        values: [.text(itemID)]
                    )
                    if changed == 1 { removedItemIDs.insert(itemID) }
                }
                try refreshTagsAfterMutation()
                try reconcileVersionSequenceMigrationFingerprintIfNeeded()
                try reconcileItemSequenceMigrationFingerprintIfNeeded()
            }
        }
        _ = itemDetailInvalidationHub.publish(removedItemIDs: removedItemIDs)
    }

    public func updateLastUsed(itemID: String, at date: Date = Date()) throws {
        let encodedDate = Self.string(from: date)
        let changed: Int = try PromptRepositoryMigrationCoordinator.shared.withWriteLock(path: databaseURL.path) {
            try database.transaction {
                let setClause = itemSequenceStorageAvailable()
                    ? "lastUsedAt = ?, itemLastUsedAtSortKey = ?"
                    : "lastUsedAt = ?"
                let predicate = itemSequenceStorageAvailable()
                    ? "id = ? AND lastUsedAt <> ?"
                    : "id = ? AND lastUsedAt <> ?"
                var values: [SQLiteValue] = [.text(encodedDate)]
                if itemSequenceStorageAvailable() { values.append(.int(itemSequenceSortKey(for: encodedDate, fallback: Date(timeIntervalSince1970: 0)))) }
                values += [.text(itemID), .text(encodedDate)]
                let result = try database.runAndReturnChanges("UPDATE prompt_items SET \(setClause) WHERE \(predicate);", values: values)
                try reconcileItemSequenceMigrationFingerprintIfNeeded()
                return result
            }
        }
        if changed == 1 {
            _ = itemDetailInvalidationHub.publish(changedItemIDs: [itemID])
        }
    }

    public func updateThumbnailPath(itemID: String, thumbnailPath: String) throws {
        let changed = try PromptRepositoryMigrationCoordinator.shared.withWriteLock(path: databaseURL.path) {
            try database.transaction {
                let value = try database.runAndReturnChanges(
                    "UPDATE prompt_items SET thumbnailPath = ?, updatedAt = ? WHERE id = ? AND thumbnailPath <> ?;",
                    values: [.text(thumbnailPath), .text(Self.string(from: Date())), .text(itemID), .text(thumbnailPath)]
                )
                try reconcileItemSequenceMigrationFingerprintIfNeeded()
                return value
            }
        }
        if changed == 1 {
            _ = itemDetailInvalidationHub.publish(changedItemIDs: [itemID])
        }
    }

    /// Persists a thumbnail batch in one transaction without loading items or
    /// refreshing tags. Empty batches perform no transaction.
    public func updateThumbnailPaths(_ paths: [String: String]) throws {
        guard !paths.isEmpty else { return }
        var changedItemIDs: Set<String> = []
        let updatedAt = Self.string(from: Date())
        try PromptRepositoryMigrationCoordinator.shared.withWriteLock(path: databaseURL.path) {
            try database.transaction {
                for itemID in paths.keys.sorted() {
                    guard let thumbnailPath = paths[itemID] else { continue }
                    let changed = try database.runAndReturnChanges(
                        "UPDATE prompt_items SET thumbnailPath = ?, updatedAt = ? WHERE id = ? AND thumbnailPath <> ?;",
                        values: [.text(thumbnailPath), .text(updatedAt), .text(itemID), .text(thumbnailPath)]
                    )
                    if changed == 1 { changedItemIDs.insert(itemID) }
                }
                try reconcileItemSequenceMigrationFingerprintIfNeeded()
            }
        }
        _ = itemDetailInvalidationHub.publish(changedItemIDs: changedItemIDs)
    }

    public func updateSortOrders(_ orders: [(id: String, sortOrder: Int)]) throws {
        guard !orders.isEmpty else { return }
        var changedItemIDs: Set<String> = []
        try PromptRepositoryMigrationCoordinator.shared.withWriteLock(path: databaseURL.path) {
            try database.transaction {
                for order in orders {
                    let changed = try database.runAndReturnChanges(
                        "UPDATE prompt_items SET sortOrder = ?, updatedAt = ? WHERE id = ? AND sortOrder <> ?;",
                        values: [
                            .int(Int64(order.sortOrder)),
                            .text(Self.string(from: Date())),
                            .text(order.id),
                            .int(Int64(order.sortOrder))
                        ]
                    )
                    if changed == 1 { changedItemIDs.insert(order.id) }
                }
                try reconcileItemSequenceMigrationFingerprintIfNeeded()
            }
        }
        _ = itemDetailInvalidationHub.publish(changedItemIDs: changedItemIDs)
    }

    public func copyAssetIntoLibrary(from sourceURL: URL, type: PromptType) throws -> URL {
        let assetKind: AssetKind
        switch type {
        case .image:
            assetKind = .image
        case .video:
            assetKind = .video
        case .text:
            assetKind = .text
        case .audio:
            assetKind = .audio
        }
        return try copyAssetIntoLibrary(from: sourceURL, assetKind: assetKind)
    }

    public func copyAssetIntoLibrary(from sourceURL: URL, assetKind: AssetKind) throws -> URL {
        let directoryName: String
        switch assetKind {
        case .image:
            directoryName = "assets/images"
        case .video:
            directoryName = "assets/videos"
        case .audio:
            directoryName = "assets/audio"
        case .document, .markdown:
            directoryName = "assets/documents"
        case .source:
            directoryName = "assets/sources"
        case .raw:
            directoryName = "assets/raw"
        case .threeD:
            directoryName = "assets/three_d"
        case .texture:
            directoryName = "assets/textures"
        case .font:
            directoryName = "assets/fonts"
        case .web:
            directoryName = "assets/web"
        case .json, .text, .data, .unknown:
            directoryName = "assets/data"
        }
        let directory = libraryURL.appendingPathComponent(directoryName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(UUID().uuidString + "-" + sourceURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return destination
    }

    /// Writes capture-host-validated bytes without trusting or rereading the
    /// browser-controlled staging path. The final move is atomic.
    public func writeCapturedAsset(data: Data, preferredFilename: String, assetKind: AssetKind) throws -> URL {
        guard !data.isEmpty else {
            throw NSError(
                domain: "PromptStudio.PromptRepository",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "captured asset data is empty"]
            )
        }
        guard assetKind == .image else {
            throw CocoaError(.fileWriteUnsupportedScheme)
        }

        let directory = libraryURL.appendingPathComponent("assets/images")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let basename = URL(fileURLWithPath: preferredFilename).lastPathComponent
        let safeName = basename.isEmpty || basename == "." || basename == ".." ? "captured-image" : basename
        let destination = directory.appendingPathComponent(UUID().uuidString + "-" + safeName)
        let temporary = directory.appendingPathComponent(".capture-" + UUID().uuidString + ".tmp")
        var createdTemporary = false
        defer {
            if createdTemporary {
                try? FileManager.default.removeItem(at: temporary)
            }
        }

        guard FileManager.default.createFile(
            atPath: temporary.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        createdTemporary = true
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            try FileManager.default.moveItem(at: temporary, to: destination)
            createdTemporary = false
            _ = chmod(destination.path, mode_t(0o600))
            return destination
        } catch {
            try? handle.close()
            throw error
        }
    }

    /// Writes a captured or migrated text prompt as a real Markdown primary
    /// asset. The temporary file is kept inside the library and moved into its
    /// final location only after the complete bytes are present.
    public func writeMarkdownPromptAsset(
        promptID: String,
        title: String,
        prompt: String,
        negativePrompt: String = ""
    ) throws -> URL {
        let directory = libraryURL.appendingPathComponent("assets/documents")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let normalizedTitle = title
            .split(whereSeparator: { $0.isNewline || $0.isWhitespace })
            .joined(separator: " ")
        var content = "# \(normalizedTitle.isEmpty ? "Prompt" : normalizedTitle)\n\n## Prompt\n\(prompt)\n"
        let negative = negativePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !negative.isEmpty {
            content += "\n## Negative Prompt\n\(negative)\n"
        }

        let fileManager = FileManager.default
        let safePromptID = promptID.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" ? String(scalar) : "_"
        }.joined()
        let fileName = "\(safePromptID.isEmpty ? UUID().uuidString : safePromptID)-\(UUID().uuidString).md"
        let destination = directory.appendingPathComponent(fileName)
        let temporary = directory.appendingPathComponent(".\(fileName).tmp")
        let destinationExistedBefore = fileManager.fileExists(atPath: destination.path)
        guard !destinationExistedBefore else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
        }
        do {
            try Data(content.utf8).write(to: temporary, options: [.atomic])
            try fileManager.moveItem(at: temporary, to: destination)
            return destination
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    public func saveTag(_ tag: Tag) throws {
        try PromptRepositoryMigrationCoordinator.shared.withWriteLock(path: databaseURL.path) {
            try database.transaction {
                try database.run(
                    "INSERT OR REPLACE INTO tags (id, name, color, count) VALUES (?, ?, ?, ?);",
                    values: [.text(tag.id), .text(tag.name), .text(tag.color), .int(Int64(tag.count))]
                )
                try reconcileItemSequenceMigrationFingerprintIfNeeded()
            }
        }
    }

    public func loadTags() throws -> [Tag] {
        try database.query("SELECT * FROM tags ORDER BY count DESC, name ASC;").map { row in
            Tag(
                id: required(row, "id"),
                name: required(row, "name"),
                color: required(row, "color"),
                count: int(row, "count")
            )
        }
    }

    public func saveModelProfile(_ profile: ModelProfile) throws {
        try PromptRepositoryMigrationCoordinator.shared.withWriteLock(path: databaseURL.path) {
            try database.transaction {
                try database.run(
                    "INSERT OR REPLACE INTO model_profiles (id, name, type, parametersJSON, defaultNegativePrompt) VALUES (?, ?, ?, ?, ?);",
                    values: [
                        .text(profile.id),
                        .text(profile.name),
                        .text(profile.type.rawValue),
                        .text(encode(profile.parameters)),
                        .text(profile.defaultNegativePrompt)
                    ]
                )
                try reconcileItemSequenceMigrationFingerprintIfNeeded()
            }
        }
    }

    public func loadModelProfiles() throws -> [ModelProfile] {
        let rows = try database.query("SELECT * FROM model_profiles ORDER BY name ASC;")
        return rows.map { row in
            ModelProfile(
                id: required(row, "id"),
                name: required(row, "name"),
                type: PromptType(rawValue: required(row, "type")) ?? .image,
                parameters: decode([String].self, from: required(row, "parametersJSON"), fallback: []),
                defaultNegativePrompt: required(row, "defaultNegativePrompt")
            )
        }
    }

    public func saveFolder(_ folder: LibraryFolder) throws {
        try PromptRepositoryMigrationCoordinator.shared.withWriteLock(path: databaseURL.path) {
            try database.transaction {
                try database.run(
                    "INSERT OR REPLACE INTO library_folders (id, name, parentId, type, count, sortOrder, createdAt) VALUES (?, ?, ?, ?, ?, ?, ?);",
                    values: [
                        .text(folder.id),
                        .text(folder.name),
                        folder.parentId.map { .text($0) } ?? .null,
                        folder.type.map { .text($0.rawValue) } ?? .null,
                        .int(Int64(folder.count)),
                        .int(Int64(folder.sortOrder)),
                        .text(Self.string(from: folder.createdAt))
                    ]
                )
                try reconcileItemSequenceMigrationFingerprintIfNeeded()
            }
        }
    }

    public func loadFolders() throws -> [LibraryFolder] {
        let rows = try database.query("SELECT * FROM library_folders ORDER BY sortOrder ASC, name ASC;")
        return rows.map { row in
            LibraryFolder(
                id: required(row, "id"),
                name: required(row, "name"),
                parentId: row["parentId"] ?? nil,
                type: (row["type"] ?? nil).flatMap(PromptType.init(rawValue:)),
                count: int(row, "count"),
                sortOrder: int(row, "sortOrder"),
                createdAt: date(row["createdAt"] ?? nil) ?? Date()
            )
        }
    }

    /// Updates folder parents and sibling ordering as one transaction.  Every
    /// row is updated separately so SQLite triggers and affected-row checks can
    /// identify the exact failing folder; any failure rolls back the complete
    /// batch.
    public func updateFolderParentsAndSort(_ updates: [FolderParentSortUpdate]) throws {
        guard !updates.isEmpty else { return }
        try PromptRepositoryMigrationCoordinator.shared.withWriteLock(path: databaseURL.path) {
            try database.transaction {
                for update in updates {
                    let changed = try database.runAndReturnChanges(
                        "UPDATE library_folders SET parentId = ?, sortOrder = ? WHERE id = ?;",
                        values: [
                            update.parentID.map { .text($0) } ?? .null,
                            .int(Int64(update.sortOrder)),
                            .text(update.folderID)
                        ]
                    )
                    guard changed == 1 else {
                        throw PromptRepositoryFolderMutationError.affectedRowsMismatch(
                            folderID: update.folderID,
                            expected: 1,
                            actual: changed
                        )
                    }
                }
                try reconcileItemSequenceMigrationFingerprintIfNeeded()
            }
        }
    }

    public func updateFolderParents(_ updates: [FolderParentSortUpdate]) throws {
        try updateFolderParentsAndSort(updates)
    }

    public func updateFolderParentAndSort(_ updates: [FolderParentSortUpdate]) throws {
        try updateFolderParentsAndSort(updates)
    }

    /// Soft-deletes every live prompt inside the selected folder subtrees and
    /// then removes the folders in the same SQLite transaction.  Source IDs
    /// that overlap through a parent/child relationship are normalized before
    /// descendants are expanded.
    public func deleteFolderSubtrees(
        sourceFolderIDs: [String],
        deletedAt: Date = Date()
    ) throws {
        let requestedIDs = FolderDragPayload(folderIDs: sourceFolderIDs).folderIDs
        guard !requestedIDs.isEmpty else { return }
        var changedItemIDs: Set<String> = []
        try PromptRepositoryMigrationCoordinator.shared.withWriteLock(path: databaseURL.path) {
            try database.transaction {
                let folders = try loadFolders()
            let foldersByID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
            for folderID in requestedIDs where foldersByID[folderID] == nil {
                throw PromptRepositoryFolderMutationError.folderNotFound(folderID)
            }
            let topLevelIDs = FolderSelectionActionContext.normalizeParentChildOverlap(
                selectedFolderIDs: requestedIDs,
                folders: folders
            )
            let childrenByParent = Dictionary(grouping: folders, by: { $0.parentId })
            var subtreeIDs: [String] = []
            var pending = topLevelIDs
            var visited = Set<String>()
            while let folderID = pending.first {
                pending.removeFirst()
                guard visited.insert(folderID).inserted else { continue }
                subtreeIDs.append(folderID)
                pending.append(contentsOf: (childrenByParent[folderID] ?? []).map(\.id))
            }

            guard !subtreeIDs.isEmpty else { return }
            let placeholders = Array(repeating: "?", count: subtreeIDs.count).joined(separator: ",")
            let updatedAt = Self.string(from: Date())
            let rows = try database.query(
                "SELECT id FROM prompt_items WHERE deletedAt IS NULL AND folderId IN (\(placeholders));",
                values: subtreeIDs.map { .text($0) }
            )
            changedItemIDs = Set(rows.map { required($0, "id") })
            try database.run(
                "UPDATE prompt_items SET deletedAt = ?, updatedAt = ? WHERE deletedAt IS NULL AND folderId IN (\(placeholders));",
                values: [.text(Self.string(from: deletedAt)), .text(updatedAt)] + subtreeIDs.map { .text($0) }
            )

            // Delete descendants after parents so a trigger can abort at any
            // point and the enclosing transaction restores all earlier work.
            for folderID in subtreeIDs.reversed() {
                let changed = try database.runAndReturnChanges(
                    "DELETE FROM library_folders WHERE id = ?;",
                    values: [.text(folderID)]
                )
                guard changed == 1 else {
                    throw PromptRepositoryFolderMutationError.affectedRowsMismatch(
                        folderID: folderID,
                        expected: 1,
                        actual: changed
                    )
                }
            }
                try refreshTagsAfterMutation()
                try reconcileItemSequenceMigrationFingerprintIfNeeded()
            }
        }
        if changedItemIDs.isEmpty {
            _ = libraryDataRevision.advance()
        } else {
            _ = itemDetailInvalidationHub.publish(changedItemIDs: changedItemIDs)
        }
    }

    public func deleteFolderTrees(
        sourceFolderIDs: [String],
        deletedAt: Date = Date()
    ) throws {
        try deleteFolderSubtrees(sourceFolderIDs: sourceFolderIDs, deletedAt: deletedAt)
    }

    public func deleteFoldersRecursively(
        ids: [String],
        deletedAt: Date = Date()
    ) throws {
        try deleteFolderSubtrees(sourceFolderIDs: ids, deletedAt: deletedAt)
    }

    /// New batch-delete spelling while retaining the original hard-delete
    /// `deleteFolders(ids:)` API for existing callers.
    public func deleteFolders(ids: [String], deletedAt: Date) throws {
        try deleteFolderSubtrees(sourceFolderIDs: ids, deletedAt: deletedAt)
    }

    public func renameFolder(id: String, name: String) throws {
        try PromptRepositoryMigrationCoordinator.shared.withWriteLock(path: databaseURL.path) {
            try database.transaction {
                try database.run(
                    "UPDATE library_folders SET name = ? WHERE id = ?;",
                    values: [.text(name), .text(id)]
                )
                try reconcileItemSequenceMigrationFingerprintIfNeeded()
            }
        }
    }

    public func deleteFolders(ids: [String]) throws {
        for id in ids {
            try deleteFolder(id: id)
        }
    }

    public func deleteFolder(id: String) throws {
        try PromptRepositoryMigrationCoordinator.shared.withWriteLock(path: databaseURL.path) {
            try database.transaction {
                try database.run("DELETE FROM library_folders WHERE id = ?;", values: [.text(id)])
                try reconcileItemSequenceMigrationFingerprintIfNeeded()
            }
        }
    }

    private func saveVersion(
        _ version: PromptVersion,
        sequence: Int64? = nil,
        createdAtString: String? = nil,
        sortKey: Int64? = nil
    ) throws {
        guard versionSequenceStorageAvailable else {
            try database.run(
                """
                INSERT OR REPLACE INTO prompt_versions (
                    id, promptItemId, version, prompt, negativePrompt, parametersJSON, note, createdAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                """,
                values: [
                    .text(version.id),
                    .text(version.promptItemId),
                    .text(version.version),
                    .text(version.prompt),
                    .text(version.negativePrompt),
                    .text(encode(version.parameters)),
                    .text(version.note),
                    .text(Self.string(from: version.createdAt))
                ]
            )
            return
        }

        let assignedSequence: Int64
        if let sequence {
            assignedSequence = sequence
        } else {
            assignedSequence = try nextVersionSequence(itemID: version.promptItemId)
        }
        try database.run(
            """
            INSERT INTO prompt_versions (
                id, promptItemId, version, prompt, negativePrompt, parametersJSON, note, createdAt,
                versionCreatedAtSortKey, versionSequence
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                promptItemId = excluded.promptItemId,
                version = excluded.version,
                prompt = excluded.prompt,
                negativePrompt = excluded.negativePrompt,
                parametersJSON = excluded.parametersJSON,
                note = excluded.note,
                createdAt = excluded.createdAt,
                versionCreatedAtSortKey = excluded.versionCreatedAtSortKey,
                versionSequence = excluded.versionSequence;
            """,
            values: [
                .text(version.id),
                .text(version.promptItemId),
                .text(version.version),
                .text(version.prompt),
                .text(version.negativePrompt),
                .text(encode(version.parameters)),
                .text(version.note),
                .text(createdAtString ?? Self.string(from: version.createdAt)),
                .int(sortKey ?? VersionSequenceTimestampSupport.sortKey(for: version.createdAt)),
                .int(assignedSequence)
            ]
        )
    }

    private enum SaveItemConflict: Equatable {
        case updateExistingID
        case ignoreExistingCapture
    }

    @discardableResult
    private func saveItemRecord(_ item: PromptItem, conflict: SaveItemConflict = .updateExistingID) throws -> Bool {
        let hasItemSequenceStorage = itemSequenceStorageAvailable()
        let encodedCreatedAt = Self.string(from: item.createdAt)
        let encodedLastUsedAt = Self.string(from: item.lastUsedAt)
        let existingItemMetadata: [String: String?]?
        if hasItemSequenceStorage {
            existingItemMetadata = try database.query(
                "SELECT createdAt, lastUsedAt, itemCreatedAtSortKey, itemLastUsedAtSortKey, itemSequence FROM prompt_items WHERE id = ?;",
                values: [.text(item.id)]
            ).first
        } else {
            existingItemMetadata = try database.query(
                "SELECT createdAt, lastUsedAt FROM prompt_items WHERE id = ?;",
                values: [.text(item.id)]
            ).first
        }
        // `createdAt` is an immutable raw-history field.  A ready load has no
        // opaque raw representation in PromptItem, so never serialize the
        // model Date back over an existing row; only new rows use that Date.
        let persistedCreatedAt: String
        if let existingRaw = existingItemMetadata?["createdAt"] ?? nil {
            persistedCreatedAt = existingRaw
        } else {
            persistedCreatedAt = encodedCreatedAt
        }
        let itemSequence: Int64?
        let createdSortKey: Int64?
        let lastUsedSortKey: Int64?
        if hasItemSequenceStorage {
            if let raw = existingItemMetadata?["itemSequence"] ?? nil, let parsed = Int64(raw), parsed > 0 {
                itemSequence = parsed
            } else {
                itemSequence = try nextItemSequence()
            }
            if let raw = existingItemMetadata?["itemCreatedAtSortKey"] ?? nil,
               let parsed = Int64(raw) {
                createdSortKey = parsed
            } else {
                createdSortKey = itemSequenceSortKey(for: persistedCreatedAt)
            }
            if existingItemMetadata?["lastUsedAt"] ?? nil == encodedLastUsedAt,
               let raw = existingItemMetadata?["itemLastUsedAtSortKey"] ?? nil,
               let parsed = Int64(raw) {
                lastUsedSortKey = parsed
            } else {
                lastUsedSortKey = itemSequenceSortKey(for: encodedLastUsedAt, fallback: Date(timeIntervalSince1970: 0))
            }
        } else {
            itemSequence = nil
            createdSortKey = nil
            lastUsedSortKey = nil
        }
        let conflictClause: String
        switch conflict {
        case .updateExistingID:
            conflictClause = """
            ON CONFLICT(id) DO UPDATE SET
                title = excluded.title,
                type = excluded.type,
                assetKind = excluded.assetKind,
                modelId = excluded.modelId,
                modelName = excluded.modelName,
                folderId = excluded.folderId,
                folderName = excluded.folderName,
                category = excluded.category,
                assetPath = excluded.assetPath,
                thumbnailPath = excluded.thumbnailPath,
                aspectRatio = excluded.aspectRatio,
                width = excluded.width,
                height = excluded.height,
                format = excluded.format,
                fileSize = excluded.fileSize,
                favorite = excluded.favorite,
                pinnedAt = excluded.pinnedAt,
                deletedAt = excluded.deletedAt,
                createdAt = excluded.createdAt,
                updatedAt = excluded.updatedAt,
                lastUsedAt = excluded.lastUsedAt,
                sortOrder = excluded.sortOrder,
                tagsJSON = excluded.tagsJSON,
                referencesJSON = excluded.referencesJSON,
                description = excluded.description,
                captureId = excluded.captureId,
                captureSourceJSON = excluded.captureSourceJSON
            """
            + (hasItemSequenceStorage ? ", itemCreatedAtSortKey = excluded.itemCreatedAtSortKey, itemLastUsedAtSortKey = excluded.itemLastUsedAtSortKey, itemSequence = excluded.itemSequence" : "")
        case .ignoreExistingCapture:
            // Match the partial unique index explicitly so unrelated constraints still fail.
            conflictClause = "ON CONFLICT(captureId) WHERE captureId IS NOT NULL DO NOTHING"
        }

        let itemSequenceColumns = hasItemSequenceStorage ? ", itemCreatedAtSortKey, itemLastUsedAtSortKey, itemSequence" : ""
        let itemSequencePlaceholders = hasItemSequenceStorage ? ", ?, ?, ?" : ""
        var itemValues: [SQLiteValue] = [
            .text(item.id), .text(item.title), .text(item.type.rawValue), .text(item.assetKind.rawValue),
            .text(item.modelId), .text(item.modelName), .text(item.folderId), .text(item.folderName), .text(item.category),
            .text(item.assetPath), .text(item.thumbnailPath), .text(item.aspectRatio), .int(Int64(item.width)), .int(Int64(item.height)),
            .text(item.format), .int(item.fileSize), .int(item.favorite ? 1 : 0),
            item.pinnedAt.map { .text(Self.string(from: $0)) } ?? .null,
            item.deletedAt.map { .text(Self.string(from: $0)) } ?? .null,
            .text(persistedCreatedAt), .text(Self.string(from: item.updatedAt)), .text(encodedLastUsedAt), .int(Int64(item.sortOrder)),
            .text(encode(item.tags)), .text(encode(item.referenceAssets)), .text(item.description),
            item.captureID.map { .text($0) } ?? .null, item.capturedSource.map { .text(encode($0)) } ?? .null
        ]
        if hasItemSequenceStorage {
            itemValues += [.int(createdSortKey ?? 0), .int(lastUsedSortKey ?? 0), .int(itemSequence ?? 0)]
        }
        try database.run(
            """
            INSERT INTO prompt_items (
                id, title, type, assetKind, modelId, modelName, folderId, folderName, category, assetPath, thumbnailPath,
                aspectRatio, width, height, format, fileSize, favorite, pinnedAt, deletedAt, createdAt, updatedAt,
                lastUsedAt, sortOrder, tagsJSON, referencesJSON, description, captureId, captureSourceJSON\(itemSequenceColumns)
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?\(itemSequencePlaceholders))
            \(conflictClause)
            ;
            """,
            values: itemValues
        )

        let hasVersionSequenceStorage = self.versionSequenceStorageAvailable
        let preservedVersionMetadata = hasVersionSequenceStorage
            ? try loadVersionMetadata(itemID: item.id)
            : [:]
        var nextSequence = preservedVersionMetadata.values.map(\.sequence).max() ?? 0
        var assignedSequences: [String: Int64] = [:]
        if hasVersionSequenceStorage {
            for version in item.versions {
                if let metadata = preservedVersionMetadata[version.id] {
                    assignedSequences[version.id] = metadata.sequence
                } else {
                    nextSequence += 1
                    assignedSequences[version.id] = nextSequence
                }
            }
        }
        let inserted = Int((try database.query("SELECT changes() AS changed;").first?["changed"] ?? nil) ?? "0") == 1
        switch conflict {
        case .updateExistingID:
            try database.run("DELETE FROM prompt_versions WHERE promptItemId = ?;", values: [.text(item.id)])
            for version in item.versions {
                let metadata = preservedVersionMetadata[version.id]
                try saveVersion(
                    version,
                    sequence: assignedSequences[version.id] ?? metadata?.sequence,
                    createdAtString: metadata?.createdAt,
                    sortKey: metadata?.sortKey
                )
            }
        case .ignoreExistingCapture:
            if inserted {
                for version in item.versions {
                    let metadata = preservedVersionMetadata[version.id]
                    try saveVersion(
                        version,
                        sequence: assignedSequences[version.id] ?? metadata?.sequence,
                        createdAtString: metadata?.createdAt,
                        sortKey: metadata?.sortKey
                    )
                }
            }
        }
        if conflict == .updateExistingID || inserted {
            var relationItem = item
            if let createdSortKey {
                relationItem.createdAt = PromptItemCreatedAtSupport.date(forSortKey: createdSortKey)
            } else if let rawCreatedAt = existingItemMetadata?["createdAt"] ?? nil,
                      let parsedCreatedAt = ISO8601DateFormatter().date(from: rawCreatedAt) {
                relationItem.createdAt = parsedCreatedAt
            }
            try dualWriteTagRelationsIfAvailable(item: relationItem, rawCreatedAt: persistedCreatedAt)
        }
        return inserted
    }

    private struct SavedVersionMetadata {
        let sequence: Int64
        let createdAt: String
        let sortKey: Int64
    }

    private func loadVersionMetadata(itemID: String) throws -> [String: SavedVersionMetadata] {
        guard versionSequenceStorageAvailable else { return [:] }
        let rows = try database.query(
            "SELECT id, createdAt, versionCreatedAtSortKey, versionSequence FROM prompt_versions WHERE promptItemId = ?;",
            values: [.text(itemID)]
        )
        var values: [String: SavedVersionMetadata] = [:]
        for row in rows {
            guard let rawSequence = row["versionSequence"] ?? nil,
                  let sequence = Int64(rawSequence),
                  let createdAt = row["createdAt"] ?? nil,
                  let rawSortKey = row["versionCreatedAtSortKey"] ?? nil,
                  let sortKey = Int64(rawSortKey) else { continue }
            values[required(row, "id")] = SavedVersionMetadata(
                sequence: sequence,
                createdAt: createdAt,
                sortKey: sortKey
            )
        }
        return values
    }

    private func nextVersionSequence(itemID: String) throws -> Int64 {
        let value = try database.query(
            "SELECT COALESCE(MAX(versionSequence), 0) + 1 AS nextSequence FROM prompt_versions WHERE promptItemId = ?;",
            values: [.text(itemID)]
        ).first?["nextSequence"] ?? nil
        return Int64(value ?? "") ?? 1
    }

    /// The columns are added before the migration reaches `.ready`. Writers
    /// therefore dual-write during backfill so a checkpoint cannot skip rows
    /// that would otherwise contain NULL sequence metadata.
    private var versionSequenceStorageAvailable: Bool {
        guard let columns = try? versionSequenceColumnNames() else { return false }
        return columns.contains("versionSequence") && columns.contains("versionCreatedAtSortKey")
    }

    private func reconcileVersionSequenceMigrationFingerprintIfNeeded() throws {
        guard (try? versionSequenceMetadataTableExists()) == true else { return }
        let state = try versionSequenceMigrationState()
        guard state.phase == .backfilling else { return }
        // Writers participate in the migration contract with one metadata-row
        // counter bump. The protected payload fingerprint is reserved for
        // prepare and final reconciliation, avoiding O(writes × versions).
        try database.run(
            "UPDATE version_sequence_migration SET changeCounter = changeCounter + 1, updatedAt = ? WHERE id = 1;",
            values: [.text(Self.string(from: Date()))]
        )
    }

    private func loadVersions(versionSequenceReady: Bool) throws -> [String: [PromptVersion]] {
        let rows: [[String: String?]]
        if versionSequenceReady {
            rows = try database.query(
                "SELECT * FROM prompt_versions ORDER BY versionCreatedAtSortKey ASC, versionSequence ASC;"
            )
        } else {
            rows = try database.query("SELECT * FROM prompt_versions ORDER BY createdAt ASC;")
        }
        var grouped: [String: [PromptVersion]] = [:]
        for row in rows {
            let itemID = required(row, "promptItemId")
            let version = PromptVersion(
                id: required(row, "id"),
                promptItemId: itemID,
                version: required(row, "version"),
                prompt: required(row, "prompt"),
                negativePrompt: required(row, "negativePrompt"),
                parameters: decode([String: String].self, from: required(row, "parametersJSON"), fallback: [:]),
                note: required(row, "note"),
                createdAt: date(required(row, "createdAt")) ?? Date(),
                versionSequence: versionSequenceReady
                    ? (row["versionSequence"] ?? nil).flatMap(Int64.init)
                    : nil,
                versionCreatedAtSortKey: versionSequenceReady
                    ? (row["versionCreatedAtSortKey"] ?? nil).flatMap(Int64.init)
                    : nil
            )
            grouped[itemID, default: []].append(version)
        }
        return grouped
    }

    private func migratePromptItemsSchema() throws {
        let columns = try database.query("PRAGMA table_info(prompt_items);")
        let columnNames = Set(columns.compactMap { $0["name"] ?? nil })
        if !columnNames.contains("sortOrder") {
            try database.execute("ALTER TABLE prompt_items ADD COLUMN sortOrder INTEGER NOT NULL DEFAULT 0;")
            let rows = try database.query("SELECT id FROM prompt_items ORDER BY createdAt DESC;")
            for (index, row) in rows.enumerated() {
                try database.run(
                    "UPDATE prompt_items SET sortOrder = ? WHERE id = ?;",
                    values: [.int(Int64(index)), .text(required(row, "id"))]
                )
            }
        }
        if !columnNames.contains("folderId") {
            try database.execute("ALTER TABLE prompt_items ADD COLUMN folderId TEXT NOT NULL DEFAULT '';")
        }
        if !columnNames.contains("pinnedAt") {
            try database.execute("ALTER TABLE prompt_items ADD COLUMN pinnedAt TEXT;")
        }
        if !columnNames.contains("assetKind") {
            try database.execute("ALTER TABLE prompt_items ADD COLUMN assetKind TEXT NOT NULL DEFAULT 'image';")
            let rows = try database.query("SELECT id, assetPath, type FROM prompt_items;")
            for row in rows {
                let id = required(row, "id")
                let path = required(row, "assetPath")
                let ext = URL(fileURLWithPath: path).pathExtension
                let promptType = PromptType(rawValue: required(row, "type"))
                let assetKind = AssetKind.infer(fileExtension: ext, fallbackType: promptType)
                try database.run(
                    "UPDATE prompt_items SET assetKind = ? WHERE id = ?;",
                    values: [.text(assetKind.rawValue), .text(id)]
                )
            }
        }
        if !columnNames.contains("captureId") {
            try database.execute("ALTER TABLE prompt_items ADD COLUMN captureId TEXT;")
        }
        if !columnNames.contains("captureSourceJSON") {
            try database.execute("ALTER TABLE prompt_items ADD COLUMN captureSourceJSON TEXT;")
        }
        try database.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_prompt_items_capture_id ON prompt_items(captureId) WHERE captureId IS NOT NULL;"
        )
    }

    private func migrateLibraryFoldersSchema() throws {
        let columns = try database.query("PRAGMA table_info(library_folders);")
        let columnNames = Set(columns.compactMap { $0["name"] ?? nil })
        guard !columnNames.contains("createdAt") else { return }

        try database.execute("ALTER TABLE library_folders ADD COLUMN createdAt TEXT;")
        try database.run(
            """
            UPDATE library_folders
            SET createdAt = COALESCE(
                (SELECT MIN(prompt_items.createdAt)
                 FROM prompt_items
                 WHERE prompt_items.folderId = library_folders.id),
                ?
            );
            """,
            values: [.text(Self.string(from: Date()))]
        )
    }

    func refreshTags(from items: [PromptItem]) throws {
        var counts: [String: Int] = [:]
        for item in items where !item.isDeleted {
            for tag in item.tags {
                counts[tag, default: 0] += 1
            }
        }
        for (name, count) in counts {
            try database.run(
                "INSERT INTO tags (id, name, color, count) VALUES (?, ?, ?, ?) ON CONFLICT(name) DO UPDATE SET count = excluded.count;",
                values: [.text(UUID().uuidString), .text(name), .text("#3B82F6"), .int(Int64(count))]
            )
        }
        let existingRows = try database.query("SELECT name FROM tags;")
        let existingNames = existingRows.map { required($0, "name") }
        for name in existingNames where counts[name] == nil {
            try database.run("DELETE FROM tags WHERE name = ?;", values: [.text(name)])
        }
    }

    private func seedKey(_ item: PromptItem) -> String {
        "\(item.title)|\(item.modelId)"
    }

    private func encode<T: Encodable>(_ value: T) -> String {
        guard let data = try? encoder.encode(value), let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }

    private func decode<T: Decodable>(_ type: T.Type, from string: String, fallback: T) -> T {
        guard let data = string.data(using: .utf8), let value = try? decoder.decode(T.self, from: data) else {
            return fallback
        }
        return value
    }

    private func decodeOptional<T: Decodable>(_ type: T.Type, from string: String?) -> T? {
        guard let string, !string.isEmpty,
              let data = string.data(using: .utf8),
              let value = try? decoder.decode(T.self, from: data) else {
            return nil
        }
        return value
    }

    private static func string(from date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func date(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        return ISO8601DateFormatter().date(from: string)
    }

    private func legacyCreatedAt(_ raw: String) throws -> Date {
        if let observation = PromptItemCreatedAtSupport.legacyObservation(from: raw) {
            return observation.date
        }
        return try legacyObservationClock.observe()
    }

    private func required(_ row: [String: String?], _ key: String) -> String {
        guard let value = row[key] else { return "" }
        return value ?? ""
    }

    private func int(_ row: [String: String?], _ key: String) -> Int {
        Int(required(row, key)) ?? 0
    }

    private func int64(_ row: [String: String?], _ key: String) -> Int64 {
        Int64(required(row, key)) ?? 0
    }
}
