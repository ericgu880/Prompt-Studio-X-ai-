import Foundation
import SwiftUI
import PromptStudioCore

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

    @Published var items: [PromptItem] = []
    @Published var tags: [Tag] = []
    @Published var models: [ModelProfile] = SeedData.models
    @Published var filter = PromptFilter()
    @Published var selectedID: String?
    @Published var modal: Modal?
    @Published var toast: String?
    @Published var isListView = false
    @Published var isImporting = false

    private var repository: PromptRepository?

    var libraryURL: URL {
        repository?.libraryURL ?? PromptRepository.defaultLibraryURL()
    }

    var selectedItem: PromptItem? {
        items.first { $0.id == selectedID }
    }

    var filteredItems: [PromptItem] {
        PromptFiltering.apply(items, filter: filter)
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
            self.selectedID = filteredItems.first?.id
        } catch {
            self.modal = .error(error.localizedDescription)
        }
    }

    func select(_ item: PromptItem) {
        selectedID = item.id
        do {
            try repository?.updateLastUsed(itemID: item.id)
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index].lastUsedAt = Date()
            }
        } catch {
            showToast("最近使用更新失败")
        }
    }

    func setCollection(_ collection: LibraryCollection) {
        filter.collection = collection
        selectedID = filteredItems.first?.id
    }

    func setModel(_ modelId: String?) {
        filter.modelId = modelId == "all" ? nil : modelId
        selectedID = filteredItems.first?.id
    }

    func copySelectedPrompt() {
        guard let prompt = selectedItem?.currentVersion?.prompt.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else {
            showToast("当前素材没有 Prompt")
            return
        }
        AppKitBridge.copyToPasteboard(prompt)
        showToast("已复制提示词")
        if let id = selectedID {
            try? repository?.updateLastUsed(itemID: id)
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

    func createPrompt(title: String, type: PromptType, modelId: String, prompt: String, negativePrompt: String, tags: [String]) {
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
        let item = PromptItem(
            id: id,
            title: title,
            type: type,
            modelId: model.id,
            modelName: model.name,
            folderName: type == .video ? "完整项目框架开发" : "PromptStudio",
            category: type.displayName,
            assetPath: selectedItem?.assetPath ?? "",
            aspectRatio: "16:9",
            width: 1920,
            height: 1080,
            format: "PNG",
            fileSize: 0,
            favorite: false,
            tags: tags,
            versions: [version],
            description: "用户新建 Prompt"
        )
        save(item, toast: "已新建 Prompt")
        selectedID = id
    }

    func importFiles(_ urls: [URL]) {
        guard let repository else { return }
        isImporting = true
        defer { isImporting = false }
        do {
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
                    folderName: "待完善信息",
                    category: type.displayName,
                    assetPath: copied.path,
                    aspectRatio: Self.normalizedAspectRatio(width: info.width, height: info.height),
                    width: info.width,
                    height: info.height,
                    format: info.format,
                    fileSize: info.fileSize,
                    tags: ["待整理"],
                    versions: [
                        PromptVersion(promptItemId: id, version: "V1.0", prompt: "", note: "导入后待完善")
                    ],
                    description: "从 Finder 导入"
                )
                try repository.saveItem(item)
                selectedID = id
            }
            reload(selecting: selectedID)
            showToast("导入完成")
        } catch {
            modal = .error(error.localizedDescription)
        }
    }

    func exportSelected() {
        guard let item = selectedItem, let directory = AppKitBridge.chooseExportDirectory() else { return }
        do {
            let source = URL(fileURLWithPath: item.assetPath)
            if FileManager.default.fileExists(atPath: source.path) {
                let target = directory.appendingPathComponent(source.lastPathComponent)
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                try FileManager.default.copyItem(at: source, to: target)
            }
            let promptTarget = directory.appendingPathComponent(item.title + "-prompt.md")
            let promptText = """
            # \(item.title)

            Model: \(item.modelName)
            Size: \(item.displaySize)

            ## Prompt
            \(item.currentVersion?.prompt ?? "")

            ## Negative Prompt
            \(item.currentVersion?.negativePrompt ?? "")
            """
            try promptText.write(to: promptTarget, atomically: true, encoding: .utf8)
            showToast(FileManager.default.fileExists(atPath: source.path) ? "导出完成" : "源文件缺失，已导出 Prompt")
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
            if let id {
                selectedID = id
            } else if selectedID == nil || !items.contains(where: { $0.id == selectedID }) {
                selectedID = filteredItems.first?.id
            }
        } catch {
            modal = .error(error.localizedDescription)
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
}
