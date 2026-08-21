import Foundation
import Testing
import PromptStudioCore

@MainActor
@Test("Preview page session appends one tail page then selects the exact ID through shared detail")
func previewPageSessionAppendsTailAndSelectsExactID() async throws {
    let revision = LibraryDataRevision()
    let executor = PreviewSessionExecutor(pages: [
        [previewSummary(id: "item-0"), previewSummary(id: "item-1"), previewSummary(id: "item-2")],
        [previewSummary(id: "item-2"), previewSummary(id: "item-3")]
    ])
    let service = LibraryQueryService(
        executor: { sql, values in try await executor.call(sql, values) },
        dataRevision: revision,
        capabilities: .itemSequence
    )
    let browser = LibraryBrowserState(service: service, initialQuery: LibraryQuery(pageSize: 2))
    let detailLoader = PreviewDetailLoader(items: [
        "item-0": previewItem(id: "item-0"),
        "item-1": previewItem(id: "item-1"),
        "item-2": previewItem(id: "item-2"),
        "item-3": previewItem(id: "item-3")
    ])
    let detail = ItemDetailController(loader: detailLoader)
    let session = PreviewPageSession(browser: browser, detailController: detail)

    await session.start(query: LibraryQuery(pageSize: 2), selectedID: "item-1")
    #expect(session.loadedSummaryIDs == ["item-0", "item-1"])
    #expect(session.hasMore)
    #expect(detail.selectedID == "item-1")

    let selected = await session.navigate(.next)
    #expect(selected == "item-2")
    #expect(executor.pageRequestCount() == 2)
    #expect(session.loadedSummaryIDs == ["item-0", "item-1", "item-2", "item-3"])
    #expect(session.cursor == nil)
    #expect(!session.hasMore)
    #expect(session.queryFingerprint.isEmpty == false)
    #expect(session.dataRevision == revision.current)
    #expect(detail.selectedID == "item-2")
}

@MainActor
@Test("Preview page session drops a stale revision result and restarts without appending old rows")
func previewPageSessionDropsStaleRevisionAndRestarts() async throws {
    let revision = LibraryDataRevision()
    let gate = PreviewSessionBarrier()
    let executor = PreviewSessionExecutor(
        pages: [
            [previewSummary(id: "old-0"), previewSummary(id: "old-1"), previewSummary(id: "old-2")],
            [previewSummary(id: "old-2"), previewSummary(id: "old-3")],
            [previewSummary(id: "new-0"), previewSummary(id: "new-1")]
        ],
        barrier: gate,
        barrierPageRequest: 2
    )
    let service = LibraryQueryService(
        executor: { sql, values in try await executor.call(sql, values) },
        dataRevision: revision,
        capabilities: .itemSequence
    )
    let browser = LibraryBrowserState(service: service, initialQuery: LibraryQuery(pageSize: 2))
    let detail = ItemDetailController(loader: PreviewDetailLoader(items: [:]))
    let session = PreviewPageSession(browser: browser, detailController: detail)

    await session.start(query: LibraryQuery(pageSize: 2), selectedID: "old-1")
    let navigationTask = Task { @MainActor in await session.navigate(.next) }
    await gate.waitUntilStarted()
    _ = revision.advance()
    await gate.release()
    _ = await navigationTask.value

    #expect(session.loadedSummaryIDs == ["new-0", "new-1"])
    #expect(!session.loadedSummaryIDs.contains("old-2"))
    #expect(session.dataRevision == revision.current)
    #expect(executor.pageRequestCount() == 3)
}

@MainActor
@Test("Preview page session rejects a stale fingerprint even when the replacement still has more pages")
func previewPageSessionDropsStaleFingerprintWithMorePages() async throws {
    let revision = LibraryDataRevision()
    let executor = PreviewSessionExecutor(
        pages: [
            [previewSummary(id: "old-0"), previewSummary(id: "old-1"), previewSummary(id: "old-2")],
            [previewSummary(id: "replacement-0"), previewSummary(id: "replacement-1"), previewSummary(id: "replacement-2")],
            [previewSummary(id: "replacement-2"), previewSummary(id: "replacement-3"), previewSummary(id: "replacement-4")],
            [previewSummary(id: "restarted-0"), previewSummary(id: "restarted-1")]
        ]
    )
    let service = LibraryQueryService(
        executor: { sql, values in try await executor.call(sql, values) },
        dataRevision: revision,
        capabilities: .itemSequence
    )
    let browser = LibraryBrowserState(service: service, initialQuery: LibraryQuery(pageSize: 2))
    let detail = ItemDetailController(loader: PreviewDetailLoader(items: [:]))
    let session = PreviewPageSession(browser: browser, detailController: detail)

    await session.start(query: LibraryQuery(pageSize: 2), selectedID: "old-1")
    // Replace the shared browser behind the still-bound preview session. The
    // replacement deliberately retains another page, so the old `&&
    // !browser.hasMore` guard would have accepted and appended its cursor.
    await browser.replace(query: LibraryQuery(.folder("replacement"), pageSize: 2))
    #expect(browser.hasMore)
    _ = await session.navigate(.next)

    #expect(session.loadedSummaryIDs == ["restarted-0", "restarted-1"])
    #expect(!session.loadedSummaryIDs.contains("old-2"))
    #expect(!session.loadedSummaryIDs.contains("replacement-0"))
    #expect(executor.pageRequestCount() == 4)
}

@MainActor
@Test("Dismissed preview invalidates an in-flight tail without selecting its late ID")
func dismissedPreviewDropsLateTailSelection() async throws {
    let revision = LibraryDataRevision()
    let gate = PreviewSessionBarrier()
    let executor = PreviewSessionExecutor(
        pages: [
            [previewSummary(id: "resident-0"), previewSummary(id: "resident-1"), previewSummary(id: "resident-2")],
            [previewSummary(id: "resident-2"), previewSummary(id: "resident-3")]
        ],
        barrier: gate,
        barrierPageRequest: 2
    )
    let service = LibraryQueryService(
        executor: { sql, values in try await executor.call(sql, values) },
        dataRevision: revision,
        capabilities: .itemSequence
    )
    let browser = LibraryBrowserState(service: service, initialQuery: LibraryQuery(pageSize: 2))
    let detail = ItemDetailController(loader: PreviewDetailLoader(items: [
        "resident-1": previewItem(id: "resident-1"),
        "resident-2": previewItem(id: "resident-2")
    ]))
    let session = PreviewPageSession(browser: browser, detailController: detail)

    await session.start(query: LibraryQuery(pageSize: 2), selectedID: "resident-1")
    let navigationTask = Task { @MainActor in await session.navigate(.next) }
    await gate.waitUntilStarted()
    session.cancelNavigation()
    await gate.release()
    _ = await navigationTask.value

    #expect(session.loadedSummaryIDs == ["resident-0", "resident-1"])
    #expect(detail.selectedID == "resident-1")
}

private func previewSummary(id: String) -> LibraryItemSummary {
    LibraryItemSummary(
        id: id,
        title: id,
        type: .image,
        assetKind: .image,
        modelId: "model",
        modelName: "Model",
        folderId: "folder",
        folderName: "Folder",
        category: "image",
        assetPath: "/tmp/(id).png",
        thumbnailPath: "/tmp/(id).png",
        aspectRatio: "1:1",
        width: 100,
        height: 100,
        format: "PNG",
        fileSize: 1,
        favorite: false,
        pinnedAt: nil,
        deletedAt: nil,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
        lastUsedAt: Date(timeIntervalSince1970: 0),
        sortOrder: 0,
        hasPrompt: true,
        hasReferences: false
    )
}

private func previewItem(id: String) -> PromptItem {
    PromptItem(
        id: id,
        title: id,
        type: .image,
        modelId: "model",
        modelName: "Model",
        folderName: "Folder",
        category: "image",
        assetPath: "/tmp/(id).png",
        aspectRatio: "1:1",
        width: 100,
        height: 100,
        format: "PNG",
        fileSize: 1,
        versions: [PromptVersion(promptItemId: id, version: "V1", prompt: id)]
    )
}

private final class PreviewDetailLoader: ItemDetailLoading, @unchecked Sendable {
    private let lock = NSLock()
    private let items: [String: PromptItem]
    private(set) var requestIDs: [String] = []

    init(items: [String: PromptItem]) {
        self.items = items
    }

    func itemDetail(id: String) async throws -> PromptItem? {
        withLock { requestIDs.append(id) }
        return items[id]
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class PreviewSessionExecutor: @unchecked Sendable {
    private let lock = NSLock()
    private let pages: [[[String: String?]]]
    private let totalCount: Int
    private var pageRequests = 0
    private let barrier: PreviewSessionBarrier?
    private let barrierPageRequest: Int?

    init(
        pages: [[LibraryItemSummary]],
        barrier: PreviewSessionBarrier? = nil,
        barrierPageRequest: Int? = nil
    ) {
        totalCount = pages.flatMap { $0 }.count
        self.pages = pages.map { $0.map(Self.previewRow) }
        self.barrier = barrier
        self.barrierPageRequest = barrierPageRequest
    }

    func pageRequestCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return pageRequests
    }

    func call(_ sql: String, _ values: [SQLiteValue]) async throws -> [[String: String?]] {
        if sql.contains("COUNT") {
            return [["totalCount": String(totalCount)]]
        }
        let request = withLock {
            pageRequests += 1
            return pageRequests
        }
        if request == barrierPageRequest {
            await barrier?.waitUntilReleased()
        }
        let index = min(request - 1, pages.count - 1)
        return pages[index]
    }

    private static func previewRow(_ summary: LibraryItemSummary) -> [String: String?] {
        [
            "id": summary.id,
            "title": summary.title,
            "type": summary.type.rawValue,
            "assetKind": summary.assetKind.rawValue,
            "modelId": summary.modelId,
            "modelName": summary.modelName,
            "folderId": summary.folderId,
            "folderName": summary.folderName,
            "category": summary.category,
            "assetPath": summary.assetPath,
            "thumbnailPath": summary.thumbnailPath,
            "aspectRatio": summary.aspectRatio,
            "width": String(summary.width),
            "height": String(summary.height),
            "format": summary.format,
            "fileSize": String(summary.fileSize),
            "favorite": summary.favorite ? "1" : "0",
            "createdAt": "2023-11-14T22:13:20Z",
            "updatedAt": "2023-11-14T22:13:20Z",
            "lastUsedAt": "1970-01-01T00:00:00Z",
            "sortOrder": String(summary.sortOrder),
            "hasPrompt": summary.hasPrompt ? "1" : "0",
            "hasReferences": summary.hasReferences ? "1" : "0",
            "itemSequence": "1",
            "itemCreatedAtSortKey": "1700000000000000",
            "itemLastUsedAtSortKey": "0"
        ]
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private actor PreviewSessionBarrier {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilReleased() async {
        started = true
        let startWaiters = self.startWaiters
        self.startWaiters.removeAll()
        startWaiters.forEach { $0.resume() }
        if released { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        released = true
        let releaseWaiters = self.releaseWaiters
        self.releaseWaiters.removeAll()
        releaseWaiters.forEach { $0.resume() }
    }
}
