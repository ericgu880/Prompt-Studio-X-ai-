import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PromptStudioCore

enum SummarySurfacePresentation: Equatable {
    case loadState
    case surface
}

/// The exact retry action installed into both production error buttons. Keeping
/// this small value explicit lets runtime tests exercise the same callback
/// boundary without reaching into SwiftUI's private Button storage.
@MainActor
struct SummaryRetryAction {
    private unowned let state: AppState

    init(state: AppState) {
        self.state = state
    }

    func perform() {
        state.retrySummaryPage()
    }
}

func summarySurfacePresentation(
    initialLoading: Bool,
    appendLoading: Bool,
    error: LibrarySummaryPaginator.ErrorState?,
    hasResidentSurface: Bool
) -> SummarySurfacePresentation {
    if initialLoading || !hasResidentSurface {
        return .loadState
    }
    if let error, error.phase != .append {
        return .loadState
    }
    // Append work and append errors are overlays on the resident surface.
    _ = appendLoading
    return .surface
}

struct SummarySurfaceView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var paginator: LibrarySummaryPaginator
    let folders: [SummaryFolderRow]

    var body: some View {
        Group {
            if summarySurfacePresentation(
                initialLoading: paginator.initialLoading,
                appendLoading: paginator.appendLoading,
                error: paginator.error,
                hasResidentSurface: !paginator.summaries.isEmpty || !folders.isEmpty
            ) == .loadState {
                SummaryLoadStateView(
                    isLoading: paginator.initialLoading,
                    error: paginator.error,
                    onRetry: SummaryRetryAction(state: state).perform
                )
            } else if state.isListView {
                SummaryListView(
                    folders: folders,
                    summaries: paginator.summaries,
                    selectedItemIDs: state.selectedIDs,
                    selectedFolderIDs: state.selectedFolderIDs,
                    hasMore: paginator.hasMore,
                    loading: paginator.isLoading,
                    error: paginator.error,
                    onSelectItem: { id, modifiers in
                        state.selectSummaryItem(id: id, modifiers: modifiers)
                    },
                    onPreviewItem: state.previewSummaryItem,
                    onContextItems: { ids in
                        state.selectSummaryItems(ids)
                    },
                    itemContextCapabilities: state.summaryItemContextCapabilities,
                    onItemContextAction: { ids, action in
                        state.performSummaryItemContextAction(action, ids: ids)
                    },
                    onSelectFolder: { id, modifiers in
                        state.selectSummaryFolder(id: id, modifiers: modifiers)
                    },
                    onOpenFolder: { id in
                        state.enterSummaryFolder(id: id)
                    },
                    onContextFolders: { ids in
                        state.selectSummaryFolderIDs(ids)
                    },
                    folderContextCapabilities: state.summaryFolderContextCapabilities,
                    onFolderContextAction: { ids, action in
                        state.performSummaryFolderContextAction(action, ids: ids)
                    },
                    onMoveItems: state.moveSummaryItems,
                    onMoveFolders: state.moveSummaryFolders,
                    onAppend: state.appendSummaryPage,
                    onRetry: SummaryRetryAction(state: state).perform
                )
            } else {
                ZStack(alignment: .bottom) {
                    SummaryMasonryCollectionView(
                        folders: folders,
                        summaries: paginator.summaries,
                        selectedItemIDs: state.selectedIDs,
                        selectedFolderIDs: state.selectedFolderIDs,
                        onBlankClick: state.clearSummarySelection,
                        onSelectItem: { id, modifiers in
                            state.selectSummaryItem(id: id, modifiers: modifiers)
                        },
                        onPreviewItem: state.previewSummaryItem,
                        onContextItems: { ids in
                            state.selectSummaryItems(ids)
                        },
                        onMakeItemContextMenu: state.makeSummaryItemContextMenu,
                        onSelectFolder: { id, modifiers in
                            state.selectSummaryFolder(id: id, modifiers: modifiers)
                        },
                        onOpenFolder: { id in
                            state.enterSummaryFolder(id: id)
                        },
                        onContextFolders: { ids in
                            state.selectSummaryFolderIDs(ids)
                        },
                        onMakeFolderContextMenu: state.makeSummaryFolderContextMenu,
                        onMoveItems: state.moveSummaryItems,
                        onMoveFolders: state.moveSummaryFolders,
                        onPrefetch: state.prefetchSummaryPage
                    )
                    if let error = paginator.error {
                        SummaryPagingErrorBanner(
                            error: error,
                            onRetry: SummaryRetryAction(state: state).perform
                        )
                            .padding(16)
                    }
                }
            }
        }
    }
}

struct SummaryLoadStateView: View {
    let isLoading: Bool
    let error: LibrarySummaryPaginator.ErrorState?
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            if isLoading {
                ProgressView()
                Text("正在加载资料库摘要…")
                    .font(StudioFont.font(13))
                    .foregroundStyle(StudioColor.secondaryText)
            } else if let error {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28))
                    .foregroundStyle(StudioColor.orange)
                Text(error.message)
                    .font(StudioFont.font(13))
                    .foregroundStyle(StudioColor.secondaryText)
                    .multilineTextAlignment(.center)
                Button("重试", action: onRetry)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
    }
}

struct SummaryPagingErrorBanner: View {
    let error: LibrarySummaryPaginator.ErrorState
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(StudioColor.orange)
            Text(error.message)
                .font(StudioFont.font(12))
                .foregroundStyle(StudioColor.secondaryText)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button("重试", action: onRetry)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(StudioColor.hairline, lineWidth: 1))
    }
}

/// Shared ID ordering for List context selection and drag payloads. Keeping
/// this outside the row views makes the multi-selection contract testable
/// without hydrating a legacy PromptItem.
enum SummaryListInteractionSupport {
    static func orderedIDs(
        clickedID: String,
        selectedIDs: Set<String>,
        visualIDs: [String]
    ) -> [String] {
        guard selectedIDs.contains(clickedID) else { return [clickedID] }
        let ordered = visualIDs.filter(selectedIDs.contains)
        return ordered.isEmpty ? [clickedID] : ordered
    }

    static func dragIDs(
        clickedID: String,
        selectedIDs: Set<String>,
        visualIDs: [String]
    ) -> [String] {
        orderedIDs(clickedID: clickedID, selectedIDs: selectedIDs, visualIDs: visualIDs)
    }
}

/// The asynchronous provider decoder remains available to non-view tests and
/// callers that already own an asynchronous drop lifecycle. Production List
/// rows use the native AppKit host below so acceptance and mutation share one
/// synchronous pasteboard boundary.
enum SummaryListDropCoordinator {
    @MainActor
    static func performItemDrop(
        providers: [NSItemProvider],
        folderID: String,
        move: @escaping ([String], String) -> Bool
    ) async -> Bool {
        guard let provider = providers.first else { return false }
        let result = await SummaryProviderLoader.loadData(
            from: provider,
            typeIdentifier: PromptItemDragPayload.pasteboardTypeIdentifier
        )
        guard case .success(let data) = result,
              let payload = try? PromptItemDragPayload.decode(data) else { return false }
        return move(payload.itemIDs, folderID)
    }

    @MainActor
    static func performFolderDrop(
        providers: [NSItemProvider],
        folderID: String,
        move: @escaping ([String], String) -> Bool
    ) async -> Bool {
        guard let provider = providers.first else { return false }
        let result = await SummaryProviderLoader.loadData(
            from: provider,
            typeIdentifier: FolderDragPayload.pasteboardTypeIdentifier
        )
        guard case .success(let data) = result,
              let payload = try? FolderDragPayload.decode(data) else { return false }
        return move(payload.folderIDs, folderID)
    }
}

/// Hosts one production List row in an AppKit drag destination.  The hosting
/// view renders the SwiftUI row while returning the actual mutation result from
/// `performDragOperation`, so SwiftUI never reports a successful drop before
/// the repository mutation has completed.
struct SummaryListDropTargetRow<Content: View>: NSViewRepresentable {
    let folderID: String
    let onMoveItems: ([String], String) -> Bool
    let onMoveFolders: ([String], String) -> Bool
    let content: Content

    func makeNSView(context: Context) -> SummaryListDropTargetHostingView {
        SummaryListDropTargetHostingView(
            rootView: AnyView(content),
            folderID: folderID,
            onMoveItems: onMoveItems,
            onMoveFolders: onMoveFolders
        )
    }

    func updateNSView(_ nsView: SummaryListDropTargetHostingView, context: Context) {
        nsView.update(
            rootView: AnyView(content),
            folderID: folderID,
            onMoveItems: onMoveItems,
            onMoveFolders: onMoveFolders
        )
    }
}

final class SummaryListDropTargetHostingView: NSHostingView<AnyView> {
    private var folderID = ""
    private var onMoveItems: ([String], String) -> Bool = { _, _ in false }
    private var onMoveFolders: ([String], String) -> Bool = { _, _ in false }

    required init(rootView: AnyView) {
        super.init(rootView: rootView)
        registerForDraggedTypes([
            NSPasteboard.PasteboardType(PromptItemDragPayload.pasteboardTypeIdentifier),
            NSPasteboard.PasteboardType(FolderDragPayload.pasteboardTypeIdentifier)
        ])
    }

    convenience init(
        rootView: AnyView,
        folderID: String,
        onMoveItems: @escaping ([String], String) -> Bool,
        onMoveFolders: @escaping ([String], String) -> Bool
    ) {
        self.init(rootView: rootView)
        self.folderID = folderID
        self.onMoveItems = onMoveItems
        self.onMoveFolders = onMoveFolders
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        rootView: AnyView,
        folderID: String,
        onMoveItems: @escaping ([String], String) -> Bool,
        onMoveFolders: @escaping ([String], String) -> Bool
    ) {
        self.rootView = rootView
        self.folderID = folderID
        self.onMoveItems = onMoveItems
        self.onMoveFolders = onMoveFolders
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        payload(from: sender.draggingPasteboard) == nil ? [] : .move
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let payload = payload(from: sender.draggingPasteboard) else { return false }
        switch payload {
        case .items(let ids):
            return onMoveItems(ids, folderID)
        case .folders(let ids):
            return onMoveFolders(ids, folderID)
        }
    }

    private enum Payload {
        case items([String])
        case folders([String])
    }

    private func payload(from pasteboard: NSPasteboard) -> Payload? {
        if let data = pasteboard.data(forType: NSPasteboard.PasteboardType(PromptItemDragPayload.pasteboardTypeIdentifier)),
           let payload = try? PromptItemDragPayload.decode(data),
           !payload.itemIDs.isEmpty {
            return .items(payload.itemIDs)
        }
        if let data = pasteboard.data(forType: NSPasteboard.PasteboardType(FolderDragPayload.pasteboardTypeIdentifier)),
           let payload = try? FolderDragPayload.decode(data),
           !payload.folderIDs.isEmpty {
            return .folders(payload.folderIDs)
        }
        return nil
    }
}

/// List counterpart to SummaryMasonryCollectionView.  It accepts only
/// LibraryItemSummary values and keeps folders as an independent row source.
struct SummaryListView: View {
    let folders: [SummaryFolderRow]
    let summaries: [LibraryItemSummary]
    let selectedItemIDs: Set<String>
    let selectedFolderIDs: Set<String>
    let hasMore: Bool
    let loading: Bool
    let error: LibrarySummaryPaginator.ErrorState?
    let onSelectItem: (String, NSEvent.ModifierFlags) -> Void
    let onPreviewItem: (String) -> Void
    let onContextItems: ([String]) -> Void
    let itemContextCapabilities: ([String]) -> [SummaryItemContextCapability]
    let onItemContextAction: ([String], SummaryItemContextAction) -> Void
    let onSelectFolder: (String, NSEvent.ModifierFlags) -> Void
    let onOpenFolder: (String) -> Void
    let onContextFolders: ([String]) -> Void
    let folderContextCapabilities: ([String]) -> [SummaryFolderContextCapability]
    let onFolderContextAction: ([String], SummaryFolderContextAction) -> Void
    let onMoveItems: ([String], String) -> Bool
    let onMoveFolders: ([String], String) -> Bool
    let onAppend: () -> Void
    let onRetry: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(folders) { row in
                    SummaryListDropTargetRow(
                        folderID: row.id,
                        onMoveItems: onMoveItems,
                        onMoveFolders: onMoveFolders,
                        content: SummaryListFolderRow(
                            row: row,
                            isSelected: selectedFolderIDs.contains(row.id),
                            onClick: { onSelectFolder(row.id, currentModifiers) },
                            onDoubleClick: { onOpenFolder(row.id) },
                            onContext: { onContextFolders(orderedSelectedFolderIDs(clickedID: row.id)) },
                            contextCapabilities: folderContextCapabilities(orderedSelectedFolderIDs(clickedID: row.id)),
                            onContextAction: { action in
                                onFolderContextAction(orderedSelectedFolderIDs(clickedID: row.id), action)
                            }
                        )
                    )
                    .onDrag {
                        folderProvider(for: selectedFolderIDs.contains(row.id) ? selectedFolderIDs : [row.id])
                    }
                }

                ForEach(summaries) { summary in
                    SummaryListItemRow(
                        summary: summary,
                        isSelected: selectedItemIDs.contains(summary.id),
                        onClick: { onSelectItem(summary.id, currentModifiers) },
                        onDoubleClick: { onPreviewItem(summary.id) },
                        onContext: { onContextItems(orderedSelectedItemIDs(clickedID: summary.id)) },
                        contextCapabilities: itemContextCapabilities(orderedSelectedItemIDs(clickedID: summary.id)),
                        onContextAction: { action in
                            onItemContextAction(orderedSelectedItemIDs(clickedID: summary.id), action)
                        }
                    )
                    .onDrag {
                        itemProvider(for: selectedItemIDs.contains(summary.id) ? selectedItemIDs : [summary.id])
                    }
                }

                if let error {
                    VStack(spacing: 8) {
                        Text(error.message)
                            .font(StudioFont.font(12))
                            .foregroundStyle(StudioColor.secondaryText)
                            .multilineTextAlignment(.center)
                        Button("重试", action: onRetry)
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(24)
                } else if hasMore {
                    ProgressView()
                        .controlSize(.small)
                        .padding(16)
                        .onAppear {
                            guard !loading else { return }
                            onAppend()
                        }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    private var currentModifiers: NSEvent.ModifierFlags {
        NSEvent.modifierFlags.intersection([.command, .shift])
    }

    private func orderedSelectedItemIDs(clickedID: String) -> [String] {
        SummaryListInteractionSupport.orderedIDs(
            clickedID: clickedID,
            selectedIDs: selectedItemIDs,
            visualIDs: summaries.map(\.id)
        )
    }

    private func orderedSelectedFolderIDs(clickedID: String) -> [String] {
        SummaryListInteractionSupport.orderedIDs(
            clickedID: clickedID,
            selectedIDs: selectedFolderIDs,
            visualIDs: folders.map(\.id)
        )
    }

    private func itemProvider(for ids: Set<String>) -> NSItemProvider {
        let payload = PromptItemDragPayload(itemIDs: ids.sorted())
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: PromptItemDragPayload.pasteboardTypeIdentifier,
            visibility: .ownProcess
        ) { completion in
            completion(try? payload.encoded(), nil)
            return nil
        }
        return provider
    }

    private func folderProvider(for ids: Set<String>) -> NSItemProvider {
        let payload = FolderDragPayload(folderIDs: ids.sorted())
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: FolderDragPayload.pasteboardTypeIdentifier,
            visibility: .ownProcess
        ) { completion in
            completion(try? payload.encoded(), nil)
            return nil
        }
        return provider
    }

}

private struct SummaryListItemRow: View {
    let summary: LibraryItemSummary
    let isSelected: Bool
    let onClick: () -> Void
    let onDoubleClick: () -> Void
    let onContext: () -> Void
    let contextCapabilities: [SummaryItemContextCapability]
    let onContextAction: (SummaryItemContextAction) -> Void
    @StateObject private var loader = SharedThumbnailImageLoader()

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let image = loader.image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "doc").foregroundStyle(StudioColor.secondaryText)
                }
            }
            .frame(width: 66, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(summary.title.isEmpty ? "未命名" : summary.title)
                    .font(StudioFont.font(14, weight: .semibold))
                    .lineLimit(1)
                Text("\(summary.modelName) · \(summary.aspectRatio) · \(summary.folderName)")
                    .font(StudioFont.font(12))
                    .foregroundStyle(StudioColor.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(summary.updatedAt.formatted(date: .numeric, time: .shortened))
                .font(StudioFont.font(11))
                .foregroundStyle(StudioColor.tertiaryText)
        }
        .padding(12)
        .studioPanel(radius: 8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? StudioColor.primaryAction.opacity(0.72) : Color.clear, lineWidth: 1.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture(count: 2, perform: onDoubleClick)
        .simultaneousGesture(TapGesture(count: 1).onEnded(onClick))
        .contextMenu {
            SummaryContextSelectionProbe(onAppear: onContext)
            ForEach(contextCapabilities) { capability in
                Button(capability.enabled || capability.reason == nil
                    ? capability.title
                    : "\(capability.title)（\(capability.reason!)）") {
                    onContext()
                    onContextAction(capability.action)
                }
                .disabled(!capability.enabled)
            }
        }
        .task(id: summary.id + summary.thumbnailPath + String(summary.updatedAt.timeIntervalSinceReferenceDate)) {
            guard !summary.thumbnailPath.isEmpty else { return }
            await loader.load(
                ThumbnailImageRequest(
                    path: summary.thumbnailPath,
                    contentVersion: summary.updatedAt.timeIntervalSinceReferenceDate,
                    maxPixelSize: 1_200
                )
            )
        }
    }
}

private struct SummaryListFolderRow: View {
    let row: SummaryFolderRow
    let isSelected: Bool
    let onClick: () -> Void
    let onDoubleClick: () -> Void
    let onContext: () -> Void
    let contextCapabilities: [SummaryFolderContextCapability]
    let onContextAction: (SummaryFolderContextAction) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.system(size: 24))
                .foregroundStyle(StudioColor.primaryAction)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.folder.name)
                    .font(StudioFont.font(14, weight: .semibold))
                Text("\(row.count) 个文件")
                    .font(StudioFont.font(11))
                    .foregroundStyle(StudioColor.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .studioPanel(radius: 8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? StudioColor.primaryAction.opacity(0.72) : Color.clear, lineWidth: 1.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture(count: 2, perform: onDoubleClick)
        .simultaneousGesture(TapGesture(count: 1).onEnded(onClick))
        .contextMenu {
            SummaryContextSelectionProbe(onAppear: onContext)
            ForEach(contextCapabilities) { capability in
                Button(capability.enabled || capability.reason == nil
                    ? capability.title
                    : "\(capability.title)（\(capability.reason!)）") {
                    onContext()
                    onContextAction(capability.action)
                }
                .disabled(!capability.enabled)
            }
        }
    }
}

private struct SummaryContextSelectionProbe: View {
    let onAppear: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear(perform: onAppear)
    }
}
