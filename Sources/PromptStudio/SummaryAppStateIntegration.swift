import AppKit
import SwiftUI
import PromptStudioCore

/// Runtime evidence for the Summary startup boundary. Normal Summary startup
/// must not call the legacy full-item loader; the explicit legacy escape hatch
/// is the only production path that increments this counter.
enum SummaryStartupBoundaryInstrumentation {
    struct Observation: Sendable {
        private let libraryURL: URL
        private let baseline: Int

        fileprivate init(libraryURL: URL, baseline: Int) {
            self.libraryURL = libraryURL
            self.baseline = baseline
        }

        var delta: Int {
            SummaryStartupBoundaryInstrumentation.legacyLoadCount(for: libraryURL) - baseline
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var legacyLoadCountStorage = 0
    nonisolated(unsafe) private static var legacyLoadCountByLibrary: [String: Int] = [:]

    static var legacyLoadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return legacyLoadCountStorage
    }

    static func legacyLoadCount(for libraryURL: URL) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return legacyLoadCountByLibrary[key(for: libraryURL), default: 0]
    }

    static func beginObservation(for libraryURL: URL) -> Observation {
        Observation(libraryURL: libraryURL, baseline: legacyLoadCount(for: libraryURL))
    }

    static func recordLegacyLoad(for libraryURL: URL) {
        lock.lock()
        legacyLoadCountStorage += 1
        let libraryKey = key(for: libraryURL)
        legacyLoadCountByLibrary[libraryKey, default: 0] += 1
        lock.unlock()
    }

    private static func key(for libraryURL: URL) -> String {
        libraryURL.standardizedFileURL.path
    }
}

enum SummaryItemContextAction: String, CaseIterable, Identifiable {
    case preview
    case openDefaultApplication
    case revealInFinder
    case edit
    case copyPrompt
    case copyFile
    case copyFilePath
    case export
    case move
    case history
    case references
    case variants
    case restore
    case trash
    case permanentDelete

    var id: String { rawValue }

    var title: String {
        switch self {
        case .preview: "预览"
        case .openDefaultApplication: "用默认应用打开"
        case .revealInFinder: "在 Finder 中显示"
        case .edit: "编辑 Prompt"
        case .copyPrompt: "复制提示词"
        case .copyFile: "复制文件"
        case .copyFilePath: "复制文件路径"
        case .export: "导出"
        case .move: "移动到文件夹"
        case .history: "历史版本"
        case .references: "参考资产管理"
        case .variants: "变体管理"
        case .restore: "恢复"
        case .trash: "移到回收站"
        case .permanentDelete: "彻底删除..."
        }
    }
}

struct SummaryItemContextCapability: Identifiable, Equatable {
    let action: SummaryItemContextAction
    let enabled: Bool
    let reason: String?

    var id: String { action.id }
    var title: String { action.title }
}

enum SummaryFolderContextAction: String, CaseIterable, Identifiable {
    case open
    case importAssets
    case export
    case createSibling
    case createChild
    case rename
    case move
    case delete

    var id: String { rawValue }

    var title: String {
        switch self {
        case .open: "打开文件夹"
        case .importAssets: "导入到此文件夹"
        case .export: "导出文件夹内容"
        case .createSibling: "新建同级文件夹"
        case .createChild: "新建子文件夹"
        case .rename: "重命名文件夹"
        case .move: "移动文件夹"
        case .delete: "删除文件夹..."
        }
    }
}

struct SummaryFolderContextCapability: Identifiable, Equatable {
    let action: SummaryFolderContextAction
    let enabled: Bool
    let reason: String?

    var id: String { action.id }
    var title: String { action.title }
}

/// Menu targets are retained by NSMenuItem.representedObject, so an AppKit
/// context menu remains ID-native after its originating card is recycled.
final class SummaryIDContextMenuTarget: NSObject {
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    @objc func run() {
        action()
    }
}

/// Identity-only actions shared by Summary List and Summary Masonry.  These
/// methods intentionally do not accept PromptItem, so UI selection and folder
/// drops cannot hydrate a full legacy row as an accidental side effect.
@MainActor
extension AppState {
#if DEBUG
    func waitForSummaryMutationRefreshForTesting() async {
        guard summaryPaginator?.hasCommittedQuery == true else { return }
        for _ in 0..<100 {
            if let task = summaryMutationRefreshTask {
                await task.value
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }
#endif

    var summaryItems: [LibraryItemSummary] {
        summaryPaginator?.summaries ?? []
    }

    var summaryIsLoading: Bool {
        summaryPaginator?.isLoading ?? false
    }

    var summaryError: LibrarySummaryPaginator.ErrorState? {
        summaryPaginator?.error
    }

    func refreshSummaryPage(for filter: PromptFilter) {
        guard let paginator = summaryPaginator else { return }
        let requestedFilter = filter
        Task { @MainActor [weak paginator] in
            await paginator?.replace(filter: requestedFilter)
        }
    }

    /// Generic repository mutations reload the legacy item array, folders, or
    /// tags.  Summary is an independent ID-only query, so those notifications
    /// must also advance its revision and replace the resident keyset page.
    /// The didSet hooks register the replacement on the same MainActor turn;
    /// the generation/cancellation guard folds a reload's folders/items/tags
    /// notifications into one authoritative replacement.
    func enqueueSummaryMutationRefresh() {
        scheduleSummaryMutationRefresh()
    }

    private func scheduleSummaryMutationRefresh() {
        guard let paginator = summaryPaginator, paginator.hasCommittedQuery else { return }
        summaryMutationRefreshGeneration &+= 1
        let generation = summaryMutationRefreshGeneration
        summaryMutationRefreshTask?.cancel()
        summaryMutationRefreshTask = Task { @MainActor [weak self, weak paginator] in
            guard !Task.isCancelled, self?.summaryMutationRefreshGeneration == generation else { return }
            await paginator?.refreshAfterMutation()
            if self?.summaryMutationRefreshGeneration == generation {
                self?.summaryMutationRefreshTask = nil
            }
        }
    }

    func retrySummaryPage() {
        guard let paginator = summaryPaginator else { return }
        summaryRetryTask?.cancel()
        summaryRetryTask = Task { @MainActor [weak self, weak paginator] in
            await paginator?.retry()
            if !Task.isCancelled {
                self?.summaryRetryTask = nil
            }
        }
    }

#if DEBUG
    func waitForSummaryRetryForTesting() async {
        await summaryRetryTask?.value
    }
#endif

    func appendSummaryPage() {
        guard let paginator = summaryPaginator else { return }
        Task { @MainActor [weak paginator] in
            await paginator?.loadNextPage()
        }
    }

    func prefetchSummaryPage(visibleRect: CGRect, contentHeight: CGFloat) {
        guard let paginator = summaryPaginator else { return }
        Task { @MainActor [weak paginator] in
            await paginator?.prefetchIfNeeded(visibleRect: visibleRect, contentHeight: contentHeight)
        }
    }

    func selectSummaryItem(
        id: String,
        modifiers: NSEvent.ModifierFlags = [],
        visualIDs: [String]? = nil
    ) {
        let visibleIDs = visualIDs ?? summaryItems.map(\.id)
        let next = selectionIDs(
            clickedID: id,
            modifiers: modifiers,
            existing: selectedIDs,
            primary: selectedID,
            visibleIDs: visibleIDs
        )
        clearSelectedFolder()
        selectItems(ids: next.ids, primaryID: next.primaryID)
    }

    func selectSummaryItems(_ ids: [String]) {
        let normalized = ids.reduce(into: [String]()) { result, id in
            if !result.contains(id) { result.append(id) }
        }
        clearSelectedFolder()
        guard !normalized.isEmpty else {
            selectItems(ids: [])
            return
        }
        selectItems(ids: Set(normalized), primaryID: normalized[0])
    }

    func clearSummarySelection() {
        clearSelectedFolder()
        selectItems(ids: [])
    }

    func selectSummaryFolder(
        id: String,
        modifiers: NSEvent.ModifierFlags = [],
        visualIDs: [String]? = nil
    ) {
        let visibleIDs = visualIDs ?? childFolderRowsForCurrentCollection().map(\.id)
        let next = selectionIDs(
            clickedID: id,
            modifiers: modifiers,
            existing: selectedFolderIDs,
            primary: selectedFolderID,
            visibleIDs: visibleIDs
        )
        selectFolders(ids: next.ids, primaryID: next.primaryID)
    }

    func selectSummaryFolderIDs(_ ids: [String]) {
        let normalized = ids.reduce(into: [String]()) { result, id in
            if !result.contains(id) { result.append(id) }
        }
        guard !normalized.isEmpty else {
            selectFolders(ids: [])
            return
        }
        selectFolders(ids: Set(normalized), primaryID: normalized[0])
    }

    /// Summary double-click publishes an ID-only point-preview request.  The
    /// detail host can resolve that ID through ItemDetailService; no
    /// PromptItem array lookup is performed here.
    func previewSummaryItem(id: String) {
        summaryPreviewItemID = id
        summaryPreviewPageSession?.synchronize(selectedID: id)
        // Synchronize first so a resident preview ID is selected by the
        // session exactly once; updateSelection then publishes the AppState
        // ID without reissuing the same controller request.
        selectSummaryItem(id: id)
        isPreviewPresented = true
    }

    /// Advances a Summary preview through the resident ID rail. At the tail
    /// the session owns the single next-page request and then selects the
    /// newly appended ID through the same detail controller.
    @discardableResult
    func navigateSummaryPreview(_ direction: PreviewPageNavigationDirection) async -> String? {
        guard let session = summaryPreviewPageSession else { return nil }
        return await session.navigate(direction)
    }

    /// Owns the UI task that awaits a preview tail request. Dismissal cancels
    /// this task and bumps the session generation without canceling the shared
    /// Summary browser's physical SQLite request.
    func beginSummaryPreviewNavigation(_ direction: PreviewPageNavigationDirection) {
        summaryPreviewNavigationTask?.cancel()
        summaryPreviewNavigationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.navigateSummaryPreview(direction)
            if !Task.isCancelled {
                self.summaryPreviewNavigationTask = nil
            }
        }
    }

    func enterSummaryFolder(id: String) {
        guard summaryFolder(withID: id) != nil else { return }
        setCollection(.folder(id))
    }

    func clearSummaryPreviewRequest() {
        summaryPreviewNavigationTask?.cancel()
        summaryPreviewNavigationTask = nil
        summaryPreviewItemID = nil
        summaryPreviewPageSession?.cancelNavigation()
        summaryDetailController?.cancel()
    }

    func summaryItemContextCapabilities(ids: [String]) -> [SummaryItemContextCapability] {
        let normalized = normalizedSummaryItemIDs(ids)
        let summaries = normalized.compactMap { id in summaryItems.first(where: { $0.id == id }) }
        let single = normalized.count == 1
        let singleReason = single ? nil : "需要选择单个项目"
        let hasFile = summaries.count == normalized.count && summaries.allSatisfy { !$0.assetPath.isEmpty }
        let allDeleted = !summaries.isEmpty && summaries.count == normalized.count && summaries.allSatisfy { $0.deletedAt != nil }
        let allActive = !summaries.isEmpty && summaries.count == normalized.count && summaries.allSatisfy { $0.deletedAt == nil }

        return SummaryItemContextAction.allCases.map { action in
            switch action {
            case .preview:
                return SummaryItemContextCapability(action: action, enabled: single, reason: singleReason)
            case .openDefaultApplication, .revealInFinder:
                return SummaryItemContextCapability(
                    action: action,
                    enabled: single && hasFile,
                    reason: single ? (hasFile ? nil : "当前项目没有可用素材文件") : singleReason
                )
            case .edit, .copyPrompt, .history, .references, .variants:
                return SummaryItemContextCapability(action: action, enabled: false, reason: "需要打开项目详情后使用")
            case .copyFile:
                return SummaryItemContextCapability(action: action, enabled: hasFile, reason: hasFile ? nil : "当前选择没有可用素材文件")
            case .copyFilePath:
                return SummaryItemContextCapability(
                    action: action,
                    enabled: single && hasFile,
                    reason: single ? (hasFile ? nil : "当前项目没有可用素材文件") : singleReason
                )
            case .export:
                return SummaryItemContextCapability(action: action, enabled: false, reason: "需要打开项目详情后使用")
            case .move:
                return SummaryItemContextCapability(action: action, enabled: false, reason: "请将项目拖到目标文件夹")
            case .restore:
                return SummaryItemContextCapability(action: action, enabled: allDeleted, reason: allDeleted ? nil : "仅回收站项目可恢复")
            case .trash:
                return SummaryItemContextCapability(action: action, enabled: allActive, reason: allActive ? nil : "仅活动项目可移入回收站")
            case .permanentDelete:
                return SummaryItemContextCapability(action: action, enabled: false, reason: "彻底删除需要详情数据")
            }
        }
    }

    func summaryFolderContextCapabilities(ids: [String]) -> [SummaryFolderContextCapability] {
        let normalized = normalizedSummaryFolderIDs(ids)
        let single = normalized.count == 1
        let singleReason = single ? nil : "需要选择单个文件夹"
        return SummaryFolderContextAction.allCases.map { action in
            switch action {
            case .open, .createSibling, .createChild, .rename:
                return SummaryFolderContextCapability(action: action, enabled: single, reason: singleReason)
            case .importAssets:
                return SummaryFolderContextCapability(action: action, enabled: false, reason: "请从导入面板选择目标文件夹")
            case .export:
                return SummaryFolderContextCapability(action: action, enabled: false, reason: "文件夹导出需要项目详情数据")
            case .move:
                return SummaryFolderContextCapability(action: action, enabled: false, reason: "请将文件夹拖到目标文件夹")
            case .delete:
                return SummaryFolderContextCapability(action: action, enabled: !normalized.isEmpty, reason: normalized.isEmpty ? "未选择文件夹" : nil)
            }
        }
    }

    func performSummaryItemContextAction(_ action: SummaryItemContextAction, ids: [String]) {
        let normalized = normalizedSummaryItemIDs(ids)
        guard !normalized.isEmpty else { return }
        selectItems(ids: Set(normalized), primaryID: normalized[0])
        switch action {
        case .preview:
            previewSummaryItem(id: normalized[0])
        case .openDefaultApplication:
            openSummaryItemInDefaultApplication(id: normalized[0])
        case .revealInFinder:
            revealSummaryItemInFinder(id: normalized[0])
        case .edit:
            guard normalized.count == 1, let item = promptItem(for: normalized[0]) else {
                showToast("需要选择单个项目")
                return
            }
            requestInlineEdit(item)
        case .copyPrompt:
            copySelectedPrompt()
        case .copyFile:
            copySummaryFiles(normalized)
        case .copyFilePath:
            copySummaryFilePath(normalized[0])
        case .export, .move:
            // These actions remain typed and visible as disabled capabilities
            // until their detail-dependent legacy flows gain ID-native APIs.
            break
        case .history:
            modal = .versionHistory
        case .references:
            modal = .references
        case .variants:
            modal = .variants
        case .restore:
            restoreSelected()
        case .trash:
            moveItemsToTrash(normalized)
        case .permanentDelete:
            beginPermanentDeleteSelectedTrashItems()
        }
    }

    private func copySummaryFiles(_ ids: [String]) {
        guard requireFeature(.baseCopyPrompt) else { return }
        let paths = normalizedSummaryItemIDs(ids).compactMap { id in
            summaryItems.first(where: { $0.id == id })?.assetPath
        }.filter { !$0.isEmpty }
        guard !paths.isEmpty else {
            showToast("当前项目没有可用素材文件")
            return
        }
        guard AppKitBridge.copyFilesToPasteboard(paths: paths) else {
            showToast("源文件不存在")
            return
        }
        showToast(paths.count > 1 ? "已复制 \(paths.count) 个文件" : "已复制文件")
    }

    private func copySummaryFilePath(_ id: String) {
        guard requireFeature(.baseCopyPrompt),
              let path = summaryItems.first(where: { $0.id == id })?.assetPath,
              !path.isEmpty else {
            showToast("当前项目没有可用素材文件")
            return
        }
        AppKitBridge.copyToPasteboard(path)
        showToast("已复制文件路径")
    }

    func performSummaryFolderContextAction(_ action: SummaryFolderContextAction, ids: [String]) {
        let normalized = normalizedSummaryFolderIDs(ids)
        guard !normalized.isEmpty else { return }
        selectFolders(ids: Set(normalized), primaryID: normalized[0])
        switch action {
        case .open:
            guard normalized.count == 1 else { return }
            enterSummaryFolder(id: normalized[0])
        case .importAssets, .export:
            // Folder import/export are represented explicitly so Summary does
            // not silently drop legacy actions. Their current legacy flows
            // require a full detail selection and are therefore disabled.
            break
        case .createSibling:
            guard normalized.count == 1, let folder = summaryFolder(withID: normalized[0]) else { return }
            beginCreateSiblingFolder(folder)
        case .createChild:
            guard normalized.count == 1, let folder = summaryFolder(withID: normalized[0]) else { return }
            beginCreateChildFolder(folder)
        case .rename:
            guard normalized.count == 1, let folder = summaryFolder(withID: normalized[0]) else { return }
            beginRenameFolder(folder)
        case .move:
            showToast("请将文件夹拖到目标文件夹")
        case .delete:
            beginDeleteFolders(normalized)
        }
    }

    private func openSummaryItemInDefaultApplication(id: String) {
        guard requireFeature(.baseBasicExport),
              let item = summaryItems.first(where: { $0.id == id }),
              !item.assetPath.isEmpty,
              FileManager.default.fileExists(atPath: item.assetPath) else {
            showToast("源文件不存在")
            return
        }
        guard AppKitBridge.openDefaultApplication(path: item.assetPath) else {
            showToast("源文件不存在")
            return
        }
        showToast("已用默认应用打开")
    }

    private func revealSummaryItemInFinder(id: String) {
        guard requireFeature(.baseBasicExport),
              let item = summaryItems.first(where: { $0.id == id }),
              !item.assetPath.isEmpty,
              FileManager.default.fileExists(atPath: item.assetPath) else {
            showToast("源文件不存在")
            return
        }
        AppKitBridge.revealInFinder(path: item.assetPath)
    }

    func makeSummaryItemContextMenu(ids: [String]) -> NSMenu {
        let normalized = normalizedSummaryItemIDs(ids)
        selectItems(ids: Set(normalized), primaryID: normalized.first)
        let menu = NSMenu(title: "项目")
        for capability in summaryItemContextCapabilities(ids: normalized) {
            let target = SummaryIDContextMenuTarget { [weak self] in
                self?.performSummaryItemContextAction(capability.action, ids: normalized)
            }
            let title = capability.enabled || capability.reason == nil
                ? capability.title
                : "\(capability.title)（\(capability.reason!)）"
            let item = NSMenuItem(title: title, action: #selector(SummaryIDContextMenuTarget.run), keyEquivalent: "")
            item.target = target
            item.representedObject = target
            item.isEnabled = capability.enabled
            item.toolTip = capability.reason
            menu.addItem(item)
        }
        return menu
    }

    func makeSummaryFolderContextMenu(ids: [String]) -> NSMenu {
        let normalized = normalizedSummaryFolderIDs(ids)
        selectFolders(ids: Set(normalized), primaryID: normalized.first)
        let menu = NSMenu(title: "文件夹")
        for capability in summaryFolderContextCapabilities(ids: normalized) {
            let target = SummaryIDContextMenuTarget { [weak self] in
                self?.performSummaryFolderContextAction(capability.action, ids: normalized)
            }
            let title = capability.enabled || capability.reason == nil
                ? capability.title
                : "\(capability.title)（\(capability.reason!)）"
            let item = NSMenuItem(title: title, action: #selector(SummaryIDContextMenuTarget.run), keyEquivalent: "")
            item.target = target
            item.representedObject = target
            item.isEnabled = capability.enabled
            item.toolTip = capability.reason
            menu.addItem(item)
        }
        return menu
    }

    private func normalizedSummaryItemIDs(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for id in summaryItems.map(\.id).filter({ ids.contains($0) }) + ids {
            if seen.insert(id).inserted { result.append(id) }
        }
        return result
    }

    private func normalizedSummaryFolderIDs(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for id in ids {
            guard summaryFolder(withID: id) != nil, seen.insert(id).inserted else { continue }
            result.append(id)
        }
        return result
    }

    @discardableResult
    func moveSummaryItems(_ itemIDs: [String], toFolderID folderID: String) -> Bool {
        guard requireFeature(.proManageCollections),
              let repository = summaryRepository,
              let destination = summaryFolder(withID: folderID) else {
            return false
        }
        do {
            let mutationDate = Date()
            let result = try repository.updateItemFolderIDs(
                itemIDs,
                toFolderID: destination.id,
                targetFolderName: destination.name,
                updatedAt: mutationDate
            )
            guard !result.changedIDs.isEmpty else {
                showToast("所选项目已在当前文件夹")
                return true
            }
            folders = try repository.loadFolders()
            // Folder membership and updatedAt ordering can both change the
            // current keyset page. Requery against the new revision instead
            // of mutating one resident row and leaving a stale cursor/order.
            enqueueSummaryMutationRefresh()
            showToast(result.changedIDs.count > 1 ? "已移动 \(result.changedIDs.count) 个项目到 \(destination.name)" : "已移动到 \(destination.name)")
            return true
        } catch {
            modal = .error(error.localizedDescription)
            return false
        }
    }

    @discardableResult
    func moveSummaryFolders(_ folderIDs: [String], toParentID parentID: String) -> Bool {
        guard summaryFolder(withID: parentID) != nil else { return false }
        return moveFolders(folderIDs, toParentID: parentID)
    }

    private func selectionIDs(
        clickedID: String,
        modifiers: NSEvent.ModifierFlags,
        existing: Set<String>,
        primary: String?,
        visibleIDs: [String]
    ) -> (ids: Set<String>, primaryID: String?) {
        if modifiers.contains(.command) {
            var ids = existing
            if ids.remove(clickedID) == nil { ids.insert(clickedID) }
            return (ids, ids.contains(clickedID) ? clickedID : ids.min())
        }
        if modifiers.contains(.shift),
           let primary,
           let start = visibleIDs.firstIndex(of: primary),
           let end = visibleIDs.firstIndex(of: clickedID) {
            let bounds = min(start, end)...max(start, end)
            return (Set(visibleIDs[bounds]), clickedID)
        }
        return ([clickedID], clickedID)
    }
}
