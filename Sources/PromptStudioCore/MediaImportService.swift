import Foundation

public enum MediaImportPhase: String, Equatable, Sendable {
    case scanning
    case preparing
    case importing
    case saving
    case completed
}

public struct MediaImportProgress: Equatable, Sendable {
    public let phase: MediaImportPhase
    public let current: Int
    public let total: Int?
    public let currentFileName: String?
    public let successCount: Int
    public let failureCount: Int

    public init(
        phase: MediaImportPhase,
        current: Int,
        total: Int?,
        currentFileName: String?,
        successCount: Int,
        failureCount: Int
    ) {
        self.phase = phase
        self.current = current
        self.total = total
        self.currentFileName = currentFileName
        self.successCount = successCount
        self.failureCount = failureCount
    }

    public var fractionCompleted: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(current) / Double(total))
    }
}

public struct MediaImportFailure: Equatable, Sendable {
    public let fileName: String
    public let path: String
    public let reason: String

    public init(fileName: String, path: String, reason: String) {
        self.fileName = fileName
        self.path = path
        self.reason = reason
    }
}

public struct MediaImportModel: Equatable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct MediaImportFileInfo: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let fileSize: Int64
    public let format: String

    public init(width: Int, height: Int, fileSize: Int64, format: String) {
        self.width = width
        self.height = height
        self.fileSize = fileSize
        self.format = format
    }
}

public struct MediaImportRequest: Sendable {
    public let sourceFiles: [URL]
    public let targetFolderID: String
    public let targetFolderName: String
    public let acceptedType: PromptType?
    public let firstSortOrder: Int
    public let modelsByType: [String: MediaImportModel]

    public init(
        sourceFiles: [URL],
        targetFolderID: String,
        targetFolderName: String,
        acceptedType: PromptType?,
        firstSortOrder: Int,
        modelsByType: [String: MediaImportModel]
    ) {
        self.sourceFiles = sourceFiles
        self.targetFolderID = targetFolderID
        self.targetFolderName = targetFolderName
        self.acceptedType = acceptedType
        self.firstSortOrder = firstSortOrder
        self.modelsByType = modelsByType
    }
}

public struct MediaImportMetrics: Equatable, Sendable {
    public let prepareMilliseconds: Double
    public let persistMilliseconds: Double

    public init(prepareMilliseconds: Double, persistMilliseconds: Double) {
        self.prepareMilliseconds = prepareMilliseconds
        self.persistMilliseconds = persistMilliseconds
    }
}

public struct MediaImportResult: Sendable {
    public let importedItems: [PromptItem]
    public let tags: [Tag]
    public let skippedCount: Int
    public let failures: [MediaImportFailure]
    public let metrics: MediaImportMetrics

    public init(
        importedItems: [PromptItem],
        tags: [Tag],
        skippedCount: Int,
        failures: [MediaImportFailure],
        metrics: MediaImportMetrics
    ) {
        self.importedItems = importedItems
        self.tags = tags
        self.skippedCount = skippedCount
        self.failures = failures
        self.metrics = metrics
    }
}

public struct MediaImportDependencies: Sendable {
    public typealias AssetKindResolver = @Sendable (URL) -> AssetKind
    public typealias FileInspector = @Sendable (URL, AssetKind) throws -> MediaImportFileInfo
    public typealias PromptParser = @Sendable (URL, AssetKind) throws -> ParsedPromptMetadata

    public let resolveAssetKind: AssetKindResolver
    public let inspectFile: FileInspector
    public let parsePrompt: PromptParser

    public init(
        resolveAssetKind: @escaping AssetKindResolver,
        inspectFile: @escaping FileInspector,
        parsePrompt: @escaping PromptParser
    ) {
        self.resolveAssetKind = resolveAssetKind
        self.inspectFile = inspectFile
        self.parsePrompt = parsePrompt
    }
}

public enum MediaImportError: Error, LocalizedError, Sendable {
    case unreadableMedia(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableMedia(let name):
            "无法读取媒体文件：\(name)"
        }
    }
}

public actor MediaImportService {
    public typealias ProgressHandler = @Sendable (MediaImportProgress) async -> Void

    private enum FileOutcome: Sendable {
        case prepared(index: Int, item: PromptItem, copiedURL: URL)
        case failed(index: Int, failure: MediaImportFailure)
        case skipped(index: Int)
        case cancelled(index: Int)

        var index: Int {
            switch self {
            case .prepared(let index, _, _),
                 .failed(let index, _),
                 .skipped(let index),
                 .cancelled(let index):
                index
            }
        }
    }

    private let libraryURL: URL
    private let maxConcurrentFileTasks: Int
    private let dependencies: MediaImportDependencies

    public init(
        libraryURL: URL,
        maxConcurrentFileTasks: Int = 2,
        dependencies: MediaImportDependencies
    ) {
        self.libraryURL = libraryURL
        self.maxConcurrentFileTasks = min(2, max(1, maxConcurrentFileTasks))
        self.dependencies = dependencies
    }

    public func scan(_ urls: [URL]) -> [URL] {
        var files: [URL] = []
        var seen = Set<String>()
        for url in urls {
            guard !Task.isCancelled else { break }
            appendImportURLs(from: url, into: &files, seen: &seen)
        }
        return files
    }

    public func importFiles(
        _ request: MediaImportRequest,
        progress: ProgressHandler
    ) async throws -> MediaImportResult {
        let total = request.sourceFiles.count
        await progress(
            MediaImportProgress(
                phase: .preparing,
                current: 0,
                total: total,
                currentFileName: nil,
                successCount: 0,
                failureCount: 0
            )
        )

        let repository = try PromptRepository(libraryURL: libraryURL)
        let prepareStart = Self.now()
        let outcomes = await processFiles(
            request: request,
            repository: repository,
            progress: progress
        )
        let prepareMilliseconds = Self.elapsedMilliseconds(since: prepareStart)

        let sortedOutcomes = outcomes.sorted { $0.index < $1.index }
        let prepared = sortedOutcomes.compactMap { outcome -> (PromptItem, URL)? in
            guard case .prepared(_, let item, let copiedURL) = outcome else { return nil }
            return (item, copiedURL)
        }
        let preparedItems = prepared.map(\.0)
        let copiedURLs = prepared.map(\.1)
        let failures = sortedOutcomes.compactMap { outcome -> MediaImportFailure? in
            guard case .failed(_, let failure) = outcome else { return nil }
            return failure
        }
        let skippedCount = sortedOutcomes.reduce(into: 0) { count, outcome in
            if case .skipped = outcome { count += 1 }
        }

        await progress(
            MediaImportProgress(
                phase: .saving,
                current: total,
                total: total,
                currentFileName: nil,
                successCount: preparedItems.count,
                failureCount: failures.count
            )
        )

        let persistStart = Self.now()
        var didPersist = false
        do {
            try Task.checkCancellation()
            if !preparedItems.isEmpty {
                try repository.saveItems(preparedItems)
            }
            didPersist = true
            let tags = try repository.loadTags()
            let persistMilliseconds = Self.elapsedMilliseconds(since: persistStart)
            await progress(
                MediaImportProgress(
                    phase: .completed,
                    current: total,
                    total: total,
                    currentFileName: nil,
                    successCount: preparedItems.count,
                    failureCount: failures.count
                )
            )
            return MediaImportResult(
                importedItems: preparedItems,
                tags: tags,
                skippedCount: skippedCount,
                failures: failures,
                metrics: MediaImportMetrics(
                    prepareMilliseconds: prepareMilliseconds,
                    persistMilliseconds: persistMilliseconds
                )
            )
        } catch {
            if !didPersist {
                Self.removeFiles(copiedURLs)
            }
            throw error
        }
    }

    private func processFiles(
        request: MediaImportRequest,
        repository: PromptRepository,
        progress: ProgressHandler
    ) async -> [FileOutcome] {
        let sources = Array(request.sourceFiles.enumerated())
        guard !sources.isEmpty else { return [] }

        var nextSourceIndex = 0
        var outcomes: [FileOutcome] = []
        var completed = 0
        var successCount = 0
        var failureCount = 0

        await withTaskGroup(of: FileOutcome.self) { group in
            let initialCount = min(maxConcurrentFileTasks, sources.count)
            for _ in 0..<initialCount {
                let source = sources[nextSourceIndex]
                nextSourceIndex += 1
                group.addTask {
                    Self.processFile(
                        index: source.offset,
                        sourceURL: source.element,
                        request: request,
                        repository: repository,
                        dependencies: self.dependencies
                    )
                }
            }

            while let outcome = await group.next() {
                outcomes.append(outcome)
                completed += 1
                switch outcome {
                case .prepared:
                    successCount += 1
                case .failed:
                    failureCount += 1
                case .skipped, .cancelled:
                    break
                }
                let fileName = request.sourceFiles[outcome.index].lastPathComponent
                await progress(
                    MediaImportProgress(
                        phase: .importing,
                        current: completed,
                        total: sources.count,
                        currentFileName: fileName,
                        successCount: successCount,
                        failureCount: failureCount
                    )
                )

                if nextSourceIndex < sources.count {
                    let source = sources[nextSourceIndex]
                    nextSourceIndex += 1
                    group.addTask {
                        Self.processFile(
                            index: source.offset,
                            sourceURL: source.element,
                            request: request,
                            repository: repository,
                            dependencies: self.dependencies
                        )
                    }
                }
            }
        }
        return outcomes
    }

    private nonisolated static func processFile(
        index: Int,
        sourceURL: URL,
        request: MediaImportRequest,
        repository: PromptRepository,
        dependencies: MediaImportDependencies
    ) -> FileOutcome {
        if Task.isCancelled { return .cancelled(index: index) }
        let assetKind = dependencies.resolveAssetKind(sourceURL)
        let type = assetKind.promptType
        if let acceptedType = request.acceptedType,
           !Self.assetKind(assetKind, matches: acceptedType) {
            return .skipped(index: index)
        }

        var copiedURL: URL?
        do {
            let copied = try repository.copyAssetIntoLibrary(from: sourceURL, assetKind: assetKind)
            copiedURL = copied
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: copied)
                return .cancelled(index: index)
            }
            let info = try dependencies.inspectFile(copied, assetKind)
            try validate(info: info, kind: assetKind, fileName: sourceURL.lastPathComponent)
            let parsed = try dependencies.parsePrompt(copied, assetKind)
            let model = request.modelsByType[type.rawValue]
                ?? MediaImportModel(id: "local_asset", name: "Local Asset")
            let id = UUID().uuidString
            let item = PromptItem(
                id: id,
                title: sourceURL.deletingPathExtension().lastPathComponent,
                type: type,
                assetKind: assetKind,
                modelId: model.id,
                modelName: model.name,
                folderId: request.targetFolderID,
                folderName: request.targetFolderName,
                category: assetKind.displayName,
                assetPath: copied.path,
                aspectRatio: normalizedAspectRatio(width: info.width, height: info.height),
                width: info.width,
                height: info.height,
                format: info.format,
                fileSize: info.fileSize,
                sortOrder: request.firstSortOrder + index,
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
            return .prepared(index: index, item: item, copiedURL: copied)
        } catch {
            if let copiedURL {
                try? FileManager.default.removeItem(at: copiedURL)
            }
            return .failed(
                index: index,
                failure: MediaImportFailure(
                    fileName: sourceURL.lastPathComponent,
                    path: sourceURL.path,
                    reason: error.localizedDescription
                )
            )
        }
    }

    private func appendImportURLs(from url: URL, into files: inout [URL], seen: inout Set<String>) {
        let standardized = url.standardizedFileURL
        let resourceValues = try? standardized.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isHiddenKey])
        guard resourceValues?.isHidden != true,
              !standardized.lastPathComponent.hasPrefix(".") else { return }

        if resourceValues?.isDirectory == true {
            guard let enumerator = FileManager.default.enumerator(
                at: standardized,
                includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey],
                options: [.skipsHiddenFiles]
            ) else { return }
            for case let fileURL as URL in enumerator {
                guard !Task.isCancelled else { break }
                let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isHiddenKey])
                guard values?.isRegularFile == true, values?.isHidden != true else { continue }
                let path = fileURL.standardizedFileURL.path
                if seen.insert(path).inserted { files.append(fileURL.standardizedFileURL) }
            }
        } else if resourceValues?.isRegularFile == true {
            if seen.insert(standardized.path).inserted { files.append(standardized) }
        }
    }

    private nonisolated static func validate(
        info: MediaImportFileInfo,
        kind: AssetKind,
        fileName: String
    ) throws {
        if (kind == .image || kind == .video || kind == .audio), info.fileSize <= 0 {
            throw MediaImportError.unreadableMedia(fileName)
        }
        if (kind == .image || kind == .video), (info.width <= 0 || info.height <= 0) {
            throw MediaImportError.unreadableMedia(fileName)
        }
    }

    private nonisolated static func assetKind(_ assetKind: AssetKind, matches type: PromptType) -> Bool {
        switch type {
        case .image: assetKind == .image
        case .video: assetKind == .video
        case .audio: assetKind == .audio
        case .text: assetKind.isTextDocumentLike || assetKind == .document
        }
    }

    private nonisolated static func normalizedAspectRatio(width: Int, height: Int) -> String {
        guard width > 0, height > 0 else { return "" }
        let divisor = greatestCommonDivisor(width, height)
        return "\(width / divisor):\(height / divisor)"
    }

    private nonisolated static func greatestCommonDivisor(_ lhs: Int, _ rhs: Int) -> Int {
        var a = abs(lhs)
        var b = abs(rhs)
        while b != 0 {
            (a, b) = (b, a % b)
        }
        return max(a, 1)
    }

    private nonisolated static func removeFiles(_ urls: [URL]) {
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private nonisolated static func now() -> Double {
        ProcessInfo.processInfo.systemUptime
    }

    private nonisolated static func elapsedMilliseconds(since start: Double) -> Double {
        max(0, (now() - start) * 1_000)
    }
}
