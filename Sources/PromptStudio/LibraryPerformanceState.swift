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

@MainActor
final class LibraryStatisticsCache: ObservableObject {
    @Published private(set) var statistics = LibraryStatistics(
        activeCount: 0,
        favoriteCount: 0,
        recentCount: 0,
        trashCount: 0
    )
    @Published private(set) var descendantFolderCounts: [String: Int] = [:]

    private var refreshTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    func invalidate(repository: PromptRepository?, folders: [LibraryFolder]) {
        generation &+= 1
        let requestedGeneration = generation
        refreshTask?.cancel()
        guard let repository else {
            statistics = LibraryStatistics(activeCount: 0, favoriteCount: 0, recentCount: 0, trashCount: 0)
            descendantFolderCounts = [:]
            return
        }
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .utility) {
                try repository.loadLibraryStatistics()
            }.result
            guard !Task.isCancelled, let self, requestedGeneration == self.generation else { return }
            switch result {
            case .success(let statistics):
                self.statistics = statistics
                self.descendantFolderCounts = Self.aggregateDescendantCounts(
                    direct: statistics.folderCounts,
                    folders: folders
                )
            case .failure:
                break
            }
        }
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
        generation &+= 1
        refreshTask?.cancel()
        refreshTask = nil
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
