import AVFoundation
import Foundation
import ImageIO

public struct AutomationListOptions: Sendable {
    public var query: String
    public var model: String?
    public var folderID: String?
    public var includeTrash: Bool

    public init(
        query: String = "",
        model: String? = nil,
        folderID: String? = nil,
        includeTrash: Bool = false
    ) {
        self.query = query
        self.model = model
        self.folderID = folderID
        self.includeTrash = includeTrash
    }
}

public struct AutomationCreatePromptInput: Sendable {
    public var title: String
    public var prompt: String
    public var negativePrompt: String
    public var tags: [String]
    public var model: String?
    public var folderID: String?

    public init(
        title: String,
        prompt: String,
        negativePrompt: String = "",
        tags: [String] = [],
        model: String? = nil,
        folderID: String? = nil
    ) {
        self.title = title
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.tags = tags
        self.model = model
        self.folderID = folderID
    }
}

public struct AutomationUpdatePromptInput: Sendable {
    public var title: String?
    public var prompt: String?
    public var negativePrompt: String?
    public var tags: [String]?
    public var folderID: String?

    public init(
        title: String? = nil,
        prompt: String? = nil,
        negativePrompt: String? = nil,
        tags: [String]? = nil,
        folderID: String? = nil
    ) {
        self.title = title
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.tags = tags
        self.folderID = folderID
    }
}

public enum AutomationServiceError: Error, LocalizedError, Sendable {
    case itemNotFound(String)
    case folderNotFound(String)
    case fileNotFound(String)
    case invalidInput(String)

    public var errorDescription: String? {
        switch self {
        case .itemNotFound(let id):
            "素材不存在：\(id)"
        case .folderNotFound(let id):
            "文件夹不存在：\(id)"
        case .fileNotFound(let path):
            "文件不存在：\(path)"
        case .invalidInput(let message):
            message
        }
    }
}

public final class PromptStudioAutomationService: @unchecked Sendable {
    public let repository: PromptRepository

    public init(libraryURL: URL = PromptRepository.defaultLibraryURL()) throws {
        self.repository = try PromptRepository(libraryURL: libraryURL)
    }

    public init(repository: PromptRepository) {
        self.repository = repository
    }

    public func listItems(options: AutomationListOptions = AutomationListOptions()) throws -> [PromptItem] {
        var filter = PromptFilter(
            query: options.query,
            collection: options.folderID.map(LibraryCollection.folder) ?? (options.includeTrash ? .trash : .all)
        )
        let model = options.model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let items = PromptFiltering.apply(try repository.loadItems(), filter: filter)
        guard let model, !model.isEmpty else { return items }
        filter.modelId = model
        let modelIDMatches = PromptFiltering.apply(try repository.loadItems(), filter: filter)
        if !modelIDMatches.isEmpty {
            return modelIDMatches
        }
        return items.filter { $0.modelName.localizedCaseInsensitiveContains(model) }
    }

    public func item(id: String) throws -> PromptItem {
        guard let item = try repository.loadItems().first(where: { $0.id == id }) else {
            throw AutomationServiceError.itemNotFound(id)
        }
        return item
    }

    public func folders() throws -> [LibraryFolder] {
        try repository.loadFolders()
    }

    @discardableResult
    public func createFolder(name: String, parentID: String? = nil) throws -> LibraryFolder {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw AutomationServiceError.invalidInput("文件夹名称不能为空")
        }
        if let parentID, try repository.loadFolders().contains(where: { $0.id == parentID }) == false {
            throw AutomationServiceError.folderNotFound(parentID)
        }
        let sortOrder = ((try repository.loadFolders()).map(\.sortOrder).max() ?? 0) + 1
        let folder = LibraryFolder(name: trimmedName, parentId: parentID, sortOrder: sortOrder)
        try repository.saveFolder(folder)
        return folder
    }

    @discardableResult
    public func createPrompt(_ input: AutomationCreatePromptInput) throws -> PromptItem {
        let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw AutomationServiceError.invalidInput("标题不能为空")
        }
        let requestedModel = input.model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let localModels = try repository.loadModelProfiles()
        let matchedModel = requestedModel.flatMap { requested in
            localModels.first(where: { $0.id == requested || $0.name.caseInsensitiveCompare(requested) == .orderedSame })
        }
        let type: PromptType
        let model: ModelProfile
        if let matchedModel {
            type = PromptTypeClassifier.classify(
                text: input.prompt,
                mode: .manual(matchedModel.type)
            )
            model = matchedModel
        } else {
            type = PromptTypeClassifier.classify(text: input.prompt)
            if let requestedModel, !requestedModel.isEmpty {
                model = ModelProfile(id: requestedModel, name: requestedModel, type: type, parameters: [])
            } else {
                model = try ensureCaptureModel(for: type)
            }
        }
        let folder = try resolveFolder(input.folderID)
        let id = UUID().uuidString
        let version = PromptVersion(
            promptItemId: id,
            version: "V1.0",
            prompt: input.prompt,
            negativePrompt: input.negativePrompt,
            note: "Created by agent"
        )
        let assetKind = assetKind(for: type)
        var createdMarkdownURL: URL?
        do {
            var assetPath = ""
            var thumbnailPath = ""
            var format = ""
            var fileSize: Int64 = 0
            if type == .text {
                let markdownURL = try repository.writeMarkdownPromptAsset(
                    promptID: id,
                    title: title,
                    prompt: input.prompt,
                    negativePrompt: input.negativePrompt
                )
                createdMarkdownURL = markdownURL
                assetPath = markdownURL.path
                thumbnailPath = markdownURL.path
                format = "MD"
                let values = try markdownURL.resourceValues(forKeys: [.fileSizeKey])
                fileSize = Int64(values.fileSize ?? 0)
            }
            let item = PromptItem(
                id: id,
                title: title,
                type: type,
                assetKind: assetKind,
                modelId: model.id,
                modelName: model.name,
                folderId: folder?.id ?? "",
                folderName: folder?.name ?? "未分类",
                category: type == .text ? "Markdown" : assetKind.displayName,
                assetPath: assetPath,
                thumbnailPath: thumbnailPath,
                aspectRatio: "",
                width: 0,
                height: 0,
                format: format,
                fileSize: fileSize,
                sortOrder: try nextTopSortOrder(),
                tags: normalizedTags(input.tags),
                versions: [version]
            )
            try repository.saveItem(item)
            return item
        } catch {
            removeGeneratedAsset(at: createdMarkdownURL)
            throw error
        }
    }

    /// Persists an approved browser selection in the free capture inbox.
    ///
    /// This intentionally has no model, folder, or content overrides: web captures
    /// always use the local capture defaults and cannot act as a general prompt API.
    @discardableResult
    public func createCapturedPrompt(_ candidate: WebCaptureCandidate) throws -> PromptItem {
        let captureID = candidate.captureID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !captureID.isEmpty else {
            throw AutomationServiceError.invalidInput("采集 ID 不能为空")
        }

        let selectedText = candidate.selectedText
        guard !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AutomationServiceError.invalidInput("采集文本不能为空")
        }
        guard selectedText.count <= 50_000 else {
            throw AutomationServiceError.invalidInput("采集文本不能超过 50,000 个字符")
        }

        if let existing = try repository.findItem(captureID: captureID) {
            return existing
        }

        let type = PromptTypeClassifier.classify(text: selectedText)
        let assetKind: AssetKind
        switch type {
        case .image:
            assetKind = .image
        case .video:
            assetKind = .video
        case .audio:
            assetKind = .audio
        case .text:
            assetKind = .markdown
        }
        var createdMarkdownURL: URL?
        do {
            let model = try ensureCaptureModel(for: type)
            let folder = try ensureCaptureFolder()
            let id = UUID().uuidString
            var assetPath = ""
            var thumbnailPath = ""
            var fileSize: Int64 = 0
            if type == .text {
                let markdownURL = try repository.writeMarkdownPromptAsset(
                    promptID: id,
                    title: captureTitle(from: selectedText),
                    prompt: selectedText
                )
                createdMarkdownURL = markdownURL
                assetPath = markdownURL.path
                thumbnailPath = markdownURL.path
                let values = try markdownURL.resourceValues(forKeys: [.fileSizeKey])
                fileSize = Int64(values.fileSize ?? 0)
            }
            let item = PromptItem(
                id: id,
                title: captureTitle(from: selectedText),
                type: type,
                assetKind: assetKind,
                modelId: model.id,
                modelName: model.name,
                folderId: folder.id,
                folderName: folder.name,
                category: type == .text ? "Markdown" : assetKind.displayName,
                assetPath: assetPath,
                thumbnailPath: thumbnailPath,
                aspectRatio: "",
                width: 0,
                height: 0,
                format: type == .text ? "MD" : "",
                fileSize: fileSize,
                sortOrder: try nextTopSortOrder(),
                tags: ["网页采集", "待整理"],
                versions: [
                    PromptVersion(
                        promptItemId: id,
                        version: "V1.0",
                        prompt: selectedText,
                        note: "Captured from web"
                    )
                ],
                description: "网页采集",
                captureID: captureID,
                capturedSource: candidate.capturedSource
            )
            let saved = try repository.saveCapturedItem(item)
            if saved.id != id {
                removeGeneratedAsset(at: createdMarkdownURL)
                createdMarkdownURL = nil
            }
            return saved
        } catch {
            removeGeneratedAsset(at: createdMarkdownURL)
            throw error
        }
    }

    @discardableResult
    public func updatePrompt(id: String, input: AutomationUpdatePromptInput) throws -> PromptItem {
        var item = try item(id: id)
        if let title = input.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            item.title = title
        }
        if let tags = input.tags {
            item.tags = normalizedTags(tags)
        }
        if let folderID = input.folderID {
            let folder = try resolveFolder(folderID)
            item.folderId = folder?.id ?? ""
            item.folderName = folder?.name ?? "未分类"
        }
        if input.prompt != nil || input.negativePrompt != nil {
            let current = item.currentVersion
            let version = PromptVersion(
                promptItemId: item.id,
                version: nextVersionName(after: item.versions),
                prompt: input.prompt ?? current?.prompt ?? "",
                negativePrompt: input.negativePrompt ?? current?.negativePrompt ?? "",
                parameters: current?.parameters ?? [:],
                note: "Updated by agent"
            )
            item.versions.append(version)
        }
        item.updatedAt = Date()
        try repository.saveItem(item)
        return item
    }

    @discardableResult
    public func addTags(itemID: String, tags: [String]) throws -> PromptItem {
        var item = try item(id: itemID)
        item.tags = normalizedTags(item.tags + tags)
        item.updatedAt = Date()
        try repository.saveItem(item)
        return item
    }

    @discardableResult
    public func setFavorite(itemID: String, favorite: Bool) throws -> PromptItem {
        var item = try item(id: itemID)
        item.favorite = favorite
        item.updatedAt = Date()
        try repository.saveItem(item)
        return item
    }

    @discardableResult
    public func moveItem(itemID: String, folderID: String) throws -> PromptItem {
        let folder = try resolveFolder(folderID)
        guard let folder else { throw AutomationServiceError.folderNotFound(folderID) }
        var item = try item(id: itemID)
        item.folderId = folder.id
        item.folderName = folder.name
        item.updatedAt = Date()
        try repository.saveItem(item)
        return item
    }

    public func markDeleted(itemID: String) throws {
        _ = try item(id: itemID)
        try repository.markDeleted(itemID: itemID, deletedAt: Date())
    }

    public func restore(itemID: String) throws {
        _ = try item(id: itemID)
        try repository.markDeleted(itemID: itemID, deletedAt: nil)
    }

    @discardableResult
    public func importFiles(paths: [String], folderID: String? = nil) throws -> [PromptItem] {
        let folder = try resolveFolder(folderID)
        var imported: [PromptItem] = []
        for path in paths {
            let source = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw AutomationServiceError.fileNotFound(path)
            }
            let assetKind = AssetKind.infer(fileExtension: source.pathExtension)
            let model = try defaultModel(for: assetKind)
            let destination = try repository.copyAssetIntoLibrary(from: source, assetKind: assetKind)
            let metadata = parsedMetadata(for: destination, assetKind: assetKind)
            let info = fileInfo(for: destination, assetKind: assetKind)
            let id = UUID().uuidString
            let version = PromptVersion(
                promptItemId: id,
                version: "V1.0",
                prompt: metadata.prompt,
                negativePrompt: metadata.negativePrompt,
                parameters: metadata.parameters,
                note: "Imported by agent"
            )
            let item = PromptItem(
                id: id,
                title: source.deletingPathExtension().lastPathComponent,
                type: assetKind.promptType,
                assetKind: assetKind,
                modelId: model.id,
                modelName: model.name,
                folderId: folder?.id ?? "",
                folderName: folder?.name ?? "未分类",
                category: assetKind.displayName,
                assetPath: destination.path,
                thumbnailPath: destination.path,
                aspectRatio: normalizedAspectRatio(width: info.width, height: info.height),
                width: info.width,
                height: info.height,
                format: info.format,
                fileSize: info.fileSize,
                sortOrder: try nextTopSortOrder() - imported.count,
                tags: normalizedTags(metadata.tags),
                versions: metadata.prompt.isEmpty && metadata.negativePrompt.isEmpty ? [] : [version],
                description: assetKind.displayName
            )
            try repository.saveItem(item)
            imported.append(item)
        }
        return imported
    }

    public func markdownExportText(for itemID: String) throws -> String {
        let item = try item(id: itemID)
        return """
        # \(item.title)

        Model: \(item.modelName)
        Type: \(item.assetKind.displayName)
        Size: \(item.displaySize)

        ## Prompt
        \(item.currentVersion?.prompt ?? "")

        ## Negative Prompt
        \(item.currentVersion?.negativePrompt ?? "")
        """
    }

    private func ensureCaptureModel(for type: PromptType = .text) throws -> ModelProfile {
        let id = "unspecified_\(type.rawValue)"
        let canonical = ModelProfile(id: id, name: "未指定模型", type: type, parameters: [])
        if let existing = try repository.loadModelProfiles().first(where: { $0.id == id }) {
            if existing != canonical {
                try repository.saveModelProfile(canonical)
            }
            return canonical
        }
        try repository.saveModelProfile(canonical)
        return canonical
    }

    private func assetKind(for type: PromptType) -> AssetKind {
        switch type {
        case .image:
            .image
        case .video:
            .video
        case .audio:
            .audio
        case .text:
            .markdown
        }
    }

    private func ensureCaptureFolder() throws -> LibraryFolder {
        let id = "folder-capture-inbox"
        if let existing = try repository.loadFolders().first(where: { $0.id == id }) {
            var canonical = existing
            canonical.name = "待整理"
            canonical.parentId = nil
            canonical.type = .text
            if canonical != existing {
                try repository.saveFolder(canonical)
            }
            return canonical
        }
        let sortOrder = ((try repository.loadFolders()).map(\.sortOrder).max() ?? 0) + 1
        let folder = LibraryFolder(id: id, name: "待整理", parentId: nil, type: .text, sortOrder: sortOrder)
        try repository.saveFolder(folder)
        return folder
    }

    private func captureTitle(from text: String) -> String {
        let lines = text.components(separatedBy: CharacterSet.newlines)
        for line in lines {
            let normalized = line.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if !normalized.isEmpty {
                return String(normalized.prefix(40))
            }
        }
        return "网页采集"
    }

    private func removeGeneratedAsset(at url: URL?) {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func defaultModel(for assetKind: AssetKind) throws -> ModelProfile {
        let models = try repository.loadModelProfiles()
        let preferredID: String
        let fallback: ModelProfile
        switch assetKind {
        case .image:
            preferredID = "nano_banana_2"
            fallback = ModelProfile(id: preferredID, name: "Nano Banana 2", type: .image, parameters: [])
        case .video:
            preferredID = "seedance_2"
            fallback = ModelProfile(id: preferredID, name: "Seedance 2.0", type: .video, parameters: [])
        case .audio:
            preferredID = "local_asset"
            fallback = ModelProfile(id: preferredID, name: "Local Asset", type: .audio, parameters: [])
        case .markdown, .json, .document, .text, .data, .source, .raw, .threeD, .texture, .font, .web, .unknown:
            preferredID = "local_asset"
            fallback = ModelProfile(id: preferredID, name: "Local Asset", type: .text, parameters: [])
        }
        return models.first { $0.id == preferredID }
            ?? models.first { $0.type == fallback.type }
            ?? fallback
    }

    private func resolveFolder(_ folderID: String?) throws -> LibraryFolder? {
        guard let folderID, !folderID.isEmpty else { return nil }
        guard let folder = try repository.loadFolders().first(where: { $0.id == folderID }) else {
            throw AutomationServiceError.folderNotFound(folderID)
        }
        return folder
    }

    private func nextTopSortOrder() throws -> Int {
        ((try repository.loadItems()).map(\.sortOrder).min() ?? 0) - 1
    }

    private func nextVersionName(after versions: [PromptVersion]) -> String {
        "V1.\(versions.count)"
    }

    private func parsedMetadata(for url: URL, assetKind: AssetKind) -> ParsedPromptMetadata {
        let support = AssetFormatCatalog.support(forFileExtension: url.pathExtension)
        guard assetKind.isTextDocumentLike || support.canExtractPrompt,
              let text = DocumentTextExtractor.readText(from: url) ?? readTextFile(url) else {
            return ParsedPromptMetadata()
        }
        return PromptImportParser.parse(text: text, assetKind: assetKind)
    }

    private func readTextFile(_ url: URL) -> String? {
        let maxBytes = 2 * 1024 * 1024
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]), data.count <= maxBytes else {
            return nil
        }
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        if let text = String(data: data, encoding: .utf16) {
            return text
        }
        return String(data: data, encoding: .isoLatin1)
    }

    private func fileInfo(for url: URL, assetKind: AssetKind) -> (width: Int, height: Int, fileSize: Int64, format: String) {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        let fileSize = Int64(values?.fileSize ?? 0)
        let format = url.pathExtension.uppercased()
        if assetKind == .image, let size = imageSize(for: url) {
            return (size.width, size.height, fileSize, format.isEmpty ? "IMAGE" : format)
        }
        if assetKind == .video, let size = videoSize(for: url) {
            return (size.width, size.height, fileSize, format.isEmpty ? "VIDEO" : format)
        }
        return (0, 0, fileSize, format.isEmpty ? "FILE" : format)
    }

    private func imageSize(for url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0,
              height > 0 else {
            return nil
        }
        return (width, height)
    }

    private func videoSize(for url: URL) -> (width: Int, height: Int)? {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else { return nil }
        let transformedSize = track.naturalSize.applying(track.preferredTransform)
        let width = Int(abs(transformedSize.width).rounded())
        let height = Int(abs(transformedSize.height).rounded())
        guard width > 0, height > 0 else { return nil }
        return (width, height)
    }

    private func normalizedAspectRatio(width: Int, height: Int) -> String {
        guard width > 0, height > 0 else { return "" }
        var a = abs(width)
        var b = abs(height)
        while b != 0 {
            let remainder = a % b
            a = b
            b = remainder
        }
        let divisor = max(a, 1)
        return "\(width / divisor):\(height / divisor)"
    }

    private func normalizedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.compactMap { raw in
            let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty, seen.insert(tag).inserted else { return nil }
            return tag
        }
    }
}
