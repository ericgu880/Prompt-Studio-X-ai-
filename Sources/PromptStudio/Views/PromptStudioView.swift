import SwiftUI
import PromptStudioCore
import AppKit
import UniformTypeIdentifiers

struct PromptStudioView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("promptStudio.sidebarWidth") private var sidebarWidth = 220.0
    @AppStorage("promptStudio.inspectorWidth") private var inspectorWidth = 330.0
    @State private var isFileDropTargeted = false
    @State private var sidebarDragStartWidth: Double?
    @State private var inspectorDragStartWidth: Double?

    var body: some View {
        ZStack(alignment: .bottom) {
            GeometryReader { proxy in
                let layout = constrainedLayout(totalWidth: proxy.size.width)

                HStack(spacing: 0) {
                    SidebarView()
                        .frame(width: layout.sidebar)

                    ResizeHandle {
                        sidebarDragStartWidth = nil
                    } onDragChanged: { translation in
                        if sidebarDragStartWidth == nil {
                            sidebarDragStartWidth = Double(layout.sidebar)
                        }
                        sidebarWidth = clampedSidebarWidth(
                            CGFloat(sidebarDragStartWidth ?? sidebarWidth) + translation,
                            totalWidth: proxy.size.width
                        )
                    }

                    MainContentView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    ResizeHandle {
                        inspectorDragStartWidth = nil
                    } onDragChanged: { translation in
                        if inspectorDragStartWidth == nil {
                            inspectorDragStartWidth = Double(layout.inspector)
                        }
                        inspectorWidth = clampedInspectorWidth(
                            CGFloat(inspectorDragStartWidth ?? inspectorWidth) - translation,
                            totalWidth: proxy.size.width
                        )
                    }

                    InspectorView()
                        .frame(width: layout.inspector)
                }
            }
            .background(StudioColor.appBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isFileDropTargeted ? StudioColor.primaryAction.opacity(0.7) : Color.clear, lineWidth: 2)
                    .padding(10)
                    .allowsHitTesting(false)
            )

            if let toast = state.toast {
                Text(toast)
                    .font(StudioFont.font(13))
                    .foregroundStyle(StudioColor.text)
                    .padding(.horizontal, 16)
                    .frame(height: 38)
                    .background(Capsule().fill(StudioColor.panelRaised))
                    .overlay(Capsule().stroke(StudioColor.hairline, lineWidth: 1))
                    .padding(.bottom, 22)
                    .transition(StudioMotion.toastTransition(reduceMotion: reduceMotion))
            }
        }
        .animation(StudioMotion.standard(reduceMotion: reduceMotion), value: state.toast)
        .background {
            SpacePreviewKeyMonitor {
                state.togglePreview()
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isFileDropTargeted) { providers in
            Task { @MainActor in
                let urls = await loadDroppedFileURLs(from: providers)
                if !urls.isEmpty {
                    state.importFiles(urls)
                }
            }
            return true
        }
        .sheet(item: $state.modal) { modal in
            sheet(for: modal)
        }
    }

    private func constrainedLayout(totalWidth: CGFloat) -> (sidebar: CGFloat, inspector: CGFloat) {
        var sidebar = min(max(CGFloat(sidebarWidth), Self.sidebarMinWidth), Self.sidebarMaxWidth)
        var inspector = min(max(CGFloat(inspectorWidth), Self.inspectorMinWidth), Self.inspectorMaxWidth)
        let availableForSidePanels = max(Self.sidebarMinWidth + Self.inspectorMinWidth, totalWidth - Self.mainMinWidth)

        if sidebar + inspector > availableForSidePanels {
            let overflow = sidebar + inspector - availableForSidePanels
            let inspectorReduction = min(overflow, inspector - Self.inspectorMinWidth)
            inspector -= inspectorReduction
            let remaining = overflow - inspectorReduction
            sidebar -= min(remaining, sidebar - Self.sidebarMinWidth)
        }

        return (sidebar, inspector)
    }

    private func clampedSidebarWidth(_ proposed: CGFloat, totalWidth: CGFloat) -> Double {
        let currentInspector = constrainedLayout(totalWidth: totalWidth).inspector
        let maxByWindow = max(Self.sidebarMinWidth, totalWidth - Self.mainMinWidth - currentInspector)
        let width = min(max(proposed, Self.sidebarMinWidth), min(Self.sidebarMaxWidth, maxByWindow))
        return Double(width)
    }

    private func clampedInspectorWidth(_ proposed: CGFloat, totalWidth: CGFloat) -> Double {
        let currentSidebar = constrainedLayout(totalWidth: totalWidth).sidebar
        let maxByWindow = max(Self.inspectorMinWidth, totalWidth - Self.mainMinWidth - currentSidebar)
        let width = min(max(proposed, Self.inspectorMinWidth), min(Self.inspectorMaxWidth, maxByWindow))
        return Double(width)
    }

    private static let sidebarMinWidth: CGFloat = 176
    private static let sidebarMaxWidth: CGFloat = 360
    private static let inspectorMinWidth: CGFloat = 292
    private static let inspectorMaxWidth: CGFloat = 480
    private static let mainMinWidth: CGFloat = 560

    @ViewBuilder
    private func sheet(for modal: AppState.Modal) -> some View {
        switch modal {
        case .newPrompt:
            NewPromptSheet()
                .environmentObject(state)
        case .editPrompt:
            if let item = state.selectedItem {
                EditPromptSheet(item: item)
                    .environmentObject(state)
            }
        case .importAssets:
            ImportSheet()
                .environmentObject(state)
        case .filters:
            FilterSheet()
                .environmentObject(state)
        case .tagManager:
            TagManagerSheet()
                .environmentObject(state)
        case .versionHistory:
            VersionHistorySheet()
                .environmentObject(state)
        case .references:
            ReferencesSheet()
                .environmentObject(state)
        case .variants:
            VariantSheet()
                .environmentObject(state)
        case .export:
            ExportSheet()
                .environmentObject(state)
        case .settings:
            SettingsSheet()
                .environmentObject(state)
        case .preview:
            PreviewSheet()
                .environmentObject(state)
        case .error(let message):
            ErrorSheet(message: message)
        }
    }
}

private struct ResizeHandle: View {
    let onDragEnded: () -> Void
    let onDragChanged: (CGFloat) -> Void
    @State private var isHovered = false
    @State private var isDragging = false

    var body: some View {
        let active = isHovered || isDragging
        Rectangle()
            .fill(active ? StudioColor.primaryAction.opacity(0.42) : StudioColor.hairline)
            .frame(width: 1)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        onDragChanged(value.translation.width)
                    }
                    .onEnded { _ in
                        isDragging = false
                        onDragEnded()
                    }
            )
    }
}

struct SpacePreviewKeyMonitor: NSViewRepresentable {
    let onSpace: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSpace: onSpace)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onSpace = onSpace
    }

    final class Coordinator {
        var onSpace: () -> Void
        private var monitor: Any?

        init(onSpace: @escaping () -> Void) {
            self.onSpace = onSpace
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let textInputActive = MainActor.assumeIsolated {
                    Self.isTextInputActive
                }
                guard event.keyCode == 49,
                      event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                      !textInputActive else {
                    return event
                }
                self?.onSpace()
                return nil
            }
        }

        @MainActor
        private static var isTextInputActive: Bool {
            guard let responder = NSApp.keyWindow?.firstResponder else { return false }
            if responder is NSTextView || responder is NSTextField {
                return true
            }
            return String(describing: type(of: responder)).contains("FieldEditor")
        }
    }
}

@MainActor
private func clearTextFocus() {
    NSApp.keyWindow?.makeFirstResponder(nil)
}

private func loadDroppedFileURLs(from providers: [NSItemProvider]) async -> [URL] {
    var urls: [URL] = []
    for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        if let data = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
           let url = URL(dataRepresentation: data, relativeTo: nil) {
            urls.append(url)
        }
    }
    return urls
}

private struct SidebarView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settingsHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            windowChrome

            Button {
                state.modal = .newPrompt
            } label: {
                Label("新建 Prompt", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(CapsuleButtonStyle(filled: true))
            .padding(.horizontal, 14)
            .padding(.top, 16)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    sidebarSection("资源库") {
                        SidebarRow(icon: "rectangle.stack", title: "全部", count: allCount, collection: .all)
                        SidebarDisclosure(title: "图片 Prompt", icon: "photo", rows: imageRows, acceptedDropType: .image)
                        SidebarDisclosure(title: "视频 Prompt", icon: "video", rows: videoRows, acceptedDropType: .video)
                    }

                    sidebarSection(nil) {
                        SidebarRow(icon: "star.fill", title: "收藏", count: state.favoriteCount, collection: .favorites, tint: StudioColor.orange)
                        SidebarRow(icon: "trash", title: "回收站", count: state.trashCount, collection: .trash)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 18)
                .padding(.bottom, 28)
            }

            Spacer(minLength: 0)

            Button {
                state.modal = .settings
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "gearshape")
                        .foregroundStyle(StudioColor.secondaryText)
                        .frame(width: 17)
                    Text("设置")
                    Spacer()
                }
                .font(StudioFont.font(13))
                .foregroundStyle(StudioColor.text)
                .frame(height: 42)
                .padding(.horizontal, 10)
                .background(settingsHovered ? StudioColor.panelRaised : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { settingsHovered = $0 }
            .animation(StudioMotion.fast(reduceMotion: reduceMotion), value: settingsHovered)
            .padding(.horizontal, 14)
            .padding(.bottom, 20)
        }
        .background {
            ZStack {
                SidebarGlassBackground()
                StudioColor.sidebar.opacity(0.18)
            }
        }
    }

    private var windowChrome: some View {
        HStack {
            Text("PromptStudio")
                .font(StudioFont.font(15))
                .foregroundStyle(StudioColor.text)
            Spacer()
        }
        .padding(.top, 24)
        .padding(.horizontal, 18)
    }

    private var imageRows: [(String, Int, LibraryCollection)] {
        [
            ("PromptStudio", folderCount("PromptStudio"), .folder("PromptStudio")),
            ("UX Pro Max Skill", folderCount("UX Pro Max Skill"), .folder("UX Pro Max Skill")),
            ("G-Stack 实战方法", folderCount("G-Stack 实战方法"), .folder("G-Stack 实战方法")),
            ("Inshennx/优化合集", folderCount("Inshennx/优化合集"), .folder("Inshennx/优化合集")),
            ("灵感实验室", folderCount("灵感实验室"), .folder("灵感实验室"))
        ]
    }

    private var allCount: Int {
        state.items.filter { !$0.isDeleted }.count
    }

    private var videoRows: [(String, Int, LibraryCollection)] {
        [
            ("PromptStudio-X AI", folderCount("PromptStudio-X AI"), .folder("PromptStudio-X AI")),
            ("完整项目框架开发", folderCount("完整项目框架开发"), .folder("完整项目框架开发")),
            ("讨论跟踪 AIGC 平台", folderCount("讨论跟踪 AIGC 平台"), .folder("讨论跟踪 AIGC 平台")),
            ("视频创作实验室", folderCount("视频创作实验室"), .folder("视频创作实验室"))
        ]
    }

    private var recentItems: [PromptItem] {
        state.items
            .filter { !$0.isDeleted }
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    private func folderCount(_ name: String) -> Int {
        state.items.filter { !$0.isDeleted && $0.folderName == name }.count
    }

    @ViewBuilder
    private func sidebarSection<Content: View>(_ title: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(StudioFont.caption(11))
                    .tracking(1.2)
                    .foregroundStyle(StudioColor.tertiaryText)
            }
            content()
        }
    }
}

private struct SidebarDisclosure: View {
    let title: String
    let icon: String
    let rows: [(String, Int, LibraryCollection)]
    let acceptedDropType: PromptType?
    @EnvironmentObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isOpen = true
    @State private var expansion: CGFloat = 1
    @State private var isHovered = false

    var body: some View {
        let fullHeight = Self.rowsHeight(for: rows.count)
        let rowOpacity = reduceMotion ? expansion : min(1, expansion * 1.2)
        let rowOffset = reduceMotion ? 0 : -6 * (1 - expansion)

        VStack(alignment: .leading, spacing: 6) {
            Button {
                toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon).frame(width: 18)
                    Text(title)
                    Spacer()
                    Image(systemName: "chevron.up")
                        .font(StudioFont.symbol(10))
                        .rotationEffect(.degrees(Double(180 * (1 - expansion))))
                }
                .font(StudioFont.font(14))
                .foregroundStyle(StudioColor.text)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                .background(isHovered ? StudioColor.selection : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .animation(StudioMotion.fast(reduceMotion: reduceMotion), value: isHovered)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows, id: \.0) { row in
                    SidebarRow(
                        icon: "folder",
                        title: row.0,
                        count: row.1,
                        collection: row.2,
                        dropFolderName: row.0,
                        acceptedDropType: acceptedDropType
                    )
                        .padding(.leading, 16)
                }
            }
            .opacity(rowOpacity)
            .offset(y: rowOffset)
            .frame(height: fullHeight * expansion, alignment: .top)
            .clipped()
            .allowsHitTesting(expansion > 0.98)
            .accessibilityHidden(expansion < 0.01)
        }
    }

    private func toggle() {
        isOpen.toggle()
        withAnimation(disclosureAnimation) {
            expansion = isOpen ? 1 : 0
        }
    }

    private static func rowsHeight(for count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count * 34 + max(0, count - 1) * 6)
    }

    private var disclosureAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.08)
            : .interactiveSpring(response: 0.22, dampingFraction: 0.92, blendDuration: 0.04)
    }
}

private struct SidebarRow: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let icon: String
    let title: String
    let count: Int
    let collection: LibraryCollection
    var isActive = false
    var tint: Color = StudioColor.secondaryText
    var dropFolderName: String?
    var acceptedDropType: PromptType?
    @State private var isHovered = false
    @State private var isDropTargeted = false

    var body: some View {
        let active = isActive || state.filter.collection == collection
        Button {
            state.setCollection(collection)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .frame(width: 17)
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Text("\(count)")
                    .foregroundStyle(StudioColor.secondaryText)
            }
            .font(StudioFont.font(13))
            .foregroundStyle(StudioColor.text)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background(rowBackground(active: active))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .leading) {
                if active {
                    Capsule()
                        .fill(StudioColor.primaryAction)
                        .frame(width: 3, height: 18)
                        .offset(x: -8)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isDropTargeted ? StudioColor.primaryAction.opacity(0.76) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .onDrop(of: [UTType.plainText.identifier], isTargeted: $isDropTargeted) { providers in
            guard let dropFolderName, let provider = providers.first else { return false }
            provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let itemID = object as? String else { return }
                Task { @MainActor in
                    state.moveItem(itemID, toFolder: dropFolderName, acceptedType: acceptedDropType)
                }
            }
            return true
        }
        .animation(StudioMotion.fast(reduceMotion: reduceMotion), value: isHovered)
        .animation(StudioMotion.fast(reduceMotion: reduceMotion), value: isDropTargeted)
        .animation(StudioMotion.spring(reduceMotion: reduceMotion), value: active)
    }

    private func rowBackground(active: Bool) -> Color {
        if isDropTargeted {
            return StudioColor.primaryAction.opacity(0.16)
        }
        if active {
            return StudioColor.selection
        }
        return isHovered ? StudioColor.panelRaised : Color.clear
    }
}

private struct RecentRow: View {
    let item: PromptItem
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            ThumbnailImage(path: item.thumbnailPath)
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(item.title)
                .lineLimit(1)
                .font(StudioFont.font(12))
            Spacer()
            Text(item.lastUsedAt.formatted(date: .omitted, time: .shortened))
                .font(StudioFont.font(11))
                .foregroundStyle(StudioColor.secondaryText)
        }
        .foregroundStyle(StudioColor.text)
        .padding(.horizontal, 8)
        .frame(height: 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovered ? StudioColor.panelRaised : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovered = $0 }
        .animation(StudioMotion.fast(reduceMotion: reduceMotion), value: isHovered)
    }
}

private struct MainContentView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            TopToolbarView()
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 14)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    AppKitBridge.zoomKeyWindow()
                }

            ModelTabsView()
                .padding(.horizontal, 24)
                .padding(.bottom, 16)

            Group {
                if state.filteredItems.isEmpty {
                    EmptyStateView()
                } else if state.isListView {
                    PromptListView(items: state.filteredItems)
                } else {
                    MasonryGridView(items: state.filteredItems)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(StudioColor.previewBackground)
            .id(contentStateKey)
            .transition(StudioMotion.contentTransition(reduceMotion: reduceMotion))
        }
        .background(StudioColor.appBackground)
        .animation(StudioMotion.standard(reduceMotion: reduceMotion), value: contentStateKey)
    }

    private var contentStateKey: String {
        if state.filteredItems.isEmpty {
            return "empty-\(state.isListView)"
        }
        return state.isListView ? "list" : "grid"
    }

}

private struct TopToolbarView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchHovered = false

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(StudioColor.secondaryText)
                TextField("全能搜索：名称、提示词、分类、标签、描述", text: Binding(
                    get: { state.filter.query },
                    set: { state.filter.query = $0 }
                ))
                .textFieldStyle(.plain)
                .font(StudioFont.font(14))
                .foregroundStyle(StudioColor.text)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(searchHovered ? StudioColor.panelRaised : StudioColor.panel)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(searchHovered ? StudioColor.primaryAction.opacity(0.32) : StudioColor.hairline, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onHover { searchHovered = $0 }
            .animation(StudioMotion.fast(reduceMotion: reduceMotion), value: searchHovered)

            Button {
                withAnimation(StudioMotion.spring(reduceMotion: reduceMotion)) {
                    state.isListView = false
                }
            } label: {
                Image(systemName: "square.grid.2x2")
            }
            .buttonStyle(CapsuleButtonStyle(accent: !state.isListView))

            Button {
                withAnimation(StudioMotion.spring(reduceMotion: reduceMotion)) {
                    state.isListView = true
                }
            } label: {
                Image(systemName: "list.bullet")
            }
            .buttonStyle(CapsuleButtonStyle(accent: state.isListView))
        }
    }
}

private struct SidebarGlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .sidebar
        nsView.blendingMode = .behindWindow
        nsView.state = .active
        nsView.isEmphasized = false
    }
}

private struct ModelTabsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 8) {
                ForEach(quickModels(for: proxy.size.width)) { model in
                    CompactModelChip(model: model, active: activeModelID == model.id)
                }

                Button {
                    state.modal = .settings
                } label: {
                    Image(systemName: "plus")
                        .font(StudioFont.symbol(15))
                }
                .buttonStyle(IconCircleButtonStyle())
                .foregroundStyle(StudioColor.text)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(height: 32)
    }

    private var activeModelID: String {
        state.filter.modelId ?? "all"
    }

    private func quickModels(for width: CGFloat) -> [ModelProfile] {
        let limit: Int
        if width >= 1120 {
            limit = 8
        } else if width >= 980 {
            limit = 7
        } else if width >= 840 {
            limit = 6
        } else if width >= 700 {
            limit = 5
        } else {
            limit = 4
        }
        return Array(state.models.prefix(limit))
    }
}

private struct CompactModelChip: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: ModelProfile
    let active: Bool
    @State private var isHovered = false

    var body: some View {
        Button {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                state.setModel(model.id)
            }
        } label: {
            Text(model.name)
                .font(StudioFont.font(12))
                .foregroundStyle(active || isHovered ? StudioColor.text : StudioColor.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Capsule().fill(active || isHovered ? StudioColor.selection : Color.clear))
                .overlay(
                    Capsule()
                        .strokeBorder(active ? StudioColor.primaryAction.opacity(0.72) : (isHovered ? StudioColor.hairline : Color.clear), lineWidth: 1)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(StudioMotion.fast(reduceMotion: reduceMotion), value: isHovered)
    }
}

private struct MasonryGridView: View {
    @EnvironmentObject private var state: AppState
    let items: [PromptItem]
    @State private var draggedItemID: String?

    var body: some View {
        GeometryReader { proxy in
            let columnCount = max(2, min(4, Int(proxy.size.width / 250)))
            let width = (proxy.size.width - CGFloat(columnCount - 1) * 12 - 48) / CGFloat(columnCount)
            let layout = makeMasonryLayout(items, columnCount: columnCount, width: width)
            ScrollViewReader { scrollProxy in
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        ForEach(layout.placements) { placement in
                            AssetCardView(
                                item: placement.item,
                                width: width,
                                draggedItemID: $draggedItemID
                            )
                            .offset(x: placement.x, y: placement.y)
                            .zIndex(state.selectedID == placement.item.id ? 1 : 0)
                        }
                    }
                    .id(Self.topAnchorID)
                    .frame(
                        width: max(0, proxy.size.width - 48),
                        height: layout.height,
                        alignment: .topLeading
                    )
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
                .onChange(of: state.filter) { _, _ in
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        scrollProxy.scrollTo(Self.topAnchorID, anchor: .top)
                    }
                }
            }
        }
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    private func makeMasonryLayout(_ items: [PromptItem], columnCount: Int, width: CGFloat) -> MasonryLayoutResult {
        var placements: [MasonryPlacement] = []
        var heights = Array(repeating: CGFloat.zero, count: columnCount)
        for item in items {
            let index = heights.enumerated().min(by: { $0.element < $1.element })?.offset ?? 0
            let height = AssetCardMetrics.totalHeight(for: item, width: width)
            placements.append(
                MasonryPlacement(
                    item: item,
                    x: CGFloat(index) * (width + 12),
                    y: heights[index],
                    height: height
                )
            )
            heights[index] += height + 12
        }
        return MasonryLayoutResult(
            placements: placements,
            height: max(0, (heights.max() ?? 12) - 12)
        )
    }

    private static let topAnchorID = "masonry-grid-top"
}

private struct MasonryLayoutResult {
    let placements: [MasonryPlacement]
    let height: CGFloat
}

private struct MasonryPlacement: Identifiable {
    let item: PromptItem
    let x: CGFloat
    let y: CGFloat
    let height: CGFloat

    var id: String { item.id }
}

private enum AssetCardMetrics {
    static let cardCornerRadius: CGFloat = 12
    static let selectionCornerRadius: CGFloat = 15
    static let selectionOutset: CGFloat = 3

    static func contentWidth(for width: CGFloat) -> CGFloat {
        max(120, width - selectionOutset * 2)
    }

    static func contentHeight(for item: PromptItem, width: CGFloat) -> CGFloat {
        let parts = item.displayAspectRatio.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0 else { return width * 1.25 }
        return max(170, min(430, width * CGFloat(parts[1] / parts[0])))
    }

    static func totalHeight(for item: PromptItem, width: CGFloat) -> CGFloat {
        contentHeight(for: item, width: contentWidth(for: width)) + selectionOutset * 2
    }
}

private struct AssetCardView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let item: PromptItem
    let width: CGFloat
    @Binding var draggedItemID: String?

    private var isSelected: Bool {
        state.selectedID == item.id
    }

    var body: some View {
        let contentWidth = AssetCardMetrics.contentWidth(for: width)
        let contentHeight = AssetCardMetrics.contentHeight(for: item, width: contentWidth)
        ZStack(alignment: .topLeading) {
            ThumbnailImage(path: item.thumbnailPath)
                .frame(width: contentWidth, height: contentHeight)
                .clipped()

            VStack {
                Spacer()
                LinearGradient(
                    colors: [
                        Color.black.opacity(0),
                        Color.black.opacity(isSelected ? 0.78 : 0.58)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: gradientHeight(for: contentHeight))
            }

            Text(item.format)
                .font(StudioFont.caption(11))
                .foregroundStyle(StudioColor.text)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(Capsule().fill(StudioColor.control))
                .padding(12)

            VStack(alignment: .leading, spacing: 8) {
                Spacer()
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.title)
                        .font(StudioFont.font(14))
                        .lineLimit(1)
                    Text("\(item.modelName) · \(item.displayAspectRatio)")
                        .font(StudioFont.font(12))
                        .foregroundStyle(StudioColor.secondaryText)

                    if isSelected {
                        HStack(spacing: 8) {
                            ForEach(item.tags.prefix(3), id: \.self) { tag in
                                Text(tag)
                                    .font(StudioFont.font(11))
                                    .padding(.horizontal, 9)
                                    .frame(height: 24)
                                    .background(Capsule().fill(StudioColor.selection))
                                    .overlay(Capsule().stroke(StudioColor.hairline, lineWidth: 1))
                            }
                        }
                        .transition(StudioMotion.contentTransition(reduceMotion: reduceMotion))
                    }

                    if isSelected {
                        HStack(spacing: 14) {
                            cardAction("pencil") { state.modal = .editPrompt }
                            cardAction("doc.on.doc") { state.copySelectedPrompt() }
                            cardAction(item.favorite ? "star.fill" : "star") { state.toggleFavorite(item) }
                            cardAction("clock") { state.modal = .versionHistory }
                            Spacer()
                            cardAction("ellipsis") { state.modal = .export }
                        }
                        .padding(.top, 2)
                        .transition(StudioMotion.contentTransition(reduceMotion: reduceMotion))
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(StudioColor.text)

        }
        .frame(width: contentWidth, height: contentHeight)
        .clipShape(RoundedRectangle(cornerRadius: AssetCardMetrics.cardCornerRadius, style: .continuous))
        .padding(AssetCardMetrics.selectionOutset)
        .overlay(
            RoundedRectangle(cornerRadius: AssetCardMetrics.selectionCornerRadius, style: .continuous)
                .strokeBorder(isSelected ? StudioColor.primaryAction.opacity(0.88) : Color.clear, lineWidth: isSelected ? 2 : 0)
        )
        .frame(width: width, height: contentHeight + AssetCardMetrics.selectionOutset * 2)
        .contentShape(RoundedRectangle(cornerRadius: AssetCardMetrics.selectionCornerRadius, style: .continuous))
        .highPriorityGesture(cardSelectionGesture)
        .simultaneousGesture(cardPreviewGesture)
        .onDrag {
            draggedItemID = item.id
            return NSItemProvider(object: item.id as NSString)
        } preview: {
            dragPreview
        }
        .onDrop(
            of: [UTType.plainText.identifier],
            delegate: AssetCardDropDelegate(
                targetItemID: item.id,
                draggedItemID: $draggedItemID,
                state: state
            )
        )
        .opacity(draggedItemID == item.id ? 0.72 : 1)
        .animation(StudioMotion.fast(reduceMotion: reduceMotion), value: draggedItemID)
    }

    private var cardSelectionGesture: some Gesture {
        TapGesture(count: 1)
            .onEnded {
                selectImmediately()
            }
    }

    private var cardPreviewGesture: some Gesture {
        TapGesture(count: 2)
            .onEnded {
                selectImmediately()
                state.previewSelected()
            }
    }

    private func selectImmediately() {
        clearTextFocus()
        state.select(item)
    }

    private var dragPreview: some View {
        ThumbnailImage(path: item.thumbnailPath)
            .frame(width: 120, height: 90)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: AssetCardMetrics.cardCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AssetCardMetrics.cardCornerRadius, style: .continuous)
                    .stroke(StudioColor.primaryAction.opacity(0.7), lineWidth: 1)
            )
            .offset(x: 60, y: 45)
    }

    private func cardAction(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(StudioFont.symbol(14))
        }
        .buttonStyle(IconCircleButtonStyle())
    }

    private func gradientHeight(for cardHeight: CGFloat) -> CGFloat {
        let selectedHeight = min(210, max(132, cardHeight * 0.54))
        let normalHeight = min(128, max(86, cardHeight * 0.36))
        return isSelected ? selectedHeight : normalHeight
    }
}

private struct AssetCardDropDelegate: DropDelegate {
    let targetItemID: String
    @Binding var draggedItemID: String?
    let state: AppState

    func validateDrop(info: DropInfo) -> Bool {
        draggedItemID != nil && draggedItemID != targetItemID
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { draggedItemID = nil }
        guard let draggedItemID, draggedItemID != targetItemID else { return false }
        state.moveFilteredItem(draggedID: draggedItemID, before: targetItemID)
        return true
    }
}

private struct PromptListView: View {
    @EnvironmentObject private var state: AppState
    let items: [PromptItem]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(items) { item in
                    HStack(spacing: 12) {
                        ThumbnailImage(path: item.thumbnailPath)
                            .frame(width: 66, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(StudioFont.font(14))
                            Text("\(item.modelName) · \(item.displayAspectRatio) · \(item.tags.joined(separator: " / "))")
                                .font(StudioFont.font(12))
                                .foregroundStyle(StudioColor.secondaryText)
                        }
                        Spacer()
                        Text(item.updatedAt.formatted(date: .numeric, time: .shortened))
                            .font(StudioFont.font(12))
                            .foregroundStyle(StudioColor.tertiaryText)
                    }
                    .padding(12)
                    .studioPanel(radius: 8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(state.selectedID == item.id ? StudioColor.primaryAction.opacity(0.72) : Color.clear, lineWidth: 1.5)
                    )
                    .onTapGesture {
                        clearTextFocus()
                        state.select(item)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }
}

private struct EmptyStateView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(StudioFont.symbol(44))
                .foregroundStyle(StudioColor.secondaryText)
            Text("没有找到素材")
                .font(StudioFont.font(24))
            Text("调整搜索或导入图片、视频、Prompt 文本。")
                .foregroundStyle(StudioColor.secondaryText)
            Button("导入素材") {
                state.modal = .importAssets
            }
            .buttonStyle(CapsuleButtonStyle(filled: true))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(StudioColor.text)
    }
}

struct ThumbnailImage: View {
    let path: String
    @StateObject private var loader = CachedImageLoader()

    var body: some View {
        Group {
            if let image = loader.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    StudioColor.panelRaised
                    Image(systemName: "photo")
                        .font(StudioFont.symbol(24))
                        .foregroundStyle(StudioColor.secondaryText)
                }
            }
        }
        .task(id: path) {
            await loader.load(path)
        }
    }
}

@MainActor
private final class CachedImageLoader: ObservableObject {
    @Published var image: NSImage?

    private static let cache = NSCache<NSString, NSImage>()
    private var path: String = ""
    private var task: Task<Void, Never>?

    func load(_ path: String) async {
        task?.cancel()
        self.path = path
        guard !path.isEmpty else {
            image = nil
            return
        }

        if let cached = Self.cache.object(forKey: path as NSString) {
            image = cached
            return
        }

        image = nil
        task = Task {
            let loaded = await Self.loadImage(at: path)
            guard !Task.isCancelled, self.path == path else { return }
            if let loaded {
                Self.cache.setObject(loaded, forKey: path as NSString)
            }
            image = loaded
        }
    }

    private nonisolated static func loadImage(at path: String) async -> NSImage? {
        await Task.detached(priority: .utility) {
            NSImage(contentsOfFile: path)
        }.value
    }
}
