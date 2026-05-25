import Foundation
import SwiftUI
import PromptStudioCore

struct ExportOptions {
    var promptMarkdown: Bool
    var pngImage: Bool
    var jpegImage: Bool

    var hasSelection: Bool {
        promptMarkdown || pngImage || jpegImage
    }
}

@MainActor
final class AppState: ObservableObject {
    enum Modal: Identifiable, Equatable {
        case newPrompt
        case editPrompt
        case importAssets
        case filters
        case tagManager
        case versionHistory
        case references
        case variants
        case export
        case settings
        case preview
        case error(String)

        var id: String {
            switch self {
            case .newPrompt: "newPrompt"
            case .editPrompt: "editPrompt"
            case .importAssets: "importAssets"
            case .filters: "filters"
            case .tagManager: "tagManager"
            case .versionHistory: "versionHistory"
            case .references: "references"
            case .variants: "variants"
            case .export: "export"
            case .settings: "settings"
            case .preview: "preview"
            case .error(let message): "error-\(message)"
            }
        }
    }

    @Published var items: [PromptItem] = [] {
        didSet {
            rebuildItemLookup()
            refreshFilteredItems()
        }
    }
    @Published var tags: [Tag] = []
    @Published var models: [ModelProfile] = SeedData.models
    @Published var filter = PromptFilter() {
        didSet {
            if !isBatchingFilterUpdate {
                refreshFilteredItems()
            }
        }
    }
    @Published var selectedID: String?
    @Published private(set) var filteredItems: [PromptItem] = []
    @Published var modal: Modal?
    @Published var toast: String?
    @Published var isListView = false
    @Published var isImporting = false

    private var repository: PromptRepository?
    private var itemsByID: [String: PromptItem] = [:]
    private var pendingLastUsedTask: Task<Void, Never>?
    private var thumbnailGenerationID = UUID()
    private var isBatchingFilterUpdate = false

    var libraryURL: URL {
        repository?.libraryURL ?? PromptRepository.defaultLibraryURL()
    }

    var selectedItem: PromptItem? {
        selectedID.flatMap { itemsByID[$0] }
    }

    var masonryLayoutItems: [PromptItem] {
        var layoutFilter = filter
        layoutFilter.modelId = nil
        return PromptFiltering.apply(items, filter: layoutFilter)
    }

    var trashCount: Int {
        items.filter(\.isDeleted).count
    }

    var favoriteCount: Int {
        items.filter { $0.favorite && !$0.isDeleted }.count
    }

    func load() {
        do {
            let repository = try PromptRepository(libraryURL: PromptRepository.defaultLibraryURL())
            let seedItems = try SeedData.makePromptItems(resourceBundle: .module, libraryURL: repository.libraryURL)
            try repository.seedIfNeeded(
                items: seedItems,
                models: SeedData.models,
                tags: SeedData.tags
            )
            try repository.repairSeedAssetPaths(from: seedItems)
            self.repository = repository
            let persistedModels = try repository.loadModelProfiles()
            self.models = SeedData.orderedModels(persistedModels.isEmpty ? SeedData.models : persistedModels)
            self.items = try repository.loadItems()
            self.tags = try repository.loadTags()
            refreshFilteredItems(selecting: filteredItems.first?.id)
            prepareMissingThumbnails()
        } catch {
            self.modal = .error(error.localizedDescription)
        }
    }

    func select(_ item: PromptItem) {
        selectedID = item.id
        scheduleLastUsedUpdate(itemID: item.id)
    }

    func setCollection(_ collection: LibraryCollection) {
        updateFilterSelectingFirst {
            filter.collection = collection
        }
    }

    func setModel(_ modelId: String?) {
        updateFilterSelectingFirst {
            filter.modelId = modelId == "all" ? nil : modelId
        }
    }

    func copySelectedPrompt() {
        guard let prompt = selectedItem?.currentVersion?.prompt.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else {
            showToast("当前素材没有 Prompt")
            return
        }
        AppKitBridge.copyToPasteboard(prompt)
        showToast("已复制提示词")
        if let id = selectedID {
            scheduleLastUsedUpdate(itemID: id)
        }
    }

    func toggleFavorite(_ item: PromptItem) {
        var updated = item
        updated.favorite.toggle()
        updated.updatedAt = Date()
        save(updated, toast: updated.favorite ? "已收藏" : "已取消收藏")
    }

    func moveSelectedToTrash() {
        guard let id = selectedID else { return }
        do {
            try repository?.markDeleted(itemID: id, deletedAt: Date())
            reload(selecting: filteredItems.first(where: { $0.id != id })?.id)
            showToast("已移入回收站")
        } catch {
            modal = .error(error.localizedDescription)
        }
    }

    func restoreSelected() {
        guard let id = selectedID else { return }
        do {
            try repository?.markDeleted(itemID: id, deletedAt: nil)
            reload(selecting: id)
            showToast("已恢复")
        } catch {
            modal = .error(error.localizedDescription)
        }
    }

    func emptyTrash() {
        do {
            for item in items where item.isDeleted {
                try repository?.permanentlyDelete(itemID: item.id)
            }
            reload()
            showToast("回收站已清空")
        } catch {
            modal = .error(error.localizedDescription)
        }
    }

    func savePrompt(
        title: String,
        type: PromptType,
        modelId: String,
        prompt: String,
        negativePrompt: String,
        tags: [String],
        parameters: [String: String],
        note: String,
        saveAsNewVersion: Bool
    ) {
        guard var item = selectedItem else { return }
        item.title = title
        item.type = type
        item.modelId = modelId
        item.modelName = models.first(where: { $0.id == modelId })?.name ?? item.modelName
        item.tags = tags
        item.updatedAt = Date()
        item.lastUsedAt = Date()

        if saveAsNewVersion || item.versions.isEmpty {
            item.versions.append(
                PromptVersion(
                    promptItemId: item.id,
                    version: nextVersion(after: item.versions.last?.version),
                    prompt: prompt,
                    negativePrompt: negativePrompt,
                    parameters: parameters,
                    note: note.isEmpty ? "编辑保存" : note
                )
            )
        } else if let index = item.versions.indices.last {
            item.versions[index].prompt = prompt
            item.versions[index].negativePrompt = negativePrompt
            item.versions[index].parameters = parameters
            item.versions[index].note = note
        }

        save(item, toast: "已保存 Prompt")
    }

    func createPrompt(
        title: String,
        type: PromptType,
        modelId: String,
        prompt: String,
        negativePrompt: String,
        tags: [String],
        referenceURLs: [URL] = []
    ) {
        let model = models.first(where: { $0.id == modelId }) ?? SeedData.models[1]
        let id = UUID().uuidString
        let version = PromptVersion(
            promptItemId: id,
            version: "V1.0",
            prompt: prompt,
            negativePrompt: negativePrompt,
            parameters: ["比例": "16:9", "质量": "high"],
            note: "新建 Prompt"
        )

        do {
            let copiedReferences = try referenceURLs.map { source -> (original: URL, copied: URL) in
                let copied = try repository?.copyAssetIntoLibrary(from: source, type: .image) ?? source
                return (source, copied)
            }
            let references = copiedReferences.map { pair in
                ReferenceAsset(
                    type: pair.original.pathExtension.uppercased(),
                    path: pair.copied.path,
                    label: pair.original.deletingPathExtension().lastPathComponent
                )
            }
            let previewPath = selectedItem?.assetPath ?? copiedReferences.first?.copied.path ?? ""
            let previewInfo = previewPath.isEmpty
                ? (width: 1920, height: 1080, fileSize: Int64(0), format: "PNG")
                : AppKitBridge.imageInfo(for: URL(fileURLWithPath: previewPath))
            let item = PromptItem(
                id: id,
                title: title,
                type: type,
                modelId: model.id,
                modelName: model.name,
                folderName: type == .video ? "完整项目框架开发" : "PromptStudio",
                category: type.displayName,
                assetPath: previewPath,
                aspectRatio: Self.normalizedAspectRatio(width: previewInfo.width, height: previewInfo.height),
                width: previewInfo.width,
                height: previewInfo.height,
                format: previewInfo.format,
                fileSize: previewInfo.fileSize,
                favorite: false,
                sortOrder: nextSortOrderForNewItem(),
                tags: tags,
                referenceAssets: references,
                versions: [version],
                description: "用户新建 Prompt"
            )
            try repository?.saveItem(item)
            reload(selecting: id)
            showToast("已新建 Prompt")
        } catch {
            modal = .error(error.localizedDescription)
        }
    }

    func importFiles(_ urls: [URL], targetFolderName: String? = nil) {
        guard let repository else { return }
        isImporting = true
        defer { isImporting = false }
        do {
            var importedIDs: [String] = []
            var nextSortOrder = nextSortOrderForNewItem() - max(0, urls.count - 1)
            for url in urls {
                let isVideo = ["mp4", "mov", "webm"].contains(url.pathExtension.lowercased())
                let type: PromptType = isVideo ? .video : .image
                let copied = try repository.copyAssetIntoLibrary(from: url, type: type)
                let info = AppKitBridge.imageInfo(for: copied)
                let id = UUID().uuidString
                let item = PromptItem(
                    id: id,
                    title: url.deletingPathExtension().lastPathComponent,
                    type: type,
                    modelId: type == .video ? "seedance_2" : "nano_banana_2",
                    modelName: type == .video ? "Seedance 2.0" : "Nano Banana 2",
                    folderName: targetFolderName ?? currentImportFolderName(for: type),
                    category: type.displayName,
                    assetPath: copied.path,
                    aspectRatio: Self.normalizedAspectRatio(width: info.width, height: info.height),
                    width: info.width,
                    height: info.height,
                    format: info.format,
                    fileSize: info.fileSize,
                    sortOrder: nextSortOrder,
                    tags: ["待整理"],
                    versions: [
                        PromptVersion(promptItemId: id, version: "V1.0", prompt: "", note: "导入后待完善")
                    ],
                    description: "从 Finder 导入"
                )
                nextSortOrder += 1
                try repository.saveItem(item)
                importedIDs.append(id)
                selectedID = id
            }
            reload(selecting: selectedID)
            if let firstImportedID = importedIDs.first {
                ensureImportedItemVisible(firstImportedID)
            }
            prepareMissingThumbnails()
            showToast("导入完成")
        } catch {
            modal = .error(error.localizedDescription)
        }
    }

    func exportSelected(options: ExportOptions = ExportOptions(promptMarkdown: true, pngImage: false, jpegImage: false)) {
        guard options.hasSelection else {
            showToast("请选择导出内容")
            return
        }
        guard let item = selectedItem, let directory = AppKitBridge.chooseExportDirectory() else { return }
        do {
            let source = URL(fileURLWithPath: item.assetPath)
            let baseName = safeExportFileName(item.title)
            var exportedCount = 0

            if options.promptMarkdown {
                let promptTarget = directory.appendingPathComponent("\(baseName)-提示词.md")
                try overwriteText(markdownPrompt(for: item), to: promptTarget)
                exportedCount += 1
            }

            if options.pngImage {
                guard FileManager.default.fileExists(atPath: source.path) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                let target = directory.appendingPathComponent("\(baseName).png")
                try overwriteImage(from: source, to: target, format: .png)
                exportedCount += 1
            }

            if options.jpegImage {
                guard FileManager.default.fileExists(atPath: source.path) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                let target = directory.appendingPathComponent("\(baseName).jpg")
                try overwriteImage(from: source, to: target, format: .jpeg)
                exportedCount += 1
            }

            showToast(exportedCount > 1 ? "已导出 \(exportedCount) 个文件" : "导出完成")
        } catch {
            modal = .error(error.localizedDescription)
        }
    }

    func revealSelectedInFinder() {
        guard let item = selectedItem, FileManager.default.fileExists(atPath: item.assetPath) else {
            showToast("源文件不存在")
            return
        }
        AppKitBridge.revealInFinder(path: item.assetPath)
    }

    func previewSelected() {
        if selectedItem != nil {
            modal = .preview
        }
    }

    func togglePreview() {
        if modal == .preview {
            modal = nil
            return
        }

        guard modal == nil, selectedItem != nil else { return }
        modal = .preview
    }

    func moveFilteredItem(draggedID: String, before targetID: String) {
        guard draggedID != targetID else { return }
        guard let fromIndex = filteredItems.firstIndex(where: { $0.id == draggedID }),
              let toIndex = filteredItems.firstIndex(where: { $0.id == targetID }) else {
            return
        }

        var reorderedFiltered = filteredItems
        let moved = reorderedFiltered.remove(at: fromIndex)
        let adjustedTargetIndex = fromIndex < toIndex ? max(0, toIndex - 1) : toIndex
        reorderedFiltered.insert(moved, at: adjustedTargetIndex)

        do {
            let orders = reorderedFiltered.enumerated().map { index, item in
                (id: item.id, sortOrder: index)
            }
            try repository?.updateSortOrders(orders)
            var updatedItems = items
            let orderLookup = Dictionary(uniqueKeysWithValues: orders.map { ($0.id, $0.sortOrder) })
            for index in updatedItems.indices {
                if let sortOrder = orderLookup[updatedItems[index].id] {
                    updatedItems[index].sortOrder = sortOrder
                    updatedItems[index].updatedAt = Date()
                }
            }
            items = updatedItems
            refreshFilteredItems(selecting: draggedID)
        } catch {
            modal = .error(error.localizedDescription)
        }
    }

    func moveItem(_ itemID: String, toFolder folderName: String, acceptedType: PromptType?) {
        guard var item = itemsByID[itemID], !item.isDeleted else { return }
        if let acceptedType, item.type != acceptedType {
            showToast("只能移动同类型素材到该文件夹")
            return
        }
        guard item.folderName != folderName else {
            selectedID = item.id
            showToast("素材已在当前文件夹")
            return
        }

        item.folderName = folderName
        item.category = item.type.displayName
        item.updatedAt = Date()
        save(item, toast: "已移动到 \(folderName)")
    }

    func generateTextVariant() {
        guard var item = selectedItem, let current = item.currentVersion else { return }
        item.versions.append(
            PromptVersion(
                promptItemId: item.id,
                version: nextVersion(after: current.version),
                prompt: current.prompt + "\n\nVariant: refine composition, stronger subject separation, cleaner lighting.",
                negativePrompt: current.negativePrompt,
                parameters: current.parameters,
                note: "本地文本变体占位"
            )
        )
        save(item, toast: "已生成文本变体版本")
    }

    func restoreVersion(_ version: PromptVersion) {
        guard var item = selectedItem else { return }
        item.versions.append(
            PromptVersion(
                promptItemId: item.id,
                version: nextVersion(after: item.versions.last?.version),
                prompt: version.prompt,
                negativePrompt: version.negativePrompt,
                parameters: version.parameters,
                note: "从 \(version.version) 恢复"
            )
        )
        save(item, toast: "已恢复为新版本")
    }

    private func save(_ item: PromptItem, toast: String) {
        do {
            try repository?.saveItem(item)
            reload(selecting: item.id)
            showToast(toast)
        } catch {
            modal = .error(error.localizedDescription)
        }
    }

    private func reload(selecting id: String? = nil) {
        do {
            items = try repository?.loadItems() ?? []
            tags = try repository?.loadTags() ?? []
            refreshFilteredItems(selecting: id)
        } catch {
            modal = .error(error.localizedDescription)
        }
    }

    private func rebuildItemLookup() {
        itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
    }

    private func updateFilterSelectingFirst(_ updates: () -> Void) {
        isBatchingFilterUpdate = true
        updates()
        isBatchingFilterUpdate = false
        refreshFilteredItems(preserveExistingSelection: false)
    }

    private func refreshFilteredItems(selecting requestedID: String? = nil, preserveExistingSelection: Bool = true) {
        let nextFilteredItems = PromptFiltering.apply(items, filter: filter)
        filteredItems = nextFilteredItems

        if let requestedID, nextFilteredItems.contains(where: { $0.id == requestedID }) {
            selectedID = requestedID
        } else if preserveExistingSelection, let selectedID, nextFilteredItems.contains(where: { $0.id == selectedID }) {
            return
        } else {
            selectedID = nextFilteredItems.first?.id
        }
    }

    private func scheduleLastUsedUpdate(itemID: String) {
        pendingLastUsedTask?.cancel()
        pendingLastUsedTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled, let self else { return }
            let date = Date()
            do {
                try repository?.updateLastUsed(itemID: itemID, at: date)
                if filter.collection == .recent, let index = items.firstIndex(where: { $0.id == itemID }) {
                    items[index].lastUsedAt = date
                    refreshFilteredItems(selecting: itemID)
                }
            } catch {
                showToast("最近使用更新失败")
            }
        }
    }

    private func prepareMissingThumbnails() {
        let libraryURL = libraryURL
        var candidates: [PromptItem] = []
        for item in items {
            if ThumbnailService.existingThumbnailPath(for: item, libraryURL: libraryURL) != nil {
                continue
            }
            candidates.append(item)
        }
        guard !candidates.isEmpty else { return }
        thumbnailGenerationID = UUID()
        ThumbnailGenerationCenter.shared.start(
            candidates: candidates,
            libraryURL: libraryURL,
            generationID: thumbnailGenerationID,
            receiver: self
        )
    }

    private func applyGeneratedThumbnails(_ generated: [(String, String)]) {
        guard !generated.isEmpty else { return }
        var updatedItems = items
        var changed = false
        for (itemID, path) in generated {
            do {
                try repository?.updateThumbnailPath(itemID: itemID, thumbnailPath: path)
                if let index = updatedItems.firstIndex(where: { $0.id == itemID }) {
                    updatedItems[index].thumbnailPath = path
                    changed = true
                }
            } catch {
                showToast("缩略图更新失败")
            }
        }
        if changed {
            items = updatedItems
        }
    }

    private func showToast(_ message: String) {
        toast = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if toast == message { toast = nil }
        }
    }

    private func nextVersion(after version: String?) -> String {
        guard let version else { return "V1.0" }
        let number = version.replacingOccurrences(of: "V", with: "")
        let parts = number.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 2 else { return "V1.1" }
        return "V\(parts[0]).\(parts[1] + 1)"
    }

    private func markdownPrompt(for item: PromptItem) -> String {
        """
        # \(item.title)

        Model: \(item.modelName)
        Size: \(item.displaySize)

        ## Prompt
        \(item.currentVersion?.prompt ?? "")

        ## Negative Prompt
        \(item.currentVersion?.negativePrompt ?? "")
        """
    }

    private func overwriteText(_ text: String, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func overwriteImage(from source: URL, to target: URL, format: AppKitBridge.ImageExportFormat) throws {
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try AppKitBridge.writeImage(from: source, to: target, format: format)
    }

    private func safeExportFileName(_ name: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:")
            .union(.newlines)
            .union(.controlCharacters)
        let cleaned = name.components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "PromptStudio-Export" : cleaned
    }

    private static func normalizedAspectRatio(width: Int, height: Int) -> String {
        guard width > 0, height > 0 else { return "16:9" }
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

    private func nextSortOrderForNewItem() -> Int {
        (items.map(\.sortOrder).min() ?? 0) - 1
    }

    private func currentImportFolderName(for type: PromptType) -> String {
        if case .folder(let folderName) = filter.collection {
            return folderName
        }
        return type == .video ? "完整项目框架开发" : "PromptStudio"
    }

    private func ensureImportedItemVisible(_ itemID: String) {
        guard filteredItems.contains(where: { $0.id == itemID }) else {
            filter.query = ""
            filter.collection = .all
            filter.modelId = nil
            filter.type = nil
            filter.requiredTag = nil
            filter.favoriteOnly = false
            filter.hasPromptOnly = false
            filter.hasReferenceOnly = false
            refreshFilteredItems(selecting: itemID)
            return
        }
        selectedID = itemID
    }
}

extension AppState: ThumbnailGenerationReceiver {
    func thumbnailGenerationDidFinish(_ generated: [(String, String)], generationID: UUID) {
        guard thumbnailGenerationID == generationID else { return }
        applyGeneratedThumbnails(generated)
    }
}
