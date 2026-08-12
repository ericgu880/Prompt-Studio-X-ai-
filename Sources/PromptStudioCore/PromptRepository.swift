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
    private let database: SQLiteDatabase
    private let captureInsertLock = NSLock()

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

    public init(libraryURL: URL) throws {
        self.libraryURL = libraryURL
        self.databaseURL = libraryURL.appendingPathComponent("database/promptstudio.sqlite")
        try Self.createLibraryDirectories(at: libraryURL)
        self.database = try SQLiteDatabase(path: databaseURL.path)
        try bootstrap()
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
                sortOrder INTEGER NOT NULL
            );
            """
        )
        try database.transaction {
            try migratePromptItemsSchema()
        }
    }

    public func loadItems() throws -> [PromptItem] {
        let rows = try database.query("SELECT * FROM prompt_items;")
        let versions = try loadVersions()
        return rows.map { row in
            let id = required(row, "id")
            let itemVersions = versions[id, default: []].sorted { $0.createdAt < $1.createdAt }
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
                createdAt: date(required(row, "createdAt")) ?? Date(),
                updatedAt: date(required(row, "updatedAt")) ?? Date(),
                lastUsedAt: date(required(row, "lastUsedAt")) ?? Date(timeIntervalSince1970: 0),
                sortOrder: int(row, "sortOrder"),
                tags: decode([String].self, from: required(row, "tagsJSON"), fallback: []),
                referenceAssets: decode([ReferenceAsset].self, from: required(row, "referencesJSON"), fallback: []),
                versions: itemVersions,
                description: required(row, "description"),
                captureID: row["captureId"] ?? nil,
                capturedSource: decodeOptional(CapturedSource.self, from: row["captureSourceJSON"] ?? nil)
            )
        }
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
                let didMigrate = try database.transaction {
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
                    return changed == 1
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
        try database.transaction {
            try saveItemRecord(item)
            try refreshTags(from: try loadItems())
        }
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

        captureInsertLock.lock()
        defer { captureInsertLock.unlock() }
        return try database.transaction {
            if let existing = try findItem(captureID: captureID) {
                return existing
            }

            let inserted = try saveItemRecord(normalizedItem, conflict: .ignoreExistingCapture)
            if inserted {
                try refreshTags(from: try loadItems())
            }
            return try findItem(captureID: captureID) ?? normalizedItem
        }
    }

    public func saveItems(_ items: [PromptItem]) throws {
        try database.transaction {
            for item in items {
                try saveItemRecord(item)
            }
            try refreshTags(from: try loadItems())
        }
    }

    public func updateItemFolders(_ items: [PromptItem]) throws {
        guard !items.isEmpty else { return }
        try database.transaction {
            for item in items {
                try database.run(
                    """
                    UPDATE prompt_items
                    SET folderId = ?, folderName = ?, category = ?, updatedAt = ?
                    WHERE id = ? AND deletedAt IS NULL;
                    """,
                    values: [
                        .text(item.folderId),
                        .text(item.folderName),
                        .text(item.category),
                        .text(Self.string(from: item.updatedAt)),
                        .text(item.id)
                    ]
                )
            }
        }
    }

    public func markDeleted(itemID: String, deletedAt: Date?) throws {
        try markDeleted(itemIDs: [itemID], deletedAt: deletedAt)
    }

    public func markDeleted(itemIDs: [String], deletedAt: Date?) throws {
        let ids = PromptItemDragPayload(itemIDs: itemIDs).itemIDs
        guard !ids.isEmpty else { return }
        try database.transaction {
            let updatedAt = Self.string(from: Date())
            for itemID in ids {
                try database.run(
                    "UPDATE prompt_items SET deletedAt = ?, updatedAt = ? WHERE id = ?;",
                    values: [
                        deletedAt.map { .text(Self.string(from: $0)) } ?? .null,
                        .text(updatedAt),
                        .text(itemID)
                    ]
                )
            }
            try refreshTags(from: try loadItems())
        }
    }

    public func permanentlyDelete(itemID: String) throws {
        try permanentlyDelete(itemIDs: [itemID])
    }

    public func permanentlyDelete(itemIDs: [String]) throws {
        let ids = PromptItemDragPayload(itemIDs: itemIDs).itemIDs
        guard !ids.isEmpty else { return }
        try database.transaction {
            for itemID in ids {
                try database.run("DELETE FROM prompt_items WHERE id = ?;", values: [.text(itemID)])
            }
            try refreshTags(from: try loadItems())
        }
    }

    public func updateLastUsed(itemID: String, at date: Date = Date()) throws {
        try database.run(
            "UPDATE prompt_items SET lastUsedAt = ? WHERE id = ?;",
            values: [.text(Self.string(from: date)), .text(itemID)]
        )
    }

    public func updateThumbnailPath(itemID: String, thumbnailPath: String) throws {
        try database.run(
            "UPDATE prompt_items SET thumbnailPath = ?, updatedAt = ? WHERE id = ?;",
            values: [.text(thumbnailPath), .text(Self.string(from: Date())), .text(itemID)]
        )
    }

    public func updateSortOrders(_ orders: [(id: String, sortOrder: Int)]) throws {
        for order in orders {
            try database.run(
                "UPDATE prompt_items SET sortOrder = ?, updatedAt = ? WHERE id = ?;",
                values: [.int(Int64(order.sortOrder)), .text(Self.string(from: Date())), .text(order.id)]
            )
        }
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
        try database.run(
            "INSERT OR REPLACE INTO tags (id, name, color, count) VALUES (?, ?, ?, ?);",
            values: [.text(tag.id), .text(tag.name), .text(tag.color), .int(Int64(tag.count))]
        )
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
        try database.run(
            "INSERT OR REPLACE INTO library_folders (id, name, parentId, type, count, sortOrder) VALUES (?, ?, ?, ?, ?, ?);",
            values: [
                .text(folder.id),
                .text(folder.name),
                folder.parentId.map { .text($0) } ?? .null,
                folder.type.map { .text($0.rawValue) } ?? .null,
                .int(Int64(folder.count)),
                .int(Int64(folder.sortOrder))
            ]
        )
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
                sortOrder: int(row, "sortOrder")
            )
        }
    }

    /// Updates folder parents and sibling ordering as one transaction.  Every
    /// row is updated separately so SQLite triggers and affected-row checks can
    /// identify the exact failing folder; any failure rolls back the complete
    /// batch.
    public func updateFolderParentsAndSort(_ updates: [FolderParentSortUpdate]) throws {
        guard !updates.isEmpty else { return }
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
            try refreshTags(from: loadItems())
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
        try database.run(
            "UPDATE library_folders SET name = ? WHERE id = ?;",
            values: [.text(name), .text(id)]
        )
    }

    public func deleteFolders(ids: [String]) throws {
        for id in ids {
            try deleteFolder(id: id)
        }
    }

    public func deleteFolder(id: String) throws {
        try database.run("DELETE FROM library_folders WHERE id = ?;", values: [.text(id)])
    }

    private func saveVersion(_ version: PromptVersion) throws {
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
    }

    private enum SaveItemConflict {
        case updateExistingID
        case ignoreExistingCapture
    }

    @discardableResult
    private func saveItemRecord(_ item: PromptItem, conflict: SaveItemConflict = .updateExistingID) throws -> Bool {
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
        case .ignoreExistingCapture:
            // Match the partial unique index explicitly so unrelated constraints still fail.
            conflictClause = "ON CONFLICT(captureId) WHERE captureId IS NOT NULL DO NOTHING"
        }

        try database.run(
            """
            INSERT INTO prompt_items (
                id, title, type, assetKind, modelId, modelName, folderId, folderName, category, assetPath, thumbnailPath,
                aspectRatio, width, height, format, fileSize, favorite, pinnedAt, deletedAt, createdAt, updatedAt,
                lastUsedAt, sortOrder, tagsJSON, referencesJSON, description, captureId, captureSourceJSON
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            \(conflictClause)
            ;
            """,
            values: [
                .text(item.id),
                .text(item.title),
                .text(item.type.rawValue),
                .text(item.assetKind.rawValue),
                .text(item.modelId),
                .text(item.modelName),
                .text(item.folderId),
                .text(item.folderName),
                .text(item.category),
                .text(item.assetPath),
                .text(item.thumbnailPath),
                .text(item.aspectRatio),
                .int(Int64(item.width)),
                .int(Int64(item.height)),
                .text(item.format),
                .int(item.fileSize),
                .int(item.favorite ? 1 : 0),
                item.pinnedAt.map { .text(Self.string(from: $0)) } ?? .null,
                item.deletedAt.map { .text(Self.string(from: $0)) } ?? .null,
                .text(Self.string(from: item.createdAt)),
                .text(Self.string(from: item.updatedAt)),
                .text(Self.string(from: item.lastUsedAt)),
                .int(Int64(item.sortOrder)),
                .text(encode(item.tags)),
                .text(encode(item.referenceAssets)),
                .text(item.description),
                item.captureID.map { .text($0) } ?? .null,
                item.capturedSource.map { .text(encode($0)) } ?? .null
            ]
        )

        let inserted = Int((try database.query("SELECT changes() AS changed;").first?["changed"] ?? nil) ?? "0") == 1
        switch conflict {
        case .updateExistingID:
            try database.run("DELETE FROM prompt_versions WHERE promptItemId = ?;", values: [.text(item.id)])
            for version in item.versions {
                try saveVersion(version)
            }
        case .ignoreExistingCapture:
            if inserted {
                for version in item.versions {
                    try saveVersion(version)
                }
            }
        }
        return inserted
    }

    private func loadVersions() throws -> [String: [PromptVersion]] {
        let rows = try database.query("SELECT * FROM prompt_versions ORDER BY createdAt ASC;")
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
                createdAt: date(required(row, "createdAt")) ?? Date()
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

    private func refreshTags(from items: [PromptItem]) throws {
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
