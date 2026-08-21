import AppKit
import SwiftUI
import Testing
import PromptStudioCore
@testable import PromptStudio
@preconcurrency import Darwin

@MainActor
@Test("Attached Summary renderer consumes ten fixed pages without reloads or scroll jumps")
func attachedSummaryRendererConsumesTenPages() async throws {
    let executor = RendererPageExecutor()
    let service = LibraryQueryService(executor: executor, capabilities: .itemSequence)
    let browser = LibraryBrowserState(service: service, initialQuery: LibraryQuery(pageSize: 1))
    let paginator = LibrarySummaryPaginator(browser: browser)

    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    scrollView.hasVerticalScroller = true
    let collectionView = AttachedRecordingCollectionView(frame: .zero)
    let layout = SummaryMasonryCollectionLayout()
    collectionView.collectionViewLayout = layout
    collectionView.dataSource = nil
    let coordinator = SummaryMasonryCollectionCoordinator()
    collectionView.dataSource = coordinator
    collectionView.delegate = coordinator
    collectionView.register(SummaryCollectionItem.self, forItemWithIdentifier: SummaryCollectionItem.reuseIdentifier)
    collectionView.isSelectable = true
    collectionView.allowsMultipleSelection = true
    scrollView.documentView = collectionView
    window.contentView = scrollView
    coordinator.collectionView = collectionView
    coordinator.layout = layout
    var prefetchEvents: [(CGRect, CGFloat)] = []
    coordinator.onPrefetch = { rect, height in
        prefetchEvents.append((rect, height))
    }
    coordinator.observeBounds(of: scrollView)
    window.makeKeyAndOrderFront(nil)
    window.displayIfNeeded()
    defer { window.orderOut(nil) }

    await paginator.replace(query: LibraryQuery(pageSize: 1))
    #expect(paginator.summaries.count == 300)
    coordinator.update(
        folders: [], summaries: paginator.summaries,
        selectedItemIDs: [], selectedFolderIDs: [], availableWidth: 900
    )
    collectionView.layoutSubtreeIfNeeded()
    #expect(collectionView.reloadDataCount == 1)
    let rssBefore = residentMemoryBytes()
    var rssPerPage = [residentMemoryBytes()]
    prefetchEvents.removeAll()
    let initialFrames = Dictionary(uniqueKeysWithValues: paginator.summaries.map { ($0.id, layout.frame(for: $0.id)!) })
    let initialColumns = Dictionary(uniqueKeysWithValues: paginator.summaries.map { ($0.id, layout.column(for: $0.id)!) })
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: 120))
    scrollView.reflectScrolledClipView(scrollView.contentView)
    await Task.yield()
    #expect(prefetchEvents.contains { $0.0 == scrollView.contentView.bounds && $0.1 > 0 })
    let initialScrollOrigin = scrollView.contentView.bounds.origin

    async let firstAppend: Void = paginator.loadNextPage()
    await executor.waitForPageStart(1)
    async let dedupedAppend: Void = paginator.loadNextPage()
    await executor.openPageOne()
    _ = await (firstAppend, dedupedAppend)
    coordinator.update(
        folders: [], summaries: paginator.summaries,
        selectedItemIDs: [], selectedFolderIDs: [], availableWidth: 900
    )
    collectionView.layoutSubtreeIfNeeded()
    rssPerPage.append(residentMemoryBytes())

    while paginator.hasMore {
        await paginator.loadNextPage()
        coordinator.update(
            folders: [], summaries: paginator.summaries,
            selectedItemIDs: [], selectedFolderIDs: [], availableWidth: 900
        )
        collectionView.layoutSubtreeIfNeeded()
        rssPerPage.append(residentMemoryBytes())
        for summary in paginator.summaries.prefix(300) {
            #expect(layout.frame(for: summary.id) == initialFrames[summary.id])
            #expect(layout.column(for: summary.id) == initialColumns[summary.id])
        }
        #expect(scrollView.contentView.bounds.origin == initialScrollOrigin)
    }

    #expect(paginator.summaries.count == 3_000)
    #expect(paginator.summaries.map(\.id) == Array(0..<3_000).map { "item-\($0)" })
    #expect(!paginator.hasMore)
    #expect(collectionView.reloadDataCount == 1)
    #expect(collectionView.insertedItemCount == 2_700)
    #expect(collectionView.insertHistory.count == 9)
    #expect(collectionView.insertHistory.allSatisfy { $0.count == 300 })
    let stats = await executor.stats()
    #expect(stats.pageCalls == 10)
    #expect(stats.maxInFlight == 1)
    #expect(rssPerPage.count == 10)
    let sortedRSS = rssPerPage.sorted()
    let p50 = sortedRSS[(sortedRSS.count - 1) / 2]
    let p95 = sortedRSS[min(sortedRSS.count - 1, Int(ceil(Double(sortedRSS.count) * 0.95)) - 1)]
    let peak = rssPerPage.max() ?? rssBefore
    let delta = peak >= rssBefore ? peak - rssBefore : 0
    #expect(peak < 512 * 1024 * 1024)
    #expect(delta < 512 * 1024 * 1024)
    #expect(p50 <= peak)
    #expect(p95 <= peak)
    if let metricsPath = ProcessInfo.processInfo.environment["PROMPTSTUDIO_SUMMARY_UI_METRICS_PATH"] {
        let metrics: [String: Any] = [
            "rssPerPageBytes": rssPerPage,
            "rssBeforeBytes": rssBefore,
            "rssPeakBytes": peak,
            "rssDeltaBytes": delta,
            "rssP50Bytes": p50,
            "rssP95Bytes": p95,
            "residentSummaries": paginator.summaries.count,
            "pageCalls": stats.pageCalls,
            "maxInFlight": stats.maxInFlight
        ]
        let data = try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys])
        try data.write(to: URL(fileURLWithPath: metricsPath), options: .atomic)
    }
}

@MainActor
@Test("Attached Summary representable drives production hit-test, events, menu, and drop")
func attachedSummaryRepresentableDrivesProductionEvents() throws {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    defer { window.orderOut(nil) }

    let selectedIDs = ["item-a", "item-b"]
    var observedClicks: [String] = []
    var previewedIDs: [String] = []
    var openedFolderIDs: [String] = []
    var droppedItems: ([String], String)?
    let item = attachedEventSummary(id: "item-a", title: "A")
    let secondItem = attachedEventSummary(id: "item-b", title: "B")
    let folder = SummaryFolderRow(folder: LibraryFolder(id: "folder-a", name: "Folder A"), count: 1)
    let secondFolder = SummaryFolderRow(folder: LibraryFolder(id: "folder-b", name: "Folder B"), count: 1)

    func surface(summaries: [LibraryItemSummary], folders: [SummaryFolderRow]) -> SummaryMasonryCollectionView {
        SummaryMasonryCollectionView(
            folders: folders,
            summaries: summaries,
            selectedItemIDs: Set(selectedIDs),
            selectedFolderIDs: ["folder-a", "folder-b"],
            onSelectItem: { id, _ in observedClicks.append(id) },
            onPreviewItem: { previewedIDs.append($0) },
            onContextItems: { _ in },
            onMakeItemContextMenu: { ids in NSMenu(title: "real-item-\(ids.joined(separator: ","))") },
            onSelectFolder: { _, _ in },
            onOpenFolder: { openedFolderIDs.append($0) },
            onContextFolders: { _ in },
            onMakeFolderContextMenu: { ids in NSMenu(title: "real-folder-\(ids.joined(separator: ","))") },
            onMoveItems: { ids, folderID in
                droppedItems = (ids, folderID)
                return true
            }
        )
    }

    let host = NSHostingView(rootView: surface(summaries: [], folders: []))
    host.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    window.displayIfNeeded()

    // Replacing rootView is the real SwiftUI updateNSView path. The first
    // rootView already invoked makeNSView above.
    host.rootView = surface(summaries: [item, secondItem], folders: [folder, secondFolder])
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()

    let scrollView = try #require(findAttachedView(NSScrollView.self, in: host))
    let collectionView = try #require(findAttachedView(NSCollectionView.self, in: scrollView))
    let nativeMarquee = try #require(collectionView as? NativeMarqueeCollectionView)
    #expect(nativeMarquee.onBlankClick != nil)
    #expect(nativeMarquee.onMarqueeBegin != nil)
    #expect(nativeMarquee.onMarqueeChange != nil)
    #expect(nativeMarquee.onMarqueeEnd != nil)
    #expect(nativeMarquee.onMarqueeCancel != nil)
    collectionView.layoutSubtreeIfNeeded()
    let itemEvent = try #require(allAttachedViews(SummaryCardEventView.self, in: collectionView).first { !$0.isFolderForTesting })
    let itemHosted = try #require(findAttachedView(SummaryPassThroughHostingView.self, in: collectionView))
    let itemCenter = NSPoint(x: itemEvent.bounds.midX, y: itemEvent.bounds.midY)
    let itemPointInWindow = itemEvent.convert(itemCenter, to: nil)
    let itemPoint = itemPointInWindow
    let itemHit = try #require(window.contentView?.hitTest(itemPoint))
    #expect(itemHit === itemEvent)
    #expect(itemHosted.hitTest(NSPoint(x: itemHosted.bounds.midX, y: itemHosted.bounds.midY)) == nil)

    itemHit.mouseDown(with: attachedMouseEvent(clickCount: 1))
    #expect(observedClicks == ["item-a"])
    itemHit.mouseDown(with: attachedMouseEvent(clickCount: 2))
    #expect(previewedIDs == ["item-a"])
    let itemMenu = try #require(itemHit.menu(for: attachedMouseEvent(clickCount: 1)))
    #expect(itemMenu.title == "real-item-item-a,item-b")

    let folderEvent = try #require(allAttachedViews(SummaryCardEventView.self, in: collectionView).first { $0.isFolderForTesting })
    let folderCenter = NSPoint(x: folderEvent.bounds.midX, y: folderEvent.bounds.midY)
    let folderPoint = folderEvent.convert(folderCenter, to: nil)
    let folderHit = try #require(window.contentView?.hitTest(folderPoint))
    #expect(folderHit === folderEvent)
    folderHit.mouseDown(with: attachedMouseEvent(clickCount: 2))
    #expect(openedFolderIDs == ["folder-a"])
    let folderMenu = try #require(folderHit.menu(for: attachedMouseEvent(clickCount: 1)))
    #expect(folderMenu.title == "real-folder-folder-a,folder-b")

    let pasteboard = NSPasteboard(name: NSPasteboard.Name("SummaryAttachedDrop-\(UUID().uuidString)"))
    pasteboard.clearContents()
    pasteboard.setData(
        try PromptItemDragPayload(itemIDs: ["item-a", "item-b"]).encoded(),
        forType: NSPasteboard.PasteboardType(PromptItemDragPayload.pasteboardTypeIdentifier)
    )
    let dragInfo = AttachedTestDraggingInfo(pasteboard: pasteboard)
    #expect(folderHit.draggingEntered(dragInfo) == .move)
    #expect(folderHit.performDragOperation(dragInfo))
    #expect(droppedItems?.0 == ["item-a", "item-b"])
    #expect(droppedItems?.1 == "folder-a")
}

@MainActor
@Test("Summary normal renderer uses zero full-item decodes and explicit legacy control records one")
func summaryRendererDecodeInstrumentation() throws {
    let decodeObservation = SummaryRendererDecodeInstrumentation.beginObservation()
    let collectionView = NSCollectionView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    let layout = SummaryMasonryCollectionLayout()
    collectionView.collectionViewLayout = layout
    let coordinator = SummaryMasonryCollectionCoordinator()
    coordinator.collectionView = collectionView
    coordinator.layout = layout
    collectionView.dataSource = coordinator
    collectionView.delegate = coordinator
    collectionView.register(SummaryCollectionItem.self, forItemWithIdentifier: SummaryCollectionItem.reuseIdentifier)
    let normal = attachedEventSummary(id: "normal", title: "Normal")
    coordinator.update(
        folders: [], summaries: [normal], selectedItemIDs: [], selectedFolderIDs: [], availableWidth: 900
    )
    _ = coordinator.collectionView(
        collectionView,
        itemForRepresentedObjectAt: IndexPath(item: 0, section: 0)
    )
    #expect(decodeObservation.delta == 0)
    let observedNormalSummaryDecodeCount = decodeObservation.delta

    let legacyFixture = attachedEventPromptFixture(id: "legacy", title: "Legacy")
    _ = legacyPromptItemsForRendering([legacyFixture], explicitLegacyMode: false)
    #expect(decodeObservation.delta == 0)
    let legacyItems = legacyPromptItemsForRendering([legacyFixture], explicitLegacyMode: true)
    #expect(legacyItems.map(\.id) == ["legacy"])
    #expect(decodeObservation.delta == 1)

    if let metricsPath = ProcessInfo.processInfo.environment["PROMPTSTUDIO_SUMMARY_UI_DECODE_METRICS_PATH"] {
        let metrics: [String: Int] = [
            "normal_summary_full_item_decode": observedNormalSummaryDecodeCount,
            "deliberate_legacy_item_control_decode": decodeObservation.delta
        ]
        let data = try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys])
        try data.write(to: URL(fileURLWithPath: metricsPath), options: .atomic)
    }
}

@MainActor
private final class AttachedRecordingCollectionView: NSCollectionView {
    private(set) var reloadDataCount = 0
    private(set) var insertedItemCount = 0
    private(set) var insertHistory: [Set<IndexPath>] = []

    override func reloadData() {
        reloadDataCount += 1
        super.reloadData()
    }

    override func insertItems(at indexPaths: Set<IndexPath>) {
        insertedItemCount += indexPaths.count
        insertHistory.append(indexPaths)
        super.insertItems(at: indexPaths)
    }
}

private actor RendererPageExecutor: LibraryQueryRowExecutor {
    private var nextPage = 0
    private var active = 0
    private var maxActive = 0
    private var calls = 0
    private var lastCursor: (sortOrder: Int64, createdAt: Int64, sequence: Int64)?
    private var startedPages: Set<Int> = []
    private var startWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private let pageOneGate = RendererGate()

    func query(sql: String, values: [SQLiteValue]) async throws -> [[String: String?]] { [] }

    func queryPageAndCount(
        pageSQL: String,
        pageValues: [SQLiteValue],
        countSQL: String,
        countValues: [SQLiteValue]
    ) async throws -> LibraryQueryReadBatch {
        let page = nextPage
        nextPage += 1
        calls += 1
        active += 1
        maxActive = max(maxActive, active)
        defer { active -= 1 }
        startedPages.insert(page)
        let waiters = startWaiters.removeValue(forKey: page) ?? []
        waiters.forEach { $0.resume() }
        guard pageValues.last.map({ isInt($0, 301) }) == true else {
            throw RendererPageError.badPageValues(pageValues)
        }
        if let lastCursor {
            let expected = [
                SQLiteValue.int(lastCursor.sortOrder), SQLiteValue.int(lastCursor.sortOrder),
                SQLiteValue.int(lastCursor.createdAt), SQLiteValue.int(lastCursor.sortOrder),
                SQLiteValue.int(lastCursor.createdAt), SQLiteValue.int(lastCursor.sequence),
                SQLiteValue.int(301)
            ]
            guard equalValues(pageValues, expected) else {
                throw RendererPageError.badCursor(expected: expected, actual: pageValues)
            }
        } else {
            guard equalValues(pageValues, [.int(301)]) else {
                throw RendererPageError.badInitialValues(pageValues)
            }
        }
        if page == 1 { await pageOneGate.wait() }
        let start = page * 300
        var rows = (start..<(start + 300)).map { rendererSummaryRow(id: "item-\($0)", sortOrder: $0) }
        if page < 9 {
            rows.append(rendererSummaryRow(id: "item-\(max(0, start - 1))", sortOrder: max(0, start - 1)))
        }
        let last = rows[299]
        guard let sortOrder = last["sortOrder"] ?? nil,
              let createdAt = last["itemCreatedAtSortKey"] ?? nil,
              let sequence = last["itemSequence"] ?? nil,
              let parsedSortOrder = Int64(sortOrder),
              let parsedCreatedAt = Int64(createdAt),
              let parsedSequence = Int64(sequence) else {
            throw RendererPageError.badRow
        }
        lastCursor = (parsedSortOrder, parsedCreatedAt, parsedSequence)
        return LibraryQueryReadBatch(pageRows: rows, countRows: [["totalCount": "3000"]])
    }

    func waitForPageStart(_ page: Int) async {
        if startedPages.contains(page) { return }
        await withCheckedContinuation { startWaiters[page, default: []].append($0) }
    }

    func openPageOne() async { await pageOneGate.open() }

    func stats() -> (pageCalls: Int, maxInFlight: Int) { (calls, maxActive) }
}

private actor RendererGate {
    private var openState = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if openState { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        openState = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private enum RendererPageError: Error {
    case badPageValues([SQLiteValue])
    case badInitialValues([SQLiteValue])
    case badCursor(expected: [SQLiteValue], actual: [SQLiteValue])
    case badRow
}

private func isInt(_ value: SQLiteValue, _ expected: Int64) -> Bool {
    guard case .int(let actual) = value else { return false }
    return actual == expected
}

private func equalValues(_ lhs: [SQLiteValue], _ rhs: [SQLiteValue]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    return zip(lhs, rhs).allSatisfy { left, right in
        switch (left, right) {
        case (.text(let a), .text(let b)): return a == b
        case (.int(let a), .int(let b)): return a == b
        case (.double(let a), .double(let b)): return a == b
        case (.null, .null): return true
        default: return false
        }
    }
}

@MainActor
private func findAttachedView<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
    if let match = view as? T { return match }
    for child in view.subviews {
        if let match = findAttachedView(type, in: child) { return match }
    }
    return nil
}

@MainActor
private func allAttachedViews<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
    var matches: [T] = []
    if let match = view as? T { matches.append(match) }
    for child in view.subviews {
        matches.append(contentsOf: allAttachedViews(type, in: child))
    }
    return matches
}

@MainActor
private func attachedMouseEvent(clickCount: Int) -> NSEvent {
    NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        eventNumber: 0,
        clickCount: clickCount,
        pressure: 1
    )!
}

private func attachedEventSummary(id: String, title: String) -> LibraryItemSummary {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    return LibraryItemSummary(
        id: id, title: title, type: .image, assetKind: .image,
        modelId: "model", modelName: "Model", folderId: "folder-a", folderName: "Folder A",
        category: "image", assetPath: "/tmp/summary-item.png", thumbnailPath: "", aspectRatio: "16:9",
        width: 1920, height: 1080, format: "PNG", fileSize: 1, favorite: false,
        pinnedAt: nil, deletedAt: nil, createdAt: date, updatedAt: date, lastUsedAt: date,
        sortOrder: 0, hasPrompt: false, hasReferences: false
    )
}

private func attachedEventPromptFixture(id: String, title: String) -> PromptItem {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    return PromptItem(
        id: id, title: title, type: .image, assetKind: .image,
        modelId: "model", modelName: "Model", folderId: "folder-a", folderName: "Folder A",
        category: "image", assetPath: "/tmp/summary-item.png", aspectRatio: "16:9",
        width: 1920, height: 1080, format: "PNG", fileSize: 1,
        createdAt: date, updatedAt: date, lastUsedAt: date
    )
}

private final class AttachedTestDraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard

    @MainActor
    init(pasteboard: NSPasteboard) {
        draggingPasteboard = pasteboard
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 0 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func namesOfPromisedFilesDropped(at dropDestination: URL) -> [String]? { nil }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [],
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

private func rendererSummaryRow(id: String, sortOrder: Int) -> [String: String?] {
    let dateValue = Date(timeIntervalSince1970: 1_700_000_000 - Double(sortOrder))
    let date = ISO8601DateFormatter().string(from: dateValue)
    let createdKey = Int64((dateValue.timeIntervalSince1970 * 1_000_000).rounded())
    return [
        "id": id, "title": id, "type": PromptType.image.rawValue, "assetKind": AssetKind.image.rawValue,
        "modelId": "model", "modelName": "Model", "folderId": "folder", "folderName": "Folder", "category": "image",
        "assetPath": "", "thumbnailPath": "", "aspectRatio": "16:9", "width": "1", "height": "1", "format": "PNG", "fileSize": "1",
        "favorite": "0", "pinnedAt": nil, "deletedAt": nil, "createdAt": date, "updatedAt": date, "lastUsedAt": date,
        "sortOrder": "\(sortOrder)", "itemCreatedAtSortKey": "\(createdKey)", "itemLastUsedAtSortKey": "0",
        "itemSequence": "\(max(1, sortOrder + 1))", "hasPrompt": "1", "hasReferences": "0"
    ]
}

private func residentMemoryBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
    )
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
}
