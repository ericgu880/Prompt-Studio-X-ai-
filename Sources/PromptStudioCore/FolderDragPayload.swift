import Foundation

public struct FolderDragPayload: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let pasteboardTypeIdentifier = "com.promptstudio.internal.folder-ids"

    public let version: Int
    public let folderIDs: [String]

    public init(folderIDs: [String]) {
        version = Self.currentVersion
        self.folderIDs = Self.normalizedFolderIDs(folderIDs)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: container.codingPath,
                    debugDescription: "Unsupported folder drag payload version: \(version)"
                )
            )
        }
        self.version = version
        folderIDs = Self.normalizedFolderIDs(try container.decode([String].self, forKey: .folderIDs))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(folderIDs, forKey: .folderIDs)
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> FolderDragPayload {
        try JSONDecoder().decode(Self.self, from: data)
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case folderIDs
    }

    private static func normalizedFolderIDs(_ folderIDs: [String]) -> [String] {
        var seen = Set<String>()
        return folderIDs.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
