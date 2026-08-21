@preconcurrency import AppKit
import SwiftUI
import Testing
import PromptStudioCore
@testable import PromptStudio

@MainActor
@Test("Summary coordinator reloads the exact folder path during append")
func summaryCoordinatorReloadsFolderOnAppend() throws {
    let layout = SummaryMasonryCollectionLayout()
    let collectionView = RecordingCollectionView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    collectionView.collectionViewLayout = layout
    let coordinator = SummaryMasonryCollectionCoordinator()
    collectionView.dataSource = coordinator
    collectionView.delegate = coordinator
    collectionView.register(SummaryCollectionItem.self, forItemWithIdentifier: SummaryCollectionItem.reuseIdentifier)
    coordinator.collectionView = collectionView
    coordinator.layout = layout

    let folder = LibraryFolder(id: "folder-a", name: "Folder A")
    let first = summaryFixture(id: "item-a", title: "A")
    coordinator.update(
        folders: [SummaryFolderRow(folder: folder, count: 1)],
        summaries: [first],
        selectedItemIDs: [],
        selectedFolderIDs: [],
        availableWidth: 900
    )
    #expect(coordinator.numberOfItems(in: collectionView) == 2)
    #expect(coordinator.collectionView(collectionView, numberOfItemsInSection: 0) == 2)

    collectionView.resetMutationHistory()
    let second = summaryFixture(id: "item-b", title: "B")
    coordinator.update(
        folders: [SummaryFolderRow(folder: folder, count: 2)],
        summaries: [first, second],
        selectedItemIDs: [],
        selectedFolderIDs: [],
        availableWidth: 900
    )

    #expect(coordinator.mutation == .incrementalAppend(["item-b"]))
    #expect(collectionView.insertHistory == [Set([IndexPath(item: 2, section: 0)])])
    #expect(collectionView.reloadHistory == [Set([IndexPath(item: 0, section: 0)])])

    var selectedIDs: [String] = []
    var previewedIDs: [String] = []
    var contextIDs: [[String]] = []
    coordinator.onSelectItem = { id, _ in selectedIDs.append(id) }
    coordinator.onPreviewItem = { id in previewedIDs.append(id) }
    coordinator.onContextItems = { ids in contextIDs.append(ids) }
    let hostedItem = coordinator.collectionView(
        collectionView,
        itemForRepresentedObjectAt: IndexPath(item: 1, section: 0)
    )
    #expect(containsHostingView(hostedItem.view))
    let eventView = try #require(findView(of: SummaryCardEventView.self, in: hostedItem.view))
    eventView.mouseDown(with: mouseEvent(clickCount: 1, modifiers: [.command]))
    eventView.mouseDown(with: mouseEvent(clickCount: 2))
    let menu = eventView.menu(for: mouseEvent(clickCount: 1))
    #expect(selectedIDs == ["item-a"])
    #expect(previewedIDs == ["item-a"])
    #expect(contextIDs == [["item-a"]])
    #expect(menu?.items.first?.title == "预览")
}

@MainActor
@Test("Summary coordinator targets content and geometry while preserving prefix frames and selection")
func summaryCoordinatorTargetsContentGeometryAndStructuralSelection() throws {
    let layout = SummaryMasonryCollectionLayout()
    let collectionView = RecordingCollectionView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    collectionView.collectionViewLayout = layout
    collectionView.isSelectable = true
    collectionView.allowsMultipleSelection = true
    let coordinator = SummaryMasonryCollectionCoordinator()
    collectionView.dataSource = coordinator
    collectionView.delegate = coordinator
    collectionView.register(SummaryCollectionItem.self, forItemWithIdentifier: SummaryCollectionItem.reuseIdentifier)
    coordinator.collectionView = collectionView
    coordinator.layout = layout

    let first = summaryFixture(id: "item-a", title: "A")
    let second = summaryFixture(id: "item-b", title: "B")
    let third = summaryFixture(id: "item-c", title: "C")
    coordinator.update(
        folders: [], summaries: [first, second, third],
        selectedItemIDs: [first.id, third.id], selectedFolderIDs: [], availableWidth: 900
    )
    #expect(collectionView.selectionIndexPaths == Set([IndexPath(item: 0, section: 0), IndexPath(item: 2, section: 0)]))
    let prefixFrame = try #require(layout.frame(for: first.id))

    collectionView.resetMutationHistory()
    let contentChanged = summaryFixture(id: first.id, title: "A revised")
    coordinator.update(
        folders: [], summaries: [contentChanged, second, third],
        selectedItemIDs: [first.id, third.id], selectedFolderIDs: [], availableWidth: 900
    )
    #expect(coordinator.mutation == .targetedContent([first.id]))
    #expect(collectionView.reloadHistory == [Set([IndexPath(item: 0, section: 0)])])
    #expect(layout.frame(for: first.id) == prefixFrame)

    collectionView.resetMutationHistory()
    let geometryChanged = summaryFixture(id: second.id, title: second.title, width: 1080, height: 1920)
    coordinator.update(
        folders: [], summaries: [contentChanged, geometryChanged, third],
        selectedItemIDs: [first.id, third.id], selectedFolderIDs: [], availableWidth: 900
    )
    #expect(coordinator.mutation == .targetedGeometry([second.id]))
    #expect(collectionView.reloadHistory == [Set([IndexPath(item: 1, section: 0)])])
    #expect(layout.frame(for: first.id) == prefixFrame)

    collectionView.resetSelectionHistory()
    let fourth = summaryFixture(id: "item-d", title: "D")
    coordinator.update(
        folders: [], summaries: [contentChanged, geometryChanged, third, fourth],
        selectedItemIDs: [first.id, second.id], selectedFolderIDs: [], availableWidth: 900
    )
    #expect(coordinator.mutation == .incrementalAppend([fourth.id]))
    #expect(collectionView.selectHistory == [Set([IndexPath(item: 1, section: 0)])])
    #expect(collectionView.deselectHistory == [Set([IndexPath(item: 2, section: 0)])])

    coordinator.update(
        folders: [], summaries: [third, contentChanged, geometryChanged, fourth],
        selectedItemIDs: [first.id, third.id], selectedFolderIDs: [], availableWidth: 900
    )
    #expect(coordinator.mutation == .structuralReload)
    #expect(collectionView.selectionIndexPaths == Set([IndexPath(item: 0, section: 0), IndexPath(item: 1, section: 0)]))
}

@MainActor
@Test("Summary coordinator reloads the full mixed geometry content and folder union")
func summaryCoordinatorTargetsMixedContentGeometryAndFolderChanges() throws {
    let layout = SummaryMasonryCollectionLayout()
    let collectionView = RecordingCollectionView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    collectionView.collectionViewLayout = layout
    let coordinator = SummaryMasonryCollectionCoordinator()
    collectionView.dataSource = coordinator
    collectionView.delegate = coordinator
    collectionView.register(SummaryCollectionItem.self, forItemWithIdentifier: SummaryCollectionItem.reuseIdentifier)
    coordinator.collectionView = collectionView
    coordinator.layout = layout

    let folder = LibraryFolder(id: "folder-a", name: "Folder A")
    let first = summaryFixture(id: "item-a", title: "A")
    let second = summaryFixture(id: "item-b", title: "B")
    coordinator.update(
        folders: [SummaryFolderRow(folder: folder, count: 1)],
        summaries: [first, second],
        selectedItemIDs: [], selectedFolderIDs: [], availableWidth: 900
    )

    collectionView.resetMutationHistory()
    let changedFolder = SummaryFolderRow(folder: folder, count: 2)
    let changedFirst = summaryFixture(id: first.id, title: "A revised")
    let changedSecond = summaryFixture(id: second.id, title: second.title, width: 1080, height: 1920)
    coordinator.update(
        folders: [changedFolder],
        summaries: [changedFirst, changedSecond],
        selectedItemIDs: [], selectedFolderIDs: [], availableWidth: 900
    )

    #expect(coordinator.mutation == .targetedReload(["folder-a", "item-a", "item-b"]))
    #expect(collectionView.reloadHistory == [Set([
        IndexPath(item: 0, section: 0),
        IndexPath(item: 1, section: 0),
        IndexPath(item: 2, section: 0)
    ])])
}

@MainActor
@Test("hosted Summary card routes multi-ID item/folder drops and folder double-click")
func hostedSummaryCardRoutesDropsAndFolderOpen() throws {
    let collectionView = RecordingCollectionView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    let layout = SummaryMasonryCollectionLayout()
    collectionView.collectionViewLayout = layout
    let coordinator = SummaryMasonryCollectionCoordinator()
    collectionView.dataSource = coordinator
    collectionView.delegate = coordinator
    collectionView.register(SummaryCollectionItem.self, forItemWithIdentifier: SummaryCollectionItem.reuseIdentifier)
    coordinator.collectionView = collectionView
    coordinator.layout = layout
    coordinator.update(
        folders: [
            SummaryFolderRow(folder: LibraryFolder(id: "folder-a", name: "A"), count: 2),
            SummaryFolderRow(folder: LibraryFolder(id: "folder-b", name: "B"), count: 1)
        ],
        summaries: [summaryFixture(id: "item-a", title: "A"), summaryFixture(id: "item-b", title: "B")],
        selectedItemIDs: ["item-a", "item-b"],
        selectedFolderIDs: ["folder-a", "folder-b"],
        availableWidth: 900
    )
    let (itemPasteboardItem, itemDragIDs) = try #require(coordinator.dragPasteboardItem(for: "item-a"))
    #expect(itemDragIDs == ["item-a", "item-b"])
    let itemData = try #require(itemPasteboardItem.data(forType: NSPasteboard.PasteboardType(PromptItemDragPayload.pasteboardTypeIdentifier)))
    #expect(try PromptItemDragPayload.decode(itemData).itemIDs == itemDragIDs)
    let (folderPasteboardItem, folderDragIDs) = try #require(coordinator.dragPasteboardItem(for: "folder-a"))
    #expect(folderDragIDs == ["folder-a", "folder-b"])
    let folderData = try #require(folderPasteboardItem.data(forType: NSPasteboard.PasteboardType(FolderDragPayload.pasteboardTypeIdentifier)))
    #expect(try FolderDragPayload.decode(folderData).folderIDs == folderDragIDs)

    var itemDrop: ([String], String)?
    var folderDrop: ([String], String)?
    var openedFolder: String?

    let itemTarget = SummaryCardEventView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
    itemTarget.configure(
        id: "folder-target", isFolder: true,
        onClick: { _, _ in }, onDoubleClick: { _ in }, onContext: { _ in },
        onBeginDrag: { _, _, _ in },
        onMoveItems: { ids, folderID in itemDrop = (ids, folderID); return true },
        onMoveFolders: { ids, folderID in folderDrop = (ids, folderID); return true },
        onOpenFolder: { openedFolder = $0 }
    )

    let itemPasteboard = NSPasteboard(name: NSPasteboard.Name("SummaryItemDrop-\(UUID().uuidString)"))
    let itemIDs = ["item-a", "item-b"]
    itemPasteboard.clearContents()
    itemPasteboard.setData(
        try PromptItemDragPayload(itemIDs: itemIDs).encoded(),
        forType: NSPasteboard.PasteboardType(PromptItemDragPayload.pasteboardTypeIdentifier)
    )
    let itemInfo = TestDraggingInfo(pasteboard: itemPasteboard)
    #expect(itemTarget.draggingEntered(itemInfo) == .move)
    #expect(itemTarget.performDragOperation(itemInfo))
    #expect(itemDrop?.0 == itemIDs)
    #expect(itemDrop?.1 == "folder-target")

    let folderPasteboard = NSPasteboard(name: NSPasteboard.Name("SummaryFolderDrop-\(UUID().uuidString)"))
    let folderIDs = ["folder-a", "folder-b"]
    folderPasteboard.clearContents()
    folderPasteboard.setData(
        try FolderDragPayload(folderIDs: folderIDs).encoded(),
        forType: NSPasteboard.PasteboardType(FolderDragPayload.pasteboardTypeIdentifier)
    )
    let folderInfo = TestDraggingInfo(pasteboard: folderPasteboard)
    #expect(itemTarget.draggingEntered(folderInfo) == .move)
    #expect(itemTarget.performDragOperation(folderInfo))
    #expect(folderDrop?.0 == folderIDs)
    #expect(folderDrop?.1 == "folder-target")

    let nonFolderTarget = SummaryCardEventView(frame: itemTarget.bounds)
    nonFolderTarget.configure(
        id: "item-target", isFolder: false,
        onClick: { _, _ in }, onDoubleClick: { _ in }, onContext: { _ in },
        onBeginDrag: { _, _, _ in },
        onMoveItems: { _, _ in true }, onMoveFolders: { _, _ in true },
        onOpenFolder: { _ in }
    )
    #expect(nonFolderTarget.draggingEntered(itemInfo) == [])
    #expect(!nonFolderTarget.performDragOperation(itemInfo))
    #expect(nonFolderTarget.draggingEntered(folderInfo) == [])
    #expect(!nonFolderTarget.performDragOperation(folderInfo))

    let folderCard = SummaryCardEventView(frame: itemTarget.bounds)
    folderCard.configure(
        id: "folder-open", isFolder: true,
        onClick: { _, _ in }, onDoubleClick: { _ in }, onContext: { _ in },
        onBeginDrag: { _, _, _ in },
        onMoveItems: { _, _ in false }, onMoveFolders: { _, _ in false },
        onOpenFolder: { openedFolder = $0 }
    )
    folderCard.mouseDown(with: mouseEvent(clickCount: 2))
    #expect(openedFolder == "folder-open")
}

@MainActor
@Test("Summary coordinator clears both domains for non-additive no-hit marquees")
func summaryCoordinatorClearsNonAdditiveNoHitMarquee() throws {
    let layout = SummaryMasonryCollectionLayout()
    let collectionView = RecordingCollectionView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    collectionView.collectionViewLayout = layout
    let coordinator = SummaryMasonryCollectionCoordinator()
    collectionView.dataSource = coordinator
    collectionView.delegate = coordinator
    coordinator.collectionView = collectionView
    coordinator.layout = layout

    let folder = SummaryFolderRow(folder: LibraryFolder(id: "folder-a", name: "Folder A"), count: 1)
    let item = summaryFixture(id: "item-a", title: "A")
    coordinator.update(
        folders: [folder],
        summaries: [item],
        selectedItemIDs: [item.id],
        selectedFolderIDs: [],
        availableWidth: 900
    )

    var itemContexts: [[String]] = []
    var folderContexts: [[String]] = []
    coordinator.onContextItems = { itemContexts.append($0) }
    coordinator.onContextFolders = { folderContexts.append($0) }

    coordinator.beginMarquee(at: .zero, additive: false)
    coordinator.updateMarquee(in: CGRect(x: 5_000, y: 5_000, width: 10, height: 10))
    #expect(itemContexts == [[]])
    #expect(folderContexts == [[]])

    itemContexts.removeAll()
    folderContexts.removeAll()
    let itemFrame = try #require(layout.frame(for: item.id))
    coordinator.beginMarquee(at: itemFrame.origin, additive: false)
    coordinator.updateMarquee(in: itemFrame)
    coordinator.updateMarquee(in: CGRect(x: 5_000, y: 5_000, width: 10, height: 10))
    #expect(itemContexts == [[item.id], []])

    itemContexts.removeAll()
    folderContexts.removeAll()
    let folderFrame = try #require(layout.frame(for: SummaryCollectionEntry.folder(folder).id))
    coordinator.beginMarquee(at: folderFrame.origin, additive: false)
    coordinator.updateMarquee(in: folderFrame)
    coordinator.updateMarquee(in: CGRect(x: 5_000, y: 5_000, width: 10, height: 10))
    #expect(folderContexts == [[folder.id], []])
}

@MainActor
@Test("Summary List native row drop returns the actual synchronous mutation result")
func summaryListNativeRowDropReturnsMutationResult() throws {
    var movedItems: ([String], String)?
    var movedFolders: ([String], String)?
    let target = SummaryListDropTargetHostingView(
        rootView: AnyView(Color.clear),
        folderID: "folder-target",
        onMoveItems: { ids, folderID in
            movedItems = (ids, folderID)
            return true
        },
        onMoveFolders: { ids, folderID in
            movedFolders = (ids, folderID)
            return true
        }
    )

    let itemPasteboard = NSPasteboard(name: NSPasteboard.Name("SummaryListItemDrop-\(UUID().uuidString)"))
    itemPasteboard.clearContents()
    itemPasteboard.setData(
        try PromptItemDragPayload(itemIDs: ["item-a", "item-b"]).encoded(),
        forType: NSPasteboard.PasteboardType(PromptItemDragPayload.pasteboardTypeIdentifier)
    )
    let itemInfo = TestDraggingInfo(pasteboard: itemPasteboard)
    #expect(target.draggingEntered(itemInfo) == .move)
    #expect(target.performDragOperation(itemInfo))
    #expect(movedItems?.0 == ["item-a", "item-b"])
    #expect(movedItems?.1 == "folder-target")

    let folderPasteboard = NSPasteboard(name: NSPasteboard.Name("SummaryListFolderDrop-\(UUID().uuidString)"))
    folderPasteboard.clearContents()
    folderPasteboard.setData(
        try FolderDragPayload(folderIDs: ["folder-a", "folder-b"]).encoded(),
        forType: NSPasteboard.PasteboardType(FolderDragPayload.pasteboardTypeIdentifier)
    )
    let folderInfo = TestDraggingInfo(pasteboard: folderPasteboard)
    #expect(target.draggingEntered(folderInfo) == .move)
    #expect(target.performDragOperation(folderInfo))
    #expect(movedFolders?.0 == ["folder-a", "folder-b"])
    #expect(movedFolders?.1 == "folder-target")

    let invalidPasteboard = NSPasteboard(name: NSPasteboard.Name("SummaryListInvalidDrop-\(UUID().uuidString)"))
    invalidPasteboard.clearContents()
    invalidPasteboard.setString("not a PromptStudio payload", forType: .string)
    let invalidInfo = TestDraggingInfo(pasteboard: invalidPasteboard)
    #expect(target.draggingEntered(invalidInfo) == [])
    #expect(!target.performDragOperation(invalidInfo))
}

@MainActor
@Test("Summary context menu receives the complete selected ID set")
func summaryContextMenuReceivesCompleteSelection() throws {
    let collectionView = RecordingCollectionView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    let layout = SummaryMasonryCollectionLayout()
    collectionView.collectionViewLayout = layout
    let coordinator = SummaryMasonryCollectionCoordinator()
    collectionView.dataSource = coordinator
    collectionView.delegate = coordinator
    collectionView.register(SummaryCollectionItem.self, forItemWithIdentifier: SummaryCollectionItem.reuseIdentifier)
    coordinator.collectionView = collectionView
    coordinator.layout = layout
    coordinator.update(
        folders: [],
        summaries: [summaryFixture(id: "item-a", title: "A"), summaryFixture(id: "item-b", title: "B")],
        selectedItemIDs: ["item-a", "item-b"],
        selectedFolderIDs: [],
        availableWidth: 900
    )

    var menuIDs: [[String]] = []
    coordinator.onMakeItemContextMenu = { ids in
        menuIDs.append(ids)
        return NSMenu(title: "ID-native")
    }
    let hostedItem = coordinator.collectionView(
        collectionView,
        itemForRepresentedObjectAt: IndexPath(item: 0, section: 0)
    )
    let eventView = try #require(findView(of: SummaryCardEventView.self, in: hostedItem.view))
    let menu = eventView.menu(for: mouseEvent(clickCount: 1))

    #expect(menu?.title == "ID-native")
    #expect(menuIDs == [["item-a", "item-b"]])
}

@MainActor
@Test("Summary List preserves folder multi-selection for drag/context and reports async drop success honestly")
func summaryListFolderMultiDragAndAsyncDrop() async throws {
    let visualFolderIDs = ["folder-a", "folder-b", "folder-c"]
    let selectedFolderIDs: Set<String> = ["folder-a", "folder-b"]
    let contextIDs = SummaryListInteractionSupport.orderedIDs(
        clickedID: "folder-b",
        selectedIDs: selectedFolderIDs,
        visualIDs: visualFolderIDs
    )
    let dragIDs = SummaryListInteractionSupport.dragIDs(
        clickedID: "folder-b",
        selectedIDs: selectedFolderIDs,
        visualIDs: visualFolderIDs
    )
    #expect(contextIDs == ["folder-a", "folder-b"])
    #expect(dragIDs == contextIDs)

    let folderProvider = listDataProvider(
        try FolderDragPayload(folderIDs: dragIDs).encoded(),
        typeIdentifier: FolderDragPayload.pasteboardTypeIdentifier
    )
    var movedFolders: ([String], String)?
    let succeeded = await SummaryListDropCoordinator.performFolderDrop(
        providers: [folderProvider],
        folderID: "folder-c",
        move: { ids, destination in
            movedFolders = (ids, destination)
            return true
        }
    )
    #expect(succeeded)
    #expect(movedFolders?.0 == ["folder-a", "folder-b"])
    #expect(movedFolders?.1 == "folder-c")

    let failed = await SummaryListDropCoordinator.performFolderDrop(
        providers: [folderProvider],
        folderID: "folder-c",
        move: { _, _ in false }
    )
    #expect(!failed)

    let itemProvider = listDataProvider(
        try PromptItemDragPayload(itemIDs: ["item-a", "item-b"]).encoded(),
        typeIdentifier: PromptItemDragPayload.pasteboardTypeIdentifier
    )
    var movedItems: [String] = []
    let itemSucceeded = await SummaryListDropCoordinator.performItemDrop(
        providers: [itemProvider],
        folderID: "folder-c",
        move: { ids, _ in
            movedItems = ids
            return true
        }
    )
    #expect(itemSucceeded)
    #expect(movedItems == ["item-a", "item-b"])
}

private func listDataProvider(_ data: Data, typeIdentifier: String) -> NSItemProvider {
    let provider = NSItemProvider()
    provider.registerDataRepresentation(forTypeIdentifier: typeIdentifier, visibility: .ownProcess) { completion in
        completion(data, nil)
        return nil
    }
    return provider
}

@MainActor
private final class RecordingCollectionView: NSCollectionView {
    private(set) var reloadHistory: [Set<IndexPath>] = []
    private(set) var insertHistory: [Set<IndexPath>] = []
    private(set) var selectHistory: [Set<IndexPath>] = []
    private(set) var deselectHistory: [Set<IndexPath>] = []

    override func reloadItems(at indexPaths: Set<IndexPath>) {
        reloadHistory.append(indexPaths)
    }

    override func insertItems(at indexPaths: Set<IndexPath>) {
        insertHistory.append(indexPaths)
    }

    override func selectItems(at indexPaths: Set<IndexPath>, scrollPosition: NSCollectionView.ScrollPosition) {
        selectHistory.append(indexPaths)
        super.selectItems(at: indexPaths, scrollPosition: scrollPosition)
    }

    override func deselectItems(at indexPaths: Set<IndexPath>) {
        deselectHistory.append(indexPaths)
        super.deselectItems(at: indexPaths)
    }

    func resetMutationHistory() {
        reloadHistory.removeAll()
        insertHistory.removeAll()
    }

    func resetSelectionHistory() {
        selectHistory.removeAll()
        deselectHistory.removeAll()
    }
}

@MainActor
private func containsHostingView(_ view: NSView) -> Bool {
    if view is NSHostingView<AnyView> { return true }
    return view.subviews.contains(where: containsHostingView)
}

@MainActor
private func findView<T: NSView>(of type: T.Type, in view: NSView) -> T? {
    if let match = view as? T { return match }
    for child in view.subviews {
        if let match = findView(of: type, in: child) { return match }
    }
    return nil
}

@MainActor
private func mouseEvent(clickCount: Int, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        eventNumber: 0,
        clickCount: clickCount,
        pressure: 1
    )!
}

private func summaryFixture(id: String, title: String, width: Int = 1920, height: Int = 1080) -> LibraryItemSummary {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    return LibraryItemSummary(
        id: id, title: title, type: .image, assetKind: .image,
        modelId: "model", modelName: "Model", folderId: "folder-a", folderName: "Folder A",
        category: "image", assetPath: "", thumbnailPath: "", aspectRatio: "16:9",
        width: width, height: height, format: "PNG", fileSize: 1, favorite: false,
        pinnedAt: nil, deletedAt: nil, createdAt: date, updatedAt: date, lastUsedAt: date,
        sortOrder: 0, hasPrompt: false, hasReferences: false
    )
}

private final class TestDraggingInfo: NSObject, NSDraggingInfo {
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
