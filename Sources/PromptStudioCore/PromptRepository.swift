import Foundation

public final class PromptRepository: @unchecked Sendable {
    public let libraryURL: URL
    public let databaseURL: URL
    private let database: SQLiteDatabase

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
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents")
            .appendingPathComponent("PromptStudio Library")
    }

    public static func createLibraryDirectories(at url: URL) throws {
        let paths = [
            url,
            url.appendingPathComponent("assets/images"),
            url.appendingPathComponent("assets/videos"),
            url.appendingPathComponent("assets/audio"),
            url.appendingPathComponent("assets/documents"),
            url.appendingPathComponent("assets/data"),
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
                deletedAt TEXT,
                createdAt TEXT NOT NULL,
                updatedAt TEXT NOT NULL,
                lastUsedAt TEXT NOT NULL,
                sortOrder INTEGER NOT NULL DEFAULT 0,
                tagsJSON TEXT NOT NULL,
                referencesJSON TEXT NOT NULL,
                description TEXT NOT NULL
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
        try migratePromptItemsSchema()
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
                deletedAt: date(row["deletedAt"] ?? nil),
                createdAt: date(required(row, "createdAt")) ?? Date(),
                updatedAt: date(required(row, "updatedAt")) ?? Date(),
                lastUsedAt: date(required(row, "lastUsedAt")) ?? Date(),
                sortOrder: int(row, "sortOrder"),
                tags: decode([String].self, from: required(row, "tagsJSON"), fallback: []),
                referenceAssets: decode([ReferenceAsset].self, from: required(row, "referencesJSON"), fallback: []),
                versions: itemVersions,
                description: required(row, "description")
            )
        }
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
        try database.run(
            """
            INSERT OR REPLACE INTO prompt_items (
                id, title, type, assetKind, modelId, modelName, folderId, folderName, category, assetPath, thumbnailPath,
                aspectRatio, width, height, format, fileSize, favorite, deletedAt, createdAt, updatedAt,
                lastUsedAt, sortOrder, tagsJSON, referencesJSON, description
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
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
                item.deletedAt.map { .text(Self.string(from: $0)) } ?? .null,
                .text(Self.string(from: item.createdAt)),
                .text(Self.string(from: item.updatedAt)),
                .text(Self.string(from: item.lastUsedAt)),
                .int(Int64(item.sortOrder)),
                .text(encode(item.tags)),
                .text(encode(item.referenceAssets)),
                .text(item.description)
            ]
        )

        try database.run("DELETE FROM prompt_versions WHERE promptItemId = ?;", values: [.text(item.id)])
        for version in item.versions {
            try saveVersion(version)
        }
        try refreshTags(from: try loadItems())
    }

    public func markDeleted(itemID: String, deletedAt: Date?) throws {
        try database.run(
            "UPDATE prompt_items SET deletedAt = ?, updatedAt = ? WHERE id = ?;",
            values: [
                deletedAt.map { .text(Self.string(from: $0)) } ?? .null,
                .text(Self.string(from: Date())),
                .text(itemID)
            ]
        )
        try refreshTags(from: try loadItems())
    }

    public func permanentlyDelete(itemID: String) throws {
        try database.run("DELETE FROM prompt_items WHERE id = ?;", values: [.text(itemID)])
        try refreshTags(from: try loadItems())
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
        try copyAssetIntoLibrary(from: sourceURL, assetKind: type == .video ? .video : .image)
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
