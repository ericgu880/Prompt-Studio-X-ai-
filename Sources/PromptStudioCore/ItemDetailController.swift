import Combine
import Foundation

public enum ItemDetailState: String, Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed
}

public enum ItemDetailFailureKind: String, Equatable, Sendable {
    case notFound
    case load
}

public struct ItemDetailNotFoundError: Error, LocalizedError, Equatable, Sendable {
    public let id: String

    public init(id: String) {
        self.id = id
    }

    public var errorDescription: String? {
        "Prompt detail was not found: \(id)"
    }
}

/// MainActor owner for one selected detail request. The controller owns only
/// local selection/load state; repository and AppState integration remain the
/// caller's responsibility.
@MainActor
public final class ItemDetailController: ObservableObject {
    public typealias State = ItemDetailState
    public typealias FailureKind = ItemDetailFailureKind
    /// Called synchronously on the MainActor when a selection starts. It is
    /// intentionally not `@Sendable`: providers commonly close over UI-owned
    /// revision state that is itself MainActor isolated.
    public typealias RevisionProvider = (String) -> UInt64
    public typealias MissingCallback = (String) -> Void

    public let loader: ItemDetailLoading
    public let cache: ItemDetailCache

    @Published public private(set) var state: ItemDetailState = .idle
    @Published public private(set) var selectedID: String?
    @Published public private(set) var currentDetail: PromptItem?
    @Published public private(set) var error: Error?
    @Published public private(set) var failureKind: ItemDetailFailureKind?
    public private(set) var generation: UInt64 = 0
    public private(set) var currentTask: Task<Void, Never>?

    private let revisionProvider: RevisionProvider
    private let missingCallback: MissingCallback?
    private var invalidationSubscription: ItemDetailInvalidationSubscription?

    public init(
        loader: ItemDetailLoading,
        cache: ItemDetailCache = ItemDetailCache(),
        revisionProvider: @escaping RevisionProvider = { _ in 0 },
        missingCallback: MissingCallback? = nil
    ) {
        self.loader = loader
        self.cache = cache
        self.revisionProvider = revisionProvider
        self.missingCallback = missingCallback
        self.invalidationSubscription = nil
        if let invalidationSource = loader as? ItemDetailInvalidationProviding {
            self.invalidationSubscription = invalidationSource.itemDetailInvalidationHub.subscribe { [weak self] event in
                // Hub callbacks may arrive from a migration/writer thread;
                // all visible state and generation changes stay on MainActor.
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if event.invalidateAll {
                        self.invalidateAll()
                    } else {
                        self.invalidate(ids: event.affectedItemIDs)
                    }
                }
            }
        }
    }

    /// Compatibility spelling for callers that use `loading` for the
    /// protocol dependency.
    public convenience init(
        loading: ItemDetailLoading,
        cache: ItemDetailCache = ItemDetailCache(),
        revisionProvider: @escaping RevisionProvider = { _ in 0 },
        missingCallback: MissingCallback? = nil
    ) {
        self.init(
            loader: loading,
            cache: cache,
            revisionProvider: revisionProvider,
            missingCallback: missingCallback
        )
    }

    /// Compatibility spelling for a callback label commonly used by UI
    /// owners. It deliberately forwards to the same MainActor callback path.
    public convenience init(
        loader: ItemDetailLoading,
        cache: ItemDetailCache = ItemDetailCache(),
        revisionProvider: @escaping RevisionProvider = { _ in 0 },
        onMissing: MissingCallback? = nil
    ) {
        self.init(
            loader: loader,
            cache: cache,
            revisionProvider: revisionProvider,
            missingCallback: onMissing
        )
    }

    public var detail: PromptItem? {
        currentDetail
    }

    public var isLoading: Bool {
        state == .loading
    }

    public var isNotFound: Bool {
        state == .failed && failureKind == .notFound
    }

    /// Selects one item and cancels the previous request before starting a new
    /// generation. A nil selection returns to idle without a pending task.
    public func select(id: String?) {
        generation = generation &+ 1
        let requestGeneration = generation
        currentTask?.cancel()
        currentTask = nil
        selectedID = id
        currentDetail = nil
        error = nil
        failureKind = nil

        guard let id else {
            state = .idle
            return
        }

        state = .loading
        let revision = revisionProvider(id)
        let loader = self.loader
        let cache = self.cache
        let cacheToken = cache.token(for: id)

        currentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard !Task.isCancelled,
                  self.generation == requestGeneration,
                  self.selectedID == id else { return }

            if let cached = cache.get(id: id, revision: revision) {
                self.applyLoaded(cached, id: id, generation: requestGeneration)
                return
            }

            do {
                let loaded = try await loader.itemDetail(id: id)
                try Task.checkCancellation()
                guard self.generation == requestGeneration,
                      self.selectedID == id else { return }

                guard let loaded else {
                    cache.invalidate(ids: [id])
                    self.applyNotFound(id: id, generation: requestGeneration)
                    return
                }

                _ = cache.insert(loaded, revision: revision, token: cacheToken)
                self.applyLoaded(loaded, id: id, generation: requestGeneration)
            } catch is CancellationError {
                // Cancellation is expected during rapid selection and must not
                // publish a failure for a request that is no longer current.
            } catch {
                guard !Task.isCancelled,
                      self.generation == requestGeneration,
                      self.selectedID == id else { return }
                self.currentTask = nil
                self.currentDetail = nil
                self.error = error
                self.failureKind = .load
                self.state = .failed
            }
        }
    }

    public func retry() {
        guard let selectedID else { return }
        select(id: selectedID)
    }

    /// Invalidates cache entries and reloads the currently selected item when
    /// affected. The visible detail is cleared while the fresh request runs.
    public func invalidate<S: Sequence>(ids: S) where S.Element == String {
        let requested = Set(ids)
        guard !requested.isEmpty else { return }
        cache.invalidate(ids: requested)
        if let selectedID, requested.contains(selectedID) {
            select(id: selectedID)
        }
    }

    public func invalidate(id: String) {
        invalidate(ids: [id])
    }

    /// Permanently removes entries from the cache. If the current selection is
    /// removed, its in-flight request is cancelled and the selection remains
    /// visible in a failed/not-found state until the caller selects elsewhere.
    public func remove<S: Sequence>(ids: S) where S.Element == String {
        let requested = Set(ids)
        guard !requested.isEmpty else { return }
        cache.remove(ids: requested)
        guard let selectedID, requested.contains(selectedID) else { return }

        generation = generation &+ 1
        currentTask?.cancel()
        currentTask = nil
        currentDetail = nil
        error = ItemDetailNotFoundError(id: selectedID)
        failureKind = .notFound
        state = .failed
    }

    public func remove(id: String) {
        remove(ids: [id])
    }

    public func invalidateAll() {
        cache.invalidateAll()
        if selectedID != nil {
            select(id: selectedID)
        }
    }

    public func cancel() {
        generation = generation &+ 1
        currentTask?.cancel()
        currentTask = nil
        if state == .loading {
            state = selectedID == nil ? .idle : .idle
        }
    }

    private func applyLoaded(_ item: PromptItem, id: String, generation: UInt64) {
        guard self.generation == generation, selectedID == id else { return }
        currentTask = nil
        currentDetail = item
        error = nil
        failureKind = nil
        state = .loaded
    }

    private func applyNotFound(id: String, generation: UInt64) {
        guard self.generation == generation, selectedID == id else { return }
        currentTask = nil
        currentDetail = nil
        let notFound = ItemDetailNotFoundError(id: id)
        error = notFound
        failureKind = .notFound
        state = .failed
        missingCallback?(id)
    }
}
