import Foundation

public enum PromptType: String, Codable, CaseIterable, Identifiable, Sendable {
    case image
    case video
    case text

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .image: "图片 Prompt"
        case .video: "视频 Prompt"
        case .text: "文本 Prompt"
        }
    }
}

public struct PromptVersion: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var promptItemId: String
    public var version: String
    public var prompt: String
    public var negativePrompt: String
    public var parameters: [String: String]
    public var note: String
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        promptItemId: String,
        version: String,
        prompt: String,
        negativePrompt: String = "",
        parameters: [String: String] = [:],
        note: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.promptItemId = promptItemId
        self.version = version
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.parameters = parameters
        self.note = note
        self.createdAt = createdAt
    }
}

public struct ReferenceAsset: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var type: String
    public var path: String
    public var label: String

    public init(id: String = UUID().uuidString, type: String, path: String, label: String) {
        self.id = id
        self.type = type
        self.path = path
        self.label = label
    }
}

public struct PromptItem: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var type: PromptType
    public var modelId: String
    public var modelName: String
    public var folderName: String
    public var category: String
    public var assetPath: String
    public var thumbnailPath: String
    public var aspectRatio: String
    public var width: Int
    public var height: Int
    public var format: String
    public var fileSize: Int64
    public var favorite: Bool
    public var deletedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var lastUsedAt: Date
    public var tags: [String]
    public var referenceAssets: [ReferenceAsset]
    public var versions: [PromptVersion]
    public var description: String

    public init(
        id: String = UUID().uuidString,
        title: String,
        type: PromptType,
        modelId: String,
        modelName: String,
        folderName: String,
        category: String,
        assetPath: String,
        thumbnailPath: String = "",
        aspectRatio: String,
        width: Int,
        height: Int,
        format: String,
        fileSize: Int64,
        favorite: Bool = false,
        deletedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastUsedAt: Date = Date(),
        tags: [String] = [],
        referenceAssets: [ReferenceAsset] = [],
        versions: [PromptVersion] = [],
        description: String = ""
    ) {
        self.id = id
        self.title = title
        self.type = type
        self.modelId = modelId
        self.modelName = modelName
        self.folderName = folderName
        self.category = category
        self.assetPath = assetPath
        self.thumbnailPath = thumbnailPath.isEmpty ? assetPath : thumbnailPath
        self.aspectRatio = aspectRatio
        self.width = width
        self.height = height
        self.format = format
        self.fileSize = fileSize
        self.favorite = favorite
        self.deletedAt = deletedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastUsedAt = lastUsedAt
        self.tags = tags
        self.referenceAssets = referenceAssets
        self.versions = versions
        self.description = description
    }

    public var currentVersion: PromptVersion? {
        versions.sorted { $0.createdAt < $1.createdAt }.last
    }

    public var isDeleted: Bool {
        deletedAt != nil
    }

    public var displaySize: String {
        "\(width) x \(height)"
    }

    public var displayAspectRatio: String {
        guard width > 0, height > 0 else { return aspectRatio }
        let divisor = Self.greatestCommonDivisor(width, height)
        let ratioWidth = width / divisor
        let ratioHeight = height / divisor
        if ratioWidth > 24 || ratioHeight > 24 {
            return aspectRatio
        }
        return "\(ratioWidth):\(ratioHeight)"
    }

    private static func greatestCommonDivisor(_ lhs: Int, _ rhs: Int) -> Int {
        var a = abs(lhs)
        var b = abs(rhs)
        while b != 0 {
            let remainder = a % b
            a = b
            b = remainder
        }
        return max(a, 1)
    }
}

public struct Tag: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var color: String
    public var count: Int

    public init(id: String = UUID().uuidString, name: String, color: String = "#3B82F6", count: Int = 0) {
        self.id = id
        self.name = name
        self.color = color
        self.count = count
    }
}

public struct ModelProfile: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var type: PromptType
    public var parameters: [String]
    public var defaultNegativePrompt: String

    public init(
        id: String,
        name: String,
        type: PromptType,
        parameters: [String],
        defaultNegativePrompt: String = ""
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.parameters = parameters
        self.defaultNegativePrompt = defaultNegativePrompt
    }
}

public struct LibraryFolder: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var parentId: String?
    public var type: PromptType?
    public var count: Int
    public var sortOrder: Int

    public init(
        id: String = UUID().uuidString,
        name: String,
        parentId: String? = nil,
        type: PromptType? = nil,
        count: Int = 0,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.name = name
        self.parentId = parentId
        self.type = type
        self.count = count
        self.sortOrder = sortOrder
    }
}

public enum LibraryCollection: Equatable, Sendable {
    case all
    case imagePrompts
    case videoPrompts
    case favorites
    case recent
    case trash
    case folder(String)
    case tag(String)
}

public struct PromptFilter: Equatable, Sendable {
    public var query: String
    public var modelId: String?
    public var collection: LibraryCollection
    public var type: PromptType?
    public var requiredTag: String?
    public var favoriteOnly: Bool
    public var hasPromptOnly: Bool
    public var hasReferenceOnly: Bool

    public init(
        query: String = "",
        modelId: String? = nil,
        collection: LibraryCollection = .all,
        type: PromptType? = nil,
        requiredTag: String? = nil,
        favoriteOnly: Bool = false,
        hasPromptOnly: Bool = false,
        hasReferenceOnly: Bool = false
    ) {
        self.query = query
        self.modelId = modelId
        self.collection = collection
        self.type = type
        self.requiredTag = requiredTag
        self.favoriteOnly = favoriteOnly
        self.hasPromptOnly = hasPromptOnly
        self.hasReferenceOnly = hasReferenceOnly
    }
}

public enum PromptFiltering {
    public static func apply(_ items: [PromptItem], filter: PromptFilter) -> [PromptItem] {
        let query = filter.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return items.filter { item in
            switch filter.collection {
            case .trash where !item.isDeleted:
                return false
            case .trash:
                break
            case .favorites where !item.favorite || item.isDeleted:
                return false
            case .recent where item.isDeleted:
                return false
            case .folder(let folder) where item.folderName != folder || item.isDeleted:
                return false
            case .tag(let tag) where !item.tags.contains(tag) || item.isDeleted:
                return false
            case .imagePrompts where item.type != .image || item.isDeleted:
                return false
            case .videoPrompts where item.type != .video || item.isDeleted:
                return false
            case .all where item.isDeleted:
                return false
            default:
                break
            }

            if let modelId = filter.modelId, item.modelId != modelId { return false }
            if let type = filter.type, item.type != type { return false }
            if let tag = filter.requiredTag, !item.tags.contains(tag) { return false }
            if filter.favoriteOnly, !item.favorite { return false }
            if filter.hasPromptOnly, item.currentVersion?.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                return false
            }
            if filter.hasReferenceOnly, item.referenceAssets.isEmpty { return false }
            if query.isEmpty { return true }

            let searchable = [
                item.title,
                item.modelName,
                item.folderName,
                item.category,
                item.description,
                item.format,
                item.tags.joined(separator: " "),
                item.referenceAssets.map(\.label).joined(separator: " "),
                item.versions.map { [$0.prompt, $0.negativePrompt, $0.note, $0.version].joined(separator: " ") }.joined(separator: " ")
            ].joined(separator: " ").lowercased()

            return searchable.contains(query)
        }
        .sorted { lhs, rhs in
            switch filter.collection {
            case .recent:
                lhs.lastUsedAt > rhs.lastUsedAt
            default:
                lhs.createdAt > rhs.createdAt
            }
        }
    }
}
