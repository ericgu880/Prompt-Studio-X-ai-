import Foundation
import SwiftUI
import PromptStudioCore
import UniformTypeIdentifiers

struct ExportOptions {
    var promptMarkdown: Bool
    var pngImage: Bool
    var jpegImage: Bool

    var hasSelection: Bool {
        promptMarkdown || pngImage || jpegImage
    }
}

enum PromptStudioExportFormat: String, CaseIterable, Identifiable {
    case imagePNG
    case imageJPEG
    case imagePDF
    case promptText
    case promptMarkdown
    case promptWord

    var id: String { rawValue }

    var title: String {
        switch self {
        case .imagePNG: ".png"
        case .imageJPEG: ".jpg"
        case .imagePDF: ".pdf"
        case .promptText: ".txt"
        case .promptMarkdown: ".md"
        case .promptWord: ".docx"
        }
    }

    var fileExtension: String {
        switch self {
        case .imagePNG: "png"
        case .imageJPEG: "jpg"
        case .imagePDF: "pdf"
        case .promptText: "txt"
        case .promptMarkdown: "md"
        case .promptWord: "docx"
        }
    }

    var requiresImage: Bool {
        switch self {
        case .imagePNG, .imageJPEG, .imagePDF: true
        case .promptText, .promptMarkdown, .promptWord: false
        }
    }

    var contentType: UTType {
        switch self {
        case .imagePNG: .png
        case .imageJPEG: .jpeg
        case .imagePDF: .pdf
        case .promptText: .plainText
        case .promptMarkdown: UTType(filenameExtension: "md") ?? .plainText
        case .promptWord: UTType(filenameExtension: "docx") ?? .data
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    struct FolderRow: Identifiable, Equatable {
        let folder: LibraryFolder
        let count: Int

        var id: String { folder.id }
        var collection: LibraryCollection { .folder(folder.id) }
    }

    struct FolderTreeRow: Identifiable, Equatable {
        let folder: LibraryFolder
        let count: Int
        let level: Int
        let hasChildren: Bool
        let isExpanded: Bool

        var id: String { folder.id }
        var collection: LibraryCollection { .folder(folder.id) }
    }

    struct InspectorEditRequest: Equatable {
        let token = UUID()
        let itemID: String
    }

    struct FolderEditorRequest: Identifiable, Equatable {
        enum Mode: Equatable {
            case create(parentId: String?)
            case rename(String)
        }

        let id = UUID()
        let mode: Mode
        let title: String
        let initialName: String
        let parentName: String?
    }

    struct FolderDeleteRequest: Identifiable, Equatable {
        let id = UUID()
        let folderID: String
        let folderName: String
        let itemCount: Int
    }

    enum PromptComposerMode: Identifiable, Equatable {
        case create
        case edit(String)

        var id: String {
            switch self {
            case .create:
                "create"
            case .edit(let itemID):
                "edit-\(itemID)"
            }
        }
    }

    private struct NavigationSnapshot: Equatable {
        let filter: PromptFilter
        let selectedID: String?
    }

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
        case modelFilterManager
        case folderEditor(FolderEditorRequest)
        case folderDeleteConfirmation(FolderDeleteRequest)
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
            case .modelFilterManager: "modelFilterManager"
            case .folderEditor(let request): "folderEditor-\(request.id)"
            case .folderDeleteConfirmation(let request): "folderDelete-\(request.id)"
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
    @Published var folders: [LibraryFolder] = []
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
    @Published var isPreviewPresented = false
    @Published var promptComposerMode: PromptComposerMode?
    @Published var markdownEditorItemID: String?
    @Published var inlineRenamingFolderID: String?
    @Published var inspectorEditRequest: InspectorEditRequest?
    @Published var expandedFolderIDs: Set<String> = []
    @Published private(set) var canNavigateBack = false
    @Published private(set) var canNavigateForward = false

    private var repository: PromptRepository?
    private var itemsByID: [String: PromptItem] = [:]
    private var pendingLastUsedTask: Task<Void, Never>?
    private var thumbnailGenerationID = UUID()
    private var isBatchingFilterUpdate = false
    private var navigationBackStack: [NavigationSnapshot] = []
    private var navigationForwardStack: [NavigationSnapshot] = []

    var libraryURL: URL {
        repository?.libraryURL ?? PromptRepository.defaultLibraryURL()
    }

    var selectedItem: PromptItem? {
        selectedID.flatMap { itemsByID[$0] }
    }

    var markdownEditorItem: PromptItem? {
        markdownEditorItemID.flatMap { itemsByID[$0] }
    }

    var masonryLayoutItems: [PromptItem] { filteredItems }

    var trashCount: Int {
        items.filter(\.isDeleted).count
    }

    var favoriteCount: Int {
        items.filter { $0.favorite && !$0.isDeleted }.count
    }

    var recentCount: Int {
        items.filter { !$0.isDeleted && Self.hasRecentUse($0) }.count
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
            try repository.seedFoldersIfNeeded(SeedData.folders)
            try migrateFolderHierarchyIfNeeded(repository: repository)
            try repository.repairSeedAssetPaths(from: seedItems)
            self.repository = repository
            let persistedModels = try repository.loadModelProfiles()
            self.models = SeedData.orderedModels(persistedModels.isEmpty ? SeedData.models : persistedModels)
            self.folders = try repository.loadFolders()
            self.expandedFolderIDs = Set(self.folders.map(\.id))
            self.items = try repository.loadItems()
            try repairLegacyRecentTimestampsIfNeeded(repository: repository)
            self.tags = try repository.loadTags()
            refreshFilteredItems(selecting: filteredItems.first?.id)
            prepareMissingThumbnails()
        } catch {
            self.modal = .error(error.localizedDescription)
        }
    }

    func select(_ item: PromptItem) {
        guard selectedID != item.id else { return }
        selectedID = item.id
    }

    func openNewPromptComposer() {
        modal = nil
        isPreviewPresented = false
        markdownEditorItemID = nil
        promptComposerMode = .create
    }

    func openEditPromptComposer(for item: PromptItem? = nil) {
        let target = item ?? selectedItem
        guard let target, target.assetKind != .markdown else { return }
        if selectedID != target.id {
            select(target)
        }
        modal = nil
        isPreviewPresented = false
        markdownEditorItemID = nil
        promptComposerMode = .edit(target.id)
    }

    func closePromptComposer() {
        promptComposerMode = nil
    }

    func openMarkdownEditor(for item: PromptItem? = nil) {
        let target = item ?? selectedItem
        guard let target, target.assetKind == .markdown else { return }
        if selectedID != target.id {
            select(target)
        }
        modal = nil
        isPreviewPresented = false
        promptComposerMode = nil
        markdownEditorItemID = target.id
    }

    func closeMarkdownEditor(returnToPreview: Bool = false) {
        markdownEditorItemID = nil
        if returnToPreview {
            isPreviewPresented = true
        }
    }

    func setCollection(_ collection: LibraryCollection) {
        guard filter.collection != collection else { return }
        pushCurrentNavigationSnapshot()
        updateFilterSelectingFirst {
            filter.collection = collection
        }
    }

    func setModel(_ modelId: String?) {
        let normalizedModelID = modelId == "all" ? nil : modelId
        guard filter.modelId != normalizedModelID else { return }
        pushCurrentNavigationSnapshot()
        updateFilterSelectingFirst {
            filter.modelId = normalizedModelID
        }
    }

    func navigateBack() {
        guard let snapshot = navigationBackStack.popLast() else { return }
        navigationForwardStack.append(currentNavigationSnapshot())
        restoreNavigationSnapshot(snapshot)
        updateNavigationAvailability()
    }

    func navigateForward() {
        guard let snapshot = navigationForwardStack.popLast() else { return }
        navigationBackStack.append(currentNavigationSnapshot())
        restoreNavigationSnapshot(snapshot)
        updateNavigationAvailability()
    }

    func copySelectedPrompt() {
        guard let prompt = selectedItem?.currentVersion?.prompt.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else {
            showToast("当前素材没有 Prompt")
            return
        }
        AppKitBridge.copyToPasteboard(prompt)
        showToast("已复制提示词")
        if let id = selectedID {
            markRecentlyUsed(itemID: id)
        }
    }

    func markdownDocumentText(for item: PromptItem) -> String {
        guard item.assetKind == .markdown else { return item.currentVersion?.prompt ?? "" }
        if !item.assetPath.isEmpty,
           let text = try? String(contentsOf: URL(fileURLWithPath: item.assetPath), encoding: .utf8) {
            return text
        }
        return item.currentVersion?.prompt ?? ""
    }

    func copyMarkdownDocumentText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showToast("当前文档没有内容")
            return
        }
        AppKitBridge.copyToPasteboard(text)
        showToast("已复制文档信息")
        if let id = selectedID {
            markRecentlyUsed(itemID: id)
        }
    }

    func copyItemContent(_ item: PromptItem) {
        if item.assetKind == .markdown {
            copyMarkdownDocumentText(markdownDocumentText(for: item))
        } else {
            if selectedID != item.id {
                select(item)
            }
            copySelectedPrompt()
        }
    }

    func requestInlineEdit(_ item: PromptItem) {
        guard item.assetKind == .markdown else {
            openEditPromptComposer(for: item)
            return
        }

        openMarkdownEditor(for: item)
    }

    func openSelectedInDefaultApplication() {
        guard let item = selectedItem else { return }
        guard AppKitBridge.openDefaultApplication(path: item.assetPath) else {
            showToast("源文件不存在")
            return
        }
        markRecentlyUsed(itemID: item.id)
        showToast("已用默认应用打开")
    }

    func copySelectedFilePath() {
        guard let item = selectedItem else { return }
        AppKitBridge.copyToPasteboard(item.assetPath)
        markRecentlyUsed(itemID: item.id)
        showToast("已复制文件路径")
    }

    func copySelectedFile() {
        guard let item = selectedItem else { return }
        guard AppKitBridge.copyFileToPasteboard(path: item.assetPath) else {
            showToast("源文件不存在")
            return
        }
        markRecentlyUsed(itemID: item.id)
        showToast("已复制文件")
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

    func restoreAllTrashItems() {
        let deletedItems = items.filter(\.isDeleted)
        guard !deletedItems.isEmpty else {
            showToast("回收站为空")
            return
        }
        do {
            for item in deletedItems {
                try repository?.markDeleted(itemID: item.id, deletedAt: nil)
            }
            reload(selecting: deletedItems.first?.id)
            showToast("已还原全部项目")
        } catch {
            modal = .error(error.localizedDescription)
        }
    }

    func emptyTrash() {
        let deletedItems = items.filter(\.isDeleted)
        guard !deletedItems.isEmpty else {
            showToast("回收站为空")
            return
        }
        do {
            for item in deletedItems {
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
        if filter.collection != .recent {
            item.lastUsedAt = Date()
        }

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
        markRecentlyUsed(itemID: item.id)
    }

    func saveMarkdownDocument(_ text: String, for item: PromptItem) {
        guard var current = selectedItem, current.id == item.id else { return }
        do {
            if !current.assetPath.isEmpty {
                let url = URL(fileURLWithPath: current.assetPath)
                try text.write(to: url, atomically: true, encoding: .utf8)
                if let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber {
                    current.fileSize = size.int64Value
                }
            }
            current.updatedAt = Date()
            if filter.collection != .recent {
                current.lastUsedAt = Date()
            }
            current.versions.append(
                PromptVersion(
                    promptItemId: current.id,
                    version: nextVersion(after: current.versions.last?.version),
                    prompt: text,
                    negativePrompt: "",
                    parameters: current.currentVersion?.parameters ?? [:],
                    note: "Markdown 全窗口编辑"
                )
            )
            save(current, toast: "已保存文档信息")
            markRecentlyUsed(itemID: current.id)
        } catch {
            modal = .error("保存文档失败：\(error.localizedDescription)")
        }
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
            let assetKind: AssetKind = previewPath.isEmpty ? .text : .image
            let previewInfo = previewPath.isEmpty
                ? (width: 0, height: 0, fileSize: Int64(0), format: "PROMPT")
                : AppKitBridge.fileInfo(for: URL(fileURLWithPath: previewPath), assetKind: assetKind)
            let item = PromptItem(
                id: id,
                title: title,
                type: type,
                assetKind: assetKind,
                modelId: model.id,
                modelName: model.name,
                folderId: defaultFolder().id,
                folderName: defaultFolder().name,
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
            markRecentlyUsed(itemID: id)
            showToast("已新建 Prompt")
        } catch {
            modal = .error(error.localizedDescription)
        }
    }

    func importFiles(_ urls: [URL], targetFolderID: String? = nil, acceptedType: PromptType? = nil) {
        guard let repository else { return }
        isImporting = true
        defer { isImporting = false }
        do {
            let sourceFiles = expandedImportURLs(urls)
            var importedIDs: [String] = []
            var skippedCount = 0
            var nextSortOrder = nextSortOrderForNewItem() - max(0, sourceFiles.count - 1)
            let targetFolder = targetFolderID.flatMap(folder(withID:)) ?? currentImportFolder()
            for url in sourceFiles {
                let assetKind = AppKitBridge.assetKind(for: url)
                let type = assetKind.promptType
                if let acceptedType, !Self.assetKind(assetKind, matches: acceptedType) {
                    skippedCount += 1
                    continue
                }
                let copied = try repository.copyAssetIntoLibrary(from: url, assetKind: assetKind)
                let info = AppKitBridge.fileInfo(for: copied, assetKind: assetKind)
                let parsed = parsedPromptMetadata(for: copied, assetKind: assetKind)
                let model = defaultModel(for: assetKind)
                let id = UUID().uuidString
                let item = PromptItem(
                    id: id,
                    title: url.deletingPathExtension().lastPathComponent,
                    type: type,
                    assetKind: assetKind,
                    modelId: model.id,
                    modelName: model.name,
                    folderId: targetFolder.id,
                    folderName: targetFolder.name,
                    category: assetKind.displayName,
                    assetPath: copied.path,
                    aspectRatio: Self.normalizedAspectRatio(width: info.width, height: info.height),
                    width: info.width,
                    height: info.height,
                    format: info.format,
                    fileSize: info.fileSize,
                    sortOrder: nextSortOrder,
                    tags: parsed.tags,
                    versions: [
                        PromptVersion(
                            promptItemId: id,
                            version: "V1.0",
                            prompt: parsed.prompt,
                            negativePrompt: parsed.negativePrompt,
                            parameters: parsed.parameters,
                            note: parsed.prompt.isEmpty ? "导入后待完善" : "导入时自动识别"
                        )
                    ],
                    description: "从 Finder 导入 · \(assetKind.displayName)"
                )
                nextSortOrder += 1
                try repository.saveItem(item)
                importedIDs.append(id)
            }
            guard !importedIDs.isEmpty else {
                showToast(skippedCount > 0 ? "没有符合当前文件夹类型的素材" : "未导入素材")
                return
            }
            if let firstImportedID = importedIDs.first {
                reload(selecting: firstImportedID)
                ensureImportedItemVisible(firstImportedID)
            }
            prepareMissingThumbnails()
            showToast(skippedCount > 0 ? "导入完成，已跳过 \(skippedCount) 个不匹配文件" : "导入完成")
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
                let promptTarget = uniqueExportURL(in: directory, baseName: "\(baseName)-提示词", extension: "md")
                try overwriteText(markdownPrompt(for: item), to: promptTarget)
                exportedCount += 1
            }

            if options.pngImage {
                guard item.assetKind == .image else {
                    throw CocoaError(.fileReadUnsupportedScheme)
                }
                guard FileManager.default.fileExists(atPath: source.path) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                let target = uniqueExportURL(in: directory, baseName: baseName, extension: "png")
                try overwriteImage(from: source, to: target, format: .png)
                exportedCount += 1
            }

            if options.jpegImage {
                guard item.assetKind == .image else {
                    throw CocoaError(.fileReadUnsupportedScheme)
                }
                guard FileManager.default.fileExists(atPath: source.path) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                let target = uniqueExportURL(in: directory, baseName: baseName, extension: "jpg")
                try overwriteImage(from: source, to: target, format: .jpeg)
                exportedCount += 1
            }

            markRecentlyUsed(itemID: item.id)
            showToast(exportedCount > 1 ? "已导出 \(exportedCount) 个文件" : "导出完成")
        } catch {
            modal = .error(error.localizedDescription)
        }
    }

    func exportSelected(format: PromptStudioExportFormat) {
        guard let item = selectedItem else { return }
        guard !format.requiresImage || item.assetKind == .image else {
            showToast("当前素材不是图片")
            return
        }

        let defaultName = defaultExportName(for: item, format: format)
        guard let requestedURL = AppKitBridge.chooseExportURL(defaultName: defaultName, allowedContentType: format.contentType) else { return }
        let target = uniqueExportURL(for: requestedURL)

        do {
            let source = URL(fileURLWithPath: item.assetPath)
            switch format {
            case .imagePNG:
                guard FileManager.default.fileExists(atPath: source.path) else { throw CocoaError(.fileNoSuchFile) }
                try overwriteImage(from: source, to: target, format: .png)
            case .imageJPEG:
                guard FileManager.default.fileExists(atPath: source.path) else { throw CocoaError(.fileNoSuchFile) }
                try overwriteImage(from: source, to: target, format: .jpeg)
            case .imagePDF:
                guard FileManager.default.fileExists(atPath: source.path) else { throw CocoaError(.fileNoSuchFile) }
                try AppKitBridge.writeImagePDF(from: source, to: target)
            case .promptText:
                try overwriteText(plainPrompt(for: item), to: target)
            case .promptMarkdown:
                try overwriteText(exportMarkdownText(for: item), to: target)
            case .promptWord:
                try AppKitBridge.writeDocx(text: exportMarkdownText(for: item), to: target)
            }
            markRecentlyUsed(itemID: item.id)
            showToast("导出完成")
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
        markRecentlyUsed(itemID: item.id)
    }

    func previewSelected() {
        guard let item = selectedItem else { return }
        modal = nil
        promptComposerMode = nil
        markdownEditorItemID = nil
        isPreviewPresented = true
        markRecentlyUsed(itemID: item.id)
    }

    func togglePreview() {
        if isPreviewPresented {
            isPreviewPresented = false
            return
        }

        guard modal == nil, promptComposerMode == nil, markdownEditorItemID == nil, selectedItem != nil else { return }
        previewSelected()
    }

    func moveFilteredItem(draggedID: String, before targetID: String) {
        guard draggedID != targetID else { return }
        guard filteredItems.contains(where: { $0.id == draggedID }),
              filteredItems.contains(where: { $0.id == targetID }) else {
            return
        }

        var reorderedAll = items.sorted {
            if $0.sortOrder == $1.sortOrder {
                return $0.createdAt > $1.createdAt
            }
            return $0.sortOrder < $1.sortOrder
        }
        guard let fromIndex = reorderedAll.firstIndex(where: { $0.id == draggedID }),
              let targetIndex = reorderedAll.firstIndex(where: { $0.id == targetID }) else {
            return
        }
        let moved = reorderedAll.remove(at: fromIndex)
        let adjustedTargetIndex = fromIndex < targetIndex ? max(0, targetIndex - 1) : targetIndex
        reorderedAll.insert(moved, at: adjustedTargetIndex)

        do {
            let orders = reorderedAll.enumerated().map { index, item in
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

    func moveItem(_ itemID: String, toFolderID folderID: String) {
        guard var item = itemsByID[itemID], !item.isDeleted else { return }
        guard let folder = folder(withID: folderID) else { return }
        guard item.folderId != folder.id else {
            selectedID = item.id
            showToast("素材已在当前文件夹")
            return
        }

        item.folderId = folder.id
        item.folderName = folder.name
        item.category = item.assetKind.displayName
        item.updatedAt = Date()
        save(item, toast: "已移动到 \(folder.name)")
    }

    func moveItem(_ itemID: String, toFolder folderName: String, acceptedType: PromptType?) {
        guard let folder = folders.first(where: { $0.name == folderName }) else { return }
        moveItem(itemID, toFolderID: folder.id)
    }

    func folderRows(for type: PromptType) -> [FolderRow] {
        folderRows()
    }

    func folderRows() -> [FolderRow] {
        folders
            .sorted {
                if $0.sortOrder == $1.sortOrder {
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                return $0.sortOrder < $1.sortOrder
            }
            .map { folder in
                FolderRow(
                    folder: folder,
                    count: itemCount(in: folder, includingDescendants: true)
                )
            }
    }

    func folderTreeRows() -> [FolderTreeRow] {
        let children = Dictionary(grouping: folders, by: { $0.parentId })
        func sorted(_ folders: [LibraryFolder]) -> [LibraryFolder] {
            folders.sorted {
                if $0.sortOrder == $1.sortOrder {
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                return $0.sortOrder < $1.sortOrder
            }
        }

        var rows: [FolderTreeRow] = []
        func append(parentID: String?, level: Int) {
            for folder in sorted(children[parentID] ?? []) {
                let hasChildren = !(children[folder.id] ?? []).isEmpty
                let isExpanded = expandedFolderIDs.contains(folder.id)
                rows.append(
                    FolderTreeRow(
                        folder: folder,
                        count: itemCount(in: folder, includingDescendants: true),
                        level: level,
                        hasChildren: hasChildren,
                        isExpanded: isExpanded
                    )
                )
                if hasChildren, isExpanded {
                    append(parentID: folder.id, level: level + 1)
                }
            }
        }
        append(parentID: nil, level: 0)
        return rows
    }

    func toggleFolderExpansion(_ folderID: String) {
        if expandedFolderIDs.contains(folderID) {
            expandedFolderIDs.remove(folderID)
        } else {
            expandedFolderIDs.insert(folderID)
        }
    }

    func selectFolder(_ folder: LibraryFolder) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            setCollection(.folder(folder.id))
        }
    }

    func beginCreateFolder(parentId: String? = nil) {
        let parentName = parentId.flatMap(folder(withID:))?.name
        modal = .folderEditor(
            FolderEditorRequest(
                mode: .create(parentId: parentId),
                title: parentName == nil ? "新增文件夹" : "新增子文件夹",
                initialName: "",
                parentName: parentName
            )
        )
    }

    func beginCreateFolder(type: PromptType) {
        beginCreateFolder(parentId: nil)
    }

    func beginCreateSiblingFolder(_ folder: LibraryFolder) {
        createInlineEditableFolder(parentId: folder.parentId)
    }

    func beginCreateChildFolder(_ folder: LibraryFolder) {
        expandedFolderIDs.insert(folder.id)
        createInlineEditableFolder(parentId: folder.id, insertAtTop: true)
    }

    func beginRenameFolder(_ folder: LibraryFolder) {
        selectFolder(folder)
        modal = .folderEditor(
            FolderEditorRequest(
                mode: .rename(folder.id),
                title: "重命名文件夹",
                initialName: folder.name,
                parentName: folder.parentId.flatMap(folder(withID:))?.name
            )
        )
    }

    func beginDeleteFolder(_ folder: LibraryFolder) {
        selectFolder(folder)
        modal = .folderDeleteConfirmation(
            FolderDeleteRequest(
                folderID: folder.id,
                folderName: folder.name,
                itemCount: itemCount(in: folder, includingDescendants: true)
            )
        )
    }

    @discardableResult
    func submitFolderEditor(_ request: FolderEditorRequest, name: String) -> Bool {
        switch request.mode {
        case .create(let parentId):
            return createFolder(parentId: parentId, name: name)
        case .rename(let folderID):
            return renameFolder(id: folderID, name: name)
        }
    }

    @discardableResult
    func createFolder(parentId: String?, name: String) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            showToast("文件夹名称不能为空")
            return false
        }
        guard !folders.contains(where: { $0.parentId == parentId && $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame }) else {
            showToast("同级已存在同名文件夹")
            return false
        }

        let sortOrder = (folders.filter { $0.parentId == parentId }.map(\.sortOrder).max() ?? -1) + 1
        let folder = LibraryFolder(
            id: uniqueFolderID(name: trimmedName),
            name: trimmedName,
            parentId: parentId,
            sortOrder: sortOrder
        )
        do {
            try repository?.saveFolder(folder)
            reload(selecting: selectedID)
            if let parentId {
                expandedFolderIDs.insert(parentId)
            }
            selectFolder(folder)
            showToast("已新增文件夹")
            return true
        } catch {
            modal = .error(error.localizedDescription)
            return false
        }
    }

    @discardableResult
    func createInlineEditableFolder(parentId: String?, insertAtTop: Bool = false) -> Bool {
        let name = nextDefaultFolderName(parentId: parentId)
        let siblingOrders = folders.filter { $0.parentId == parentId }.map(\.sortOrder)
        let sortOrder = insertAtTop
            ? (siblingOrders.min() ?? 0) - 1
            : (siblingOrders.max() ?? -1) + 1
        let folder = LibraryFolder(
            id: uniqueFolderID(name: name),
            name: name,
            parentId: parentId,
            sortOrder: sortOrder
        )

        do {
            try repository?.saveFolder(folder)
            if let parentId {
                expandedFolderIDs.insert(parentId)
            }
            reload(selecting: selectedID)
            selectFolder(folder)
            inlineRenamingFolderID = folder.id
            return true
        } catch {
            modal = .error(error.localizedDescription)
            return false
        }
    }

    private func nextDefaultFolderName(parentId: String?) -> String {
        let existingNames = Set(
            folders
                .filter { $0.parentId == parentId }
                .map { $0.name.lowercased() }
        )
        var index = 1
        while true {
            let name = "新建文件夹\(index)"
            if !existingNames.contains(name.lowercased()) {
                return name
            }
            index += 1
        }
    }

    @discardableResult
    func renameFolder(id: String, name: String) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            showToast("文件夹名称不能为空")
            return false
        }
        guard let folder = folders.first(where: { $0.id == id }) else { return false }
        guard !folders.contains(where: { $0.id != id && $0.parentId == folder.parentId && $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame }) else {
            showToast("同级已存在同名文件夹")
            return false
        }

        do {
            try repository?.renameFolder(id: id, name: trimmedName)
            var updatedItems = items
            var selectedAfterRename = selectedID
            for index in updatedItems.indices where updatedItems[index].folderId == folder.id {
                updatedItems[index].folderName = trimmedName
                updatedItems[index].updatedAt = Date()
                try repository?.saveItem(updatedItems[index])
                if selectedAfterRename == nil {
                    selectedAfterRename = updatedItems[index].id
                }
            }
            reload(selecting: selectedAfterRename)
            showToast("已重命名文件夹")
            return true
        } catch {
            modal = .error(error.localizedDescription)
            return false
        }
    }

    func deleteFolderMovingItemsToTrash(id: String) {
        guard let folder = folders.first(where: { $0.id == id }) else { return }
        do {
            let deletedAt = Date()
            let folderIDs = descendantFolderIDs(of: folder.id, includingSelf: true)
            for item in items where !item.isDeleted && folderIDs.contains(item.folderId) {
                try repository?.markDeleted(itemID: item.id, deletedAt: deletedAt)
            }
            try repository?.deleteFolders(ids: Array(folderIDs))
            if case .folder(let activeFolderID) = filter.collection, folderIDs.contains(activeFolderID) {
                filter.collection = .all
                filter.type = nil
            }
            reload()
            showToast("文件夹已删除，素材已移入回收站")
        } catch {
            modal = .error(error.localizedDescription)
        }
    }

    func importFiles(to folder: LibraryFolder) {
        selectFolder(folder)
        let urls = AppKitBridge.chooseImportFiles()
        guard !urls.isEmpty else { return }
        importFiles(urls, targetFolderID: folder.id)
    }

    func exportFolder(_ folderID: String) {
        guard let folder = folders.first(where: { $0.id == folderID }) else { return }
        let folderIDs = descendantFolderIDs(of: folder.id, includingSelf: true)
        let folderItems = items.filter { !$0.isDeleted && folderIDs.contains($0.folderId) }
        guard !folderItems.isEmpty else {
            showToast("文件夹为空")
            return
        }
        guard let directory = AppKitBridge.chooseExportDirectory() else { return }
        let targetDirectory = directory.appendingPathComponent(safeExportFileName(folder.name), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
            var exportedCount = 0
            for item in folderItems {
                let baseName = safeExportFileName(item.title)
                let promptTarget = uniqueExportURL(in: targetDirectory, baseName: "\(baseName)-提示词", extension: "md")
                try overwriteText(markdownPrompt(for: item), to: promptTarget)
                exportedCount += 1

                let source = URL(fileURLWithPath: item.assetPath)
                if FileManager.default.fileExists(atPath: source.path) {
                    let fileExtension = source.pathExtension.isEmpty ? item.format.lowercased() : source.pathExtension
                    let assetTarget = uniqueExportURL(in: targetDirectory, baseName: baseName, extension: fileExtension)
                    try FileManager.default.copyItem(at: source, to: assetTarget)
                    exportedCount += 1
                }
            }
            showToast("已导出 \(exportedCount) 个文件")
        } catch {
            modal = .error(error.localizedDescription)
        }
    }

    private func itemCount(in folder: LibraryFolder, includingDescendants: Bool = false) -> Int {
        let folderIDs = includingDescendants ? descendantFolderIDs(of: folder.id, includingSelf: true) : [folder.id]
        return items.filter { !$0.isDeleted && folderIDs.contains($0.folderId) }.count
    }

    func saveModelFilterLabel(id: String, name: String, type: PromptType) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            showToast("筛选标签名称不能为空")
            return
        }
        guard var model = models.first(where: { $0.id == id }), model.id != "all" else { return }
        let oldName = model.name
        model.name = trimmedName
        model.type = type
        persist(model: model, replacingItemModelName: oldName == trimmedName ? nil : trimmedName)
    }

    func createModelFilterLabel(name: String, type: PromptType) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            showToast("筛选标签名称不能为空")
            return
        }
        guard !models.contains(where: { $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame }) else {
            showToast("已存在同名筛选标签")
            return
        }

        let model = ModelProfile(
            id: uniqueModelID(for: trimmedName),
            name: trimmedName,
            type: type,
            parameters: type == .video ? ["duration", "camera", "motion"] : ["aspectRatio", "style", "seed"]
        )
        persist(model: model, replacingItemModelName: nil)
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

    private func persist(model: ModelProfile, replacingItemModelName newItemModelName: String?) {
        do {
            try repository?.saveModelProfile(model)
            if let newItemModelName {
                var updatedItems = items
                var changed = false
                for index in updatedItems.indices where updatedItems[index].modelId == model.id {
                    updatedItems[index].modelName = newItemModelName
                    updatedItems[index].updatedAt = Date()
                    try repository?.saveItem(updatedItems[index])
                    changed = true
                }
                if changed {
                    items = updatedItems
                }
            }
            let persistedModels = try repository?.loadModelProfiles() ?? models
            models = SeedData.orderedModels(persistedModels)
            refreshFilteredItems(selecting: selectedID)
            showToast("筛选标签已保存")
        } catch {
            modal = .error(error.localizedDescription)
        }
    }

    private func migrateFolderHierarchyIfNeeded(repository: PromptRepository) throws {
        var loadedFolders = try repository.loadFolders()
        if loadedFolders.isEmpty {
            try repository.seedFoldersIfNeeded(SeedData.folders)
            loadedFolders = try repository.loadFolders()
        }

        let hasLegacyTypedFolders = loadedFolders.contains { $0.type != nil }
        if hasLegacyTypedFolders {
            var keptByName: [String: LibraryFolder] = [:]
            var duplicateIDs: [String] = []

            for folder in loadedFolders.sorted(by: { $0.sortOrder < $1.sortOrder }) {
                let key = folder.name.lowercased()
                if keptByName[key] == nil {
                    var normalized = folder
                    normalized.type = nil
                    try repository.saveFolder(normalized)
                    keptByName[key] = normalized
                } else {
                    duplicateIDs.append(folder.id)
                }
            }

            if !duplicateIDs.isEmpty {
                try repository.deleteFolders(ids: duplicateIDs)
            }
            loadedFolders = try repository.loadFolders()
        }

        if !loadedFolders.contains(where: { $0.id == SeedData.uncategorizedFolderID }) {
            try repository.saveFolder(
                LibraryFolder(id: SeedData.uncategorizedFolderID, name: "未分类", sortOrder: (loadedFolders.map(\.sortOrder).max() ?? 98) + 1)
            )
            loadedFolders = try repository.loadFolders()
        }

        let foldersByID = Dictionary(uniqueKeysWithValues: loadedFolders.map { ($0.id, $0) })
        let foldersByName = Dictionary(grouping: loadedFolders, by: { $0.name.lowercased() })
        let fallback = foldersByID[SeedData.uncategorizedFolderID] ?? loadedFolders.first

        for var item in try repository.loadItems() {
            let existingFolder = foldersByID[item.folderId]
            let matchedFolder = existingFolder
                ?? foldersByName[item.folderName.lowercased()]?.first
                ?? fallback
            guard let matchedFolder else { continue }
            if item.folderId != matchedFolder.id || item.folderName != matchedFolder.name {
                item.folderId = matchedFolder.id
                item.folderName = matchedFolder.name
                item.updatedAt = Date()
                try repository.saveItem(item)
            }
        }
    }

    private func uniqueModelID(for name: String) -> String {
        let base = name
            .lowercased()
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }
            .reduce(into: "") { $0.append($1) }
            .split(separator: "_")
            .joined(separator: "_")
        let normalized = base.isEmpty ? "model" : base
        var candidate = "custom_\(normalized)"
        var index = 2
        let existingIDs = Set(models.map(\.id))
        while existingIDs.contains(candidate) {
            candidate = "custom_\(normalized)_\(index)"
            index += 1
        }
        return candidate
    }

    private func uniqueFolderID(name: String) -> String {
        let base = name
            .lowercased()
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }
            .reduce(into: "") { $0.append($1) }
            .split(separator: "_")
            .joined(separator: "_")
        let normalized = base.isEmpty ? "folder" : base
        var candidate = "folder_\(normalized)"
        var index = 2
        let existingIDs = Set(folders.map(\.id))
        while existingIDs.contains(candidate) {
            candidate = "folder_\(normalized)_\(index)"
            index += 1
        }
        return candidate
    }

    private func folder(withID id: String) -> LibraryFolder? {
        folders.first { $0.id == id }
    }

    private func descendantFolderIDs(of folderID: String, includingSelf: Bool) -> Set<String> {
        let children = Dictionary(grouping: folders, by: { $0.parentId })
        var ids = Set<String>()
        if includingSelf {
            ids.insert(folderID)
        }
        func appendChildren(of id: String) {
            for child in children[id] ?? [] {
                ids.insert(child.id)
                appendChildren(of: child.id)
            }
        }
        appendChildren(of: folderID)
        return ids
    }

    private static func assetKind(_ assetKind: AssetKind, matches promptType: PromptType) -> Bool {
        switch promptType {
        case .image:
            assetKind == .image
        case .video:
            assetKind == .video
        case .text:
            assetKind != .image && assetKind != .video
        }
    }

    private func defaultModel(for assetKind: AssetKind) -> (id: String, name: String) {
        switch assetKind {
        case .video:
            ("seedance_2", "Seedance 2.0")
        case .image:
            ("nano_banana_2", "Nano Banana 2")
        case .audio, .markdown, .json, .document, .text, .data, .unknown:
            ("local_asset", "Local Asset")
        }
    }

    private func parsedPromptMetadata(for fileURL: URL, assetKind: AssetKind) -> ParsedPromptMetadata {
        guard [.markdown, .json, .text, .data].contains(assetKind),
              let text = readTextFile(fileURL) else {
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

    private func expandedImportURLs(_ urls: [URL]) -> [URL] {
        var files: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                if let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey],
                    options: [.skipsHiddenFiles]
                ) {
                    for case let fileURL as URL in enumerator {
                        let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isHiddenKey])
                        if values?.isRegularFile == true, values?.isHidden != true {
                            files.append(fileURL)
                        }
                    }
                }
            } else {
                files.append(url)
            }
        }
        return files
    }

    private func reload(selecting id: String? = nil) {
        do {
            folders = try repository?.loadFolders() ?? []
            items = try repository?.loadItems() ?? []
            tags = try repository?.loadTags() ?? []
            refreshFilteredItems(selecting: id)
        } catch {
            modal = .error(error.localizedDescription)
        }
    }

    private func filteredItems(for filter: PromptFilter) -> [PromptItem] {
        guard case .folder(let folderID) = filter.collection else {
            return PromptFiltering.apply(items, filter: filter)
        }
        let folderIDs = descendantFolderIDs(of: folderID, includingSelf: true)
        var adjustedFilter = filter
        adjustedFilter.collection = .all
        return PromptFiltering.apply(
            items.filter { folderIDs.contains($0.folderId) },
            filter: adjustedFilter
        )
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

    private func currentNavigationSnapshot() -> NavigationSnapshot {
        NavigationSnapshot(filter: filter, selectedID: selectedID)
    }

    private func pushCurrentNavigationSnapshot() {
        let snapshot = currentNavigationSnapshot()
        guard navigationBackStack.last != snapshot else { return }
        navigationBackStack.append(snapshot)
        if navigationBackStack.count > 100 {
            navigationBackStack.removeFirst(navigationBackStack.count - 100)
        }
        navigationForwardStack.removeAll()
        updateNavigationAvailability()
    }

    private func restoreNavigationSnapshot(_ snapshot: NavigationSnapshot) {
        isBatchingFilterUpdate = true
        filter = snapshot.filter
        isBatchingFilterUpdate = false
        refreshFilteredItems(selecting: snapshot.selectedID, preserveExistingSelection: false)
    }

    private func updateNavigationAvailability() {
        canNavigateBack = !navigationBackStack.isEmpty
        canNavigateForward = !navigationForwardStack.isEmpty
    }

    private func refreshFilteredItems(selecting requestedID: String? = nil, preserveExistingSelection: Bool = true) {
        let nextFilteredItems = filteredItems(for: filter)
        filteredItems = nextFilteredItems

        if let requestedID, nextFilteredItems.contains(where: { $0.id == requestedID }) {
            selectedID = requestedID
        } else if preserveExistingSelection, let selectedID, nextFilteredItems.contains(where: { $0.id == selectedID }) {
            return
        } else {
            selectedID = nextFilteredItems.first?.id
        }
    }

    func markRecentlyUsed(itemID: String) {
        guard filter.collection != .recent else { return }
        pendingLastUsedTask?.cancel()
        pendingLastUsedTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled, let self else { return }
            let date = Date()
            do {
                try repository?.updateLastUsed(itemID: itemID, at: date)
                if let index = items.firstIndex(where: { $0.id == itemID }) {
                    items[index].lastUsedAt = date
                }
            } catch {
                showToast("最近使用更新失败")
            }
        }
    }

    private func repairLegacyRecentTimestampsIfNeeded(repository: PromptRepository) throws {
        let defaultsKey = "promptStudio.didRepairLegacyRecentTimestamps"
        guard !UserDefaults.standard.bool(forKey: defaultsKey) else { return }
        let activeItems = items.filter { !$0.isDeleted }
        guard !activeItems.isEmpty, activeItems.allSatisfy(Self.hasRecentUse) else {
            UserDefaults.standard.set(true, forKey: defaultsKey)
            return
        }

        let neverUsedDate = Date(timeIntervalSince1970: 0)
        for item in activeItems {
            try repository.updateLastUsed(itemID: item.id, at: neverUsedDate)
        }
        for index in items.indices where !items[index].isDeleted {
            items[index].lastUsedAt = neverUsedDate
        }
        UserDefaults.standard.set(true, forKey: defaultsKey)
    }

    private static func hasRecentUse(_ item: PromptItem) -> Bool {
        item.lastUsedAt.timeIntervalSince1970 > 0
    }

    private func prepareMissingThumbnails() {
        let libraryURL = libraryURL
        var candidates: [PromptItem] = []
        for item in items {
            guard item.assetKind.supportsGeneratedThumbnail else { continue }
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

    private func plainPrompt(for item: PromptItem) -> String {
        if item.assetKind == .markdown {
            return markdownDocumentText(for: item)
        }
        return """
        \(item.title)

        Model: \(item.modelName)
        Size: \(item.displaySize)

        Prompt:
        \(item.currentVersion?.prompt ?? "")

        Negative Prompt:
        \(item.currentVersion?.negativePrompt ?? "")
        """
    }

    private func exportMarkdownText(for item: PromptItem) -> String {
        item.assetKind == .markdown ? markdownDocumentText(for: item) : markdownPrompt(for: item)
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

    private func uniqueExportURL(in directory: URL, baseName: String, extension fileExtension: String) -> URL {
        let cleanExtension = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        var candidate = directory.appendingPathComponent(baseName).appendingPathExtension(cleanExtension)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName)-\(index)").appendingPathExtension(cleanExtension)
            index += 1
        }
        return candidate
    }

    private func uniqueExportURL(for requestedURL: URL) -> URL {
        let directory = requestedURL.deletingLastPathComponent()
        let fileExtension = requestedURL.pathExtension
        let baseName = requestedURL.deletingPathExtension().lastPathComponent
        return uniqueExportURL(in: directory, baseName: baseName, extension: fileExtension)
    }

    private func defaultExportName(for item: PromptItem, format: PromptStudioExportFormat) -> String {
        let baseName = safeExportFileName(item.title)
        let name = format.requiresImage ? baseName : "\(baseName)-提示词"
        return "\(name).\(format.fileExtension)"
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

    private func currentImportFolder() -> LibraryFolder {
        if case .folder(let folderID) = filter.collection, let folder = folder(withID: folderID) {
            return folder
        }
        return defaultFolder()
    }

    private func defaultFolder() -> LibraryFolder {
        folder(withID: SeedData.defaultFolderID)
            ?? folders.first(where: { $0.parentId == nil })
            ?? LibraryFolder(id: SeedData.uncategorizedFolderID, name: "未分类", sortOrder: 0)
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
