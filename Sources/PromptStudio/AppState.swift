import Foundation
import SwiftUI
import PromptStudioCore
import UniformTypeIdentifiers
import Combine

struct ExportOptions {
    var promptMarkdown: Bool
    var pngImage: Bool
    var jpegImage: Bool

    var hasSelection: Bool {
        promptMarkdown || pngImage || jpegImage
    }
}

struct ExternalFileOpenRequest: Identifiable, Equatable {
    let id = UUID()
    let urls: [URL]
}

struct TemporaryTextPreviewRequest: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let title: String
    let format: String
    let fileSize: Int64
    let text: String
}

struct MarkdownDocumentTextSnapshot: Sendable {
    let assetPath: String
    let updatedAt: Date
    let fallbackText: String

    init(item: PromptItem) {
        assetPath = item.assetPath
        updatedAt = item.updatedAt
        fallbackText = item.currentVersion?.prompt ?? ""
    }
}

actor MarkdownDocumentTextCache {
    static let shared = MarkdownDocumentTextCache()

    private static let cacheLimit = 256
    private var cachedTextByKey: [String: String] = [:]
    private var cacheKeyOrder: [String] = []

    func text(snapshot: MarkdownDocumentTextSnapshot) -> String {
        let key = "\(snapshot.assetPath)|\(snapshot.updatedAt.timeIntervalSince1970)"
        if let cached = cachedTextByKey[key] {
            markKeyUsed(key)
            return cached
        }

        let text = Self.loadText(snapshot: snapshot)
        cachedTextByKey[key] = text
        markKeyUsed(key)
        enforceCacheLimit()
        return text
    }

    private func markKeyUsed(_ key: String) {
        cacheKeyOrder.removeAll { $0 == key }
        cacheKeyOrder.append(key)
    }

    private func enforceCacheLimit() {
        while cachedTextByKey.count > Self.cacheLimit, let oldestKey = cacheKeyOrder.first {
            cacheKeyOrder.removeFirst()
            cachedTextByKey.removeValue(forKey: oldestKey)
        }
    }

    private static func loadText(snapshot: MarkdownDocumentTextSnapshot) -> String {
        if !snapshot.assetPath.isEmpty,
           let text = AppKitBridge.readDocumentText(from: URL(fileURLWithPath: snapshot.assetPath)) {
            return text
        }
        return snapshot.fallbackText
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
    private struct SelectionState: Equatable {
        var primaryID: String?
        var ids: Set<String>

        init(primaryID: String? = nil, ids: Set<String> = []) {
            self.primaryID = primaryID
            self.ids = ids
        }
    }

    struct FolderDestination: Identifiable, Equatable {
        let folderID: String
        let name: String

        var id: String { folderID }
    }

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

    struct FolderMoveDestinationRow: Identifiable, Equatable {
        let folder: LibraryFolder
        let level: Int

        var id: String { folder.id }
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
        let folderIDs: [String]
        let folderName: String
        let folderCount: Int
        let itemCount: Int
    }

    struct PermanentDeleteRequest: Identifiable, Equatable {
        let id = UUID()
        let itemIDs: Set<String>
        let itemTitle: String?

        var itemCount: Int { itemIDs.count }
    }

    struct PromptComposerPrefill: Identifiable, Equatable {
        let token: UUID
        let interpretation: PromptClipboardInterpretation

        init(interpretation: PromptClipboardInterpretation, token: UUID = UUID()) {
            self.token = token
            self.interpretation = interpretation
        }

        var id: UUID { token }
    }

    enum PromptComposerMode: Identifiable, Equatable {
        case create(prefill: PromptComposerPrefill?)
        case edit(String)

        var id: String {
            switch self {
            case .create(let prefill):
                prefill.map { "create-\($0.token.uuidString)" } ?? "create"
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
        case permanentDeleteConfirmation(PermanentDeleteRequest)
        case externalFileOpen(ExternalFileOpenRequest)
        case temporaryTextPreview(TemporaryTextPreviewRequest)
        case preview
        case featureDenied(FeatureDecision)
        case error(String)

        var id: String {
            switch self {
            case .newPrompt: "newPrompt"
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
            case .permanentDeleteConfirmation(let request): "permanentDelete-\(request.id)"
            case .externalFileOpen(let request): "externalFileOpen-\(request.id)"
            case .temporaryTextPreview(let request): "temporaryTextPreview-\(request.id)"
            case .preview: "preview"
            case .featureDenied(let decision): "featureDenied-\(decision.feature.rawValue)-\(decision.reason.map(String.init(describing:)) ?? "unknown")"
            case .error(let message): "error-\(message)"
            }
        }
    }

    let licenseManager = LicenseManager()
    let libraryFilterController = LibraryFilterController()
    let libraryStatisticsCache = LibraryStatisticsCache()
    let thumbnailUpdateState = ThumbnailUpdateState()
    let importProgressState = ImportProgressState()

    @Published var items: [PromptItem] = [] {
        didSet {
            rebuildItemLookup()
            handleItemsChanged(from: oldValue)
        }
    }
    @Published var tags: [Tag] = []
    @Published var models: [ModelProfile] = SeedData.models
    @Published var folders: [LibraryFolder] = [] {
        didSet {
            masonryDatasetRevision.folderRevision &+= 1
            libraryStatisticsCache.recomputeFolderHierarchy(folders)
        }
    }
    @Published var filter = PromptFilter() {
        didSet {
            libraryFilterController.setDraftWithoutSubmitting(filter.query)
            if !isBatchingFilterUpdate {
                refreshFilteredItems()
            }
        }
    }
    @Published private var selectionState = SelectionState()
    /// The folder currently shown in the inspector without changing the active collection.
    /// This is intentionally separate from `filter.collection`: a single click previews a
    /// folder, while double-click/arrow actions continue to enter it.
    @Published private(set) var selectedFolderIDs: Set<String> = []
    @Published private(set) var selectedFolderID: String?
    var selectedID: String? { selectionState.primaryID }
    var selectedIDs: Set<String> { selectionState.ids }

    func selectedItemIDsOrFallback(_ itemID: String) -> [String] {
        selectionActionContext(clickedItemID: itemID).orderedItemIDs
    }

    func selectionActionContext(
        clickedItemID: String,
        visualItemIDs: [String]? = nil
    ) -> PromptItemSelectionActionContext {
        let visualIDs = visualItemIDs ?? filteredItems.map(\.id)
        return PromptItemSelectionActionContext.resolve(
            clickedItemID: clickedItemID,
            selectedItemIDs: selectedIDs,
            primaryID: selectedID,
            visualItemIDs: visualIDs
        )
    }

    func folderSelectionActionContext(
        clickedFolderID: String,
        visualFolderIDs: [String]? = nil
    ) -> FolderSelectionActionContext {
        let visualIDs = visualFolderIDs ?? {
            let currentChildren = childFolderRowsForCurrentCollection().map(\.id)
            return currentChildren.isEmpty ? folderRows().map(\.id) : currentChildren
        }()
        return FolderSelectionActionContext.resolve(
            clickedFolderID: clickedFolderID,
            selectedFolderIDs: selectedFolderIDs,
            primaryID: selectedFolderID,
            visualFolderIDs: visualIDs,
            folders: folders
        )
    }

    func selectedItemsAreInFolder(_ folderID: String, fallbackItemID: String) -> Bool {
        let itemIDs = selectedItemIDsOrFallback(fallbackItemID)
        return selectedItemsAreInFolder(folderID, itemIDs: itemIDs)
    }

    func selectedItemsAreInFolder(_ folderID: String, itemIDs: [String]) -> Bool {
        let itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        return itemIDs.allSatisfy { itemsByID[$0]?.folderId == folderID }
    }

    @Published private(set) var filteredItems: [PromptItem] = []
    @Published var modal: Modal?
    @Published var toast: String?
    @Published var isListView = false
    var importProgress: MediaImportProgress? { importProgressState.progress }
    var importFailures: [MediaImportFailure] { importProgressState.failures }
    @Published var isPreviewPresented = false
    @Published var referenceLightbox: ReferenceAsset?
    @Published var promptComposerMode: PromptComposerMode?
    @Published var pendingSmartPasteRequest: PromptComposerPrefill?
    @Published var markdownEditorItemID: String?
    @Published var inlineRenamingFolderID: String?
    @Published var inspectorEditRequest: InspectorEditRequest?
    @Published var preferredSettingsPageID: String?
    @Published private(set) var pendingLicenseRecoveryToken: String?
    @Published var expandedFolderIDs: Set<String> = []
    @Published private(set) var canNavigateBack = false
    @Published private(set) var canNavigateForward = false
    @Published private(set) var libraryAccessState: LibraryAccessState = .loading

    /// The app-side adapter is intentionally a closure. PromptStudioCore owns
    /// the production capture model; this keeps the Pet target buildable while
    /// allowing the integration branch to connect `createCapturedPrompt`.
    private var petCaptureHandler: PetCaptureHandler?
    private var petImageCaptureHandler: PetImageCaptureHandler?

    private let configuredLibraryURL: URL
    private let libraryAccessCoordinator: LibraryAccessCoordinator
    private var authorizedLibraryContext: AuthorizedLibraryContext?
    private var repository: PromptRepository? {
        authorizedLibraryContext?.repository
    }
    private var itemsByID: [String: PromptItem] = [:]
    private var itemIndexByID: [String: Int] = [:]
    private var libraryFilterSnapshot: LibraryFilterSnapshot?
    private var filterTask: Task<Void, Never>?
    private var filterSnapshotTask: Task<Void, Never>?
    private var filterGeneration: UInt64 = 0
    private var thumbnailPathBatcher: ThumbnailPathBatcher?
    private var pendingLastUsedTask: Task<Void, Never>?
    private var libraryLoadTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var activeThumbnailGenerationIDs: Set<UUID> = []
    private var activeThumbnailGenerationBatches: [UUID: Set<String>] = [:]
    private var activeThumbnailItemIDs: Set<String> = []
    private var referenceThumbnailService: ReferenceThumbnailService?
    private var referenceThumbnailBackfillTask: Task<Void, Never>?
    private var referenceThumbnailPriorityTask: Task<Void, Never>?
    private var mediaImportService: MediaImportService?
    private var mediaImportTask: Task<Void, Never>?
    private var importStatusDismissTask: Task<Void, Never>?
    private var mediaImportSessionID: UUID?
    private var inspectorSelectionStartedAt: [String: Double] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var isBatchingFilterUpdate = false
    private var navigationBackStack: [NavigationSnapshot] = []
    private var navigationForwardStack: [NavigationSnapshot] = []
    private var lastExternalOpenSignature: String?
    private var lastExternalOpenAt: Date?
    private(set) var masonryDatasetRevision = MasonryDatasetRevision()

    var libraryURL: URL {
        authorizedLibraryContext?.url ?? configuredLibraryURL
    }

    var isImporting: Bool {
        mediaImportTask != nil
    }

    init(libraryURL: URL = PromptRepository.defaultLibraryURL()) {
        self.configuredLibraryURL = libraryURL
        self.libraryAccessCoordinator = LibraryAccessCoordinator(defaultURL: libraryURL)
        libraryFilterController.configure(initialQuery: "") { [weak self] query in
            guard let self, self.filter.query != query else { return }
            self.filter.query = query
        }
        licenseManager.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.objectWillChange.send()
                }
            }
            .store(in: &cancellables)
    }

    var selectedItem: PromptItem? {
        selectedID.flatMap { itemsByID[$0] }
    }

    /// Resolve composer and inspector work by stable item identity. Selection
    /// can change while a sheet is open, so edit paths must not read only the
    /// current selected item.
    func promptItem(for itemID: String) -> PromptItem? {
        itemsByID[itemID] ?? items.first(where: { $0.id == itemID })
    }

    var selectedFolder: LibraryFolder? {
        guard let selectedFolderID else { return nil }
        return folders.first { $0.id == selectedFolderID }
    }

    var masonryLayoutItems: [PromptItem] { filteredItems }

    var trashCount: Int {
        libraryStatisticsCache.statistics.trashCount
    }

    var favoriteCount: Int {
        libraryStatisticsCache.statistics.favoriteCount
    }

    var recentCount: Int {
        libraryStatisticsCache.statistics.recentCount
    }

    var isLibraryReady: Bool {
        libraryAccessState.isReady
    }

    func load() {
        startLibraryLoad { [libraryAccessCoordinator] in
            try libraryAccessCoordinator.loadInitialContext()
        }
    }

    func configurePetCaptureHandler(_ handler: @escaping PetCaptureHandler) {
        petCaptureHandler = handler
    }

    func configurePetImageCaptureHandler(_ handler: @escaping PetImageCaptureHandler) {
        petImageCaptureHandler = handler
    }

    /// Connects the desktop pet to Core's capture-only persistence API.
    ///
    /// Browser captures deliberately cannot override their folder, model, or
    /// tags here. Core owns those fixed defaults and the capture-ID based
    /// idempotency guarantee.
    func configureDefaultPetCaptureHandler() {
        petCaptureHandler = { [weak self] request in
            do {
                guard let self else { throw PetCaptureError.unavailable }
                let decision = self.licenseManager.featureGate.evaluate(.proCreatePrompt)
                guard decision.allowed else {
                    return .failed(
                        captureID: request.captureID,
                        message: decision.message ?? "当前 License 仅支持预览",
                        code: "feature-denied",
                        retryable: false
                    )
                }
                // Resolve the authorized library for every request. Users can
                // reconnect a different library while the app remains open;
                // capturing must follow that live context instead of the URL
                // that happened to be active when the handler was installed.
                let targetLibraryURL = self.libraryURL
                let service = try PromptStudioAutomationService(libraryURL: targetLibraryURL)
                let clickPoint = request.clickPoint.map {
                    WebCapturePoint(x: $0.x, y: $0.y)
                } ?? .zero
                let candidate = WebCaptureCandidate(
                    captureID: request.captureID,
                    selectedText: request.selectedText,
                    pageTitle: request.pageTitle,
                    pageURL: request.pageURL,
                    siteName: request.siteName,
                    clickScreenPoint: clickPoint,
                    capturedAt: request.capturedAt
                )
                let item = try service.createCapturedPrompt(candidate)
                self.reload(selecting: self.selectedID)
                return .saved(
                    captureID: item.captureID ?? request.captureID,
                    mouthPoint: nil
                )
            } catch {
                return .failed(
                    captureID: request.captureID,
                    message: error.localizedDescription,
                    code: "capture-save-failed",
                    retryable: true
                )
            }
        }
    }

    /// Connects image captures to Core while resolving the active library for
    /// every request. The socket/pet layer owns staged-file cleanup.
    func configureDefaultPetImageCaptureHandler() {
        petImageCaptureHandler = { [weak self] request, stagedFileURL in
            do {
                guard let self else { throw PetCaptureError.unavailable }
                let decision = self.licenseManager.featureGate.evaluate(.proCreatePrompt)
                guard decision.allowed else {
                    try? FileManager.default.removeItem(at: stagedFileURL)
                    return .failed(
                        captureID: request.captureID,
                        message: decision.message ?? "当前 License 仅支持预览",
                        code: "feature-denied",
                        retryable: false
                    )
                }
                let service = try PromptStudioAutomationService(libraryURL: self.libraryURL)
                let candidate = WebImageCaptureCandidate(
                    captureID: request.captureID,
                    domSourceKind: ImageDOMSourceKind(rawValue: request.candidate.domSourceKind) ?? .image,
                    acquisitionMethod: ImageAcquisitionMethod(rawValue: request.candidate.acquisitionMethod) ?? .pageContext,
                    sha256: request.candidate.sha256,
                    pageTitle: request.candidate.pageTitle,
                    pageURL: request.candidate.pageURL,
                    siteName: request.candidate.siteName,
                    resourceURL: request.candidate.resourceURL,
                    altText: request.candidate.altText,
                    originalFileName: request.candidate.originalFileName,
                    isScreenshot: request.candidate.isScreenshot,
                    mimeType: request.candidate.mimeType,
                    byteCount: request.candidate.byteCount,
                    pixelWidth: request.candidate.pixelWidth,
                    pixelHeight: request.candidate.pixelHeight,
                    clickScreenPoint: request.candidate.clickScreenPoint.map { WebCapturePoint(x: $0.x, y: $0.y) } ?? .zero,
                    capturedAt: request.candidate.capturedAt
                )
                let item = try service.createCapturedImage(candidate, stagedFileURL: stagedFileURL)
                self.reload(selecting: self.selectedID)
                return .saved(captureID: item.captureID ?? request.captureID, mouthPoint: nil)
            } catch {
                return .failed(
                    captureID: request.captureID,
                    message: error.localizedDescription,
                    code: "capture-save-failed",
                    retryable: true
                )
            }
        }
    }

    func handlePetCapture(_ request: PetCaptureRequest) async throws -> PetCaptureOutcome {
        guard let petCaptureHandler else {
            throw PetCaptureError.unavailable
        }
        return try await petCaptureHandler(request)
    }

    func handlePetImageCapture(_ request: PetImageCaptureRequest, stagedFileURL: URL) async throws -> PetCaptureOutcome {
        guard let petImageCaptureHandler else { throw PetCaptureError.unavailable }
        return try await petImageCaptureHandler(request, stagedFileURL)
    }

    func retryLoadLibrary() {
        load()
    }

    func reconnectExistingLibrary() {
        guard !isImporting else {
            showToast("请等待当前导入完成")
            return
        }
        let defaultURL = libraryAccessState.lastKnownURL ?? libraryAccessCoordinator.preferredPanelURL
        guard let panelURL = AppKitBridge.chooseExistingLibraryDirectory(defaultURL: defaultURL) else { return }
        startLibraryLoad { [libraryAccessCoordinator] in
            try libraryAccessCoordinator.connectExistingLibrary(fromPanelURL: panelURL)
        }
    }

    private struct LoadedLibraryData {
        let models: [ModelProfile]
        let folders: [LibraryFolder]
        let items: [PromptItem]
        let tags: [Tag]
    }

    private func startLibraryLoad(_ makeContext: @escaping () throws -> AuthorizedLibraryContext) {
        libraryLoadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        libraryAccessState = .loading

        libraryLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let context = try makeContext()
                let data = try self.loadRepositoryData(repository: context.repository)
                guard generation == self.loadGeneration, !Task.isCancelled else { return }
                self.installLibraryContext(context, data: data)
            } catch let error as LibraryLoadError {
                guard generation == self.loadGeneration, !Task.isCancelled else { return }
                self.handleLibraryLoadError(error)
            } catch {
                guard generation == self.loadGeneration, !Task.isCancelled else { return }
                self.handleLibraryLoadError(.ioFailure(nil, error.localizedDescription))
            }
        }
    }

    private func loadRepositoryData(repository: PromptRepository) throws -> LoadedLibraryData {
        let seedItems: [PromptItem]
        if AppRuntimePolicy.includesDemoLibraryContent,
           let seedBundle = Self.seedResourceBundle() {
            seedItems = try SeedData.makePromptItems(resourceBundle: seedBundle, libraryURL: repository.libraryURL)
        } else {
            seedItems = []
        }
        try repository.seedIfNeeded(
            items: seedItems,
            models: SeedData.models,
            tags: AppRuntimePolicy.includesDemoLibraryContent ? SeedData.tags : []
        )
        try repository.seedFoldersIfNeeded(initialFolders)
        try migrateFolderHierarchyIfNeeded(repository: repository)
        try repository.repairSeedAssetPaths(from: seedItems)
        let placeholderMigration = try repository.migratePromptPlaceholders()
        if placeholderMigration.migratedCount > 0 || placeholderMigration.failedCount > 0 {
            DebugPerformanceProbe.record(
                "prompt.placeholder.migration.count",
                value: Double(placeholderMigration.migratedCount)
            )
            if placeholderMigration.failedCount > 0 {
                DebugPerformanceProbe.record(
                    "prompt.placeholder.migration.failure",
                    value: Double(placeholderMigration.failedCount)
                )
            }
            print(
                "Prompt placeholder migration: migrated \(placeholderMigration.migratedCount) of "
                    + "\(placeholderMigration.candidateCount), failed \(placeholderMigration.failedCount)"
            )
        }
        let persistedModels = try repository.loadModelProfiles()
        let loadedFolders = try repository.loadFolders()
        let loadedItems = try repository.loadItems()
        try repairLegacyRecentTimestampsIfNeeded(repository: repository)
        let loadedTags = try repository.loadTags()
        return LoadedLibraryData(
            models: SeedData.orderedModels(persistedModels.isEmpty ? SeedData.models : persistedModels),
            folders: loadedFolders,
            items: loadedItems,
            tags: loadedTags
        )
    }

    private var initialFolders: [LibraryFolder] {
        if AppRuntimePolicy.includesDemoLibraryContent {
            return SeedData.folders
        }
        return [LibraryFolder(id: SeedData.uncategorizedFolderID, name: "未分类", sortOrder: 0)]
    }

    private static func seedResourceBundle() -> Bundle? {
        let bundleName = "PromptStudio_PromptStudio.bundle"
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(bundleName),
            Bundle.main.bundleURL.appendingPathComponent(bundleName),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources").appendingPathComponent(bundleName),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(bundleName),
            Bundle.main.executableURL?.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources").appendingPathComponent(bundleName)
        ]

        for candidate in candidates.compactMap({ $0 }) {
            if let bundle = Bundle(url: candidate) {
                return bundle
            }
        }
        return nil
    }

    private func installLibraryContext(_ context: AuthorizedLibraryContext, data: LoadedLibraryData) {
        stopLibraryBackgroundWork()
        authorizedLibraryContext = context
        referenceThumbnailService = ReferenceThumbnailService.shared(
            libraryURL: context.url,
            probe: { event in
                Self.recordReferenceThumbnailProbe(event)
            }
        )
        let repository = context.repository
        thumbnailPathBatcher = ThumbnailPathBatcher { [weak self] updates in
            try await Task.detached(priority: .utility) {
                try repository.updateThumbnailPaths(updates)
            }.value
            await MainActor.run {
                self?.commitThumbnailPaths(updates)
            }
        }
        mediaImportService = Self.makeMediaImportService(libraryURL: context.url)
        models = data.models
        folders = data.folders
        expandedFolderIDs = Set(data.folders.map(\.id))
        items = data.items
        tags = data.tags
        clearSelectedFolder()
        updateSelection(ids: [], primaryID: nil)
        isBatchingFilterUpdate = true
        filter = PromptFilter()
        isBatchingFilterUpdate = false
        refreshFilteredItems(preserveExistingSelection: false, allowEmptySelection: true)
        libraryAccessState = .ready(
            LibraryDescriptor(
                url: context.url,
                isSecurityScoped: context.session != nil,
                isSandboxed: libraryAccessCoordinator.isSandboxed
            )
        )
        libraryStatisticsCache.invalidate(repository: context.repository, folders: data.folders)
    }

    private func stopLibraryBackgroundWork() {
        pendingLastUsedTask?.cancel()
        pendingLastUsedTask = nil
        activeThumbnailGenerationIDs.removeAll()
        activeThumbnailGenerationBatches.removeAll()
        activeThumbnailItemIDs.removeAll()
        referenceThumbnailBackfillTask?.cancel()
        referenceThumbnailBackfillTask = nil
        referenceThumbnailPriorityTask?.cancel()
        referenceThumbnailPriorityTask = nil
        referenceThumbnailService?.cancelPendingRequests()
        referenceThumbnailService = nil
        mediaImportTask?.cancel()
        mediaImportTask = nil
        mediaImportService = nil
        importStatusDismissTask?.cancel()
        importStatusDismissTask = nil
        mediaImportSessionID = nil
        importProgressState.reset()
        filterTask?.cancel()
        filterTask = nil
        filterSnapshotTask?.cancel()
        filterSnapshotTask = nil
        libraryFilterController.cancel()
        libraryStatisticsCache.cancel()
        if let thumbnailPathBatcher {
            Task { await thumbnailPathBatcher.cancel() }
        }
        thumbnailPathBatcher = nil
        thumbnailUpdateState.reset()
    }

    private func handleLibraryLoadError(_ error: LibraryLoadError) {
        if let context = authorizedLibraryContext {
            libraryAccessState = .ready(
                LibraryDescriptor(
                    url: context.url,
                    isSecurityScoped: context.session != nil,
                    isSandboxed: libraryAccessCoordinator.isSandboxed
                )
            )
            modal = .error(error.localizedDescription)
            return
        }

        items = []
        folders = []
        tags = []
        clearSelectedFolder()
        updateSelection(ids: [], primaryID: nil)
        refreshFilteredItems(preserveExistingSelection: false, allowEmptySelection: true)

        switch error {
        case .authorizationRequired(let reason, let url):
            libraryAccessState = .needsAuthorization(reason: reason, lastKnownURL: url ?? libraryAccessCoordinator.preferredPanelURL)
        case .permissionDenied(let url, _):
            let reason: LibraryAuthorizationReason = libraryAccessCoordinator.isSandboxed
                ? .noBookmarkInSandbox
                : .permissionDenied
            libraryAccessState = .needsAuthorization(reason: reason, lastKnownURL: url ?? libraryAccessCoordinator.preferredPanelURL)
        case .bookmarkResolutionFailed:
            libraryAccessState = .needsAuthorization(
                reason: .bookmarkUnavailable,
                lastKnownURL: libraryAccessCoordinator.preferredPanelURL
            )
        case .notFound(let url, _):
            libraryAccessState = .missing(lastKnownURL: url ?? libraryAccessCoordinator.preferredPanelURL)
        case .readOnly(let url, _):
            libraryAccessState = .readOnly(url)
        case .invalidLibrary(let url, let message):
            libraryAccessState = .invalidLibrary(url, message: message)
        case .incompatibleSchema(let url, let message):
            libraryAccessState = .invalidLibrary(url, message: message)
        case .databaseCorrupted, .ioFailure, .databaseBusy, .diskFull:
            libraryAccessState = .failed(error)
        }
    }

    func select(_ item: PromptItem) {
        clearSelectedFolder()
        updateSelection(ids: [item.id], primaryID: item.id)
    }

    func toggleSelection(_ item: PromptItem) {
        clearSelectedFolder()
        var nextIDs = selectedIDs
        let nextPrimaryID: String?
        if nextIDs.remove(item.id) != nil {
            nextPrimaryID = nextIDs.first
        } else {
            nextIDs.insert(item.id)
            nextPrimaryID = item.id
        }
        updateSelection(ids: nextIDs, primaryID: nextPrimaryID)
    }

    func selectItems(ids: Set<String>, primaryID: String? = nil) {
        if !ids.isEmpty {
            clearSelectedFolder()
        }
        updateSelection(ids: ids, primaryID: primaryID)
    }

    /// Selects folders for the right inspector without navigating away from the current view.
    func selectFolders(ids: Set<String>, primaryID: String? = nil) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            selectedFolderIDs = ids
            selectedFolderID = primaryID.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
            updateSelection(ids: [], primaryID: nil)
        }
    }

    func selectFolderForPreview(_ folder: LibraryFolder) {
        selectFolders(ids: [folder.id], primaryID: folder.id)
    }

    func clearSelectedFolder() {
        guard selectedFolderID != nil || !selectedFolderIDs.isEmpty else { return }
        selectedFolderIDs = []
        selectedFolderID = nil
    }

    func folderDescendantIDs(for folderID: String) -> Set<String> {
        descendantFolderIDs(of: folderID, includingSelf: true)
    }

    func childFolders(of folderID: String) -> [LibraryFolder] {
        folders
            .filter { $0.parentId == folderID }
            .sorted {
                if $0.sortOrder == $1.sortOrder {
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                return $0.sortOrder < $1.sortOrder
            }
    }

    private func updateSelection(ids: Set<String>, primaryID: String?) {
        let normalizedPrimaryID = primaryID.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
        let nextState = SelectionState(primaryID: normalizedPrimaryID, ids: ids)
        guard nextState != selectionState else { return }
        referenceLightbox = nil
        if let normalizedPrimaryID {
            inspectorSelectionStartedAt = [normalizedPrimaryID: DebugPerformanceProbe.now()]
        } else {
            inspectorSelectionStartedAt.removeAll()
        }
        selectionState = nextState
        if let normalizedPrimaryID, let item = itemsByID[normalizedPrimaryID] {
            prioritizeReferenceThumbnails(for: item)
        }
    }

    func presentReferenceLightbox(_ reference: ReferenceAsset) {
        let fileExtension = URL(fileURLWithPath: reference.path).pathExtension
        guard AssetFormatCatalog.support(forFileExtension: fileExtension).assetKind == .image,
              FileManager.default.fileExists(atPath: reference.path) else {
            showToast("参考图文件不存在")
            return
        }
        referenceLightbox = reference
    }

    func dismissReferenceLightbox() {
        referenceLightbox = nil
    }

    func recordInspectorReady(itemID: String) {
        guard let startedAt = inspectorSelectionStartedAt.removeValue(forKey: itemID) else { return }
        DebugPerformanceProbe.recordDuration("inspector.selection.ready.ms", startedAt: startedAt)
    }

    func orderedItemIDsForDrag(startingWith itemID: String) -> [String] {
        selectionActionContext(clickedItemID: itemID).orderedItemIDs
    }

    @discardableResult
    func requireFeature(_ feature: FeatureKey) -> Bool {
        let decision = licenseManager.featureGate.evaluate(feature)
        guard decision.allowed else {
            presentFeatureDenied(decision)
            return false
        }
        return true
    }

    func presentFeatureDenied(_ decision: FeatureDecision) {
        modal = .featureDenied(decision)
    }

    func openNewPromptComposer(prefill: PromptClipboardInterpretation? = nil) {
        guard requireFeature(.proCreatePrompt) else { return }
        referenceLightbox = nil
        modal = nil
        isPreviewPresented = false
        markdownEditorItemID = nil
        pendingSmartPasteRequest = nil
        promptComposerMode = .create(prefill: prefill.map { PromptComposerPrefill(interpretation: $0) })
    }

    func consumeSmartPasteRequest(token: UUID) {
        guard pendingSmartPasteRequest?.token == token else { return }
        pendingSmartPasteRequest = nil
    }

    /// Routes the app-level paste command while preserving native text-field paste behavior.
    @MainActor
    func routePasteCommand() {
        let textInputActive = AppKitBridge.isTextInputActive()
        let fileURLs = AppKitBridge.pasteboardFileURLs()
        // Finder file pasteboards may expose a string representation on some macOS versions;
        // only consider plain text when no file payload is present outside a text editor.
        let plainText = (!fileURLs.isEmpty && !textInputActive) ? nil : AppKitBridge.pasteboardPlainText()
        switch PromptPasteRouteResolver.resolve(
            isTextInputActive: textInputActive,
            hasFileURLs: !fileURLs.isEmpty,
            plainText: plainText
        ) {
        case .nativeTextPaste:
            NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
        case .importFiles:
            importFiles(fileURLs)
        case .smartPaste(let text):
            let interpretation = PromptClipboardInterpreter.interpret(text)
            switch promptComposerMode {
            case .create:
                pendingSmartPasteRequest = PromptComposerPrefill(interpretation: interpretation)
            case .edit:
                showToast("编辑模式不支持智能粘贴")
            case nil:
                openNewPromptComposer(prefill: interpretation)
            }
        case .unavailable:
            showToast("剪贴板没有可粘贴内容")
        }
    }

    /// Reads only the plain-text pasteboard payload for the explicit smart-paste UI action.
    /// This intentionally bypasses the first responder and never imports Finder files.
    @MainActor
    func readSmartPasteFromPasteboard() -> PromptClipboardInterpretation? {
        guard AppKitBridge.pasteboardFileURLs().isEmpty else {
            showToast("剪贴板包含文件，请使用粘贴导入")
            return nil
        }
        guard let text = AppKitBridge.pasteboardPlainText(),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showToast("剪贴板没有可识别的 Prompt 文本")
            return nil
        }
        return PromptClipboardInterpreter.interpret(text)
    }

    func openEditPromptComposer(for item: PromptItem? = nil) {
        guard requireFeature(.proEditPrompt) else { return }
        let target = item ?? selectedItem
        guard let target, !target.isTextDocumentLike else { return }
        if selectedID != target.id {
            select(target)
        }
        referenceLightbox = nil
        modal = nil
        isPreviewPresented = false
        markdownEditorItemID = nil
        promptComposerMode = .edit(target.id)
    }

    func closePromptComposer() {
        pendingSmartPasteRequest = nil
        promptComposerMode = nil
    }

    func openMarkdownEditor(for item: PromptItem? = nil) {
        guard requireFeature(.proEditPrompt) else { return }
        let target = item ?? selectedItem
        guard let target, target.isTextDocumentLike else { return }
        if selectedID != target.id {
            select(target)
        }
        modal = nil
        promptComposerMode = nil
        markdownEditorItemID = target.id
        isPreviewPresented = true
    }

    func handleExternalFileOpen(_ urls: [URL]) {
        let supportedURLs = urls.filter(Self.isSupportedExternalMainAssetURL)
        guard !supportedURLs.isEmpty else {
            showToast("暂不支持打开这些文件")
            return
        }
        guard shouldHandleExternalOpen(supportedURLs) else { return }
        if repository == nil {
            load()
        }
        let matchedItems = supportedURLs.compactMap(itemMatchingExternalURL)
        if let item = matchedItems.first {
            revealAndOpenExternalItem(item)
            return
        }
        guard supportedURLs.allSatisfy(Self.isSupportedExternalTextPreviewURL) else {
            importFiles(supportedURLs)
            return
        }
        previewExternalFileTemporarily(ExternalFileOpenRequest(urls: supportedURLs))
    }

    func importExternalFiles(_ request: ExternalFileOpenRequest) {
        modal = nil
        importFiles(request.urls)
    }

    func openImportAssets() {
        guard requireFeature(.proSingleImport) else { return }
        modal = .importAssets
    }

    func openAdvancedFilters() {
        guard requireFeature(.proAdvancedSearch) else { return }
        modal = .filters
    }

    func openSettings() {
        preferredSettingsPageID = nil
        modal = .settings
    }

    func openLicenseSettings() {
        preferredSettingsPageID = "license"
        modal = .settings
    }

    @discardableResult
    func handleIncomingURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "promptstudio",
              url.host?.lowercased() == "license",
              url.path == "/recover",
              let fragment = url.fragment,
              let token = URLComponents(string: "?\(fragment)")?.queryItems?
                .first(where: { $0.name == "token" })?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            return false
        }
        pendingLicenseRecoveryToken = token
        openLicenseSettings()
        return true
    }

    func consumePendingLicenseRecoveryToken() -> String? {
        defer { pendingLicenseRecoveryToken = nil }
        return pendingLicenseRecoveryToken
    }

    func previewExternalFileTemporarily(_ request: ExternalFileOpenRequest) {
        guard let url = request.urls.first else {
            modal = nil
            return
        }
        let text = Self.readExternalText(from: url)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            modal = .error("无法读取该文本文档")
            return
        }
        let attributes = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let fileSize = attributes[.size] as? Int64 ?? 0
        modal = .temporaryTextPreview(
            TemporaryTextPreviewRequest(
                url: url,
                title: Self.cleanedTitle(from: url),
                format: url.pathExtension.uppercased(),
                fileSize: fileSize,
                text: text
            )
        )
    }

    func closeMarkdownEditor(returnToPreview: Bool = false) {
        markdownEditorItemID = nil
        if returnToPreview {
            isPreviewPresented = true
        }
    }

    func setCollection(_ collection: LibraryCollection) {
        guard filter.collection != collection else { return }
        clearSelectedFolder()
        pushCurrentNavigationSnapshot()
        updateFilterPreservingSelection { filter in
            filter.collection = collection
        }
    }

    func resetToAll() {
        guard filter != PromptFilter() else { return }
        clearSelectedFolder()
        pushCurrentNavigationSnapshot()
        updateFilterPreservingSelection { filter in
            filter = PromptFilter()
        }
    }

    func setModel(_ modelId: String?) {
        let normalizedModelID = modelId == "all" ? nil : modelId
        guard filter.modelId != normalizedModelID || filter.textFormat != nil || filter.assetKindFilter != nil || filter.requiredTag != nil else { return }
        pushCurrentNavigationSnapshot()
        updateFilterPreservingSelection { filter in
            filter.modelId = normalizedModelID
            filter.textFormat = nil
            filter.assetKindFilter = nil
            filter.requiredTag = nil
            if let normalizedModelID,
               let model = models.first(where: { $0.id == normalizedModelID }) {
                filter.type = model.type
            }
        }
    }

    func setPromptType(_ type: PromptType?) {
        guard filter.type != type || filter.modelId != nil || filter.textFormat != nil || filter.assetKindFilter != nil || filter.requiredTag != nil else { return }
        pushCurrentNavigationSnapshot()
        updateFilterPreservingSelection { filter in
            filter.type = type
            filter.requiredTag = nil
            filter.assetKindFilter = nil
            if type == nil {
                filter.modelId = nil
                filter.textFormat = nil
                return
            }
            if type != .text {
                filter.textFormat = nil
            }
            if type == .text {
                filter.modelId = nil
            } else if let modelId = filter.modelId,
                      let model = models.first(where: { $0.id == modelId }),
                      let type,
                      model.type != type {
                filter.modelId = nil
            }
        }
    }

    func setTextFormat(_ textFormat: TextFormatFilter?) {
        guard filter.textFormat != textFormat || filter.type != .text || filter.modelId != nil || filter.assetKindFilter != nil || filter.requiredTag != nil else { return }
        pushCurrentNavigationSnapshot()
        updateFilterPreservingSelection { filter in
            filter.type = .text
            filter.modelId = nil
            filter.textFormat = textFormat
            filter.assetKindFilter = nil
            filter.requiredTag = nil
        }
    }

    func setAssetKindFilter(_ assetKindFilter: AssetKindFilter?) {
        guard filter.assetKindFilter != assetKindFilter || filter.modelId != nil || filter.textFormat != nil || filter.requiredTag != nil else { return }
        pushCurrentNavigationSnapshot()
        updateFilterPreservingSelection { filter in
            filter.type = nil
            filter.modelId = nil
            filter.textFormat = nil
            filter.assetKindFilter = assetKindFilter
            filter.requiredTag = nil
        }
    }

    func setRequiredTag(_ tag: String?) {
        let normalizedTag = tag?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextTag = normalizedTag?.isEmpty == false ? normalizedTag : nil
        guard filter.requiredTag != nextTag || filter.type != nil || filter.modelId != nil || filter.textFormat != nil || filter.assetKindFilter != nil else { return }
        pushCurrentNavigationSnapshot()
        updateFilterPreservingSelection { filter in
            filter.type = nil
            filter.modelId = nil
            filter.textFormat = nil
            filter.assetKindFilter = nil
            filter.requiredTag = nextTag
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
        guard requireFeature(.baseCopyPrompt) else { return }
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

    func copyPromptFragment(_ fragment: String) {
        guard requireFeature(.baseCopyPrompt) else { return }
        let text = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        AppKitBridge.copyToPasteboard(text)
        showToast("已复制提示词")
        if let id = selectedID {
            markRecentlyUsed(itemID: id)
        }
    }

    func markdownDocumentText(for item: PromptItem) -> String {
        if !item.assetPath.isEmpty,
           let text = AppKitBridge.readDocumentText(from: URL(fileURLWithPath: item.assetPath)) {
            return text
        }
        return item.currentVersion?.prompt ?? ""
    }

    func copyMarkdownDocumentText(_ text: String) {
        guard requireFeature(.baseCopyPrompt) else { return }
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
        if item.isTextDocumentLike {
            copyMarkdownDocumentText(markdownDocumentText(for: item))
        } else {
            if selectedID != item.id {
                select(item)
            }
            copySelectedPrompt()
        }
    }

    func requestInlineEdit(_ item: PromptItem) {
        if item.isTextDocumentLike {
            openMarkdownEditor(for: item)
            return
        }

        if item.assetKind == .audio {
            // Audio prompts edit their Prompt metadata; an audio file itself
            // has no inline editor. Placeholders still open the composer.
            openEditPromptComposer(for: item)
            return
        }

        if item.assetKind == .image || item.assetKind == .video {
            openEditPromptComposer(for: item)
        }
    }

    func openSelectedInDefaultApplication() {
        guard requireFeature(.baseBasicExport) else { return }
        guard let item = selectedItem else { return }
        guard item.hasAvailablePrimaryAsset else {
            showToast("当前 Prompt 尚未添加主素材")
            return
        }
        guard AppKitBridge.openDefaultApplication(path: item.assetPath) else {
            showToast("源文件不存在")
            return
        }
        markRecentlyUsed(itemID: item.id)
        showToast("已用默认应用打开")
    }

    func copySelectedFilePath() {
        guard requireFeature(.baseCopyPrompt) else { return }
        guard let item = selectedItem else { return }
        guard item.hasAvailablePrimaryAsset else {
            showToast("当前 Prompt 尚未添加主素材")
            return
        }
        AppKitBridge.copyToPasteboard(item.assetPath)
        markRecentlyUsed(itemID: item.id)
        showToast("已复制文件路径")
    }

    func copySelectedFile() {
        copySelectedFileForPasteboard()
    }

    func copySelectedFileForPasteboard() {
        guard requireFeature(.baseCopyPrompt) else { return }
        let selectedItems = orderedSelectedItems()
        let realItems = selectedItems.filter(\.hasAvailablePrimaryAsset)
        guard !realItems.isEmpty else {
            showToast("当前 Prompt 尚未添加主素材")
            return
        }
        guard AppKitBridge.copyFilesToPasteboard(paths: realItems.map(\.assetPath)) else {
            showToast("源文件不存在")
            return
        }
        for item in realItems { markRecentlyUsed(itemID: item.id) }
        showToast(realItems.count > 1 ? "已复制 \(realItems.count) 个文件" : "已复制文件")
    }

    func pasteFilesFromPasteboard() {
        let urls = AppKitBridge.pasteboardFileURLs()
        guard !urls.isEmpty else {
            showToast("剪贴板没有可导入文件")
            return
        }
        importFiles(urls)
    }

    func toggleFavorite(_ item: PromptItem) {
        guard requireFeature(.proEditPrompt) else { return }
        var updated = item
        updated.favorite.toggle()
        updated.updatedAt = Date()
        save(updated, toast: updated.favorite ? "已收藏" : "已取消收藏")
    }

    func moveSelectedToTrash() {
        let ids = selectedItemIDsOrFallback(selectedID ?? "")
        moveItemsToTrash(ids)
    }

    /// Moves an explicit interaction snapshot to the trash. Context menus and drag
    /// sessions use this so AppKit selection changes after mouse-down cannot reduce
    /// a multi-selection to a single item before the action executes.
    func moveItemsToTrash(_ itemIDs: [String]) {
        guard requireFeature(.baseDeleteLocalData) else { return }
        let ids = Set(PromptItemDragPayload(itemIDs: itemIDs).itemIDs)
        guard !ids.isEmpty else { return }
        do {
            try repository?.markDeleted(itemIDs: Array(ids), deletedAt: Date())
            reload(selecting: filteredItems.first(where: { !ids.contains($0.id) })?.id)
            showToast(ids.count > 1 ? "已移入回收站 \(ids.count) 个项目" : "已移入回收站")
        } catch {
            modal = .error(error.localizedDescription)
        }
    }

    func restoreSelected() {
        guard requireFeature(.baseDeleteLocalData) else { return }
        let ids = selectedIDs.isEmpty ? selectedID.map { Set([$0]) } ?? [] : selectedIDs
        guard !ids.isEmpty else { return }
        do {
            try repository?.markDeleted(itemIDs: Array(ids), deletedAt: nil)
            reload(selecting: selectedID ?? ids.first)
            showToast(ids.count > 1 ? "已恢复 \(ids.count) 个项目" : "已恢复")
        } catch {
            modal = .error(error.localizedDescription)
        }
    }

    func restoreAllTrashItems() {
        guard requireFeature(.baseDeleteLocalData) else { return }
        let deletedItems = items.filter(\.isDeleted)
        guard !deletedItems.isEmpty else {
            showToast("回收站为空")
            return
        }
        do {
            try repository?.markDeleted(itemIDs: deletedItems.map(\.id), deletedAt: nil)
            reload(selecting: deletedItems.first?.id)
            showToast("已还原全部项目")
        } catch {
            modal = .error(error.localizedDescription)
        }
    }

    func beginPermanentDeleteSelectedTrashItems() {
        guard requireFeature(.baseDeleteLocalData) else { return }
        let ids = selectedTrashItemIDs()
        guard !ids.isEmpty else { return }
        let title = ids.count == 1 ? ids.first.flatMap { itemsByID[$0]?.title } : nil
        modal = .permanentDeleteConfirmation(
            PermanentDeleteRequest(itemIDs: ids, itemTitle: title)
        )
    }

    func confirmPermanentDelete(_ request: PermanentDeleteRequest) {
        guard requireFeature(.baseDeleteLocalData) else { return }
        permanentlyDeleteTrashItems(withIDs: request.itemIDs, emptyTrashMessage: false)
    }

    func emptyTrash() {
        guard requireFeature(.baseDeleteLocalData) else { return }
        let deletedItems = items.filter(\.isDeleted)
        guard !deletedItems.isEmpty else {
            showToast("回收站为空")
            return
        }
        permanentlyDeleteTrashItems(withIDs: Set(deletedItems.map(\.id)), emptyTrashMessage: true)
    }

    private func selectedTrashItemIDs() -> Set<String> {
        let ids = selectedIDs.isEmpty ? selectedID.map { Set([$0]) } ?? [] : selectedIDs
        return Set(ids.filter { itemsByID[$0]?.isDeleted == true })
    }

    private func permanentlyDeleteTrashItems(withIDs ids: Set<String>, emptyTrashMessage: Bool) {
        let deletedItems = ids.compactMap { itemsByID[$0] }.filter(\.isDeleted)
        guard !deletedItems.isEmpty else { return }

        var deletedIDs: Set<String> = []
        var failures: [String] = []
        do {
            for item in deletedItems {
                do {
                    try deleteFilesForPermanentDeletion(of: item)
                } catch {
                    failures.append("\(item.title)：\(error.localizedDescription)")
                    continue
                }
                deletedIDs.insert(item.id)
            }
            try repository?.permanentlyDelete(itemIDs: Array(deletedIDs))
        } catch {
            modal = .error(error.localizedDescription)
            return
        }

        if !deletedIDs.isEmpty {
            reload(selecting: filteredItems.first(where: { !deletedIDs.contains($0.id) })?.id)
            if failures.isEmpty {
                if emptyTrashMessage {
                    showToast("回收站已清空")
                } else {
                    showToast(deletedIDs.count > 1 ? "已彻底删除 \(deletedIDs.count) 个项目" : "已彻底删除")
                }
            } else {
                showToast("已删除 \(deletedIDs.count) 个项目，\(failures.count) 个失败")
            }
        }

        if !failures.isEmpty {
            modal = .error(failures.prefix(3).joined(separator: "\n"))
        }
    }

    private func deleteFilesForPermanentDeletion(of item: PromptItem) throws {
        try removePrimaryAssetFileIfNeeded(path: item.assetPath)
        removeGeneratedThumbnailIfNeeded(for: item)
    }

    private func removePrimaryAssetFileIfNeeded(path: String) throws {
        guard !path.isEmpty else { return }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else { return }
        try fileManager.removeItem(at: URL(fileURLWithPath: path))
    }

    private func removeGeneratedThumbnailIfNeeded(for item: PromptItem) {
        guard item.thumbnailPath != item.assetPath,
              !item.thumbnailPath.isEmpty,
              FileManager.default.fileExists(atPath: item.thumbnailPath) else {
            return
        }
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: item.thumbnailPath))
    }

    private func cleanupReplacedPrimaryAsset(
        oldPath: String,
        oldThumbnailPath: String,
        updatedItem: PromptItem,
        primaryAssetChanged: Bool
    ) {
        guard primaryAssetChanged, !oldPath.isEmpty else { return }
        let normalizedOldPath = URL(fileURLWithPath: oldPath).standardizedFileURL.path
        let normalizedNewPath = URL(fileURLWithPath: updatedItem.assetPath).standardizedFileURL.path
        guard normalizedOldPath != normalizedNewPath else { return }
        if oldThumbnailPath != oldPath,
           !oldThumbnailPath.isEmpty,
           oldThumbnailPath != updatedItem.thumbnailPath,
           FileManager.default.fileExists(atPath: oldThumbnailPath) {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: oldThumbnailPath))
        }
        guard isLibraryAssetPath(oldPath),
              !updatedItem.referenceAssets.contains(where: { $0.path == oldPath }),
              !items.contains(where: {
                  $0.id != updatedItem.id
                      && ($0.assetPath == oldPath || $0.referenceAssets.contains(where: { $0.path == oldPath }))
              }) else {
            return
        }
        if FileManager.default.fileExists(atPath: oldPath) {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: oldPath))
        }
    }

    private func isLibraryAssetPath(_ path: String) -> Bool {
        let assetsRoot = libraryURL.appendingPathComponent("assets", isDirectory: true).standardizedFileURL.path
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        return normalized == assetsRoot || normalized.hasPrefix(assetsRoot + "/")
    }

    @discardableResult
    func savePrompt(
        itemID: String,
        title: String,
        type: PromptType,
        modelId: String?,
        prompt: String,
        negativePrompt: String,
        tags: [String],
        parameters: [String: String],
        note: String,
        saveAsNewVersion: Bool,
        primaryAssetUpdate: PrimaryAssetUpdate = .unchanged,
        preserveExistingPrimaryAsReference: Bool = false,
        referenceURLs: [URL] = []
    ) -> Bool {
        guard requireFeature(.proEditPrompt) else { return false }
        guard var item = promptItem(for: itemID), let repository else { return false }

        let oldAssetPath = item.assetPath
        let oldThumbnailPath = item.thumbnailPath
        var newlyCopiedPaths: [String] = []
        var primaryAssetChanged = false

        do {
            let oldPrimaryIsAvailable = oldAssetPath.isEmpty || FileManager.default.fileExists(atPath: oldAssetPath)
            guard item.type == type
                    || primaryAssetUpdate != .unchanged
                    || preserveExistingPrimaryAsReference
                    || oldAssetPath.isEmpty
                    || !oldPrimaryIsAvailable else {
                throw CocoaError(.validationMissingMandatoryProperty)
            }

            let copiedReferences = try referenceURLs.map { source -> (original: URL, copied: URL) in
                let copied = try repository.copyAssetIntoLibrary(from: source, assetKind: AppKitBridge.assetKind(for: source))
                newlyCopiedPaths.append(copied.path)
                return (source, copied)
            }
            item.referenceAssets.append(contentsOf: copiedReferences.map { pair in
                ReferenceAsset(
                    type: pair.original.pathExtension.uppercased(),
                    path: pair.copied.path,
                    label: pair.original.deletingPathExtension().lastPathComponent
                )
            })

            if preserveExistingPrimaryAsReference,
               !oldAssetPath.isEmpty,
               !item.referenceAssets.contains(where: { $0.path == oldAssetPath }) {
                item.referenceAssets.append(
                    ReferenceAsset(
                        type: item.format,
                        path: oldAssetPath,
                        label: URL(fileURLWithPath: oldAssetPath).deletingPathExtension().lastPathComponent
                    )
                )
            }

            if type == .text {
                let textAssetURL = try createTextPromptAssetIfNeeded(
                    title: title,
                    type: .text,
                    prompt: prompt,
                    parameters: parameters,
                    hasPrimaryAsset: false
                )
                guard let textAssetURL else {
                    throw CocoaError(.fileWriteUnknown)
                }
                newlyCopiedPaths.append(textAssetURL.path)
                let assetKind = AppKitBridge.assetKind(for: textAssetURL)
                let fileInfo = AppKitBridge.fileInfo(for: textAssetURL, assetKind: assetKind)
                item.assetKind = assetKind
                item.assetPath = textAssetURL.path
                item.thumbnailPath = textAssetURL.path
                item.aspectRatio = Self.normalizedAspectRatio(width: fileInfo.width, height: fileInfo.height)
                item.width = fileInfo.width
                item.height = fileInfo.height
                item.format = fileInfo.format
                item.fileSize = fileInfo.fileSize
                primaryAssetChanged = oldAssetPath != item.assetPath
            } else {
                switch primaryAssetUpdate {
                case .unchanged:
                    if item.type != type {
                        primaryAssetChanged = !oldAssetPath.isEmpty
                        item.assetKind = type == .image ? .image : (type == .video ? .video : .audio)
                        item.assetPath = ""
                        item.thumbnailPath = ""
                        item.aspectRatio = ""
                        item.width = 0
                        item.height = 0
                        item.format = ""
                        item.fileSize = 0
                    }
                case .replace(let source):
                    let sourceKind = AppKitBridge.assetKind(for: source)
                    guard sourceKind.promptType == type else {
                        throw CocoaError(.fileWriteInvalidFileName)
                    }
                    let copied = try repository.copyAssetIntoLibrary(from: source, assetKind: sourceKind)
                    newlyCopiedPaths.append(copied.path)
                    primaryAssetChanged = URL(fileURLWithPath: oldAssetPath).standardizedFileURL.path
                        != copied.standardizedFileURL.path
                    let info = AppKitBridge.fileInfo(for: copied, assetKind: sourceKind)
                    item.assetKind = sourceKind
                    item.assetPath = copied.path
                    item.thumbnailPath = copied.path
                    item.aspectRatio = Self.normalizedAspectRatio(width: info.width, height: info.height)
                    item.width = info.width
                    item.height = info.height
                    item.format = info.format
                    item.fileSize = info.fileSize
                case .remove:
                    primaryAssetChanged = !oldAssetPath.isEmpty
                    item.assetKind = type == .image ? .image : (type == .video ? .video : .audio)
                    item.assetPath = ""
                    item.thumbnailPath = ""
                    item.aspectRatio = ""
                    item.width = 0
                    item.height = 0
                    item.format = ""
                    item.fileSize = 0
                }
            }

            item.title = title
            item.type = type
            item.category = type.displayName
            if let modelId {
                item.modelId = modelId
                item.modelName = models.first(where: { $0.id == modelId })?.name
                    ?? (modelId == PromptComposerMetadataPolicy.unspecifiedModelID
                        ? PromptComposerMetadataPolicy.unspecifiedModelName
                        : item.modelName)
            }
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

            // Persist the complete item before touching any old file. If SQLite
            // fails, the copied files are cleaned and the composer stays open.
            try repository.saveItem(item)
            cleanupReplacedPrimaryAsset(
                oldPath: oldAssetPath,
                oldThumbnailPath: oldThumbnailPath,
                updatedItem: item,
                primaryAssetChanged: primaryAssetChanged
            )
            reload(selecting: item.id)
            showToast("已保存 Prompt")
            markRecentlyUsed(itemID: item.id)
            return true
        } catch {
            for path in newlyCopiedPaths where path != oldAssetPath {
                guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { continue }
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
            }
            modal = .error(error.localizedDescription)
            return false
        }
    }

    func saveMarkdownDocument(_ text: String, for item: PromptItem) {
        guard requireFeature(.proEditPrompt) else { return }
        guard var current = promptItem(for: item.id) else { return }
        do {
            if !current.assetPath.isEmpty {
                let url = URL(fileURLWithPath: current.assetPath)
                if current.isWordDocument {
                    try AppKitBridge.writeDocx(text: text, to: url)
                } else {
                    try text.write(to: url, atomically: true, encoding: .utf8)
                }
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
                    note: "文档全窗口编辑"
                )
            )
            try repository?.saveItem(current)
            reload(selecting: current.id)
            showToast("已保存文档信息")
            invalidateAndRegenerateTextThumbnail(for: current)
            markRecentlyUsed(itemID: current.id)
        } catch {
            modal = .error("保存文档失败：\(error.localizedDescription)")
        }
    }

    @discardableResult
    func createPrompt(
        title: String,
        type: PromptType,
        modelId: String?,
        prompt: String,
        negativePrompt: String,
        tags: [String],
        parameters: [String: String] = ["比例": "16:9", "质量": "high"],
        primaryAssetURL: URL? = nil,
        referenceURLs: [URL] = []
    ) -> Bool {
        guard requireFeature(.proCreatePrompt) else { return false }
        let model = modelId.flatMap { requestedID in
            models.first(where: { $0.id == requestedID && $0.type == type })
        } ?? ModelProfile(
            id: PromptComposerMetadataPolicy.unspecifiedModelID,
            name: PromptComposerMetadataPolicy.unspecifiedModelName,
            type: type,
            parameters: []
        )
        let id = UUID().uuidString
        let version = PromptVersion(
            promptItemId: id,
            version: "V1.0",
            prompt: prompt,
            negativePrompt: negativePrompt,
            parameters: parameters,
            note: "新建 Prompt"
        )

        var newlyCopiedPaths: [String] = []
        do {
            guard let repository else {
                throw CocoaError(.fileWriteUnknown)
            }
            let primaryAssetKind: AssetKind? = primaryAssetURL.map(AppKitBridge.assetKind(for:))
            if let primaryAssetKind, primaryAssetKind.promptType != type {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            let primaryPath = try primaryAssetURL.map { source in
                let copied = try repository.copyAssetIntoLibrary(from: source, assetKind: primaryAssetKind ?? AppKitBridge.assetKind(for: source))
                newlyCopiedPaths.append(copied.path)
                return copied
            }?.path ?? ""
            let textAssetURL = try createTextPromptAssetIfNeeded(
                title: title,
                type: type,
                prompt: prompt,
                parameters: parameters,
                hasPrimaryAsset: type != .text && primaryAssetURL != nil
            )
            if let textAssetURL {
                newlyCopiedPaths.append(textAssetURL.path)
            }
            let copiedReferences = try referenceURLs.map { source -> (original: URL, copied: URL) in
                let copied = try repository.copyAssetIntoLibrary(from: source, assetKind: AppKitBridge.assetKind(for: source))
                newlyCopiedPaths.append(copied.path)
                return (source, copied)
            }
            let references = copiedReferences.map { pair in
                ReferenceAsset(
                    type: pair.original.pathExtension.uppercased(),
                    path: pair.copied.path,
                    label: pair.original.deletingPathExtension().lastPathComponent
                )
            }
            let assetURL = textAssetURL ?? (primaryPath.isEmpty ? nil : URL(fileURLWithPath: primaryPath))
            let assetKind: AssetKind = textAssetURL.map { AppKitBridge.assetKind(for: $0) }
                ?? primaryAssetKind
                ?? {
                    switch type {
                    case .image: return .image
                    case .video: return .video
                    case .audio: return .audio
                    case .text: return .markdown
                    }
                }()
            let previewInfo = assetURL.map { AppKitBridge.fileInfo(for: $0, assetKind: assetKind) }
                ?? (width: 0, height: 0, fileSize: Int64(0), format: "")
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
                assetPath: assetURL?.path ?? "",
                aspectRatio: assetURL == nil ? "" : Self.normalizedAspectRatio(width: previewInfo.width, height: previewInfo.height),
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
            try repository.saveItem(item)
            reload(selecting: id)
            markRecentlyUsed(itemID: id)
            showToast("已新建 Prompt")
            return true
        } catch {
            for path in newlyCopiedPaths where !path.isEmpty && FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
            }
            modal = .error(error.localizedDescription)
            return false
        }
    }

    func importFiles(_ urls: [URL], targetFolderID: String? = nil, acceptedType: PromptType? = nil) {
        guard repository != nil else { return }
        guard mediaImportTask == nil else {
            showToast("已有导入任务正在进行")
            return
        }
        guard !urls.isEmpty else {
            showToast("未导入素材")
            return
        }

        let targetFolder = targetFolderID.flatMap(folder(withID:)) ?? currentImportFolder()
        let mediaImportService = mediaImportService ?? Self.makeMediaImportService(libraryURL: libraryURL)
        self.mediaImportService = mediaImportService
        let sessionID = UUID()
        let totalStartedAt = DebugPerformanceProbe.now()
        mediaImportSessionID = sessionID
        importStatusDismissTask?.cancel()
        importStatusDismissTask = nil
        importProgressState.update(progress: MediaImportProgress(
            phase: .scanning,
            current: 0,
            total: nil,
            currentFileName: nil,
            successCount: 0,
            failureCount: 0
        ), failures: [])
        DebugPerformanceProbe.recordDuration("import.drop_to_status.ms", startedAt: totalStartedAt)

        mediaImportTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await Task.yield()

            let scanStartedAt = DebugPerformanceProbe.now()
            let sourceFiles = await mediaImportService.scan(urls)
            DebugPerformanceProbe.recordDuration("import.scan.ms", startedAt: scanStartedAt)
            DebugPerformanceProbe.record("import.file_count", value: Double(sourceFiles.count))
            guard !Task.isCancelled, self.mediaImportSessionID == sessionID else { return }
            guard !sourceFiles.isEmpty else {
                self.finishMediaImportWithoutResult(sessionID: sessionID, message: "未导入素材")
                return
            }
            guard self.requireFeature(sourceFiles.count > 1 ? .proBatchImport : .proSingleImport) else {
                self.finishMediaImportWithoutResult(sessionID: sessionID)
                return
            }

            let firstSortOrder = self.nextSortOrderForNewItem() - max(0, sourceFiles.count - 1)
            let request = MediaImportRequest(
                sourceFiles: sourceFiles,
                targetFolderID: targetFolder.id,
                targetFolderName: targetFolder.name,
                acceptedType: acceptedType,
                firstSortOrder: firstSortOrder,
                modelsByType: self.mediaImportModels()
            )

            do {
                let result = try await mediaImportService.importFiles(request) { progress in
                    await MainActor.run { [weak self] in
                        guard let self, self.mediaImportSessionID == sessionID else { return }
                        self.importProgressState.update(progress: progress)
                    }
                }
                guard !Task.isCancelled, self.mediaImportSessionID == sessionID else { return }
                DebugPerformanceProbe.record("import.prepare.ms", value: result.metrics.prepareMilliseconds)
                DebugPerformanceProbe.record("import.persist.ms", value: result.metrics.persistMilliseconds)
                let applyStartedAt = DebugPerformanceProbe.now()
                self.applyMediaImportResult(result)
                DebugPerformanceProbe.recordDuration("import.ui_apply.ms", startedAt: applyStartedAt)
                DebugPerformanceProbe.recordDuration("import.total.ms", startedAt: totalStartedAt)
                self.finishMediaImport(result: result, sessionID: sessionID)
            } catch is CancellationError {
                self.finishMediaImportWithoutResult(sessionID: sessionID)
            } catch {
                self.finishMediaImportWithoutResult(sessionID: sessionID)
                self.modal = .error(error.localizedDescription)
            }
        }
    }

    func exportSelected(options: ExportOptions = ExportOptions(promptMarkdown: true, pngImage: false, jpegImage: false)) {
        guard requireFeature(.baseBasicExport) else { return }
        guard options.hasSelection else {
            showToast("请选择导出内容")
            return
        }
        if options.pngImage || options.jpegImage {
            guard requireFeature(.proAdvancedExport) else { return }
        }
        let selectedItems = orderedSelectedItems()
        guard !selectedItems.isEmpty, let directory = AppKitBridge.chooseExportDirectory() else { return }
        do {
            var exportedCount = 0
            for item in selectedItems {
                let source = URL(fileURLWithPath: item.assetPath)
                let baseName = safeExportFileName(item.title)
                if options.promptMarkdown {
                    let promptTarget = uniqueExportURL(in: directory, baseName: "\(baseName)-提示词", extension: "md")
                    try overwriteText(markdownPrompt(for: item), to: promptTarget)
                    exportedCount += 1
                }
                if options.pngImage, item.assetKind == .image {
                    guard FileManager.default.fileExists(atPath: source.path) else { throw CocoaError(.fileNoSuchFile) }
                    let target = uniqueExportURL(in: directory, baseName: baseName, extension: "png")
                    try overwriteImage(from: source, to: target, format: .png)
                    exportedCount += 1
                }
                if options.jpegImage, item.assetKind == .image {
                    guard FileManager.default.fileExists(atPath: source.path) else { throw CocoaError(.fileNoSuchFile) }
                    let target = uniqueExportURL(in: directory, baseName: baseName, extension: "jpg")
                    try overwriteImage(from: source, to: target, format: .jpeg)
                    exportedCount += 1
                }
                markRecentlyUsed(itemID: item.id)
            }
            showToast(exportedCount > 1 ? "已导出 \(exportedCount) 个文件" : "导出完成")
        } catch {
            modal = .error(error.localizedDescription)
        }
    }

    private func orderedSelectedItems() -> [PromptItem] {
        let requested = selectedIDs.isEmpty ? selectedID.map { Set([$0]) } ?? [] : selectedIDs
        let visible = filteredItems.filter { requested.contains($0.id) }
        let visibleIDs = Set(visible.map(\.id))
        return visible + items.filter { requested.contains($0.id) && !visibleIDs.contains($0.id) }
    }

    func exportSelected(format: PromptStudioExportFormat) {
        guard requireFeature(.baseBasicExport) else { return }
        guard let item = selectedItem else { return }
        guard item.hasAvailablePrimaryAsset else {
            showToast("当前 Prompt 尚未添加主素材")
            return
        }
        guard !format.requiresImage || item.assetKind == .image else {
            showToast("当前素材不是图片")
            return
        }
        switch format {
        case .promptText, .promptMarkdown:
            break
        case .imagePNG, .imageJPEG, .imagePDF, .promptWord:
            guard requireFeature(.proAdvancedExport) else { return }
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
        guard requireFeature(.baseBasicExport) else { return }
        guard let item = selectedItem, item.hasAvailablePrimaryAsset,
              FileManager.default.fileExists(atPath: item.assetPath) else {
            showToast("源文件不存在")
            return
        }
        AppKitBridge.revealInFinder(path: item.assetPath)
        markRecentlyUsed(itemID: item.id)
    }

    func previewSelected() {
        guard let item = selectedItem else { return }
        guard requireFeature(.baseViewPrompt) else { return }
        referenceLightbox = nil
        guard item.hasAvailablePrimaryAsset || item.isTextDocumentLike else {
            openEditPromptComposer(for: item)
            return
        }
        modal = nil
        promptComposerMode = nil
        markdownEditorItemID = nil
        isPreviewPresented = true
        markRecentlyUsed(itemID: item.id)
    }

    func togglePreview() {
        guard markdownEditorItemID == nil else { return }

        if isPreviewPresented {
            referenceLightbox = nil
            isPreviewPresented = false
            return
        }

        guard modal == nil, promptComposerMode == nil, selectedItem != nil else { return }
        previewSelected()
    }

    var allowsManualItemReordering: Bool {
        guard filter.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch filter.collection {
        case .recent, .trash:
            return false
        default:
            return true
        }
    }

    func moveFilteredItem(draggedID: String, toTargetPosition targetID: String) {
        guard requireFeature(.proManageCollections) else { return }
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
        reorderedAll.move(
            fromOffsets: IndexSet(integer: fromIndex),
            toOffset: targetIndex > fromIndex ? targetIndex + 1 : targetIndex
        )

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

    func swapFilteredItems(_ firstID: String, _ secondID: String) {
        guard requireFeature(.proManageCollections) else { return }
        guard firstID != secondID else { return }
        guard filteredItems.contains(where: { $0.id == firstID }),
              filteredItems.contains(where: { $0.id == secondID }),
              let firstIndex = items.firstIndex(where: { $0.id == firstID }),
              let secondIndex = items.firstIndex(where: { $0.id == secondID }) else {
            return
        }

        var updatedItems = items
        let firstOrder = updatedItems[firstIndex].sortOrder
        let secondOrder = updatedItems[secondIndex].sortOrder
        updatedItems[firstIndex].sortOrder = secondOrder
        updatedItems[secondIndex].sortOrder = firstOrder
        updatedItems[firstIndex].updatedAt = Date()
        updatedItems[secondIndex].updatedAt = Date()

        do {
            try repository?.updateSortOrders([
                (id: firstID, sortOrder: secondOrder),
                (id: secondID, sortOrder: firstOrder)
            ])
            items = updatedItems
            refreshFilteredItems(selecting: firstID)
        } catch {
            modal = .error(error.localizedDescription)
        }
    }

    func moveItems(_ itemIDs: [String], toFolderID folderID: String) {
        guard requireFeature(.proManageCollections) else { return }
        guard let repository else {
            modal = .error("资料库尚未连接")
            return
        }
        guard let folder = folder(withID: folderID) else {
            modal = .error("目标文件夹不存在")
            return
        }

        let previousSelectedIDs = selectedIDs
        let previousSelectedID = selectedID
        let plan = PromptItemBatchMovePlanner.plan(
            items: items,
            requestedIDs: itemIDs,
            targetFolderID: folder.id,
            targetFolderName: folder.name
        )
        guard !plan.updatedItems.isEmpty else {
            if !plan.unchangedIDs.isEmpty {
                showToast("所选素材已在当前文件夹")
            }
            return
        }

        do {
            try repository.updateItemFolders(plan.updatedItems)
            let nextFolders = try repository.loadFolders()
            let nextItems = try repository.loadItems()
            let nextTags = try repository.loadTags()
            folders = nextFolders
            items = nextItems
            tags = nextTags

            let retainedIDs = previousSelectedIDs.intersection(Set(filteredItems.map(\.id)))
            if !retainedIDs.isEmpty {
                let retainedPrimaryID = previousSelectedID.flatMap { retainedIDs.contains($0) ? $0 : nil }
                    ?? filteredItems.first(where: { retainedIDs.contains($0.id) })?.id
                selectItems(ids: retainedIDs, primaryID: retainedPrimaryID)
            }

            if plan.updatedItems.count > 1 {
                showToast("已移动 \(plan.updatedItems.count) 个项目到 \(folder.name)")
            } else {
                showToast("已移动到 \(folder.name)")
            }
        } catch {
            modal = .error(error.localizedDescription)
        }
    }

    func moveItem(_ itemID: String, toFolderID folderID: String) {
        moveItems([itemID], toFolderID: folderID)
    }

    func moveItem(_ itemID: String, toFolder folderName: String, acceptedType: PromptType?) {
        guard let folder = folders.first(where: { $0.name == folderName }) else { return }
        moveItem(itemID, toFolderID: folder.id)
    }

    func folderRows(for type: PromptType) -> [FolderRow] {
        folderRows()
    }

    func folderDestinations() -> [FolderDestination] {
        folders
            .sorted {
                if $0.sortOrder == $1.sortOrder {
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                return $0.sortOrder < $1.sortOrder
            }
            .map { folder in
                FolderDestination(folderID: folder.id, name: folder.name)
            }
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

    func childFolderRowsForCurrentCollection() -> [FolderRow] {
        guard case .folder(let folderID) = filter.collection else { return [] }
        return childFolderRows(parentID: folderID)
    }

    func folderTreeRows(orderOverrides: [String: Int] = [:]) -> [FolderTreeRow] {
        let children = Dictionary(grouping: folders, by: { $0.parentId })
        func sorted(_ folders: [LibraryFolder]) -> [LibraryFolder] {
            folders.sorted {
                let lhsOrder = orderOverrides[$0.id] ?? $0.sortOrder
                let rhsOrder = orderOverrides[$1.id] ?? $1.sortOrder
                if lhsOrder == rhsOrder {
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                return lhsOrder < rhsOrder
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

    func folderMoveDestinationRows(for movingFolder: LibraryFolder) -> [FolderMoveDestinationRow] {
        let excludedIDs = descendantFolderIDs(of: movingFolder.id, includingSelf: true)
        let availableFolders = folders.filter { !excludedIDs.contains($0.id) }
        let children = Dictionary(grouping: availableFolders, by: { $0.parentId })

        func sorted(_ folders: [LibraryFolder]) -> [LibraryFolder] {
            folders.sorted {
                if $0.sortOrder == $1.sortOrder {
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                return $0.sortOrder < $1.sortOrder
            }
        }

        var rows: [FolderMoveDestinationRow] = []
        func append(parentID: String?, level: Int) {
            for folder in sorted(children[parentID] ?? []) {
                rows.append(FolderMoveDestinationRow(folder: folder, level: level))
                append(parentID: folder.id, level: level + 1)
            }
        }
        append(parentID: nil, level: 0)
        return rows
    }

    func reorderFolders(parentId: String?, orderedIDs: [String]) {
        guard requireFeature(.proManageCollections) else { return }
        let siblings = folders
            .filter { $0.parentId == parentId }
            .sorted {
                if $0.sortOrder == $1.sortOrder {
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                return $0.sortOrder < $1.sortOrder
            }
        let siblingIDSet = Set(siblings.map(\.id))
        var finalIDs = orderedIDs.filter { siblingIDSet.contains($0) }
        for folder in siblings where !finalIDs.contains(folder.id) {
            finalIDs.append(folder.id)
        }
        guard finalIDs.count == siblings.count else { return }

        do {
            let lookup = Dictionary(uniqueKeysWithValues: siblings.map { ($0.id, $0) })
            for (index, id) in finalIDs.enumerated() {
                guard var folder = lookup[id] else { continue }
                folder.sortOrder = index
                try repository?.saveFolder(folder)
            }
            folders = try repository?.loadFolders() ?? folders
        } catch {
            modal = .error(error.localizedDescription)
        }
    }

    private func childFolderRows(parentID: String) -> [FolderRow] {
        folders
            .filter { $0.parentId == parentID }
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

    func toggleFolderExpansion(_ folderID: String) {
        if expandedFolderIDs.contains(folderID) {
            expandedFolderIDs.remove(folderID)
        } else {
            expandedFolderIDs.insert(folderID)
        }
    }

    func selectFolder(_ folder: LibraryFolder) {
        clearSelectedFolder()
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            setCollection(.folder(folder.id))
        }
    }

    func swapFolderOrder(draggedID: String, targetID: String) {
        guard requireFeature(.proManageCollections) else { return }
        guard draggedID != targetID,
              let dragged = folder(withID: draggedID),
              let target = folder(withID: targetID),
              dragged.parentId == target.parentId else { return }

        var siblings = folders
            .filter { $0.parentId == target.parentId }
            .sorted {
                if $0.sortOrder == $1.sortOrder {
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                return $0.sortOrder < $1.sortOrder
            }

        guard let draggedIndex = siblings.firstIndex(where: { $0.id == draggedID }),
              let targetIndex = siblings.firstIndex(where: { $0.id == targetID }) else { return }

        siblings.swapAt(draggedIndex, targetIndex)

        do {
            for index in siblings.indices {
                var folder = siblings[index]
                folder.sortOrder = index
                try repository?.saveFolder(folder)
            }
            folders = try repository?.loadFolders() ?? folders
        } catch {
            modal = .error(error.localizedDescription)
        }
    }

    func beginCreateFolder(parentId: String? = nil) {
        guard requireFeature(.proManageCollections) else { return }
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
        guard requireFeature(.proManageCollections) else { return }
        createInlineEditableFolder(parentId: folder.parentId, afterFolderID: folder.id)
    }

    func beginCreateChildFolder(_ folder: LibraryFolder) {
        guard requireFeature(.proManageCollections) else { return }
        expandedFolderIDs.insert(folder.id)
        createInlineEditableFolder(parentId: folder.id, insertAtTop: true)
    }

    func moveFolder(_ folder: LibraryFolder, toParentID parentID: String?) {
        moveFolders([folder.id], toParentID: parentID)
    }

    func moveFolders(_ folderIDs: [String], toParentID parentID: String?) {
        guard requireFeature(.proManageCollections) else { return }
        guard let repository else {
            modal = .error("资料库尚未连接")
            return
        }
        do {
            let contextIDs = FolderSelectionActionContext.normalizeParentChildOverlap(
                selectedFolderIDs: folderIDs,
                folders: folders
            )
            let plan = try FolderBatchMovePlanner.plan(
                allFolders: folders,
                sourceFolderIDs: contextIDs,
                targetParentID: parentID
            )
            try repository.updateFolderParentsAndSort(plan.updates)
            folders = try repository.loadFolders()
            if let parentID {
                expandedFolderIDs.insert(parentID)
            }
            clearSelectedFolder()
            showToast(plan.sourceFolderIDs.count > 1 ? "已移动 \(plan.sourceFolderIDs.count) 个文件夹" : "已移动文件夹")
        } catch let error as FolderBatchMoveError {
            showToast(error.localizedDescription)
        } catch {
            modal = .error(error.localizedDescription)
        }
    }

    func beginRenameFolder(_ folder: LibraryFolder) {
        guard requireFeature(.proManageCollections) else { return }
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
        let context = folderSelectionActionContext(clickedFolderID: folder.id)
        selectFolders(ids: Set(context.orderedFolderIDs), primaryID: context.primaryID)
        beginDeleteSelectedFolders()
    }

    func beginDeleteSelectedFolders() {
        beginDeleteFolders(Array(selectedFolderIDs))
    }

    func beginDeleteFolders(_ folderIDs: [String]) {
        guard !isImporting else {
            showToast("请等待当前导入完成")
            return
        }
        guard requireFeature(.proManageCollections) else { return }
        let normalizedIDs = FolderSelectionActionContext.normalizeParentChildOverlap(
            selectedFolderIDs: folderIDs,
            folders: folders
        )
        guard !normalizedIDs.isEmpty else { return }
        let selectedNames = normalizedIDs.compactMap { folder(withID: $0)?.name }
        let allTreeIDs = Set(normalizedIDs.flatMap { Array(descendantFolderIDs(of: $0, includingSelf: true)) })
        let count = items.filter { !$0.isDeleted && allTreeIDs.contains($0.folderId) }.count
        modal = .folderDeleteConfirmation(
            FolderDeleteRequest(
                folderIDs: normalizedIDs,
                folderName: selectedNames.first ?? "所选文件夹",
                folderCount: normalizedIDs.count,
                itemCount: count
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
        guard requireFeature(.proManageCollections) else { return false }
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
    func createInlineEditableFolder(parentId: String?, insertAtTop: Bool = false, afterFolderID: String? = nil) -> Bool {
        guard requireFeature(.proManageCollections) else { return false }
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
            if let afterFolderID {
                folders = try repository?.loadFolders() ?? (folders + [folder])
                let orderedIDs = folderIDsAfterInserting(folder.id, after: afterFolderID, parentId: parentId)
                try saveFolderOrder(parentId: parentId, orderedIDs: orderedIDs)
            }
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

    private func folderIDsAfterInserting(_ insertedID: String, after anchorID: String, parentId: String?) -> [String] {
        var ids = folders
            .filter { $0.parentId == parentId }
            .sorted {
                if $0.sortOrder == $1.sortOrder {
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                return $0.sortOrder < $1.sortOrder
            }
            .map(\.id)
            .filter { $0 != insertedID }
        let insertIndex = (ids.firstIndex(of: anchorID).map { $0 + 1 }) ?? ids.count
        ids.insert(insertedID, at: min(max(insertIndex, 0), ids.count))
        return ids
    }

    private func saveFolderOrder(parentId: String?, orderedIDs: [String]) throws {
        let siblings = folders.filter { $0.parentId == parentId }
        let lookup = Dictionary(uniqueKeysWithValues: siblings.map { ($0.id, $0) })
        for (index, id) in orderedIDs.enumerated() {
            guard var folder = lookup[id] else { continue }
            folder.sortOrder = index
            try repository?.saveFolder(folder)
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
        guard requireFeature(.proManageCollections) else { return false }
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
        deleteFoldersMovingItemsToTrash(ids: [id])
    }

    func deleteFoldersMovingItemsToTrash(ids: [String]) {
        guard !isImporting else {
            showToast("请等待当前导入完成")
            return
        }
        guard requireFeature(.proManageCollections) else { return }
        guard let repository else { return }
        do {
            let deletedAt = Date()
            let folderIDs = Set(ids.flatMap { Array(descendantFolderIDs(of: $0, includingSelf: true)) })
            try repository.deleteFolderSubtrees(sourceFolderIDs: ids, deletedAt: deletedAt)
            if case .folder(let activeFolderID) = filter.collection, folderIDs.contains(activeFolderID) {
                filter.collection = .all
                filter.type = nil
            }
            clearSelectedFolder()
            reload()
            showToast(ids.count > 1 ? "文件夹已批量删除，素材已移入回收站" : "文件夹已删除，素材已移入回收站")
        } catch {
            modal = .error(error.localizedDescription)
        }
    }

    func importFiles(to folder: LibraryFolder) {
        guard !isImporting else {
            showToast("已有导入任务正在进行")
            return
        }
        selectFolder(folder)
        let urls = AppKitBridge.chooseImportFiles()
        guard !urls.isEmpty else { return }
        importFiles(urls, targetFolderID: folder.id)
    }

    func exportFolder(_ folderID: String) {
        guard requireFeature(.proAdvancedExport) else { return }
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
        if includingDescendants {
            return libraryStatisticsCache.count(includingDescendants: folder.id)
        }
        return libraryStatisticsCache.statistics.folderCounts[folder.id] ?? 0
    }

    func saveModelFilterLabel(id: String, name: String, type: PromptType) {
        guard requireFeature(.proAdvancedSearch) else { return }
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
        guard requireFeature(.proAdvancedSearch) else { return }
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
            parameters: defaultParameters(for: type)
        )
        persist(model: model, replacingItemModelName: nil)
    }

    func generateTextVariant() {
        guard requireFeature(.proAIAssist) else { return }
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
        guard requireFeature(.proEditPrompt) else { return }
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
            try repository.seedFoldersIfNeeded(initialFolders)
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

    private func defaultParameters(for type: PromptType) -> [String] {
        switch type {
        case .image:
            ["aspectRatio", "style", "seed"]
        case .video:
            ["duration", "camera", "motion"]
        case .text:
            ["format", "tone", "length"]
        case .audio:
            ["voice", "mood", "duration"]
        }
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
        case .audio:
            assetKind == .audio
        case .text:
            assetKind.isTextDocumentLike || assetKind == .document
        }
    }

    private func defaultModel(for assetKind: AssetKind) -> (id: String, name: String) {
        switch assetKind {
        case .video:
            ("seedance_2", "Seedance 2.0")
        case .image:
            ("image_2", "GPT Image 2")
        case .audio, .markdown, .json, .document, .text, .data, .source, .raw, .threeD, .texture, .font, .web, .unknown:
            ("local_asset", "Local Asset")
        }
    }

    private func mediaImportModels() -> [String: MediaImportModel] {
        let image = defaultModel(for: .image)
        let video = defaultModel(for: .video)
        let audio = defaultModel(for: .audio)
        let text = defaultModel(for: .text)
        return [
            PromptType.image.rawValue: MediaImportModel(id: image.id, name: image.name),
            PromptType.video.rawValue: MediaImportModel(id: video.id, name: video.name),
            PromptType.audio.rawValue: MediaImportModel(id: audio.id, name: audio.name),
            PromptType.text.rawValue: MediaImportModel(id: text.id, name: text.name)
        ]
    }

    private static func makeMediaImportService(libraryURL: URL) -> MediaImportService {
        MediaImportService(
            libraryURL: libraryURL,
            maxConcurrentFileTasks: 2,
            dependencies: MediaImportDependencies(
                resolveAssetKind: { AppKitBridge.assetKind(for: $0) },
                inspectFile: { url, assetKind in
                    let info = AppKitBridge.fileInfo(for: url, assetKind: assetKind)
                    return MediaImportFileInfo(
                        width: info.width,
                        height: info.height,
                        fileSize: info.fileSize,
                        format: info.format
                    )
                },
                parsePrompt: { url, assetKind in
                    let support = AssetFormatCatalog.support(forFileExtension: url.pathExtension)
                    guard assetKind.isTextDocumentLike || support.canExtractPrompt else {
                        return ParsedPromptMetadata()
                    }
                    guard let text = AppKitBridge.readDocumentText(from: url) ?? Self.readImportTextFile(url) else {
                        return ParsedPromptMetadata()
                    }
                    return PromptImportParser.parse(text: text, assetKind: assetKind)
                }
            )
        )
    }

    private nonisolated static func readImportTextFile(_ url: URL) -> String? {
        let maxBytes = 2 * 1024 * 1024
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]), data.count <= maxBytes else {
            return nil
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .isoLatin1)
    }

    private func applyMediaImportResult(_ result: MediaImportResult) {
        guard !result.importedItems.isEmpty else {
            tags = result.tags
            return
        }

        let firstImportedItem = result.importedItems[0]
        if !itemWouldBeVisibleUnderCurrentFilter(firstImportedItem) {
            isBatchingFilterUpdate = true
            filter = PromptFilter()
            isBatchingFilterUpdate = false
        }

        items = items + result.importedItems
        tags = result.tags
        updateSelection(ids: [firstImportedItem.id], primaryID: firstImportedItem.id)
        libraryStatisticsCache.invalidate(repository: repository, folders: folders)
    }

    private func itemWouldBeVisibleUnderCurrentFilter(_ item: PromptItem) -> Bool {
        if case .folder(let folderID) = filter.collection, item.folderId != folderID {
            return false
        }
        var adjustedFilter = filter
        adjustedFilter.collection = .all
        return PromptFiltering.apply([item], filter: adjustedFilter).contains(where: { $0.id == item.id })
    }

    private func finishMediaImport(result: MediaImportResult, sessionID: UUID) {
        guard mediaImportSessionID == sessionID else { return }
        mediaImportTask = nil
        importProgressState.update(progress: MediaImportProgress(
            phase: .completed,
            current: result.importedItems.count + result.failures.count + result.skippedCount,
            total: result.importedItems.count + result.failures.count + result.skippedCount,
            currentFileName: nil,
            successCount: result.importedItems.count,
            failureCount: result.failures.count
        ), failures: result.failures)

        if result.failures.isEmpty {
            if result.importedItems.isEmpty {
                showToast(result.skippedCount > 0 ? "没有符合当前文件夹类型的素材" : "未导入素材")
            } else if result.skippedCount > 0 {
                showToast("导入完成，已跳过 \(result.skippedCount) 个不匹配文件")
            } else {
                showToast("已导入 \(result.importedItems.count) 个素材")
            }
            importStatusDismissTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, self?.mediaImportSessionID == sessionID else { return }
                self?.dismissImportStatus()
            }
        } else {
            showToast("成功导入 \(result.importedItems.count) 个，\(result.failures.count) 个失败")
        }
    }

    private func finishMediaImportWithoutResult(sessionID: UUID, message: String? = nil) {
        guard mediaImportSessionID == sessionID else { return }
        mediaImportTask = nil
        mediaImportSessionID = nil
        importProgressState.reset()
        if let message {
            showToast(message)
        }
    }

    func dismissImportStatus() {
        guard mediaImportTask == nil else { return }
        importStatusDismissTask?.cancel()
        importStatusDismissTask = nil
        mediaImportSessionID = nil
        importProgressState.reset()
    }

    private func parsedPromptMetadata(for fileURL: URL, assetKind: AssetKind) -> ParsedPromptMetadata {
        let support = AssetFormatCatalog.support(forFileExtension: fileURL.pathExtension)
        guard assetKind.isTextDocumentLike || support.canExtractPrompt else {
            return ParsedPromptMetadata()
        }
        let text = AppKitBridge.readDocumentText(from: fileURL) ?? readTextFile(fileURL)
        guard let text else { return ParsedPromptMetadata() }
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

    private static func isSupportedExternalMainAssetURL(_ url: URL) -> Bool {
        switch AssetFormatCatalog.support(forFileExtension: url.pathExtension).previewMode {
        case .image, .video, .audio, .textDocument:
            return true
        case .document, .reference, .generic:
            return false
        }
    }

    private static func isSupportedExternalTextPreviewURL(_ url: URL) -> Bool {
        AssetFormatCatalog.support(forFileExtension: url.pathExtension).previewMode == .textDocument
    }

    private static func readExternalText(from url: URL) -> String {
        if let documentText = AppKitBridge.readDocumentText(from: url) {
            return documentText
        }
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        if let text = try? String(contentsOf: url, encoding: .utf16) {
            return text
        }
        return ""
    }

    private static func cleanedTitle(from url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        let pattern = #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}-"#
        return name.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }

    private func shouldHandleExternalOpen(_ urls: [URL]) -> Bool {
        let signature = urls
            .map { $0.standardizedFileURL.path }
            .sorted()
            .joined(separator: "\n")
        let now = Date()
        defer {
            lastExternalOpenSignature = signature
            lastExternalOpenAt = now
        }
        guard lastExternalOpenSignature == signature,
              let lastExternalOpenAt,
              now.timeIntervalSince(lastExternalOpenAt) < 1.0 else {
            return true
        }
        return false
    }

    private func itemMatchingExternalURL(_ url: URL) -> PromptItem? {
        let externalPath = url.standardizedFileURL.path
        return items.first { item in
            guard !item.assetPath.isEmpty else { return false }
            return URL(fileURLWithPath: item.assetPath).standardizedFileURL.path == externalPath
        }
    }

    private func revealAndOpenExternalItem(_ item: PromptItem) {
        isBatchingFilterUpdate = true
        filter = PromptFilter()
        isBatchingFilterUpdate = false
        refreshFilteredItems(selecting: item.id, preserveExistingSelection: false)
        previewSelected()
        showToast(item.isTextDocumentLike ? "已打开文档" : "已打开素材")
    }

    private func reload(selecting id: String? = nil) {
        do {
            folders = try repository?.loadFolders() ?? []
            let validFolderIDs = selectedFolderIDs.intersection(Set(folders.map(\.id)))
            if validFolderIDs.isEmpty {
                clearSelectedFolder()
            } else if validFolderIDs != selectedFolderIDs {
                selectFolders(ids: validFolderIDs, primaryID: selectedFolderID)
            }
            items = try repository?.loadItems() ?? []
            tags = try repository?.loadTags() ?? []
            refreshFilteredItems(selecting: id)
            libraryStatisticsCache.invalidate(repository: repository, folders: folders)
        } catch {
            modal = .error(error.localizedDescription)
        }
    }

    private func rebuildItemLookup() {
        itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        itemIndexByID = Dictionary(uniqueKeysWithValues: items.indices.map { (items[$0].id, $0) })
    }

    private func handleItemsChanged(from oldItems: [PromptItem]) {
        masonryDatasetRevision.dataRevision &+= 1

        let oldByID = Dictionary(uniqueKeysWithValues: oldItems.map { ($0.id, $0) })
        let removedIDs = Set(oldByID.keys).subtracting(itemsByID.keys)
        let changedItems = items.filter { oldByID[$0.id] != $0 }
        let requiresFullBuild = libraryFilterSnapshot == nil
            || oldItems.isEmpty
            || filterSnapshotTask != nil
            || changedItems.count + removedIDs.count > max(1_000, items.count / 3)
        filterSnapshotTask?.cancel()
        if requiresFullBuild {
            let currentItems = items
            let startedAt = DebugPerformanceProbe.now()
            filterSnapshotTask = Task { [weak self] in
                let snapshot = await Task.detached(priority: .userInitiated) {
                    LibraryFilterSnapshot(items: currentItems)
                }.value
                guard !Task.isCancelled, let self else { return }
                self.libraryFilterSnapshot = snapshot
                self.filterSnapshotTask = nil
                DebugPerformanceProbe.recordDuration("filter.snapshot.build.ms", startedAt: startedAt)
                DebugPerformanceProbe.record("filter.snapshot.item_count", value: Double(snapshot.count))
                self.refreshFilteredItems()
            }
        } else if let snapshot = libraryFilterSnapshot, !changedItems.isEmpty || !removedIDs.isEmpty {
            filterSnapshotTask = Task { [weak self] in
                await Task.detached(priority: .utility) {
                    _ = snapshot.remove(ids: removedIDs)
                    snapshot.upsert(contentsOf: changedItems)
                }.value
                guard !Task.isCancelled, let self else { return }
                self.filterSnapshotTask = nil
                DebugPerformanceProbe.record("filter.snapshot.incremental_count", value: Double(changedItems.count + removedIDs.count))
                self.refreshFilteredItems()
            }
        } else {
            refreshFilteredItems()
        }

        if statisticsChanged(oldByID: oldByID, changedItems: changedItems, removedIDs: removedIDs) {
            libraryStatisticsCache.invalidate(repository: repository, folders: folders)
        }
    }

    private func statisticsChanged(
        oldByID: [String: PromptItem],
        changedItems: [PromptItem],
        removedIDs: Set<String>
    ) -> Bool {
        guard !removedIDs.isEmpty || !changedItems.isEmpty else { return false }
        if !removedIDs.isEmpty { return true }
        for item in changedItems {
            guard let old = oldByID[item.id] else { return true }
            if old.folderId != item.folderId
                || old.favorite != item.favorite
                || old.isDeleted != item.isDeleted
                || Self.hasRecentUse(old) != Self.hasRecentUse(item) {
                return true
            }
        }
        return false
    }

    private func updateFilterPreservingSelection(_ updates: (inout PromptFilter) -> Void) {
        var nextFilter = filter
        updates(&nextFilter)
        isBatchingFilterUpdate = true
        filter = nextFilter
        isBatchingFilterUpdate = false
        refreshFilteredItems(preserveExistingSelection: true)
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

    private func refreshFilteredItems(
        selecting requestedID: String? = nil,
        preserveExistingSelection: Bool = true,
        allowEmptySelection: Bool = false
    ) {
        guard let snapshot = libraryFilterSnapshot else { return }
        filterTask?.cancel()
        filterGeneration &+= 1
        let generation = filterGeneration
        let requestedFilter = filter
        filterTask = Task { [weak self] in
            do {
                let result = try await snapshot.filter(requestedFilter)
                guard !Task.isCancelled, let self, generation == self.filterGeneration else { return }
                let nextFilteredItems = result.ids.compactMap { self.itemsByID[$0] }
                self.libraryFilterController.record(result: result)
                DebugPerformanceProbe.record("filter.apply.ms", value: result.durationMilliseconds)
                DebugPerformanceProbe.record("filter.scanned_count", value: Double(result.scannedCount))
                self.masonryDatasetRevision.queryRevision &+= 1
                self.filteredItems = nextFilteredItems

                if let requestedID, self.itemsByID[requestedID] != nil,
                   result.ids.contains(requestedID) {
                    if requestedID != self.selectedID {
                        self.updateSelection(ids: [requestedID], primaryID: requestedID)
                    }
                } else {
                    let nextSelectedID = PromptSelectionResolver.selectedID(
                        preserving: preserveExistingSelection ? self.selectedID : nil,
                        in: nextFilteredItems,
                        allowEmptySelection: allowEmptySelection
                    )
                    if nextSelectedID != self.selectedID {
                        self.updateSelection(
                            ids: nextSelectedID.map { Set([$0]) } ?? [],
                            primaryID: nextSelectedID
                        )
                    }
                }
                self.filterTask = nil
            } catch is CancellationError {
                DebugPerformanceProbe.record("filter.cancelled")
            } catch {
                self?.filterTask = nil
            }
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

    private func prioritizeReferenceThumbnails(for item: PromptItem) {
        let imageReferences = item.referenceAssets.filter(Self.isImageReferenceAsset)
        guard let service = referenceThumbnailService, !imageReferences.isEmpty else { return }
        referenceThumbnailPriorityTask?.cancel()
        referenceThumbnailPriorityTask = Task(priority: .userInitiated) {
            await service.prewarm(imageReferences, priority: .userInitiated)
        }
    }

    private static func isImageReferenceAsset(_ reference: ReferenceAsset) -> Bool {
        let pathExtension = URL(fileURLWithPath: reference.path).pathExtension
        let format = pathExtension.isEmpty ? reference.type : pathExtension
        return AssetFormatCatalog.support(forFileExtension: format).assetKind == .image
    }

    private nonisolated static func recordReferenceThumbnailProbe(_ event: ReferenceThumbnailService.ProbeEvent) {
        switch event {
        case .hit:
            DebugPerformanceProbe.record("reference.thumbnail.hit")
        case .miss:
            DebugPerformanceProbe.record("reference.thumbnail.miss")
        case .generation(let milliseconds):
            DebugPerformanceProbe.record("reference.thumbnail.generation.ms", value: milliseconds)
        case .failure:
            DebugPerformanceProbe.record("reference.thumbnail.failure")
        }
    }

    private func applyGeneratedThumbnails(_ generated: [(String, String)]) {
        guard !generated.isEmpty else { return }
        let updates = Dictionary(generated, uniquingKeysWith: { _, latest in latest })
        guard let thumbnailPathBatcher else { return }
        Task { [weak self] in
            do {
                _ = try await thumbnailPathBatcher.enqueue(updates)
            } catch {
                await MainActor.run { self?.showToast("缩略图更新失败") }
            }
        }
    }

    private func commitThumbnailPaths(_ updates: [String: String]) {
        guard !updates.isEmpty else { return }
        for (itemID, path) in updates {
            guard var item = itemsByID[itemID] else { continue }
            item.thumbnailPath = path
            itemsByID[itemID] = item
        }
        thumbnailUpdateState.apply(updates)
        DebugPerformanceProbe.record("thumbnail.persist.batch_size", value: Double(updates.count))
    }

    func thumbnailPathOverride(for itemID: String) -> String? {
        thumbnailUpdateState.path(for: itemID)
    }

    private func invalidateAndRegenerateTextThumbnail(for item: PromptItem) {
        guard item.isTextDocumentLike else { return }
        ThumbnailService.invalidateGeneratedThumbnail(for: item, libraryURL: libraryURL)
        applyGeneratedThumbnails([(item.id, item.assetPath)])

        let candidate = itemsByID[item.id] ?? item
        startThumbnailGeneration(for: [candidate])
    }

    func prepareVisibleThumbnails(for itemIDs: [String]) {
        guard !itemIDs.isEmpty else { return }
        var candidates: [PromptItem] = []
        var existingGenerated: [(String, String)] = []

        for itemID in itemIDs {
            guard var item = itemsByID[itemID],
                  item.supportsGeneratedThumbnail,
                  item.hasAvailablePrimaryAsset,
                  !item.isTextDocumentLike else {
                continue
            }
            if let override = thumbnailUpdateState.path(for: itemID) {
                item.thumbnailPath = override
            }

            if let existingPath = ThumbnailService.existingThumbnailPath(for: item, libraryURL: libraryURL) {
                if existingPath != item.thumbnailPath {
                    existingGenerated.append((item.id, existingPath))
                }
            } else {
                candidates.append(item)
            }
        }

        applyGeneratedThumbnails(existingGenerated)
        startThumbnailGeneration(for: candidates)
    }

    private func startThumbnailGeneration(for candidates: [PromptItem]) {
        let uniqueCandidates = candidates.filter { !activeThumbnailItemIDs.contains($0.id) }
        guard !uniqueCandidates.isEmpty else { return }
        let generationID = UUID()
        let itemIDs = Set(uniqueCandidates.map(\.id))
        activeThumbnailGenerationIDs.insert(generationID)
        activeThumbnailGenerationBatches[generationID] = itemIDs
        activeThumbnailItemIDs.formUnion(itemIDs)
        ThumbnailGenerationCenter.shared.start(
            candidates: uniqueCandidates,
            libraryURL: libraryURL,
            generationID: generationID,
            receiver: self
        )
    }

    func showToast(_ message: String) {
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
        if item.isTextDocumentLike {
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
        item.isTextDocumentLike ? markdownDocumentText(for: item) : markdownPrompt(for: item)
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

    private func createTextPromptAssetIfNeeded(
        title: String,
        type: PromptType,
        prompt: String,
        parameters _: [String: String],
        hasPrimaryAsset: Bool
    ) throws -> URL? {
        guard type == .text, !hasPrimaryAsset, let repository else { return nil }
        let directory = repository.libraryURL.appendingPathComponent("assets/documents")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let baseName = safeExportFileName(title.isEmpty ? "Untitled Prompt" : title)
        let destination = directory.appendingPathComponent("\(UUID().uuidString)-\(baseName).md")
        try prompt.write(to: destination, atomically: true, encoding: .utf8)
        return destination
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
        updateSelection(ids: [itemID], primaryID: itemID)
    }
}

extension AppState: ThumbnailGenerationReceiver {
    func thumbnailGenerationDidFinish(_ generated: [(String, String)], generationID: UUID) {
        guard activeThumbnailGenerationIDs.remove(generationID) != nil else { return }
        if let itemIDs = activeThumbnailGenerationBatches.removeValue(forKey: generationID) {
            activeThumbnailItemIDs.subtract(itemIDs)
        }
        applyGeneratedThumbnails(generated)
    }
}
