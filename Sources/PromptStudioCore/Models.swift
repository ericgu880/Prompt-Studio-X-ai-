import Foundation

public enum AssetKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case image
    case video
    case audio
    case markdown
    case json
    case document
    case text
    case data
    case source
    case raw
    case threeD
    case texture
    case font
    case web
    case unknown

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .image:
            "图片"
        case .video:
            "视频"
        case .audio:
            "音频"
        case .markdown:
            "Markdown"
        case .json:
            "JSON"
        case .document:
            "文档"
        case .text:
            "文本"
        case .data:
            "数据"
        case .source:
            "源文件"
        case .raw:
            "RAW"
        case .threeD:
            "3D"
        case .texture:
            "贴图"
        case .font:
            "字体"
        case .web:
            "网页"
        case .unknown:
            "文件"
        }
    }

    public var promptType: PromptType {
        switch self {
        case .video:
            .video
        case .image:
            .image
        case .audio:
            .audio
        case .markdown, .json, .document, .text, .data, .source, .raw, .threeD, .texture, .font, .web, .unknown:
            .text
        }
    }

    public var isTextDocumentLike: Bool {
        switch self {
        case .markdown, .json, .text, .data:
            true
        case .image, .video, .audio, .document, .source, .raw, .threeD, .texture, .font, .web, .unknown:
            false
        }
    }

    public var supportsGeneratedThumbnail: Bool {
        self == .image || self == .video || self == .audio || isTextDocumentLike
    }

    public static func infer(fileExtension: String, fallbackType: PromptType? = nil) -> AssetKind {
        let support = AssetFormatCatalog.support(forFileExtension: fileExtension)
        if support.assetKind != .unknown {
            return support.assetKind
        }
        if support.fileExtension.isEmpty, let fallbackType {
            switch fallbackType {
            case .image:
                return .image
            case .video:
                return .video
            case .audio:
                return .audio
            case .text:
                return .text
            }
        }
        return support.assetKind
    }
}

public enum AssetSupportTier: String, Codable, CaseIterable, Identifiable, Sendable {
    case p0Native
    case p1System
    case p2Reference

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .p0Native:
            "原生预览"
        case .p1System:
            "系统预览"
        case .p2Reference:
            "参考资产"
        }
    }
}

public enum AssetPreviewMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case image
    case video
    case textDocument
    case audio
    case document
    case reference
    case generic

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .image:
            "图片预览"
        case .video:
            "视频预览"
        case .textDocument:
            "文档预览"
        case .audio:
            "音频预览"
        case .document:
            "文件预览"
        case .reference:
            "参考资产"
        case .generic:
            "通用文件"
        }
    }
}

public struct AssetFormatSupport: Equatable, Sendable {
    public var fileExtension: String
    public var assetKind: AssetKind
    public var supportTier: AssetSupportTier
    public var previewMode: AssetPreviewMode
    public var displayName: String
    public var canExtractPrompt: Bool

    public init(
        fileExtension: String,
        assetKind: AssetKind,
        supportTier: AssetSupportTier,
        previewMode: AssetPreviewMode,
        displayName: String,
        canExtractPrompt: Bool = false
    ) {
        self.fileExtension = fileExtension.lowercased()
        self.assetKind = assetKind
        self.supportTier = supportTier
        self.previewMode = previewMode
        self.displayName = displayName
        self.canExtractPrompt = canExtractPrompt
    }
}

public enum AssetFormatCatalog {
    public static let promptDocumentExtensions = [
        "md", "markdown", "mdown", "json", "txt", "csv", "tsv", "rtf", "log", "xml", "plist", "yaml", "yml", "toml"
    ]

    public static let eagleMacOSExtensions = [
        "bmp", "gif", "heic", "heif", "hif", "icns", "ico", "jpeg", "jpg", "png", "svg", "tif", "tiff", "ttf",
        "webp", "avif", "base64", "jfif", "insp", "jxl", "jpe",
        "fbx", "obj", "3ds", "3mf", "dae", "ifc", "ply", "stl", "glb",
        "dds", "exr", "hdr", "tga",
        "af", "afdesign", "afphoto", "afpub", "ai", "c4d", "cdr", "clip", "dwg", "graffle", "idml", "indd",
        "indt", "mindnode", "psb", "psd", "psdt", "pxd", "principle", "sketch", "skt", "skp", "xd", "xmind",
        "m4v", "mp4", "webm", "mov", "mkv", "flv", "f4v", "ts", "mts", "m2ts", "3gp",
        "aac", "flac", "m4a", "mp3", "ogg", "wav",
        "otf", "ttc", "woff",
        "3fr", "arw", "cr2", "cr3", "crw", "dng", "erf", "mrw", "nef", "nrw", "orf", "pef", "raf", "raw",
        "rw2", "sr2", "srw", "x3f",
        "txt", "key", "numbers", "pages", "pdf", "potx", "ppt", "pptx", "xls", "xlsx", "doc", "docx", "eddx", "emmx",
        "html", "mhtml", "url"
    ]

    public static var allKnownExtensions: [String] {
        Array(Set(supportsByExtension.keys)).sorted()
    }

    public static func support(forFileExtension fileExtension: String) -> AssetFormatSupport {
        let ext = normalize(fileExtension)
        guard !ext.isEmpty else {
            return unknownSupport(fileExtension: "")
        }
        return supportsByExtension[ext] ?? unknownSupport(fileExtension: ext)
    }

    public static func support(for item: PromptItem) -> AssetFormatSupport {
        let fileSupport = support(forFileExtension: (item.assetPath as NSString).pathExtension)
        if fileSupport.assetKind != .unknown {
            return fileSupport
        }
        return support(for: item.assetKind, format: item.format)
    }

    public static func support(for assetKind: AssetKind, format: String = "") -> AssetFormatSupport {
        let ext = normalize(format)
        let displayName = ext.isEmpty ? assetKind.displayName : ext.uppercased()
        switch assetKind {
        case .image:
            return AssetFormatSupport(fileExtension: ext, assetKind: .image, supportTier: .p0Native, previewMode: .image, displayName: displayName)
        case .video:
            return AssetFormatSupport(fileExtension: ext, assetKind: .video, supportTier: .p0Native, previewMode: .video, displayName: displayName)
        case .audio:
            return AssetFormatSupport(fileExtension: ext, assetKind: .audio, supportTier: .p1System, previewMode: .audio, displayName: displayName)
        case .markdown, .json, .text, .data:
            return AssetFormatSupport(fileExtension: ext, assetKind: assetKind, supportTier: .p0Native, previewMode: .textDocument, displayName: displayName, canExtractPrompt: true)
        case .document:
            return AssetFormatSupport(fileExtension: ext, assetKind: .document, supportTier: .p1System, previewMode: .document, displayName: displayName)
        case .source, .raw, .threeD, .texture, .font:
            return AssetFormatSupport(fileExtension: ext, assetKind: assetKind, supportTier: .p2Reference, previewMode: .reference, displayName: displayName)
        case .web:
            return AssetFormatSupport(fileExtension: ext, assetKind: .web, supportTier: .p1System, previewMode: .document, displayName: displayName)
        case .unknown:
            return unknownSupport(fileExtension: ext)
        }
    }

    private static let supportsByExtension: [String: AssetFormatSupport] = {
        var result: [String: AssetFormatSupport] = [:]
        func register(
            _ extensions: [String],
            assetKind: AssetKind,
            tier: AssetSupportTier,
            previewMode: AssetPreviewMode,
            canExtractPrompt: Bool = false
        ) {
            for ext in extensions {
                let normalized = normalize(ext)
                result[normalized] = AssetFormatSupport(
                    fileExtension: normalized,
                    assetKind: assetKind,
                    supportTier: tier,
                    previewMode: previewMode,
                    displayName: normalized.uppercased(),
                    canExtractPrompt: canExtractPrompt
                )
            }
        }

        register(
            ["png", "jpg", "jpeg", "jpe", "jfif", "webp", "gif", "heic", "heif", "hif", "tif", "tiff", "bmp", "avif", "svg", "ico", "icns", "jxl", "insp", "base64"],
            assetKind: .image,
            tier: .p0Native,
            previewMode: .image
        )
        register(["mp4", "mov", "m4v", "webm", "mkv", "flv", "f4v", "ts", "mts", "m2ts", "3gp", "avi", "hevc"], assetKind: .video, tier: .p0Native, previewMode: .video)
        register(["mp3", "m4a", "wav", "aac", "aiff", "aif", "flac", "ogg", "opus"], assetKind: .audio, tier: .p1System, previewMode: .audio)
        register(["md", "markdown", "mdown"], assetKind: .markdown, tier: .p0Native, previewMode: .textDocument, canExtractPrompt: true)
        register(["json"], assetKind: .json, tier: .p0Native, previewMode: .textDocument, canExtractPrompt: true)
        register(["txt", "csv", "tsv", "rtf", "log"], assetKind: .text, tier: .p0Native, previewMode: .textDocument, canExtractPrompt: true)
        register(["xml", "plist", "yaml", "yml", "toml"], assetKind: .data, tier: .p0Native, previewMode: .textDocument, canExtractPrompt: true)
        register(["doc", "docx"], assetKind: .document, tier: .p0Native, previewMode: .textDocument, canExtractPrompt: true)
        register(["pdf"], assetKind: .document, tier: .p0Native, previewMode: .document)
        register(["key", "numbers", "pages", "potx", "ppt", "pptx", "xls", "xlsx", "eddx", "emmx"], assetKind: .document, tier: .p1System, previewMode: .document)
        register(["html", "mhtml", "url"], assetKind: .web, tier: .p1System, previewMode: .document)
        register(
            ["af", "afdesign", "afphoto", "afpub", "ai", "eps", "c4d", "cdr", "clip", "dwg", "graffle", "idml", "indd", "indt", "mindnode", "psb", "psd", "psdt", "pxd", "principle", "sketch", "skt", "skp", "xd", "xmind"],
            assetKind: .source,
            tier: .p2Reference,
            previewMode: .reference
        )
        register(["fbx", "obj", "3ds", "3mf", "dae", "ifc", "ply", "stl", "glb", "blend", "blender"], assetKind: .threeD, tier: .p2Reference, previewMode: .reference)
        register(["dds", "exr", "hdr", "tga"], assetKind: .texture, tier: .p2Reference, previewMode: .reference)
        register(["3fr", "arw", "cr2", "cr3", "crw", "dng", "erf", "mrw", "nef", "nrw", "orf", "pef", "raf", "raw", "rw2", "sr2", "srw", "x3f"], assetKind: .raw, tier: .p2Reference, previewMode: .reference)
        register(["ttf", "otf", "ttc", "woff", "woff2"], assetKind: .font, tier: .p2Reference, previewMode: .reference)
        return result
    }()

    private static func unknownSupport(fileExtension: String) -> AssetFormatSupport {
        AssetFormatSupport(
            fileExtension: fileExtension,
            assetKind: .unknown,
            supportTier: .p2Reference,
            previewMode: .generic,
            displayName: fileExtension.isEmpty ? "FILE" : fileExtension.uppercased()
        )
    }

    private static func normalize(_ fileExtension: String) -> String {
        fileExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
    }
}

public enum PromptType: String, Codable, CaseIterable, Identifiable, Sendable {
    case image
    case video
    case text
    case audio

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .image: "图片 Prompt"
        case .video: "视频 Prompt"
        case .text: "文本 Prompt"
        case .audio: "音频 Prompt"
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
    public var assetKind: AssetKind
    public var modelId: String
    public var modelName: String
    public var folderId: String
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
    public var pinnedAt: Date?
    public var deletedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var lastUsedAt: Date
    public var sortOrder: Int
    public var tags: [String]
    public var referenceAssets: [ReferenceAsset]
    public var versions: [PromptVersion]
    public var description: String

    public init(
        id: String = UUID().uuidString,
        title: String,
        type: PromptType,
        assetKind: AssetKind? = nil,
        modelId: String,
        modelName: String,
        folderId: String = "",
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
        pinnedAt: Date? = nil,
        deletedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastUsedAt: Date = Date(timeIntervalSince1970: 0),
        sortOrder: Int = 0,
        tags: [String] = [],
        referenceAssets: [ReferenceAsset] = [],
        versions: [PromptVersion] = [],
        description: String = ""
    ) {
        self.id = id
        self.title = title
        self.type = type
        if let assetKind {
            self.assetKind = assetKind
        } else {
            switch type {
            case .image:
                self.assetKind = .image
            case .video:
                self.assetKind = .video
            case .audio:
                self.assetKind = .audio
            case .text:
                self.assetKind = .text
            }
        }
        self.modelId = modelId
        self.modelName = modelName
        self.folderId = folderId
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
        self.pinnedAt = pinnedAt
        self.deletedAt = deletedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastUsedAt = lastUsedAt
        self.sortOrder = sortOrder
        self.tags = tags
        self.referenceAssets = referenceAssets
        self.versions = versions
        self.description = description
    }

    public var currentVersion: PromptVersion? {
        versions.sorted { $0.createdAt < $1.createdAt }.last
    }

    public var isTextDocumentLike: Bool {
        assetKind.isTextDocumentLike || isWordDocument || formatSupport.previewMode == .textDocument
    }

    public var isPromptPrimaryAsset: Bool {
        assetKind == .image || assetKind == .video || assetKind == .audio || isTextDocumentLike
    }

    public var isAttachmentAsset: Bool {
        !isPromptPrimaryAsset
    }

    public var supportsGeneratedThumbnail: Bool {
        assetKind.supportsGeneratedThumbnail || isTextDocumentLike
    }

    public var formatSupport: AssetFormatSupport {
        AssetFormatCatalog.support(for: self)
    }

    public var previewMode: AssetPreviewMode {
        if isTextDocumentLike {
            return .textDocument
        }
        return formatSupport.previewMode
    }

    public var supportTier: AssetSupportTier {
        formatSupport.supportTier
    }

    public var canExtractPromptFromAsset: Bool {
        isTextDocumentLike || formatSupport.canExtractPrompt
    }

    public var isWordDocument: Bool {
        let normalizedFormat = format.lowercased()
        let pathExtension = (assetPath as NSString).pathExtension.lowercased()
        return ["doc", "docx", "word"].contains(normalizedFormat) || ["doc", "docx"].contains(pathExtension)
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

public enum TextFormatFilter: String, CaseIterable, Identifiable, Sendable {
    case markdown
    case json
    case text
    case word

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .markdown:
            "MD"
        case .json:
            "Json"
        case .text:
            "txt"
        case .word:
            "Word"
        }
    }

    public func matches(_ item: PromptItem) -> Bool {
        switch self {
        case .markdown:
            return item.assetKind == .markdown
        case .json:
            return item.assetKind == .json
        case .text:
            return item.assetKind == .text
        case .word:
            let format = item.format.lowercased()
            let pathExtension = (item.assetPath as NSString).pathExtension.lowercased()
            return ["doc", "docx", "word"].contains(format) || ["doc", "docx"].contains(pathExtension)
        }
    }
}

public enum AssetKindFilter: String, CaseIterable, Identifiable, Sendable {
    case image
    case video
    case audio
    case promptDocument
    case document
    case source
    case raw
    case threeD
    case texture
    case font
    case web
    case other

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .image:
            "图片"
        case .video:
            "视频"
        case .audio:
            "音频"
        case .promptDocument:
            "Prompt 文档"
        case .document:
            "办公/PDF"
        case .source:
            "源文件"
        case .raw:
            "RAW"
        case .threeD:
            "3D"
        case .texture:
            "贴图"
        case .font:
            "字体"
        case .web:
            "网页/链接"
        case .other:
            "附件/其他"
        }
    }

    public func matches(_ item: PromptItem) -> Bool {
        switch self {
        case .image:
            return item.assetKind == .image
        case .video:
            return item.assetKind == .video
        case .audio:
            return item.assetKind == .audio
        case .promptDocument:
            return item.isTextDocumentLike
        case .document:
            return item.assetKind == .document && !item.isTextDocumentLike
        case .source:
            return item.assetKind == .source
        case .raw:
            return item.assetKind == .raw
        case .threeD:
            return item.assetKind == .threeD
        case .texture:
            return item.assetKind == .texture
        case .font:
            return item.assetKind == .font
        case .web:
            return item.assetKind == .web
        case .other:
            return item.isAttachmentAsset
        }
    }
}

public struct PromptFilter: Equatable, Sendable {
    public var query: String
    public var modelId: String?
    public var collection: LibraryCollection
    public var type: PromptType?
    public var textFormat: TextFormatFilter?
    public var assetKindFilter: AssetKindFilter?
    public var requiredTag: String?
    public var favoriteOnly: Bool
    public var hasPromptOnly: Bool
    public var hasReferenceOnly: Bool

    public init(
        query: String = "",
        modelId: String? = nil,
        collection: LibraryCollection = .all,
        type: PromptType? = nil,
        textFormat: TextFormatFilter? = nil,
        assetKindFilter: AssetKindFilter? = nil,
        requiredTag: String? = nil,
        favoriteOnly: Bool = false,
        hasPromptOnly: Bool = false,
        hasReferenceOnly: Bool = false
    ) {
        self.query = query
        self.modelId = modelId
        self.collection = collection
        self.type = type
        self.textFormat = textFormat
        self.assetKindFilter = assetKindFilter
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
            case .recent where item.isDeleted || item.lastUsedAt.timeIntervalSince1970 <= 0:
                return false
            case .folder(let folderID) where item.folderId != folderID || item.isDeleted:
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
            if let textFormat = filter.textFormat, !textFormat.matches(item) { return false }
            if let assetKindFilter = filter.assetKindFilter, !assetKindFilter.matches(item) { return false }
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
                if lhs.lastUsedAt != rhs.lastUsedAt {
                    return lhs.lastUsedAt > rhs.lastUsedAt
                }
                return lhs.createdAt > rhs.createdAt
            default:
                if lhs.sortOrder != rhs.sortOrder {
                    return lhs.sortOrder < rhs.sortOrder
                }
                return lhs.createdAt > rhs.createdAt
            }
        }
    }
}
