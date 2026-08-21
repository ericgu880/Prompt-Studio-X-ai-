import Foundation
import PromptStudioCore
import SwiftUI

@MainActor
final class LibraryFilterController: ObservableObject {
    @Published private(set) var draftQuery = ""
    @Published private(set) var lastDurationMilliseconds: Double = 0
    @Published private(set) var lastScannedCount = 0

    private var debounceTask: Task<Void, Never>?
    private var commitHandler: ((String) -> Void)?

    func configure(initialQuery: String, onCommit: @escaping (String) -> Void) {
        commitHandler = onCommit
        setDraftWithoutSubmitting(initialQuery)
    }

    func submitDraft(_ query: String) {
        let startedAt = DebugPerformanceProbe.now()
        draftQuery = query
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            self.commitHandler?(self.draftQuery)
        }
        DebugPerformanceProbe.recordDuration("search.input.main.ms", startedAt: startedAt)
    }

    func submitImmediately(_ query: String) {
        debounceTask?.cancel()
        debounceTask = nil
        draftQuery = query
        commitHandler?(query)
    }

    func setDraftWithoutSubmitting(_ query: String) {
        debounceTask?.cancel()
        debounceTask = nil
        if draftQuery != query { draftQuery = query }
    }

    func record(result: LibraryFilterResult) {
        lastDurationMilliseconds = result.durationMilliseconds
        lastScannedCount = result.scannedCount
    }

    func cancel() {
        debounceTask?.cancel()
        debounceTask = nil
    }
}

enum LibraryStatisticsCacheError: Error, LocalizedError, Equatable, Sendable {
    case staleStatistics(message: String)

    var message: String {
        switch self {
        case .staleStatistics(let message):
            return message
        }
    }

    var errorDescription: String? {
        switch self {
        case .staleStatistics(let message):
            return "Library statistics are stale: \(message)"
        }
    }
}

private enum LibraryStatisticsLoadResult: Sendable {
    case success(LibraryStatistics)
    case failure(message: String)
}

/// Synchronous generation authority shared by the MainActor cache and the
/// coordinator actor. It closes the window where a canceled debounce task has
/// passed its cancellation check but has not yet submitted to the actor.
private final class LibraryStatisticsGenerationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var activeGeneration: UInt64?

    func activate(_ generation: UInt64) {
        lock.withLock { activeGeneration = generation }
    }

    func cancel(_ generation: UInt64) {
        lock.withLock {
            if let active = activeGeneration, active <= generation {
                activeGeneration = nil
            }
        }
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        lock.withLock { activeGeneration == generation }
    }
}

private actor LibraryStatisticsLoadCoordinator {
    typealias Loader = @Sendable (PromptRepository) throws -> LibraryStatistics
    typealias Completion = @Sendable (UInt64, LibraryStatisticsLoadResult) -> Void

    private let loader: Loader
    private let generationGate: LibraryStatisticsGenerationGate
    private var pendingRepository: PromptRepository?
    private var pendingGeneration: UInt64 = 0
    private var pendingCompletion: Completion?
    private var workerTask: Task<Void, Never>?
    private var running = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(loader: @escaping Loader, generationGate: LibraryStatisticsGenerationGate) {
        self.loader = loader
        self.generationGate = generationGate
    }

    func submit(
        repository: PromptRepository,
        generation: UInt64,
        completion: @escaping Completion
    ) {
        guard generationGate.isCurrent(generation) else { return }
        guard generation >= pendingGeneration else { return }
        pendingRepository = repository
        pendingGeneration = generation
        pendingCompletion = completion
        startWorkerIfNeeded()
    }

    func cancelPending() {
        pendingRepository = nil
        pendingCompletion = nil
    }

    func cancelPendingAndWait() async {
        pendingRepository = nil
        pendingCompletion = nil
        guard running else { return }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    private func startWorkerIfNeeded() {
        guard workerTask == nil else { return }
        workerTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    private func runLoop() async {
        while let repository = pendingRepository {
            let generation = pendingGeneration
            let completion = pendingCompletion
            pendingRepository = nil
            pendingCompletion = nil
            guard generationGate.isCurrent(generation) else { continue }
            running = true

            let loader = self.loader
            let result: LibraryStatisticsLoadResult = await Task.detached(priority: .utility) {
                do {
                    return .success(try loader(repository))
                } catch {
                    return .failure(message: error.localizedDescription)
                }
            }.value

            running = false
            completion?(generation, result)
        }

        workerTask = nil
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

@MainActor
final class LibraryStatisticsCache: ObservableObject {
    typealias Loader = @Sendable (PromptRepository) throws -> LibraryStatistics

    @Published private(set) var statistics = LibraryStatistics(
        activeCount: 0,
        favoriteCount: 0,
        recentCount: 0,
        trashCount: 0
    )
    @Published private(set) var descendantFolderCounts: [String: Int] = [:]
    @Published private(set) var staleError: LibraryStatisticsCacheError?
    @Published private(set) var staleErrorMessage: String?

    private let loadCoordinator: LibraryStatisticsLoadCoordinator
    private let generationGate: LibraryStatisticsGenerationGate
    private let refreshDelayNanoseconds: UInt64
    private let beforeSubmit: (@Sendable (UInt64) async -> Void)?
    private var refreshTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var lastRepository: PromptRepository?
    private var lastFolders: [LibraryFolder] = []
    private var lastRepositoryKey: String?

    init(
        refreshDelayNanoseconds: UInt64 = 100_000_000,
        beforeSubmit: (@Sendable (UInt64) async -> Void)? = nil,
        loader: @escaping Loader = { try $0.loadLibraryStatistics() }
    ) {
        let generationGate = LibraryStatisticsGenerationGate()
        self.generationGate = generationGate
        self.refreshDelayNanoseconds = refreshDelayNanoseconds
        self.beforeSubmit = beforeSubmit
        loadCoordinator = LibraryStatisticsLoadCoordinator(loader: loader, generationGate: generationGate)
    }

    var error: LibraryStatisticsCacheError? { staleError }
    var errorMessage: String? { staleErrorMessage }

    func invalidate(repository: PromptRepository?, folders: [LibraryFolder]) {
        generation &+= 1
        let requestedGeneration = generation
        generationGate.activate(requestedGeneration)
        refreshTask?.cancel()
        let repositoryKey = Self.repositoryKey(repository)
        let repositoryReplaced = repositoryKey != lastRepositoryKey
        lastRepository = repository
        lastFolders = folders
        lastRepositoryKey = repositoryKey
        staleError = nil
        staleErrorMessage = nil
        if repositoryReplaced {
            resetStatistics()
        }
        guard let repository else {
            Task { await loadCoordinator.cancelPending() }
            resetStatistics()
            return
        }
        let coordinator = loadCoordinator
        let requestedFolders = folders
        let refreshDelayNanoseconds = refreshDelayNanoseconds
        let beforeSubmit = beforeSubmit
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: refreshDelayNanoseconds)
            guard !Task.isCancelled else { return }
            await beforeSubmit?(requestedGeneration)
            await coordinator.submit(
                repository: repository,
                generation: requestedGeneration
            ) { [weak self] generation, result in
                Task { @MainActor [weak self] in
                    guard let self,
                          generation == self.generation else { return }
                    self.apply(result, folders: requestedFolders)
                    self.refreshTask = nil
                }
            }
        }
    }

    func retry() {
        guard let lastRepository else { return }
        invalidate(repository: lastRepository, folders: lastFolders)
    }

    func recomputeFolderHierarchy(_ folders: [LibraryFolder]) {
        descendantFolderCounts = Self.aggregateDescendantCounts(
            direct: statistics.folderCounts,
            folders: folders
        )
    }

    func count(includingDescendants folderID: String) -> Int {
        descendantFolderCounts[folderID] ?? statistics.folderCounts[folderID] ?? 0
    }

    func cancel() {
        clearForCancellation()
        Task { await loadCoordinator.cancelPending() }
    }

    func cancelAndWait() async {
        clearForCancellation()
        await loadCoordinator.cancelPendingAndWait()
    }

    private func apply(_ result: LibraryStatisticsLoadResult, folders: [LibraryFolder]) {
        switch result {
        case .success(let statistics):
            self.statistics = statistics
            descendantFolderCounts = Self.aggregateDescendantCounts(
                direct: statistics.folderCounts,
                folders: folders
            )
            staleError = nil
            staleErrorMessage = nil
        case .failure(let message):
            // Keep the last-known snapshot visible. The next explicit
            // invalidate/retry starts one bounded new read; no retry loop
            // can silently hide a persistent statistics failure.
            let staleError = LibraryStatisticsCacheError.staleStatistics(message: message)
            self.staleError = staleError
            staleErrorMessage = staleError.localizedDescription
        }
    }

    private func clearForCancellation() {
        generation &+= 1
        generationGate.cancel(generation)
        refreshTask?.cancel()
        refreshTask = nil
        lastRepository = nil
        lastFolders = []
        lastRepositoryKey = nil
        resetStatistics()
        staleError = nil
        staleErrorMessage = nil
    }

    private func resetStatistics() {
        statistics = LibraryStatistics(activeCount: 0, favoriteCount: 0, recentCount: 0, trashCount: 0)
        descendantFolderCounts = [:]
    }

    private static func repositoryKey(_ repository: PromptRepository?) -> String? {
        repository?.databaseURL.standardizedFileURL.path
    }

    private static func aggregateDescendantCounts(
        direct: [String: Int],
        folders: [LibraryFolder]
    ) -> [String: Int] {
        let children = Dictionary(grouping: folders, by: \LibraryFolder.parentId)
        var result: [String: Int] = [:]
        var visiting = Set<String>()

        func total(for folderID: String) -> Int {
            if let cached = result[folderID] { return cached }
            guard visiting.insert(folderID).inserted else { return direct[folderID] ?? 0 }
            var count = direct[folderID] ?? 0
            for child in children[folderID] ?? [] {
                count += total(for: child.id)
            }
            visiting.remove(folderID)
            result[folderID] = count
            return count
        }

        for folder in folders { _ = total(for: folder.id) }
        return result
    }
}

@MainActor
final class ThumbnailUpdateState: ObservableObject {
    @Published private(set) var revision: UInt64 = 0
    private(set) var pathsByItemID: [String: String] = [:]
    private(set) var changedItemIDs = Set<String>()

    func apply(_ updates: [String: String]) {
        guard !updates.isEmpty else { return }
        for (id, path) in updates {
            pathsByItemID[id] = path
            changedItemIDs.insert(id)
        }
        revision &+= 1
    }

    func path(for itemID: String) -> String? {
        pathsByItemID[itemID]
    }

    func consumeChangedItemIDs() -> Set<String> {
        defer { changedItemIDs.removeAll(keepingCapacity: true) }
        return changedItemIDs
    }

    func reset() {
        pathsByItemID.removeAll(keepingCapacity: false)
        changedItemIDs.removeAll(keepingCapacity: false)
        revision &+= 1
    }
}

@MainActor
final class ImportProgressState: ObservableObject {
    @Published private(set) var progress: MediaImportProgress?
    @Published private(set) var failures: [MediaImportFailure] = []

    func update(progress: MediaImportProgress?, failures: [MediaImportFailure]? = nil) {
        self.progress = progress
        if let failures { self.failures = failures }
    }

    func reset() {
        progress = nil
        failures = []
    }
}

struct MasonryDatasetRevision: Equatable {
    var queryRevision: UInt64 = 0
    var dataRevision: UInt64 = 0
    var folderRevision: UInt64 = 0
    var geometryRevision: UInt64 = 0
}
