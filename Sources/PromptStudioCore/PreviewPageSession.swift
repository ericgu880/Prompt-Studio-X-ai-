import Combine
import Foundation

/// Navigation direction for a Summary-backed preview rail.
public enum PreviewPageNavigationDirection: Equatable, Sendable {
    case previous
    case next
}

/// Owns the Summary IDs used by one preview session. The session deliberately
/// keeps only bounded card projections and delegates content loading to the
/// one shared ItemDetailController supplied by the composition root.
@MainActor
public final class PreviewPageSession: ObservableObject {
    @Published public private(set) var queryFingerprint = ""
    @Published public private(set) var dataRevision: UInt64 = 0
    @Published public private(set) var generation: UInt64 = 0
    @Published public private(set) var loadedSummaries: [LibraryItemSummary] = []
    @Published public private(set) var cursor: LibraryQueryCursor?
    @Published public private(set) var hasMore = false
    @Published public private(set) var isLoading = false
    @Published public private(set) var error: Error?

    public let browser: LibraryBrowserState
    public let detailController: ItemDetailController

    public var loadedSummaryIDs: [String] { loadedSummaries.map(\.id) }

    private var query: LibraryQuery?
    private var currentID: String?
    private var tailLoadInFlight = false

    public init(browser: LibraryBrowserState, detailController: ItemDetailController) {
        self.browser = browser
        self.detailController = detailController
        dataRevision = browser.dataRevision
    }

    /// Starts or restarts one fingerprint/revision-bound session. The initial
    /// page is obtained from the same BrowserState used by the Summary surface.
    public func start(query rawQuery: LibraryQuery, selectedID: String? = nil) async {
        generation &+= 1
        let requestGeneration = generation
        var nextQuery = rawQuery
        nextQuery.cursor = nil
        nextQuery.dataRevision = browser.service.dataRevision.current
        query = nextQuery
        self.currentID = selectedID
        cursor = nil
        hasMore = false
        error = nil
        isLoading = true

        await browser.replace(query: nextQuery)
        guard generation == requestGeneration else { return }
        isLoading = false
        error = browser.error
        guard browser.error == nil else {
            loadedSummaries = []
            self.cursor = nil
            hasMore = false
            dataRevision = browser.dataRevision
            queryFingerprint = fingerprint(for: nextQuery) ?? ""
            return
        }

        syncFromBrowser(fallbackQuery: nextQuery)
        if let selectedID, loadedSummaryIDs.contains(selectedID) {
            detailController.select(id: selectedID)
        }
    }

    /// Selects a loaded Summary ID immediately. Full item content is always
    /// requested through the shared detail owner; this method never searches a
    /// full-item array.
    public func select(id: String) async {
        guard loadedSummaryIDs.contains(id) else { return }
        currentID = id
        detailController.select(id: id)
    }

    /// Binds the session to the already-committed Summary browser page. This
    /// is used when a card opens preview after Summary startup; it avoids a
    /// duplicate first-page query while retaining the same browser cursor,
    /// revision, and generation guards used by `start(query:)` in tests and
    /// explicit session restarts.
    public func synchronize(selectedID: String? = nil) {
        generation &+= 1
        tailLoadInFlight = false
        query = browser.currentQuery
        currentID = selectedID ?? browser.selectionID
        isLoading = browser.initial || browser.loadingNext
        error = browser.error
        syncFromBrowser(fallbackQuery: browser.currentQuery)
        if let currentID, loadedSummaryIDs.contains(currentID) {
            detailController.select(id: currentID)
        }
    }

    /// Moves within the resident rail. At the loaded tail, exactly one next
    /// page request is issued; only after its IDs commit does this select the
    /// next ID through the shared detail controller.
    @discardableResult
    public func navigate(_ direction: PreviewPageNavigationDirection) async -> String? {
        guard let currentID,
              let currentIndex = loadedSummaryIDs.firstIndex(of: currentID) else {
            return nil
        }

        let nextIndex: Int
        switch direction {
        case .previous:
            nextIndex = currentIndex - 1
        case .next:
            nextIndex = currentIndex + 1
        }

        if loadedSummaryIDs.indices.contains(nextIndex) {
            let selectedID = loadedSummaryIDs[nextIndex]
            self.currentID = selectedID
            detailController.select(id: selectedID)
            return selectedID
        }

        guard direction == .next, hasMore, !tailLoadInFlight else { return nil }
        guard let query else { return nil }
        tailLoadInFlight = true
        let requestGeneration = generation
        let requestRevision = dataRevision
        let requestFingerprint = queryFingerprint
        let previousCount = loadedSummaries.count
        defer { tailLoadInFlight = false }

        isLoading = true
        await browser.loadNextPage()
        guard generation == requestGeneration else {
            isLoading = false
            return nil
        }

        let observedRevision = browser.dataRevision
        let observedFingerprint = browser.nextCursor?.queryFingerprint
            ?? fingerprint(for: browser.currentQuery)
            ?? requestFingerprint
        let staleRevision = observedRevision != requestRevision
        let staleFingerprint = observedFingerprint != requestFingerprint
        if staleRevision || staleFingerprint || browser.error != nil {
            isLoading = false
            await restartAfterStale(query: query)
            return nil
        }

        syncFromBrowser(fallbackQuery: query)
        isLoading = false
        guard loadedSummaries.count > previousCount else { return nil }
        let selectedID = loadedSummaries[previousCount].id
        self.currentID = selectedID
        detailController.select(id: selectedID)
        return selectedID
    }

    public func reset() {
        generation &+= 1
        tailLoadInFlight = false
        browser.cancel()
        query = nil
        currentID = nil
        loadedSummaries = []
        cursor = nil
        hasMore = false
        isLoading = false
        error = nil
        queryFingerprint = ""
        dataRevision = browser.dataRevision
        detailController.cancel()
    }

    /// Invalidates a UI preview navigation without canceling the shared
    /// browser request. The browser may finish its own Summary append, but
    /// this session cannot append/select a late page after dismissal.
    public func cancelNavigation() {
        generation &+= 1
        tailLoadInFlight = false
        isLoading = false
        currentID = nil
        detailController.cancel()
    }

    private func restartAfterStale(query oldQuery: LibraryQuery) async {
        currentID = nil
        detailController.cancel()
        var nextQuery = oldQuery
        nextQuery.cursor = nil
        nextQuery.dataRevision = browser.service.dataRevision.current
        await start(query: nextQuery)
    }

    private func syncFromBrowser(fallbackQuery: LibraryQuery) {
        var seen = Set<String>()
        loadedSummaries = browser.summaries.filter { seen.insert($0.id).inserted }
        cursor = browser.nextCursor
        hasMore = browser.hasMore
        dataRevision = browser.dataRevision
        queryFingerprint = cursor?.queryFingerprint
            ?? fingerprint(for: browser.currentQuery)
            ?? fingerprint(for: fallbackQuery)
            ?? ""
        error = browser.error
    }

    private func fingerprint(for query: LibraryQuery) -> String? {
        try? LibraryQuerySQLBuilder.build(
            query,
            capabilities: browser.service.capabilities
        ).queryFingerprint
    }
}
