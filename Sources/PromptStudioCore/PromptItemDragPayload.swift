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

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> PromptItemDragPayload {
        let payload = try JSONDecoder().decode(Self.self, from: data)
        guard payload.version == currentVersion else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Unsupported prompt item drag payload version: \(payload.version)")
            )
        }
        return PromptItemDragPayload(itemIDs: payload.itemIDs)
    }

    private static func normalizedItemIDs(_ itemIDs: [String]) -> [String] {
        var seen = Set<String>()
        return itemIDs.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
