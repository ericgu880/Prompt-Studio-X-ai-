import Foundation

public struct PromptItemDragPayload: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let pasteboardTypeIdentifier = "com.promptstudio.internal.prompt-item-ids"

    public let version: Int
    public let itemIDs: [String]

    public init(itemIDs: [String]) {
        version = Self.currentVersion
        self.itemIDs = Self.normalizedItemIDs(itemIDs)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: container.codingPath,
                    debugDescription: "Unsupported prompt item drag payload version: \(version)"
                )
            )
        }
        self.version = version
        itemIDs = Self.normalizedItemIDs(try container.decode([String].self, forKey: .itemIDs))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(itemIDs, forKey: .itemIDs)
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> PromptItemDragPayload {
        try JSONDecoder().decode(Self.self, from: data)
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case itemIDs
    }

    private static func normalizedItemIDs(_ itemIDs: [String]) -> [String] {
        var seen = Set<String>()
        return itemIDs.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
