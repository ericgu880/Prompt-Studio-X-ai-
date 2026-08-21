import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PromptStudioCore

/// Folder rows are deliberately not part of the Summary page/count stream.
/// They are a separate section in the same collection view so folder changes
/// never invalidate an item cursor.
struct SummaryFolderRow: Identifiable, Equatable {
    let folder: LibraryFolder
    let count: Int

    var id: String { folder.id }
}

extension AppState.FolderRow {
    var summaryRow: SummaryFolderRow { SummaryFolderRow(folder: folder, count: count) }
}

enum SummaryCollectionEntry: Equatable {
    case folder(SummaryFolderRow)
    case item(LibraryItemSummary)

    var id: String {
        switch self {
        case .folder(let row): return "folder:\(row.id)"
        case .item(let summary): return summary.id
        }
    }

    var itemID: String? {
        guard case .item(let summary) = self else { return nil }
        return summary.id
    }

    var folderID: String? {
        guard case .folder(let row) = self else { return nil }
        return row.id
    }

    var summary: LibraryItemSummary? {
        guard case .item(let summary) = self else { return nil }
        return summary
    }

    var folder: SummaryFolderRow? {
        guard case .folder(let row) = self else { return nil }
        return row
    }
}

/// Decode telemetry is intentionally scoped to the one explicit legacy
/// control. Summary cards receive LibraryItemSummary values directly, so the
/// normal renderer never increments this counter.
enum SummaryRendererDecodeInstrumentation {
    struct Observation: Sendable {
        fileprivate let baseline: Int

        var delta: Int {
            SummaryRendererDecodeInstrumentation.legacyItemDecodeCount - baseline
        }
    }

    private static let lock = NSLock()
    private static var legacyItemDecodeCountStorage = 0

    static var legacyItemDecodeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return legacyItemDecodeCountStorage
    }

    static func beginObservation() -> Observation {
        Observation(baseline: legacyItemDecodeCount)
    }

    static func legacyItem(_ item: PromptItem) -> SummaryCollectionEntry {
        lock.lock()
        legacyItemDecodeCountStorage += 1
        lock.unlock()
        let summary = LibraryItemSummary(
            id: item.id,
            title: item.title,
            type: item.type,
            assetKind: item.assetKind,
            modelId: item.modelId,
            modelName: item.modelName,
            folderId: item.folderId,
            folderName: item.folderName,
            category: item.category,
            assetPath: item.assetPath,
            thumbnailPath: item.thumbnailPath,
            aspectRatio: item.aspectRatio,
            width: item.width,
            height: item.height,
            format: item.format,
            fileSize: item.fileSize,
            favorite: item.favorite,
            pinnedAt: item.pinnedAt,
            deletedAt: item.deletedAt,
            createdAt: item.createdAt,
            updatedAt: item.updatedAt,
            lastUsedAt: item.lastUsedAt,
            sortOrder: item.sortOrder,
            hasPrompt: item.currentVersion?.prompt.isEmpty == false,
            hasReferences: !item.referenceAssets.isEmpty
        )
        return .item(summary)
    }
}

enum SummaryCollectionMutation: Equatable {
    case none
    case structuralReload
    case incrementalAppend([String])
    case targetedContent([String])
    case targetedGeometry([String])
    case targetedReload([String])
}

enum SummaryCardMetrics {
    static let itemSpacing: CGFloat = 12
    static let selectionOutset: CGFloat = 3
    static let cornerRadius: CGFloat = 12

    static func contentWidth(for width: CGFloat) -> CGFloat {
        max(120, width - selectionOutset * 2)
    }

    static func contentHeight(for summary: LibraryItemSummary, width: CGFloat) -> CGFloat {
        let contentWidth = contentWidth(for: width)
        if summary.assetKind.isTextDocumentLike {
            return contentWidth
        }
        if summary.assetKind == .image,
           summary.width > 0,
           summary.height > 0 {
            return contentWidth * CGFloat(summary.height) / CGFloat(summary.width)
        }
        let parts = summary.aspectRatio.split(separator: ":").compactMap { Double($0) }
        if parts.count == 2, parts[0] > 0, parts[1] > 0 {
            return max(150, min(430, contentWidth * CGFloat(parts[1] / parts[0])))
        }
        switch summary.assetKind {
        case .audio, .document, .font, .web:
            return contentWidth * 0.82
        default:
            return contentWidth * 1.25
        }
    }

    static func totalHeight(for summary: LibraryItemSummary, width: CGFloat) -> CGFloat {
        contentHeight(for: summary, width: width) + selectionOutset * 2
    }

    static func totalHeight(for folder: SummaryFolderRow, width: CGFloat) -> CGFloat {
        max(112, min(150, contentWidth(for: width) * 0.46)) + selectionOutset * 2
    }
}

/// Native waterfall layout with an explicit incremental append path. Existing
/// frames and column assignments are retained when a page is appended; a
/// targeted geometry change only reflows the suffix after the changed item.
@MainActor
final class SummaryMasonryCollectionLayout: NSCollectionViewLayout {
    private var attributesByIndexPath: [IndexPath: NSCollectionViewLayoutAttributes] = [:]
    private var entryIDs: [String] = []
    private var entryByID: [String: SummaryCollectionEntry] = [:]
    private var columnByID: [String: Int] = [:]
    private var columnHeights: [CGFloat] = []
    private var visibleIndex = MasonryVisibleAttributeIndex<IndexPath>()
    private(set) var framesByID: [String: CGRect] = [:]
    private(set) var visualItemIDs: [String] = []
    private(set) var visualFolderIDs: [String] = []
    private(set) var columnCount = 0
    private(set) var itemWidth: CGFloat = 0

    func configure(entries: [SummaryCollectionEntry], columnCount: Int, itemWidth: CGFloat) {
        self.columnCount = max(0, columnCount)
        self.itemWidth = itemWidth
        entryIDs = entries.map(\.id)
        entryByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        attributesByIndexPath.removeAll(keepingCapacity: true)
        columnByID.removeAll(keepingCapacity: true)
        framesByID.removeAll(keepingCapacity: true)
        columnHeights = Array(repeating: 0, count: self.columnCount)
        visibleIndex.reset(columnCount: self.columnCount)
        place(entries, startingAt: 0)
        invalidateLayout()
    }

    func append(entries: [SummaryCollectionEntry]) {
        guard !entries.isEmpty else { return }
        guard entryIDs.count == attributesByIndexPath.count || entryIDs.isEmpty else {
            // The coordinator only calls append for an exact prefix. Keeping a
            // defensive no-op here prevents a malformed caller from corrupting
            // index paths and selection state.
            return
        }
        let start = entryIDs.count
        entryIDs.append(contentsOf: entries.map(\.id))
        for entry in entries { entryByID[entry.id] = entry }
        place(entries, startingAt: start)
        invalidateLayout()
    }

    /// Updates one entry in place. Equal-height updates keep every frame;
    /// height changes preserve all prefix frames and only reflow the suffix.
    func update(entry: SummaryCollectionEntry, at index: Int) {
        guard entryIDs.indices.contains(index), entryIDs[index] == entry.id else { return }
        entryByID[entry.id] = entry
        let oldHeight = framesByID[entry.id]?.height ?? 0
        let newHeight = height(for: entry)
        if abs(oldHeight - newHeight) < 0.5 {
            rebuildAttribute(for: entry, at: index, frame: framesByID[entry.id] ?? .zero)
            return
        }

        var prefixHeights = Array(repeating: CGFloat.zero, count: columnCount)
        for prefixIndex in 0..<index {
            let id = entryIDs[prefixIndex]
            guard let column = columnByID[id], let frame = framesByID[id] else { continue }
            prefixHeights[column] = max(prefixHeights[column], frame.maxY + SummaryCardMetrics.itemSpacing)
        }
        columnHeights = prefixHeights
        for suffixIndex in index..<entryIDs.count {
            let suffixID = entryIDs[suffixIndex]
            framesByID[suffixID] = nil
            columnByID[suffixID] = nil
            attributesByIndexPath[IndexPath(item: suffixIndex, section: 0)] = nil
        }
        rebuildVisibleIndex()

        // Rebuild only the suffix. Prefix attributes remain untouched.
        let suffixEntries = entryIDs[index...].compactMap { entryByID[$0] }
        place(suffixEntries, startingAt: index)
        invalidateLayout()
    }

    func frame(for id: String) -> CGRect? { framesByID[id] }

    func column(for id: String) -> Int? { columnByID[id] }

    func indexPathsForItems(in rect: CGRect) -> [IndexPath] {
        visibleIndex.entriesIntersecting(rect).map(\.value)
    }

    override var collectionViewContentSize: NSSize {
        let height = max(0, (columnHeights.max() ?? 0) - SummaryCardMetrics.itemSpacing + 24)
        let width = max(collectionView?.bounds.width ?? 0, CGFloat(columnCount) * itemWidth + CGFloat(max(0, columnCount - 1)) * SummaryCardMetrics.itemSpacing)
        return CGSize(width: width, height: height)
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        indexPathsForItems(in: rect).compactMap { attributesByIndexPath[$0] }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        attributesByIndexPath[indexPath]
    }

    private func place(_ entries: [SummaryCollectionEntry], startingAt start: Int) {
        guard columnCount > 0 else { return }
        for (offset, entry) in entries.enumerated() {
            let index = start + offset
            let column = shortestColumnIndex()
            let frame = CGRect(
                x: CGFloat(column) * (itemWidth + SummaryCardMetrics.itemSpacing),
                y: columnHeights[column],
                width: itemWidth,
                height: height(for: entry)
            )
            columnByID[entry.id] = column
            framesByID[entry.id] = frame
            columnHeights[column] = frame.maxY + SummaryCardMetrics.itemSpacing
            rebuildAttribute(for: entry, at: index, frame: frame)
        }
        rebuildVisibleIndex()
        rebuildVisualOrder()
    }

    private func rebuildAttribute(for entry: SummaryCollectionEntry, at index: Int, frame: CGRect) {
        let indexPath = IndexPath(item: index, section: 0)
        let attributes = attributesByIndexPath[indexPath] ?? NSCollectionViewLayoutAttributes(forItemWith: indexPath)
        attributes.frame = frame
        attributesByIndexPath[indexPath] = attributes
    }

    private func rebuildVisibleIndex() {
        visibleIndex.reset(columnCount: columnCount)
        for (index, id) in entryIDs.enumerated() {
            guard let column = columnByID[id], let frame = framesByID[id] else { continue }
            visibleIndex.append(IndexPath(item: index, section: 0), frame: frame, order: index, toColumn: column)
        }
    }

    private func rebuildVisualOrder() {
        let ordered = entryIDs.compactMap { id -> (id: String, frame: CGRect, item: Bool)? in
            guard let frame = framesByID[id] else { return nil }
            return (id, frame, !id.hasPrefix("folder:"))
        }.sorted {
            if abs($0.frame.minY - $1.frame.minY) > 0.5 { return $0.frame.minY < $1.frame.minY }
            return $0.frame.minX < $1.frame.minX
        }
        visualItemIDs = ordered.filter(\.item).map(\.id)
        visualFolderIDs = ordered.filter { !$0.item }.map { String($0.id.dropFirst("folder:".count)) }
    }

    private func shortestColumnIndex() -> Int {
        columnHeights.indices.min {
            if columnHeights[$0] == columnHeights[$1] { return $0 < $1 }
            return columnHeights[$0] < columnHeights[$1]
        } ?? 0
    }

    private func height(for entry: SummaryCollectionEntry) -> CGFloat {
        switch entry {
        case .folder(let row): return SummaryCardMetrics.totalHeight(for: row, width: itemWidth)
        case .item(let summary): return SummaryCardMetrics.totalHeight(for: summary, width: itemWidth)
        }
    }

}

/// Real AppKit coordinator used by the Summary List/Masonry surfaces. It is
/// intentionally internal (rather than hidden in a SwiftUI closure) so tests
/// can exercise data-source, incremental insert, hosted callbacks, and native
/// selection against the same object used in production.
@MainActor
final class SummaryMasonryCollectionCoordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate, NSDraggingSource {
    weak var collectionView: NSCollectionView?
    weak var layout: SummaryMasonryCollectionLayout?
    private(set) var entries: [SummaryCollectionEntry] = []
    private(set) var mutation: SummaryCollectionMutation = .none
    private(set) var selectedItemIDs: Set<String> = []
    private(set) var selectedFolderIDs: Set<String> = []
    private(set) var primaryItemID: String?
    private(set) var primaryFolderID: String?

    var onSelectItem: ((String, NSEvent.ModifierFlags) -> Void)?
    var onBlankClick: (() -> Void)?
    var onPreviewItem: ((String) -> Void)?
    var onContextItems: (([String]) -> Void)?
    var onMakeItemContextMenu: (([String]) -> NSMenu?)?
    var onSelectFolder: ((String, NSEvent.ModifierFlags) -> Void)?
    var onOpenFolder: ((String) -> Void)?
    var onContextFolders: (([String]) -> Void)?
    var onMakeFolderContextMenu: (([String]) -> NSMenu?)?
    var onMoveItems: (([String], String) -> Bool)?
    var onMoveFolders: (([String], String) -> Bool)?
    var onPrefetch: ((CGRect, CGFloat) -> Void)?

    private var itemIndexByID: [String: IndexPath] = [:]
    private var folderIndexByID: [String: IndexPath] = [:]
    private var lastContentHeight: CGFloat = 0
    private var activeDragIDs: [String] = []
    private var boundsObserver: NSObjectProtocol?
    private var marqueeBaseItemIDs: Set<String> = []
    private var marqueeBaseFolderIDs: Set<String> = []
    private var marqueeAdditive = false
    private var marqueeStartPoint: CGPoint?
    private var marqueeDomain: MarqueeDomain?

    private enum MarqueeDomain {
        case items
        case folders
    }

    deinit {
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
        }
    }

    func update(
        folders: [SummaryFolderRow],
        summaries: [LibraryItemSummary],
        selectedItemIDs: Set<String>,
        selectedFolderIDs: Set<String>,
        availableWidth: CGFloat,
        thumbnailScale: Double = 1
    ) {
        let nextEntries = folders.map(SummaryCollectionEntry.folder) + summaries.map(SummaryCollectionEntry.item)
        let width = max(1, availableWidth)
        let columns = max(2, min(6, Int((width + 12) / (250 * CGFloat(thumbnailScale) + 12))))
        let itemWidth = max(120, (width - CGFloat(columns - 1) * SummaryCardMetrics.itemSpacing) / CGFloat(columns))
        let oldIDs = entries.map(\.id)
        let newIDs = nextEntries.map(\.id)

        let previousSelectedItemIDs = self.selectedItemIDs
        let previousSelectedFolderIDs = self.selectedFolderIDs
        self.selectedItemIDs = selectedItemIDs
        self.selectedFolderIDs = selectedFolderIDs
        primaryItemID = primaryItemID.flatMap { selectedItemIDs.contains($0) ? $0 : nil } ?? selectedItemIDs.min()
        primaryFolderID = primaryFolderID.flatMap { selectedFolderIDs.contains($0) ? $0 : nil } ?? selectedFolderIDs.min()
        rebuildIndexMaps(nextEntries)

        guard let collectionView, let layout else {
            entries = nextEntries
            mutation = .structuralReload
            return
        }

        if oldIDs.isEmpty {
            entries = nextEntries
            layout.configure(entries: entries, columnCount: columns, itemWidth: itemWidth)
            reloadDataWithoutAnimation(collectionView)
            mutation = .structuralReload
            lastContentHeight = layout.collectionViewContentSize.height
            restoreCompleteSelection()
            return
        }

        let prefix = Array(newIDs.prefix(oldIDs.count)) == oldIDs
        if prefix, nextEntries.count > entries.count,
           layout.columnCount == columns,
           abs(layout.itemWidth - itemWidth) < 0.5 {
            let existingContentChanges = changedEntries(old: entries, new: nextEntries, geometryOnly: false)
            let appended = Array(nextEntries.dropFirst(entries.count))
            entries = nextEntries
            layout.append(entries: appended)
            // Appending a page does not make an already-resident row stale:
            // apply its ID-targeted content/folder refresh in the same update
            // transaction, then insert only the genuinely new index paths.
            for id in existingContentChanges {
                guard let index = entries.firstIndex(where: { $0.id == id }) else { continue }
                layout.update(entry: entries[index], at: index)
            }
            let changedPaths = Set(existingContentChanges.compactMap(indexPath(for:)))
            let indexPaths = appended.indices.map { IndexPath(item: entries.count - appended.count + $0, section: 0) }
            collectionView.insertItems(at: Set(indexPaths))
            if !changedPaths.isEmpty { collectionView.reloadItems(at: changedPaths) }
            mutation = .incrementalAppend(appended.map(\.id))
            lastContentHeight = layout.collectionViewContentSize.height
            restoreIncrementalSelection(
                previousItemIDs: previousSelectedItemIDs,
                previousFolderIDs: previousSelectedFolderIDs
            )
            return
        }

        if oldIDs == newIDs, entries.count == nextEntries.count,
           layout.columnCount == columns,
           abs(layout.itemWidth - itemWidth) < 0.5 {
            let contentChanges = changedEntries(old: entries, new: nextEntries, geometryOnly: false)
            let geometryChanges = changedEntries(old: entries, new: nextEntries, geometryOnly: true)
            entries = nextEntries
            if !geometryChanges.isEmpty {
                // Keep the existing prefix frames/columns and reflow only the
                // changed suffix. A targeted update must not turn into a full
                // layout/reload, otherwise scroll position and native reuse
                // become observable to callers.
                for id in geometryChanges {
                    guard let index = entries.firstIndex(where: { $0.id == id }) else { continue }
                    layout.update(entry: entries[index], at: index)
                }
                // Geometry changes are item-only: folder rows have fixed
                // geometry and must not be treated as layout invalidations.
                // Content/folder changes can arrive in the same transaction;
                // reload the complete changed-ID union so none is dropped by
                // the geometry branch.
                let paths = Set(contentChanges.compactMap(indexPath(for:)))
                if !paths.isEmpty { collectionView.reloadItems(at: paths) }
                mutation = Set(contentChanges) == Set(geometryChanges)
                    ? .targetedGeometry(geometryChanges)
                    : .targetedReload(contentChanges)
            } else if !contentChanges.isEmpty {
                let paths = Set(contentChanges.compactMap(indexPath(for:)))
                if !paths.isEmpty { collectionView.reloadItems(at: paths) }
                mutation = .targetedContent(contentChanges)
            } else {
                mutation = .none
            }
            lastContentHeight = layout.collectionViewContentSize.height
            restoreIncrementalSelection(
                previousItemIDs: previousSelectedItemIDs,
                previousFolderIDs: previousSelectedFolderIDs
            )
            return
        }

        entries = nextEntries
        layout.configure(entries: entries, columnCount: columns, itemWidth: itemWidth)
        reloadDataWithoutAnimation(collectionView)
        mutation = .structuralReload
        lastContentHeight = layout.collectionViewContentSize.height
        // AppKit discards native selection on structural reload. Restore every
        // selected item/folder, not just the primary ID or symmetric delta.
        restoreCompleteSelection()
    }

    func viewportChanged(visibleRect: CGRect) {
        onPrefetch?(visibleRect, lastContentHeight)
    }

    func beginMarquee(at point: CGPoint, additive: Bool) {
        marqueeBaseItemIDs = selectedItemIDs
        marqueeBaseFolderIDs = selectedFolderIDs
        marqueeAdditive = additive
        marqueeStartPoint = point
        marqueeDomain = nil
    }

    func updateMarquee(in rect: CGRect) {
        guard let layout else { return }
        let hitPaths = layout.indexPathsForItems(in: rect)
        if marqueeDomain == nil, let firstPath = hitPaths.min(), entries.indices.contains(firstPath.item) {
            marqueeDomain = entries[firstPath.item].folderID == nil ? .items : .folders
        }
        switch marqueeDomain {
        case .items:
            let hits = Set(hitPaths.compactMap { path -> String? in
                guard entries.indices.contains(path.item) else { return nil }
                return entries[path.item].itemID
            })
            onContextItems?(orderedIDs(
                MarqueeSelectionResolver.selection(base: marqueeBaseItemIDs, hits: hits, additive: marqueeAdditive),
                orderedBy: layout.visualItemIDs
            ))
        case .folders:
            let hits = Set(hitPaths.compactMap { path -> String? in
                guard entries.indices.contains(path.item) else { return nil }
                return entries[path.item].folderID
            })
            onContextFolders?(orderedIDs(
                MarqueeSelectionResolver.selection(base: marqueeBaseFolderIDs, hits: hits, additive: marqueeAdditive),
                orderedBy: layout.visualFolderIDs
            ))
        case nil:
            guard !marqueeAdditive else { return }
            onContextItems?([])
            onContextFolders?([])
        }
    }

    func endMarquee() {
        marqueeBaseItemIDs = []
        marqueeBaseFolderIDs = []
        marqueeAdditive = false
        marqueeStartPoint = nil
        marqueeDomain = nil
    }

    func cancelMarquee() {
        if !marqueeBaseFolderIDs.isEmpty {
            onContextFolders?(orderedIDs(marqueeBaseFolderIDs, orderedBy: layout?.visualFolderIDs ?? []))
        } else {
            onContextItems?(orderedIDs(marqueeBaseItemIDs, orderedBy: layout?.visualItemIDs ?? []))
        }
        endMarquee()
    }

    func clearSelectionFromBlankClick() {
        onBlankClick?()
        endMarquee()
    }

    private func orderedIDs(_ ids: Set<String>, orderedBy visualIDs: [String]) -> [String] {
        visualIDs.filter(ids.contains) + ids.subtracting(visualIDs).sorted()
    }

    /// Connects the real scroll clip view to the two-viewport prefetch rule.
    /// The observer is installed once for the AppKit host and remains active
    /// while pages are appended; no SwiftUI redraw is required to drive it.
    func observeBounds(of scrollView: NSScrollView) {
        guard boundsObserver == nil else { return }
        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self, weak clipView] _ in
            guard let self, let clipView else { return }
            Task { @MainActor in
                self.viewportChanged(visibleRect: clipView.bounds)
            }
        }
        viewportChanged(visibleRect: clipView.bounds)
    }

    func stopObservingBounds() {
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
            self.boundsObserver = nil
        }
    }

    func numberOfItems(in collectionView: NSCollectionView) -> Int { entries.count }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        entries.count
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: SummaryCollectionItem.reuseIdentifier, for: indexPath)
        guard let summaryItem = item as? SummaryCollectionItem, entries.indices.contains(indexPath.item) else { return item }
        summaryItem.configure(
            entry: entries[indexPath.item],
            width: layout?.layoutAttributesForItem(at: indexPath)?.frame.width ?? 200,
            isSelected: selectedIndexPaths().contains(indexPath),
            onClick: { [weak self] id, modifiers in self?.handleClick(id: id, modifiers: modifiers) },
            onDoubleClick: { [weak self] id in self?.onPreviewItem?(id) },
            onContext: { [weak self] id in self?.notifyContext(id: id) },
            onContextMenu: { [weak self] id in self?.makeContextMenu(id: id) },
            onBeginDrag: { [weak self] id, event, source in self?.beginDrag(id: id, event: event, source: source) },
            onMoveItems: { [weak self] ids, folderID in self?.onMoveItems?(ids, folderID) ?? false },
            onMoveFolders: { [weak self] ids, folderID in self?.onMoveFolders?(ids, folderID) ?? false },
            onOpenFolder: { [weak self] id in self?.onOpenFolder?(id) }
        )
        return summaryItem
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let indexPath = indexPaths.first, entries.indices.contains(indexPath.item) else { return }
        switch entries[indexPath.item] {
        case .item(let summary): onSelectItem?(summary.id, [])
        case .folder(let row): onSelectFolder?(row.id, [])
        }
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {}

    private func handleClick(id: String, modifiers: NSEvent.ModifierFlags) {
        if let indexPath = itemIndexByID[id], entries.indices.contains(indexPath.item), case .item = entries[indexPath.item] {
            onSelectItem?(id, modifiers)
        } else if let indexPath = folderIndexByID[id], entries.indices.contains(indexPath.item), case .folder = entries[indexPath.item] {
            onSelectFolder?(id, modifiers)
        }
    }

    private func contextIDs(for id: String) -> (items: [String]?, folders: [String]?) {
        if itemIndexByID[id] != nil {
            return (orderedSelectedIDs(clickedID: id), nil)
        } else if folderIndexByID[id] != nil {
            return (nil, orderedSelectedFolderIDs(clickedID: id))
        }
        return (nil, nil)
    }

    private func notifyContext(id: String) {
        let context = contextIDs(for: id)
        if let itemIDs = context.items {
            onContextItems?(itemIDs)
        } else if let folderIDs = context.folders {
            onContextFolders?(folderIDs)
        }
    }

    private func makeContextMenu(id: String) -> NSMenu? {
        let context = contextIDs(for: id)
        if let itemIDs = context.items {
            return onMakeItemContextMenu?(itemIDs)
        }
        if let folderIDs = context.folders {
            return onMakeFolderContextMenu?(folderIDs)
        }
        return nil
    }

    private func orderedSelectedIDs(clickedID: String) -> [String] {
        guard selectedItemIDs.contains(clickedID) else { return [clickedID] }
        let ordered = entries.compactMap(\.itemID).filter(selectedItemIDs.contains)
        return ordered.isEmpty ? [clickedID] : ordered
    }

    private func orderedSelectedFolderIDs(clickedID: String) -> [String] {
        guard selectedFolderIDs.contains(clickedID) else { return [clickedID] }
        let ordered = entries.compactMap(\.folderID).filter(selectedFolderIDs.contains)
        return ordered.isEmpty ? [clickedID] : ordered
    }

    private func beginDrag(id: String, event: NSEvent, source: NSView) {
        guard let collectionView else { return }
        guard let (pasteboardItem, _) = dragPasteboardItem(for: id) else { return }
        let drag = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let frame = source.convert(source.bounds, to: collectionView)
        drag.setDraggingFrame(frame, contents: source.snapshotImage())
        activeDragIDs = orderedDragIDs(for: id)
        let session = collectionView.beginDraggingSession(with: [drag], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = false
    }

    /// Builds the exact multi-ID payload used by the hosted card's drag
    /// callback. Keeping this on the production coordinator lets tests decode
    /// the same pasteboard item that `beginDrag` hands to AppKit.
    func dragPasteboardItem(for id: String) -> (NSPasteboardItem, [String])? {
        guard itemIndexByID[id] != nil || folderIndexByID[id] != nil else { return nil }
        let isFolder = folderIndexByID[id] != nil
        let ids = orderedDragIDs(for: id)
        let data: Data?
        let pasteboardType: NSPasteboard.PasteboardType
        if isFolder {
            data = try? FolderDragPayload(folderIDs: ids).encoded()
            pasteboardType = NSPasteboard.PasteboardType(FolderDragPayload.pasteboardTypeIdentifier)
        } else {
            data = try? PromptItemDragPayload(itemIDs: ids).encoded()
            pasteboardType = NSPasteboard.PasteboardType(PromptItemDragPayload.pasteboardTypeIdentifier)
        }
        guard let data else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setData(data, forType: pasteboardType)
        pasteboardItem.setString(ids.joined(separator: "\n"), forType: .string)
        return (pasteboardItem, ids)
    }

    private func orderedDragIDs(for id: String) -> [String] {
        if folderIndexByID[id] != nil {
            return orderedSelectedFolderIDs(clickedID: id)
        }
        return orderedSelectedIDs(clickedID: id)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        activeDragIDs = []
    }

    private func selectedIndexPaths() -> Set<IndexPath> {
        Set(selectedItemIDs.compactMap { itemIndexByID[$0] }).union(selectedFolderIDs.compactMap { folderIndexByID[$0] })
    }

    private func restoreCompleteSelection() {
        collectionView?.selectionIndexPaths = selectedIndexPaths()
    }

    private func restoreIncrementalSelection(
        previousItemIDs: Set<String>,
        previousFolderIDs: Set<String>
    ) {
        guard let collectionView else { return }
        let removedItems = previousItemIDs.subtracting(selectedItemIDs)
        let addedItems = selectedItemIDs.subtracting(previousItemIDs)
        let removedFolders = previousFolderIDs.subtracting(selectedFolderIDs)
        let addedFolders = selectedFolderIDs.subtracting(previousFolderIDs)
        let removedPaths = Set(removedItems.compactMap { itemIndexByID[$0] })
            .union(removedFolders.compactMap { folderIndexByID[$0] })
        let addedPaths = Set(addedItems.compactMap { itemIndexByID[$0] })
            .union(addedFolders.compactMap { folderIndexByID[$0] })
        // Keep the native selection untouched for retained IDs. Incremental
        // branches mutate only the symmetric difference; assigning the full
        // set is reserved for structural reloads after AppKit discards it.
        if !removedPaths.isEmpty {
            collectionView.deselectItems(at: removedPaths)
        }
        if !addedPaths.isEmpty {
            collectionView.selectItems(at: addedPaths, scrollPosition: [])
        }
    }

    private func rebuildIndexMaps(_ entries: [SummaryCollectionEntry]) {
        itemIndexByID = [:]
        folderIndexByID = [:]
        for (index, entry) in entries.enumerated() {
            let path = IndexPath(item: index, section: 0)
            if let itemID = entry.itemID { itemIndexByID[itemID] = path }
            if let folderID = entry.folderID { folderIndexByID[folderID] = path }
        }
    }

    private func indexPath(for id: String) -> IndexPath? {
        itemIndexByID[id] ?? folderIndexByID[id]
    }

    private func changedEntries(old: [SummaryCollectionEntry], new: [SummaryCollectionEntry], geometryOnly: Bool) -> [String] {
        old.indices.compactMap { index in
            switch (old[index], new[index]) {
            case (.item(let oldSummary), .item(let newSummary)):
                if geometryOnly {
                    return oldSummary.geometryKey != newSummary.geometryKey ? newSummary.id : nil
                }
                return oldSummary != newSummary ? newSummary.id : nil
            case (.folder(let oldFolder), .folder(let newFolder)):
                // Folder rows are an independent source. Count/name changes
                // refresh only that row and never invalidate item pagination.
                if geometryOnly { return nil }
                return oldFolder != newFolder ? newFolder.id : nil
            default:
                return nil
            }
        }
    }

    private func reloadDataWithoutAnimation(_ collectionView: NSCollectionView) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            collectionView.reloadData()
            collectionView.layoutSubtreeIfNeeded()
        }
    }
}

/// AppKit-backed Summary collection host. No full PromptItem is accepted by
/// this API, making accidental legacy hydration visible at compile time.
struct SummaryMasonryCollectionView: NSViewRepresentable {
    let folders: [SummaryFolderRow]
    let summaries: [LibraryItemSummary]
    let selectedItemIDs: Set<String>
    let selectedFolderIDs: Set<String>
    let onBlankClick: (() -> Void)?
    let onSelectItem: (String, NSEvent.ModifierFlags) -> Void
    let onPreviewItem: (String) -> Void
    let onContextItems: ([String]) -> Void
    let onMakeItemContextMenu: (([String]) -> NSMenu?)?
    let onSelectFolder: (String, NSEvent.ModifierFlags) -> Void
    let onOpenFolder: (String) -> Void
    let onContextFolders: ([String]) -> Void
    let onMakeFolderContextMenu: (([String]) -> NSMenu?)?
    let onMoveItems: ([String], String) -> Bool
    let onMoveFolders: ([String], String) -> Bool
    let onPrefetch: ((CGRect, CGFloat) -> Void)?
    let thumbnailScale: Double

    init(
        folders: [SummaryFolderRow],
        summaries: [LibraryItemSummary],
        selectedItemIDs: Set<String> = [],
        selectedFolderIDs: Set<String> = [],
        onBlankClick: (() -> Void)? = nil,
        thumbnailScale: Double = 1,
        onSelectItem: @escaping (String, NSEvent.ModifierFlags) -> Void = { _, _ in },
        onPreviewItem: @escaping (String) -> Void = { _ in },
        onContextItems: @escaping ([String]) -> Void = { _ in },
        onMakeItemContextMenu: (([String]) -> NSMenu?)? = nil,
        onSelectFolder: @escaping (String, NSEvent.ModifierFlags) -> Void = { _, _ in },
        onOpenFolder: @escaping (String) -> Void = { _ in },
        onContextFolders: @escaping ([String]) -> Void = { _ in },
        onMakeFolderContextMenu: (([String]) -> NSMenu?)? = nil,
        onMoveItems: @escaping ([String], String) -> Bool = { _, _ in false },
        onMoveFolders: @escaping ([String], String) -> Bool = { _, _ in false },
        onPrefetch: ((CGRect, CGFloat) -> Void)? = nil
    ) {
        self.folders = folders
        self.summaries = summaries
        self.selectedItemIDs = selectedItemIDs
        self.selectedFolderIDs = selectedFolderIDs
        self.onBlankClick = onBlankClick
        self.thumbnailScale = thumbnailScale
        self.onSelectItem = onSelectItem
        self.onPreviewItem = onPreviewItem
        self.onContextItems = onContextItems
        self.onMakeItemContextMenu = onMakeItemContextMenu
        self.onSelectFolder = onSelectFolder
        self.onOpenFolder = onOpenFolder
        self.onContextFolders = onContextFolders
        self.onMakeFolderContextMenu = onMakeFolderContextMenu
        self.onMoveItems = onMoveItems
        self.onMoveFolders = onMoveFolders
        self.onPrefetch = onPrefetch
    }

    func makeCoordinator() -> SummaryMasonryCollectionCoordinator {
        SummaryMasonryCollectionCoordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView(frame: .zero)
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay

        let collectionView = NativeMarqueeCollectionView(frame: .zero)
        let layout = SummaryMasonryCollectionLayout()
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.register(SummaryCollectionItem.self, forItemWithIdentifier: SummaryCollectionItem.reuseIdentifier)
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.clear]
        scrollView.documentView = collectionView
        context.coordinator.collectionView = collectionView
        context.coordinator.layout = layout
        collectionView.onBlankClick = { [weak coordinator = context.coordinator] in
            coordinator?.clearSelectionFromBlankClick()
        }
        collectionView.onMarqueeBegin = { [weak coordinator = context.coordinator] point, additive in
            coordinator?.beginMarquee(at: point, additive: additive)
        }
        collectionView.onMarqueeChange = { [weak coordinator = context.coordinator] rect in
            coordinator?.updateMarquee(in: rect)
        }
        collectionView.onMarqueeEnd = { [weak coordinator = context.coordinator] in
            coordinator?.endMarquee()
        }
        collectionView.onMarqueeCancel = { [weak coordinator = context.coordinator] in
            coordinator?.cancelMarquee()
        }
        context.coordinator.observeBounds(of: scrollView)
        context.coordinator.onBlankClick = onBlankClick
        context.coordinator.onSelectItem = onSelectItem
        context.coordinator.onPreviewItem = onPreviewItem
        context.coordinator.onContextItems = onContextItems
        context.coordinator.onMakeItemContextMenu = onMakeItemContextMenu
        context.coordinator.onSelectFolder = onSelectFolder
        context.coordinator.onOpenFolder = onOpenFolder
        context.coordinator.onContextFolders = onContextFolders
        context.coordinator.onMakeFolderContextMenu = onMakeFolderContextMenu
        context.coordinator.onMoveItems = onMoveItems
        context.coordinator.onMoveFolders = onMoveFolders
        context.coordinator.onPrefetch = onPrefetch
        context.coordinator.update(
            folders: folders,
            summaries: summaries,
            selectedItemIDs: selectedItemIDs,
            selectedFolderIDs: selectedFolderIDs,
            availableWidth: 600,
            thumbnailScale: thumbnailScale
        )
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let collectionView = scrollView.documentView as? NSCollectionView else { return }
        context.coordinator.update(
            folders: folders,
            summaries: summaries,
            selectedItemIDs: selectedItemIDs,
            selectedFolderIDs: selectedFolderIDs,
            availableWidth: max(1, collectionView.bounds.width),
            thumbnailScale: thumbnailScale
        )
        if let collectionView = collectionView as? NativeMarqueeCollectionView {
            collectionView.onBlankClick = { [weak coordinator = context.coordinator] in
                coordinator?.clearSelectionFromBlankClick()
            }
            collectionView.onMarqueeBegin = { [weak coordinator = context.coordinator] point, additive in
                coordinator?.beginMarquee(at: point, additive: additive)
            }
            collectionView.onMarqueeChange = { [weak coordinator = context.coordinator] rect in
                coordinator?.updateMarquee(in: rect)
            }
            collectionView.onMarqueeEnd = { [weak coordinator = context.coordinator] in
                coordinator?.endMarquee()
            }
            collectionView.onMarqueeCancel = { [weak coordinator = context.coordinator] in
                coordinator?.cancelMarquee()
            }
        }
        context.coordinator.onBlankClick = onBlankClick
        context.coordinator.onPrefetch = onPrefetch
        context.coordinator.onSelectItem = onSelectItem
        context.coordinator.onPreviewItem = onPreviewItem
        context.coordinator.onContextItems = onContextItems
        context.coordinator.onMakeItemContextMenu = onMakeItemContextMenu
        context.coordinator.onSelectFolder = onSelectFolder
        context.coordinator.onOpenFolder = onOpenFolder
        context.coordinator.onContextFolders = onContextFolders
        context.coordinator.onMakeFolderContextMenu = onMakeFolderContextMenu
        context.coordinator.onMoveItems = onMoveItems
        context.coordinator.onMoveFolders = onMoveFolders
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: SummaryMasonryCollectionCoordinator) {
        coordinator.stopObservingBounds()
    }
}

final class SummaryCollectionItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("SummaryCollectionItem")
    private var hostedView: SummaryPassThroughHostingView?
    private var eventView: SummaryCardEventView?

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        hostedView?.removeFromSuperview()
        hostedView = nil
        eventView?.removeFromSuperview()
        eventView = nil
    }

    func configure(
        entry: SummaryCollectionEntry,
        width: CGFloat,
        isSelected: Bool,
        onClick: @escaping (String, NSEvent.ModifierFlags) -> Void,
        onDoubleClick: @escaping (String) -> Void,
        onContext: @escaping (String) -> Void,
        onContextMenu: @escaping (String) -> NSMenu? = { _ in nil },
        onBeginDrag: @escaping (String, NSEvent, NSView) -> Void,
        onMoveItems: @escaping ([String], String) -> Bool,
        onMoveFolders: @escaping ([String], String) -> Bool,
        onOpenFolder: @escaping (String) -> Void
    ) {
        let height: CGFloat
        let root: AnyView
        let id = entry.itemID ?? entry.folderID ?? entry.id
        switch entry {
        case .item(let summary):
            height = SummaryCardMetrics.totalHeight(for: summary, width: width)
            root = AnyView(SummaryCardView(summary: summary, isSelected: isSelected))
        case .folder(let row):
            height = SummaryCardMetrics.totalHeight(for: row, width: width)
            root = AnyView(SummaryFolderCardView(row: row, isSelected: isSelected))
        }
        view.frame.size = CGSize(width: width, height: height)
        let interactive = eventView ?? SummaryCardEventView(frame: view.bounds)
        interactive.frame = view.bounds
        interactive.autoresizingMask = [.width, .height]
        interactive.configure(
            id: id,
            isFolder: entry.folderID != nil,
            onClick: onClick,
            onDoubleClick: onDoubleClick,
            onContext: onContext,
            onContextMenu: onContextMenu,
            onBeginDrag: onBeginDrag,
            onMoveItems: onMoveItems,
            onMoveFolders: onMoveFolders,
            onOpenFolder: onOpenFolder
        )
        if interactive.superview == nil { view.addSubview(interactive) }
        eventView = interactive
        let hosted = hostedView ?? SummaryPassThroughHostingView(rootView: root)
        hosted.rootView = root
        hosted.frame = interactive.bounds
        hosted.autoresizingMask = [.width, .height]
        if hosted.superview == nil { interactive.addSubview(hosted) }
        hostedView = hosted
    }
}

/// The SwiftUI card is visual content. The sibling event view owns the native
/// hit-test and AppKit event stream, so the hosting layer must never cover it.
final class SummaryPassThroughHostingView: NSHostingView<AnyView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class SummaryCardEventView: NSView {
    private var representedID = ""
    private var isFolder = false
    private var clickAction: ((String, NSEvent.ModifierFlags) -> Void)?
    private var doubleClickAction: ((String) -> Void)?
    private var contextAction: ((String) -> Void)?
    private var contextMenuAction: ((String) -> NSMenu?)?
    private var dragAction: ((String, NSEvent, NSView) -> Void)?
    private var moveItems: (([String], String) -> Bool)?
    private var moveFolders: (([String], String) -> Bool)?
    private var openFolder: ((String) -> Void)?
    private var contextMenuTargets: [SummaryContextMenuActionTarget] = []
    private var dragStart: NSPoint?
    private var didDrag = false

    var representedIDForTesting: String { representedID }
    var isFolderForTesting: Bool { isFolder }

    func configure(
        id: String,
        isFolder: Bool,
        onClick: @escaping (String, NSEvent.ModifierFlags) -> Void,
        onDoubleClick: @escaping (String) -> Void,
        onContext: @escaping (String) -> Void,
        onContextMenu: @escaping (String) -> NSMenu? = { _ in nil },
        onBeginDrag: @escaping (String, NSEvent, NSView) -> Void,
        onMoveItems: @escaping ([String], String) -> Bool,
        onMoveFolders: @escaping ([String], String) -> Bool,
        onOpenFolder: @escaping (String) -> Void
    ) {
        representedID = id
        self.isFolder = isFolder
        clickAction = onClick
        doubleClickAction = onDoubleClick
        contextAction = onContext
        contextMenuAction = onContextMenu
        dragAction = onBeginDrag
        moveItems = onMoveItems
        moveFolders = onMoveFolders
        openFolder = onOpenFolder
        contextMenuTargets.removeAll(keepingCapacity: true)
        registerForDraggedTypes([
            NSPasteboard.PasteboardType(PromptItemDragPayload.pasteboardTypeIdentifier),
            NSPasteboard.PasteboardType(FolderDragPayload.pasteboardTypeIdentifier),
            .string
        ])
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = event.locationInWindow
        didDrag = false
        if event.clickCount >= 2 {
            if isFolder { openFolder?(representedID) } else { doubleClickAction?(representedID) }
            return
        }
        clickAction?(representedID, event.modifierFlags.intersection([.command, .shift]))
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didDrag, let dragStart else { return }
        let delta = event.locationInWindow
        guard hypot(delta.x - dragStart.x, delta.y - dragStart.y) >= 6 else { return }
        didDrag = true
        dragAction?(representedID, event, self)
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
        didDrag = false
        super.mouseUp(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextAction?(representedID)
        if let contextMenu = contextMenuAction?(representedID) {
            return contextMenu
        }
        let menu = NSMenu(title: isFolder ? "文件夹" : "项目")
        let target = SummaryContextMenuActionTarget { [weak self] in
            if self?.isFolder == true {
                self?.openFolder?(self?.representedID ?? "")
            } else {
                self?.doubleClickAction?(self?.representedID ?? "")
            }
        }
        contextMenuTargets = [target]
        let item = NSMenuItem(
            title: isFolder ? "打开文件夹" : "预览",
            action: #selector(SummaryContextMenuActionTarget.run),
            keyEquivalent: ""
        )
        item.target = target
        menu.addItem(item)
        return menu
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isFolder else { return [] }
        return sender.draggingPasteboard.canReadItem(withDataConformingToTypes: [
            PromptItemDragPayload.pasteboardTypeIdentifier,
            FolderDragPayload.pasteboardTypeIdentifier
        ]) ? NSDragOperation.move : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        if let data = pasteboard.data(forType: NSPasteboard.PasteboardType(PromptItemDragPayload.pasteboardTypeIdentifier)),
           let payload = try? PromptItemDragPayload.decode(data),
           isFolder {
            return moveItems?(payload.itemIDs, representedID) ?? false
        }
        if let data = pasteboard.data(forType: NSPasteboard.PasteboardType(FolderDragPayload.pasteboardTypeIdentifier)),
           let payload = try? FolderDragPayload.decode(data),
           isFolder {
            return moveFolders?(payload.folderIDs, representedID) ?? false
        }
        return false
    }
}

private final class SummaryContextMenuActionTarget: NSObject {
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    @objc func run() {
        action()
    }
}

private struct SummaryCardView: View {
    let summary: LibraryItemSummary
    let isSelected: Bool
    @StateObject private var loader = SharedThumbnailImageLoader()

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: SummaryCardMetrics.cornerRadius, style: .continuous)
                .fill(StudioColor.panelRaised)
            if let image = loader.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: SummaryCardMetrics.cornerRadius, style: .continuous))
            } else {
                Image(systemName: symbolName)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(StudioColor.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            LinearGradient(
                colors: [.clear, Color.black.opacity(0.72)],
                startPoint: .center,
                endPoint: .bottom
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.title.isEmpty ? "未命名" : summary.title)
                    .font(StudioFont.font(13, weight: .semibold))
                    .lineLimit(2)
                Text(summary.folderName.isEmpty ? summary.assetKind.displayName : summary.folderName)
                    .font(StudioFont.font(10))
                    .foregroundStyle(.white.opacity(0.72))
            }
            .foregroundStyle(.white)
            .padding(12)
        }
        .overlay(
            RoundedRectangle(cornerRadius: SummaryCardMetrics.cornerRadius + 2, style: .continuous)
                .stroke(isSelected ? StudioColor.primaryAction : Color.clear, lineWidth: 2)
        )
        .task(id: summary.id + summary.thumbnailPath + String(summary.updatedAt.timeIntervalSinceReferenceDate)) {
            guard !summary.thumbnailPath.isEmpty else { return }
            let request = ThumbnailImageRequest(
                path: summary.thumbnailPath,
                contentVersion: summary.updatedAt.timeIntervalSinceReferenceDate,
                maxPixelSize: 1_200
            )
            await loader.load(request)
        }
    }

    private var symbolName: String {
        switch summary.assetKind {
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .markdown, .json, .text, .data: return "doc.text"
        default: return "doc"
        }
    }
}

private struct SummaryFolderCardView: View {
    let row: SummaryFolderRow
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "folder.fill")
                .font(.system(size: 28))
                .foregroundStyle(StudioColor.primaryAction)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.folder.name)
                    .font(StudioFont.font(14, weight: .semibold))
                    .lineLimit(2)
                Text("\(row.count) 个文件")
                    .font(StudioFont.font(11))
                    .foregroundStyle(StudioColor.mutedText)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(StudioColor.panelRaised))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected ? StudioColor.primaryAction : StudioColor.hairline, lineWidth: isSelected ? 2 : 1)
        )
    }
}

private extension NSView {
    func snapshotImage() -> NSImage {
        guard let representation = bitmapImageRepForCachingDisplay(in: bounds) else { return NSImage(size: bounds.size) }
        cacheDisplay(in: bounds, to: representation)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(representation)
        return image
    }
}
