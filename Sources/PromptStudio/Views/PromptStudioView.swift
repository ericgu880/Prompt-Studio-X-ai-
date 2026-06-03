import SwiftUI
import PromptStudioCore
import AppKit
import UniformTypeIdentifiers

struct PromptStudioView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("promptStudio.sidebarWidth") private var sidebarWidth = 220.0
    @AppStorage("promptStudio.inspectorWidth") private var inspectorWidth = 330.0
    @AppStorage("promptStudio.sidebarVisible") private var isSidebarVisible = true
    @State private var sidebarDragStartWidth: Double?
    @State private var inspectorDragStartWidth: Double?
    @State private var liveSidebarWidth: Double?
    @State private var liveInspectorWidth: Double?
    @State private var isSplitResizing = false

    var body: some View {
        ZStack(alignment: .bottom) {
            GeometryReader { proxy in
                let layout = constrainedLayout(totalWidth: proxy.size.width)

                ZStack(alignment: .topLeading) {
                    HStack(spacing: 0) {
                        if isSidebarVisible {
                            SidebarView()
                                .frame(width: layout.sidebar)
                                .transition(sidebarTransition)
                        }

                        MainContentView(isSidebarVisible: $isSidebarVisible, isSplitResizing: isSplitResizing)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        InspectorView()
                            .frame(width: layout.inspector)
                    }
                    .ignoresSafeArea(.container, edges: .top)
                    .animation(StudioMotion.standard(reduceMotion: reduceMotion), value: isSidebarVisible)

                    TopWindowControlsRow(
                        isSidebarVisible: $isSidebarVisible,
                        sidebarWidth: isSidebarVisible ? layout.sidebar : CGFloat(sidebarWidth),
                        inspectorWidth: layout.inspector,
                        totalWidth: proxy.size.width
                    )
                    .frame(width: proxy.size.width, height: 38, alignment: .topLeading)
                    .ignoresSafeArea(.container, edges: .top)
                    .zIndex(20)

                    if isSidebarVisible {
                        SplitResizeHotZone {
                            if let liveSidebarWidth {
                                sidebarWidth = liveSidebarWidth
                            }
                            liveSidebarWidth = nil
                            sidebarDragStartWidth = nil
                            isSplitResizing = false
                        } onDragChanged: { translation in
                            isSplitResizing = true
                            if sidebarDragStartWidth == nil {
                                sidebarDragStartWidth = Double(layout.sidebar)
                            }
                            let nextWidth = clampedSidebarWidth(
                                CGFloat(sidebarDragStartWidth ?? sidebarWidth) + translation,
                                totalWidth: proxy.size.width
                            )
                            if liveSidebarWidth != nextWidth {
                                liveSidebarWidth = nextWidth
                            }
                        }
                        .frame(width: Self.resizeHotZoneWidth, height: proxy.size.height + Self.resizeHotZoneVerticalBleed * 2)
                        .position(x: layout.sidebar, y: proxy.size.height / 2)
                        .ignoresSafeArea(.container, edges: .vertical)
                    }

                    SplitResizeHotZone {
                        if let liveInspectorWidth {
                            inspectorWidth = liveInspectorWidth
                        }
                        liveInspectorWidth = nil
                        inspectorDragStartWidth = nil
                        isSplitResizing = false
                    } onDragChanged: { translation in
                        isSplitResizing = true
                        if inspectorDragStartWidth == nil {
                            inspectorDragStartWidth = Double(layout.inspector)
                        }
                        let nextWidth = clampedInspectorWidth(
                            CGFloat(inspectorDragStartWidth ?? inspectorWidth) - translation,
                            totalWidth: proxy.size.width
                        )
                        if liveInspectorWidth != nextWidth {
                            liveInspectorWidth = nextWidth
                        }
                    }
                    .frame(width: Self.resizeHotZoneWidth, height: proxy.size.height + Self.resizeHotZoneVerticalBleed * 2)
                    .position(x: proxy.size.width - layout.inspector, y: proxy.size.height / 2)
                    .ignoresSafeArea(.container, edges: .vertical)

                }
            }
            .background(StudioColor.appBackground)

            if state.isPreviewPresented, let item = state.selectedItem {
                ImmersivePreviewOverlay(item: item)
                    .environmentObject(state)
                    .zIndex(80)
            }

            if let item = state.markdownEditorItem {
                MarkdownEditorOverlay(item: item)
                    .environmentObject(state)
                    .zIndex(88)
            }

            if let mode = state.promptComposerMode {
                PromptComposerOverlay(mode: mode)
                    .environmentObject(state)
                    .zIndex(90)
            }

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
        .sheet(item: $state.modal) { modal in
            sheet(for: modal)
        }
    }

    private func constrainedLayout(totalWidth: CGFloat) -> (sidebar: CGFloat, inspector: CGFloat) {
        let minimumSidebarWidth = isSidebarVisible ? Self.sidebarMinWidth : 0
        var sidebar = isSidebarVisible
            ? min(max(CGFloat(liveSidebarWidth ?? sidebarWidth), Self.sidebarMinWidth), Self.sidebarMaxWidth)
            : 0
        var inspector = min(max(CGFloat(liveInspectorWidth ?? inspectorWidth), Self.inspectorMinWidth), Self.inspectorMaxWidth)
        let availableForSidePanels = max(minimumSidebarWidth + Self.inspectorMinWidth, totalWidth - Self.mainMinWidth)

        if sidebar + inspector > availableForSidePanels {
            let overflow = sidebar + inspector - availableForSidePanels
            let inspectorReduction = min(overflow, inspector - Self.inspectorMinWidth)
            inspector -= inspectorReduction
            let remaining = overflow - inspectorReduction
            sidebar -= min(remaining, max(0, sidebar - minimumSidebarWidth))
        }

        return (sidebar, inspector)
    }

    private func clampedSidebarWidth(_ proposed: CGFloat, totalWidth: CGFloat) -> Double {
        let currentInspector = constrainedLayout(totalWidth: totalWidth).inspector
        let maxByWindow = max(Self.sidebarMinWidth, totalWidth - Self.mainMinWidth - currentInspector)
        let width = min(max(proposed, Self.sidebarMinWidth), min(Self.sidebarMaxWidth, maxByWindow))
        return Double(width.rounded(.toNearestOrAwayFromZero))
    }

    private func clampedInspectorWidth(_ proposed: CGFloat, totalWidth: CGFloat) -> Double {
        let currentSidebar = constrainedLayout(totalWidth: totalWidth).sidebar
        let maxByWindow = max(Self.inspectorMinWidth, totalWidth - Self.mainMinWidth - currentSidebar)
        let width = min(max(proposed, Self.inspectorMinWidth), min(Self.inspectorMaxWidth, maxByWindow))
        return Double(width.rounded(.toNearestOrAwayFromZero))
    }

    private static let sidebarMinWidth: CGFloat = 176
    private static let sidebarMaxWidth: CGFloat = 360
    private static let inspectorMinWidth: CGFloat = 292
    private static let inspectorMaxWidth: CGFloat = 480
    private static let mainMinWidth: CGFloat = 560
    private static let resizeHotZoneWidth: CGFloat = 16
    private static let resizeHotZoneVerticalBleed: CGFloat = 80

    private var sidebarTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity)
    }

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
        case .modelFilterManager:
            ModelFilterManagerSheet()
                .environmentObject(state)
        case .folderEditor(let request):
            FolderEditorSheet(request: request)
                .environmentObject(state)
        case .folderDeleteConfirmation(let request):
            FolderDeleteConfirmationSheet(request: request)
                .environmentObject(state)
        case .preview:
            PreviewSheet()
                .environmentObject(state)
        case .error(let message):
            ErrorSheet(message: message)
        }
    }
}

private struct SplitResizeHotZone: View {
    let onDragEnded: () -> Void
    let onDragChanged: (CGFloat) -> Void
    @State private var isHovered = false
    @State private var isDragging = false
    @State private var cursorIsPushed = false

    var body: some View {
        let active = isHovered || isDragging
        ZStack {
            Color.clear

            Rectangle()
                .fill(active ? StudioColor.text.opacity(isDragging ? 0.16 : 0.11) : StudioColor.hairline.opacity(0.22))
                .frame(width: 1)
        }
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
                if hovering {
                    pushResizeCursorIfNeeded()
                } else if !isDragging {
                    popResizeCursorIfNeeded()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        pushResizeCursorIfNeeded()
                        onDragChanged(value.translation.width)
                    }
                    .onEnded { _ in
                        isDragging = false
                        if !isHovered {
                            popResizeCursorIfNeeded()
                        }
                        onDragEnded()
                    }
            )
            .onDisappear {
                popResizeCursorIfNeeded()
            }
    }

    private func pushResizeCursorIfNeeded() {
        guard !cursorIsPushed else { return }
        NSCursor.resizeLeftRight.push()
        cursorIsPushed = true
    }

    private func popResizeCursorIfNeeded() {
        guard cursorIsPushed else { return }
        NSCursor.pop()
        cursorIsPushed = false
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
    guard let window = NSApp.keyWindow else { return }
    window.endEditing(for: nil)
    if let contentView = window.contentView {
        window.makeFirstResponder(contentView)
    } else {
        window.makeFirstResponder(nil)
    }
}

private struct SidebarCollapseControl: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var isSidebarVisible: Bool

    var body: some View {
        TitlebarControlButton(
            systemImage: "sidebar.left",
            isActive: isSidebarVisible,
            showsBackground: false,
            accessibilityLabel: isSidebarVisible ? "隐藏侧边栏" : "显示侧边栏"
        ) {
            withAnimation(StudioMotion.standard(reduceMotion: reduceMotion)) {
                isSidebarVisible.toggle()
            }
        }
    }
}

private struct TopWindowControlsRow: View {
    @Binding var isSidebarVisible: Bool
    let sidebarWidth: CGFloat
    let inspectorWidth: CGFloat
    let totalWidth: CGFloat

    private let topInset: CGFloat = 8
    private let edgeInset: CGFloat = 14
    private let mainInset: CGFloat = 24
    private let scaleControlWidth: CGFloat = 196

    var body: some View {
        ZStack(alignment: .topLeading) {
            SidebarCollapseControl(isSidebarVisible: $isSidebarVisible)
                .padding(.top, topInset)
                .padding(.leading, sidebarCollapseLeading)

            TitlebarNavigationControls()
                .padding(.top, topInset)
                .padding(.leading, mainLeading)

            ThumbnailScaleControl()
                .frame(width: scaleControlWidth, alignment: .trailing)
                .padding(.top, topInset)
                .padding(.leading, scaleLeading)
        }
        .allowsHitTesting(true)
    }

    private var sidebarCollapseLeading: CGFloat {
        return max(edgeInset, sidebarWidth - edgeInset - 26)
    }

    private var mainLeading: CGFloat {
        sidebarWidth + mainInset
    }

    private var scaleLeading: CGFloat {
        max(mainLeading + 140, totalWidth - inspectorWidth - mainInset - scaleControlWidth)
    }
}

private struct TitlebarNavigationControls: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 5) {
            TitlebarControlButton(
                systemImage: "arrow.left",
                isEnabled: state.canNavigateBack,
                accessibilityLabel: "后退"
            ) {
                state.navigateBack()
            }

            TitlebarControlButton(
                systemImage: "arrow.right",
                isEnabled: state.canNavigateForward,
                accessibilityLabel: "前进"
            ) {
                state.navigateForward()
            }
        }
    }
}

private struct TitlebarControlButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let systemImage: String
    var isEnabled = true
    var isActive = false
    var showsBackground = true
    let accessibilityLabel: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(StudioFont.symbol(12))
                .frame(width: 26, height: 26)
                .foregroundStyle(foregroundColor)
                .background(backgroundShape)
                .clipShape(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityLabel)
        .onHover { hovering in
            guard isEnabled else { return }
            isHovered = hovering
        }
        .animation(StudioMotion.fast(reduceMotion: reduceMotion), value: isHovered)
        .animation(StudioMotion.fast(reduceMotion: reduceMotion), value: isActive)
    }

    private var foregroundColor: Color {
        if !isEnabled {
            return StudioColor.tertiaryText.opacity(0.42)
        }
        return isActive || isHovered ? StudioColor.text : StudioColor.secondaryText
    }

    private var backgroundShape: some View {
        Circle()
            .fill(showsBackground && (isActive || isHovered) ? StudioColor.selection.opacity(0.92) : Color.clear)
            .overlay(
                Circle()
                    .stroke(showsBackground && isHovered ? StudioColor.hairline : Color.clear, lineWidth: 1)
            )
    }
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
    @State private var sidebarScrollHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            windowChrome

            Button {
                state.openNewPromptComposer()
            } label: {
                Label("新建 Prompt", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(CapsuleButtonStyle(filled: true))
            .padding(.horizontal, 14)
            .padding(.top, 24)

            SidebarHoverScrollView(isHovering: sidebarScrollHovered) {
                VStack(alignment: .leading, spacing: 14) {
                    sidebarSection(nil) {
                        VStack(alignment: .leading, spacing: 4) {
                            SidebarRow(icon: "rectangle.stack", title: "全部", count: allCount, collection: .all)
                            SidebarRow(icon: "clock", title: "最近使用", count: state.recentCount, collection: .recent)
                            SidebarRow(icon: "trash", title: "回收站", count: state.trashCount, collection: .trash)
                        }
                        Text("文件夹")
                            .font(StudioFont.caption(11))
                            .tracking(1.2)
                            .foregroundStyle(StudioColor.sectionTitleText)
                            .padding(.leading, 10)
                            .padding(.top, 8)
                            .padding(.bottom, -4)
                        FolderTreeView()
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 28)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
            .contentShape(Rectangle())
            .onHover { sidebarScrollHovered = $0 }
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    sidebarScrollHovered = true
                case .ended:
                    sidebarScrollHovered = false
                }
            }

            Button {
                state.modal = .settings
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape")
                        .foregroundStyle(StudioColor.secondaryText)
                        .frame(width: 17)
                    Text("设置")
                    Spacer()
                }
                .font(StudioFont.font(14))
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
                    .ignoresSafeArea(.container, edges: .top)
                StudioColor.sidebar.opacity(0.30)
                    .ignoresSafeArea(.container, edges: .top)
            }
        }
    }

    private var windowChrome: some View {
        HStack {
            Text("PromptStudio")
                .font(StudioFont.font(16, weight: .semibold))
                .foregroundStyle(StudioColor.text)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
            Spacer()
        }
        .padding(.top, StudioLayout.contentTopPadding)
        .padding(.horizontal, 18)
    }

    private var allCount: Int {
        state.items.filter { !$0.isDeleted }.count
    }

    @ViewBuilder
    private func sidebarSection<Content: View>(_ title: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(StudioFont.caption(11))
                    .tracking(1.2)
                    .foregroundStyle(StudioColor.sectionTitleText)
            }
            content()
        }
    }
}

private struct SidebarHoverScrollView<Content: View>: View {
    let isHovering: Bool
    @ViewBuilder let content: () -> Content
    @State private var internalHovering = false
    @State private var scrollOffset: CGFloat = 0
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        GeometryReader { outerProxy in
            ZStack(alignment: .topTrailing) {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        GeometryReader { offsetProxy in
                            Color.clear.preference(
                                key: SidebarScrollOffsetPreferenceKey.self,
                                value: offsetProxy.frame(in: .named("sidebarFolderScroll")).minY
                            )
                        }
                        .frame(height: 0)

                        content()
                            .background(
                                GeometryReader { contentProxy in
                                    Color.clear.preference(
                                        key: SidebarContentHeightPreferenceKey.self,
                                        value: contentProxy.size.height
                                    )
                                }
                            )
                    }
                }
                .coordinateSpace(name: "sidebarFolderScroll")
                .onPreferenceChange(SidebarScrollOffsetPreferenceKey.self) { scrollOffset = $0 }
                .onPreferenceChange(SidebarContentHeightPreferenceKey.self) { contentHeight = $0 }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if shouldShowScrollbar(viewportHeight: outerProxy.size.height) {
                    Capsule()
                        .fill(Color.white.opacity(0.40))
                        .frame(width: 2, height: scrollbarHeight(viewportHeight: outerProxy.size.height))
                        .offset(y: scrollbarOffset(viewportHeight: outerProxy.size.height))
                        .padding(.trailing, 12)
                        .zIndex(10)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.clear)
            .contentShape(Rectangle())
            .onHover { internalHovering = $0 }
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    internalHovering = true
                case .ended:
                    internalHovering = false
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .contentShape(Rectangle())
        .onHover { internalHovering = $0 }
        .onContinuousHover { phase in
            switch phase {
            case .active:
                internalHovering = true
            case .ended:
                internalHovering = false
            }
        }
    }

    private func isScrollable(viewportHeight: CGFloat) -> Bool {
        contentHeight > viewportHeight * 0.98
    }

    private func shouldShowScrollbar(viewportHeight: CGFloat) -> Bool {
        isScrollable(viewportHeight: viewportHeight)
    }

    private func scrollbarHeight(viewportHeight: CGFloat) -> CGFloat {
        guard contentHeight > 0 else { return 0 }
        return max(34, viewportHeight * min(1, viewportHeight / contentHeight))
    }

    private func scrollbarOffset(viewportHeight: CGFloat) -> CGFloat {
        let maxScroll = max(1, contentHeight - viewportHeight)
        let progress = min(max(-scrollOffset / maxScroll, 0), 1)
        return progress * max(0, viewportHeight - scrollbarHeight(viewportHeight: viewportHeight))
    }
}

private struct SidebarScrollOffsetPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct SidebarContentHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct FolderTreeView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(state.folderTreeRows()) { row in
                FolderTreeRowView(row: row)
            }
        }
    }
}

private struct FolderTreeRowView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let row: AppState.FolderTreeRow
    @State private var isHovered = false
    @State private var isDisclosureHovered = false
    @State private var isDropTargeted = false
    @State private var isEditingName = false
    @State private var draftName = ""
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        let active = state.filter.collection == row.collection
        HStack(spacing: 0) {
            treeIndent

            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(StudioColor.text)
                    .frame(width: 17)

                if isEditingName {
                    TextField("", text: $draftName)
                        .textFieldStyle(.plain)
                        .focused($nameFieldFocused)
                        .font(StudioFont.font(14))
                        .foregroundStyle(StudioColor.text)
                        .submitLabel(.done)
                        .onSubmit(commitInlineRename)
                        .onExitCommand(perform: cancelInlineRename)
                        .onChange(of: nameFieldFocused) { _, focused in
                            if !focused {
                                commitInlineRename()
                            }
                        }
                } else {
                    Text(row.folder.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 16)

                if !isEditingName {
                    Text("\(row.count)")
                        .foregroundStyle(StudioColor.secondaryText)
                }
            }
            .font(StudioFont.font(14))
            .foregroundStyle(StudioColor.text)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .background(rowBackground(active: active))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .leading) {
                disclosureButton
                    .offset(x: -14)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isDropTargeted ? StudioColor.primaryAction.opacity(0.76) : Color.clear, lineWidth: 1)
            )
            .onTapGesture {
                guard !isEditingName else { return }
                state.selectFolder(row.folder)
            }
            .simultaneousGesture(
                TapGesture(count: 2)
                    .onEnded {
                        guard row.hasChildren, !isEditingName else { return }
                        state.toggleFolderExpansion(row.folder.id)
                    }
            )
        }
        .onHover { isHovered = $0 }
        .onDrop(of: [UTType.plainText.identifier, UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
            if providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
                Task { @MainActor in
                    let urls = await loadDroppedFileURLs(from: providers)
                    if !urls.isEmpty {
                        state.importFiles(urls, targetFolderID: row.folder.id)
                    }
                }
                return true
            }

            guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
            provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let itemID = object as? String else { return }
                Task { @MainActor in
                    state.moveItem(itemID, toFolderID: row.folder.id)
                }
            }
            return true
        }
        .contextMenu {
            folderContextMenu(row.folder)
        }
        .onAppear(perform: startInlineRenameIfRequested)
        .onChange(of: state.inlineRenamingFolderID) { _, _ in
            startInlineRenameIfRequested()
        }
        .animation(StudioMotion.fast(reduceMotion: reduceMotion), value: isHovered)
        .animation(StudioMotion.fast(reduceMotion: reduceMotion), value: isDisclosureHovered)
        .animation(StudioMotion.fast(reduceMotion: reduceMotion), value: isDropTargeted)
        .animation(StudioMotion.spring(reduceMotion: reduceMotion), value: active)
    }

    private var treeIndent: some View {
        HStack(spacing: 0) {
            ForEach(0..<row.level, id: \.self) { _ in
                Color.clear
                    .frame(width: 18)
            }
        }
        .frame(height: 32)
    }

    @ViewBuilder
    private var disclosureButton: some View {
        if row.hasChildren {
            Button {
                state.toggleFolderExpansion(row.folder.id)
            } label: {
                Image(systemName: "play.fill")
                    .font(StudioFont.symbol(7, weight: .semibold))
                    .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                    .frame(width: 18, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(isDisclosureHovered ? StudioColor.text.opacity(0.86) : StudioColor.sectionTitleText)
            .onHover { isDisclosureHovered = $0 }
            .animation(StudioMotion.spring(reduceMotion: reduceMotion), value: row.isExpanded)
        } else {
            Color.clear.frame(width: 18, height: 24)
        }
    }

    private func startInlineRename() {
        state.selectFolder(row.folder)
        draftName = row.folder.name
        isEditingName = true
        DispatchQueue.main.async {
            nameFieldFocused = true
        }
    }

    private func startInlineRenameIfRequested() {
        guard state.inlineRenamingFolderID == row.folder.id else { return }
        startInlineRename()
        state.inlineRenamingFolderID = nil
    }

    private func commitInlineRename() {
        guard isEditingName else { return }
        let trimmedName = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        isEditingName = false
        nameFieldFocused = false
        guard !trimmedName.isEmpty, trimmedName != row.folder.name else { return }
        state.renameFolder(id: row.folder.id, name: trimmedName)
    }

    private func cancelInlineRename() {
        guard isEditingName else { return }
        isEditingName = false
        nameFieldFocused = false
        draftName = row.folder.name
    }

    @ViewBuilder
    private func folderContextMenu(_ folder: LibraryFolder) -> some View {
        Button {
            state.selectFolder(folder)
        } label: {
            Label("打开文件夹", systemImage: "folder")
        }

        Button {
            state.beginCreateSiblingFolder(folder)
        } label: {
            Label("新增文件夹", systemImage: "folder.badge.plus")
        }

        Button {
            state.beginCreateChildFolder(folder)
        } label: {
            Label("新增子文件夹", systemImage: "folder.badge.plus")
        }

        Button {
            startInlineRename()
        } label: {
            Label("重命名", systemImage: "pencil")
        }

        Divider()

        Button {
            state.importFiles(to: folder)
        } label: {
            Label("导入到此文件夹", systemImage: "square.and.arrow.down")
        }

        Button {
            state.exportFolder(folder.id)
        } label: {
            Label("导出文件夹...", systemImage: "square.and.arrow.up")
        }

        Divider()

        Button(role: .destructive) {
            state.beginDeleteFolder(folder)
        } label: {
            Label("删除文件夹", systemImage: "trash")
        }
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

private struct SidebarDisclosure: View {
    let title: String
    let icon: String
    let rows: [AppState.FolderRow]
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
                ForEach(rows) { row in
                    SidebarRow(
                        icon: "folder",
                        title: row.folder.name,
                        count: row.count,
                        collection: row.collection,
                        tint: StudioColor.text,
                        folder: row.folder,
                        dropFolderName: row.folder.name,
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
    var folder: LibraryFolder?
    var dropFolderName: String?
    var acceptedDropType: PromptType?
    @State private var isHovered = false
    @State private var isDropTargeted = false

    var body: some View {
        let active = isActive || state.filter.collection == collection
        Button {
            state.setCollection(collection)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .frame(width: 17)
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 16)
                Text("\(count)")
                    .foregroundStyle(StudioColor.secondaryText)
            }
            .font(StudioFont.font(14))
            .foregroundStyle(StudioColor.text)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .background(rowBackground(active: active))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
        .contextMenu {
            if collection == .trash {
                Button {
                    state.restoreAllTrashItems()
                } label: {
                    Label("还原全部项目", systemImage: "arrow.uturn.backward")
                }
                .disabled(state.trashCount == 0)

                Button(role: .destructive) {
                    state.emptyTrash()
                } label: {
                    Label("清空回收站", systemImage: "trash")
                }
                .disabled(state.trashCount == 0)
            } else if let folder {
                folderContextMenu(folder)
            }
        }
        .animation(StudioMotion.fast(reduceMotion: reduceMotion), value: isHovered)
        .animation(StudioMotion.fast(reduceMotion: reduceMotion), value: isDropTargeted)
        .animation(StudioMotion.spring(reduceMotion: reduceMotion), value: active)
    }

    @ViewBuilder
    private func folderContextMenu(_ folder: LibraryFolder) -> some View {
        Button {
            state.selectFolder(folder)
        } label: {
            Label("打开文件夹", systemImage: "folder")
        }

        Button {
            state.beginCreateFolder(type: folder.type ?? .image)
        } label: {
            Label("新增文件夹", systemImage: "folder.badge.plus")
        }

        Button {
            state.beginRenameFolder(folder)
        } label: {
            Label("重命名", systemImage: "pencil")
        }

        Divider()

        Button {
            state.importFiles(to: folder)
        } label: {
            Label("导入到此文件夹", systemImage: "square.and.arrow.down")
        }

        Button {
            state.exportFolder(folder.id)
        } label: {
            Label("导出文件夹...", systemImage: "square.and.arrow.up")
        }

        Divider()

        Button(role: .destructive) {
            state.beginDeleteFolder(folder)
        } label: {
            Label("删除文件夹", systemImage: "trash")
        }
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
            AssetMediaView(item: item)
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(item.title)
                .lineLimit(1)
                .font(StudioFont.font(14))
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
    @Binding var isSidebarVisible: Bool
    let isSplitResizing: Bool
    @State private var isFileDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            TopToolbarView()
                .padding(.horizontal, 24)
                .padding(.top, StudioLayout.contentTopPadding)
                .padding(.bottom, 8)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    AppKitBridge.zoomKeyWindow()
                }

            ModelTabsView()
                .padding(.horizontal, 24)
                .padding(.bottom, 12)

            Group {
                if state.filteredItems.isEmpty {
                    EmptyStateView()
                } else if state.isListView {
                    PromptListView(items: state.filteredItems)
                } else {
                    MasonryGridView(items: state.filteredItems, isSplitResizing: isSplitResizing)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(StudioColor.previewBackground)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded {
                clearTextFocus()
            })
            .id(contentStateKey)
            .transition(StudioMotion.contentTransition(reduceMotion: reduceMotion))
        }
        .background(StudioColor.previewBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isFileDropTargeted ? StudioColor.primaryAction.opacity(0.7) : Color.clear, lineWidth: 2)
                .padding(10)
                .allowsHitTesting(false)
        )
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isFileDropTargeted) { providers in
            Task { @MainActor in
                let urls = await loadDroppedFileURLs(from: providers)
                if !urls.isEmpty {
                    state.importFiles(urls)
                }
            }
            return true
        }
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
    @State private var searchFocused = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(StudioColor.secondaryText)
            SearchInputField(text: Binding(
                get: { state.filter.query },
                set: { state.filter.query = $0 }
            ), placeholder: "全能搜索：名称、提示词、分类、标签、描述", isFocused: $searchFocused)
            .frame(height: 22)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .background(searchHovered || searchFocused ? StudioColor.panelRaised : StudioColor.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(searchHovered || searchFocused ? StudioColor.primaryAction.opacity(0.32) : StudioColor.hairline, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { searchHovered = $0 }
        .animation(StudioMotion.fast(reduceMotion: reduceMotion), value: searchHovered)
        .animation(StudioMotion.fast(reduceMotion: reduceMotion), value: searchFocused)
    }
}

private struct SearchInputField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    @Binding var isFocused: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField()
        textField.delegate = context.coordinator
        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.textColor = NSColor.white
        textField.font = NSFont(name: "PingFangSC-Regular", size: 14) ?? .systemFont(ofSize: 14)
        textField.lineBreakMode = .byTruncatingTail
        textField.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.34),
                .font: textField.font as Any
            ]
        )
        textField.stringValue = text
        return textField
    }

    func updateNSView(_ textField: NSTextField, context: Context) {
        context.coordinator.parent = self
        if textField.stringValue != text {
            textField.stringValue = text
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchInputField

        init(_ parent: SearchInputField) {
            self.parent = parent
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.isFocused = true
            setWhiteInsertionPoint(for: notification.object)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.isFocused = false
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            parent.text = textField.stringValue
            setWhiteInsertionPoint(for: textField)
        }

        private func setWhiteInsertionPoint(for object: Any?) {
            guard let textField = object as? NSTextField,
                  let editor = textField.window?.fieldEditor(true, for: textField) as? NSTextView else { return }
            editor.insertionPointColor = NSColor.white
        }
    }
}

private struct ThumbnailScaleControl: View {
    @AppStorage("promptStudio.thumbnailScale") private var thumbnailScale = 1.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "minus")
                .font(StudioFont.symbol(10, weight: .medium))
                .foregroundStyle(StudioColor.secondaryText)
            Slider(value: $thumbnailScale, in: 0.72...1.36)
                .frame(width: 128)
                .controlSize(.small)
            Image(systemName: "plus")
                .font(StudioFont.symbol(10, weight: .medium))
                .foregroundStyle(StudioColor.secondaryText)
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(isHovered ? StudioColor.panelRaised : StudioColor.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isHovered ? StudioColor.primaryAction.opacity(0.32) : StudioColor.hairline, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .help("调整缩略图大小")
        .onHover { isHovered = $0 }
        .animation(StudioMotion.fast(reduceMotion: reduceMotion), value: isHovered)
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
                    clearTextFocus()
                    state.modal = .modelFilterManager
                } label: {
                    Image(systemName: "plus")
                        .font(StudioFont.symbol(15))
                }
                .buttonStyle(IconCircleButtonStyle())
                .foregroundStyle(StudioColor.text)
                .help("管理筛选标签")
                .accessibilityLabel("管理筛选标签")
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
            clearTextFocus()
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
    @AppStorage("promptStudio.thumbnailScale") private var thumbnailScale = 1.0
    let items: [PromptItem]
    let isSplitResizing: Bool
    @State private var draggedItemID: String?
    @State private var lockedColumnCount: Int?

    var body: some View {
        GeometryReader { proxy in
            let computedColumnCount = computedColumnCount(for: proxy.size.width)
            let columnCount = lockedColumnCount ?? computedColumnCount
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
            .onChange(of: isSplitResizing) { _, resizing in
                if resizing {
                    lockedColumnCount = lockedColumnCount ?? computedColumnCount
                } else {
                    lockedColumnCount = nil
                }
            }
        }
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    private func computedColumnCount(for availableWidth: CGFloat) -> Int {
        let contentWidth = max(0, availableWidth - 48)
        let targetWidth = 250 * CGFloat(thumbnailScale)
        let proposed = Int((contentWidth + 12) / (targetWidth + 12))
        return max(2, min(6, proposed))
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
        if item.assetKind.isTextDocumentLike {
            return width * 9 / 16
        }
        if item.assetKind.supportsGeneratedThumbnail, item.width > 0, item.height > 0 {
            return width * CGFloat(item.height) / CGFloat(item.width)
        }
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
            cardContent
                .frame(width: contentWidth, height: contentHeight)
                .clipped()

            ImmediateCardClickLayer {
                selectImmediately()
            } onDoubleClick: {
                selectImmediately()
                state.previewSelected()
            }
            .frame(width: contentWidth, height: contentHeight)

            if isSelected {
                selectedCardOverlay
                    .frame(width: contentWidth, height: contentHeight, alignment: .bottom)
                    .transition(.opacity)
            }

        }
        .frame(width: contentWidth, height: contentHeight)
        .clipShape(RoundedRectangle(cornerRadius: AssetCardMetrics.cardCornerRadius, style: .continuous))
        .padding(AssetCardMetrics.selectionOutset)
        .overlay(
            RoundedRectangle(cornerRadius: AssetCardMetrics.selectionCornerRadius, style: .continuous)
                .strokeBorder(isSelected ? StudioColor.primaryAction.opacity(0.72) : Color.clear, lineWidth: isSelected ? 1.5 : 0)
        )
        .frame(width: width, height: contentHeight + AssetCardMetrics.selectionOutset * 2)
        .contentShape(RoundedRectangle(cornerRadius: AssetCardMetrics.selectionCornerRadius, style: .continuous))
        .contextMenu {
            assetContextMenu
        }
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
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    @ViewBuilder
    private var cardContent: some View {
        if item.assetKind.isTextDocumentLike {
            TextDocumentCardPreview(item: item)
        } else {
            AssetMediaView(item: item)
        }
    }

    private var selectedCardOverlay: some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                Text(item.title)
                    .font(StudioFont.font(13, weight: .semibold))
                    .foregroundStyle(StudioColor.text)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                HStack(spacing: 8) {
                    cardAction("pencil", help: "编辑") { state.requestInlineEdit(item) }
                    cardAction("doc.on.doc", help: item.assetKind.isTextDocumentLike ? "复制文档信息" : "复制提示词") {
                        state.copyItemContent(item)
                    }
                    cardAction("clock", help: "历史版本") { state.modal = .versionHistory }
                }
                .allowsHitTesting(true)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            .frame(height: 82, alignment: .bottom)
            .background(
                LinearGradient(
                    colors: [
                        Color.black.opacity(0),
                        Color.black.opacity(0.42),
                        Color.black.opacity(0.68)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }

    private func selectImmediately() {
        clearTextFocus()
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            state.select(item)
        }
    }

    @ViewBuilder
    private var assetContextMenu: some View {
        Button {
            runContextAction {
                state.previewSelected()
            }
        } label: {
            Label("预览", systemImage: "eye")
        }

        Button {
            runContextAction {
                state.openSelectedInDefaultApplication()
            }
        } label: {
            Label("用默认应用打开", systemImage: "arrow.up.right.square")
        }

        Button {
            runContextAction {
                state.revealSelectedInFinder()
            }
        } label: {
            Label("在 Finder 中显示", systemImage: "folder")
        }

        Divider()

        if !item.isDeleted {
            Menu {
                ForEach(contextFolderRows) { row in
                    Button {
                        runContextAction {
                            state.moveItem(item.id, toFolderID: row.folder.id)
                        }
                    } label: {
                        if item.folderId == row.folder.id {
                            Label(row.folder.name, systemImage: "checkmark")
                        } else {
                            Text(row.folder.name)
                        }
                    }
                    .disabled(item.folderId == row.folder.id)
                }
            } label: {
                Label("移动到文件夹", systemImage: "folder")
            }
        }

        Button {
            runContextAction {
                state.modal = .export
            }
        } label: {
            Label("导出...", systemImage: "square.and.arrow.up")
        }

        Divider()

        Button {
            runContextAction {
                state.requestInlineEdit(item)
            }
        } label: {
            Label("编辑 Prompt", systemImage: "pencil")
        }

        Button {
            runContextAction {
                state.copyItemContent(item)
            }
        } label: {
            Label(item.assetKind.isTextDocumentLike ? "复制文档信息" : "复制提示词", systemImage: "doc.on.doc")
        }
        .disabled(!hasPrompt)

        Button {
            runContextAction {
                state.copySelectedFile()
            }
        } label: {
            Label("复制文件", systemImage: "doc")
        }

        Button {
            runContextAction {
                state.copySelectedFilePath()
            }
        } label: {
            Label("复制文件路径", systemImage: "text.badge.checkmark")
        }

        Divider()

        Button {
            runContextAction {
                state.modal = .versionHistory
            }
        } label: {
            Label("历史版本", systemImage: "clock")
        }

        Button {
            runContextAction {
                state.modal = .references
            }
        } label: {
            Label("参考图管理", systemImage: "photo.on.rectangle")
        }

        Divider()

        if item.isDeleted {
            Button {
                runContextAction {
                    state.restoreSelected()
                }
            } label: {
                Label("恢复", systemImage: "arrow.uturn.backward")
            }
        } else {
            Button {
                runContextAction {
                    state.moveSelectedToTrash()
                }
            } label: {
                Label("移到回收站", systemImage: "trash")
            }
        }
    }

    private var hasPrompt: Bool {
        if item.assetKind.isTextDocumentLike {
            return !state.markdownDocumentText(for: item).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return item.currentVersion?.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private var contextFolderRows: [AppState.FolderRow] {
        state.folderRows()
    }

    private func runContextAction(_ action: () -> Void) {
        selectImmediately()
        action()
    }

    private var dragPreview: some View {
        let previewWidth = min(138, max(88, width * 0.46))
        let previewHeight = min(156, max(72, AssetCardMetrics.contentHeight(for: item, width: previewWidth)))
        return AssetMediaView(item: item)
            .frame(width: previewWidth, height: previewHeight)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.white.opacity(0.55), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.36), radius: 14, x: 0, y: 10)
            .opacity(0.86)
            .offset(x: 0, y: previewHeight * 0.64)
    }

    private func cardAction(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button {
            selectImmediately()
            action()
        } label: {
            LucideIcon(kind: lucideKind(for: systemName))
                .frame(width: 14, height: 14)
        }
        .buttonStyle(IconCircleButtonStyle())
        .help(help)
        .accessibilityLabel(help)
    }

    private func lucideKind(for systemName: String) -> LucideIcon.Kind {
        switch systemName {
        case "pencil":
            .pencil
        case "doc.on.doc":
            .copy
        case "clock":
            .history
        default:
            .copy
        }
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

private struct ImmediateCardClickLayer: NSViewRepresentable {
    let onClick: () -> Void
    let onDoubleClick: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onClick: onClick, onDoubleClick: onDoubleClick)
    }

    func makeNSView(context: Context) -> ClickPassthroughView {
        let view = ClickPassthroughView()
        view.onMouseDown = { event in
            if event.clickCount >= 2 {
                context.coordinator.onDoubleClick()
            } else {
                context.coordinator.onClick()
            }
        }
        return view
    }

    func updateNSView(_ nsView: ClickPassthroughView, context: Context) {
        context.coordinator.onClick = onClick
        context.coordinator.onDoubleClick = onDoubleClick
        nsView.onMouseDown = { event in
            if event.clickCount >= 2 {
                context.coordinator.onDoubleClick()
            } else {
                context.coordinator.onClick()
            }
        }
    }

    final class Coordinator {
        var onClick: () -> Void
        var onDoubleClick: () -> Void

        init(onClick: @escaping () -> Void, onDoubleClick: @escaping () -> Void) {
            self.onClick = onClick
            self.onDoubleClick = onDoubleClick
        }
    }
}

private final class ClickPassthroughView: NSView {
    var onMouseDown: ((NSEvent) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?(event)
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
                        AssetMediaView(item: item)
                            .frame(width: 66, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(StudioFont.font(14))
                            Text("\(item.modelName) · \(item.displayAspectRatio) · \(item.tags.joined(separator: " / "))")
                                .font(StudioFont.font(14))
                                .foregroundStyle(StudioColor.secondaryText)
                        }
                        Spacer()
                        Text(item.updatedAt.formatted(date: .numeric, time: .shortened))
                            .font(StudioFont.font(14))
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
            if isTrash {
                LucideIcon(kind: .trash2)
                    .frame(width: 58, height: 58)
                    .foregroundStyle(StudioColor.secondaryText)
                Text("回收站为空")
                    .font(StudioFont.font(14))
                Text("移入回收站的素材会显示在这里。")
                    .foregroundStyle(StudioColor.secondaryText)
            } else {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(StudioFont.symbol(44))
                    .foregroundStyle(StudioColor.secondaryText)
                Text("没有找到素材")
                .font(StudioFont.font(14))
                Text("调整搜索或导入图片、视频、音频、文档或 Prompt 文本。")
                    .foregroundStyle(StudioColor.secondaryText)
                Button("导入素材") {
                    state.modal = .importAssets
                }
                .buttonStyle(CapsuleButtonStyle(filled: true))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(StudioColor.text)
    }

    private var isTrash: Bool {
        state.filter.collection == .trash
    }
}

private struct TextDocumentCardPreview: View {
    let item: PromptItem
    @State private var text = ""

    private var allPreviewLines: [String] {
        let source = text.isEmpty ? item.currentVersion?.prompt ?? "" : text
        return source
            .components(separatedBy: .newlines)
            .map { line in
                let limit = 160
                guard line.count > limit else { return line }
                return String(line.prefix(limit)) + "..."
            }
    }

    var body: some View {
        GeometryReader { proxy in
            previewContent(size: proxy.size)
        }
        .overlay(
            RoundedRectangle(cornerRadius: AssetCardMetrics.cardCornerRadius, style: .continuous)
                .stroke(TextDocumentCardPalette.border, lineWidth: 1)
        )
        .task(id: previewReloadID) {
            text = Self.loadText(for: item)
        }
    }

    @ViewBuilder
    private func previewContent(size: CGSize) -> some View {
        let lines = visibleLines(for: size)
        ZStack(alignment: .topLeading) {
            TextDocumentCardPalette.background

            if allPreviewLines.isEmpty || allPreviewLines.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                VStack(spacing: 8) {
                    Image(systemName: item.assetKind == .json ? "curlybraces" : "doc.text")
                        .font(StudioFont.symbol(26))
                    Text(item.format.isEmpty ? item.assetKind.displayName.uppercased() : item.format.uppercased())
                        .font(StudioFont.caption(10))
                }
                .foregroundStyle(TextDocumentCardPalette.mutedText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        TextDocumentPreviewLine(line: line)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
    }

    private var previewReloadID: String {
        "\(item.assetPath)|\(item.updatedAt.timeIntervalSince1970)"
    }

    private func visibleLines(for size: CGSize) -> [String] {
        let verticalPadding: CGFloat = 24
        let rowHeight: CGFloat = 17
        let maxLines = max(1, min(18, Int((size.height - verticalPadding) / rowHeight)))
        return Array(allPreviewLines.prefix(maxLines))
    }

    private static func loadText(for item: PromptItem) -> String {
        if !item.assetPath.isEmpty,
           let text = try? String(contentsOf: URL(fileURLWithPath: item.assetPath), encoding: .utf8) {
            return text
        }
        if !item.assetPath.isEmpty,
           let text = try? String(contentsOf: URL(fileURLWithPath: item.assetPath), encoding: .utf16) {
            return text
        }
        return item.currentVersion?.prompt ?? ""
    }
}

private struct TextDocumentPreviewLine: View {
    let line: String

    var body: some View {
        lineText
            .font(.system(size: 11, weight: .regular, design: .default))
    }

    private var lineText: Text {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") {
            return Text(line).foregroundColor(TextDocumentCardPalette.blue)
        }
        if isNegativeConstraint(trimmed) {
            return Text(line).foregroundColor(TextDocumentCardPalette.red)
        }
        if trimmed.hasPrefix(">") {
            let indent = String(line.prefix { $0 == " " || $0 == "\t" })
            let rest = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            return Text(indent)
                + Text(">").foregroundColor(TextDocumentCardPalette.green)
                + Text(" " + rest).foregroundColor(TextDocumentCardPalette.text)
        }
        if let marker = listMarker(in: trimmed) {
            let indent = String(line.prefix { $0 == " " || $0 == "\t" })
            let rest = String(trimmed.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            return Text(indent)
                + Text(marker).foregroundColor(TextDocumentCardPalette.orange)
                + Text(rest.isEmpty ? "" : " " + rest).foregroundColor(TextDocumentCardPalette.text)
        }
        return inlineCodeText(line)
    }

    private func inlineCodeText(_ value: String) -> Text {
        let parts = value.split(separator: "`", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 1 else {
            return Text(value).foregroundColor(TextDocumentCardPalette.text)
        }
        return parts.enumerated().reduce(Text("")) { result, part in
            let color = part.offset % 2 == 1 ? TextDocumentCardPalette.green : TextDocumentCardPalette.text
            return result + Text(part.element).foregroundColor(color)
        }
    }

    private func listMarker(in value: String) -> String? {
        if value.hasPrefix("- ") { return "-" }
        if value.hasPrefix("* ") { return "*" }
        let prefix = value.prefix { $0.isNumber }
        if !prefix.isEmpty, value.dropFirst(prefix.count).hasPrefix(". ") {
            return "\(prefix)."
        }
        return nil
    }

    private func isNegativeConstraint(_ value: String) -> Bool {
        let keywords = [
            "负面提示词", "负面约束", "反向提示词", "Negative Prompt",
            "不要", "禁止", "避免", "不出现", "不使用",
            "无字幕", "无文字", "无水印", "无logo", "无Logo", "无LOGO",
            "无品牌", "无现代", "无多余", "无夸张", "无脸部崩坏", "无身份不一致"
        ]
        return keywords.contains { value.localizedCaseInsensitiveContains($0) }
    }
}

private enum TextDocumentCardPalette {
    static let background = Color(hex: 0x141414)
    static let border = Color(hex: 0x363A3F)
    static let text = Color(hex: 0xBDBEC0)
    static let mutedText = Color(hex: 0xBDBEC0).opacity(0.72)
    static let red = Color(hex: 0xFF5F57)
    static let orange = Color(hex: 0xFF9F0A)
    static let green = Color(hex: 0x37DD61)
    static let blue = Color(hex: 0x41CBE0)
}

struct AssetMediaView: View {
    let item: PromptItem
    var contentMode: ContentMode = .fill

    var body: some View {
        if item.assetKind.supportsGeneratedThumbnail, let thumbnailPath {
            ThumbnailImage(path: thumbnailPath, contentMode: contentMode)
        } else {
            FileKindPlaceholder(assetKind: item.assetKind, format: item.format)
        }
    }

    private var thumbnailPath: String? {
        if item.thumbnailPath != item.assetPath, !item.thumbnailPath.isEmpty {
            return item.thumbnailPath
        }
        if item.assetKind == .image || item.assetKind == .video {
            return item.assetPath
        }
        return nil
    }
}

private struct FileKindPlaceholder: View {
    let assetKind: AssetKind
    let format: String

    var body: some View {
        ZStack {
            StudioColor.panelRaised
            VStack(spacing: 10) {
                Image(systemName: symbolName)
                    .font(StudioFont.symbol(30))
                    .foregroundStyle(StudioColor.text)
                Text(format.isEmpty ? assetKind.displayName.uppercased() : format.uppercased())
                    .font(StudioFont.caption(11))
                    .foregroundStyle(StudioColor.secondaryText)
                    .lineLimit(1)
            }
        }
    }

    private var symbolName: String {
        switch assetKind {
        case .image:
            "photo"
        case .video:
            "film"
        case .audio:
            "waveform"
        case .markdown:
            "text.alignleft"
        case .json, .data:
            "curlybraces"
        case .document:
            "doc.richtext"
        case .text:
            "doc.text"
        case .unknown:
            "doc"
        }
    }
}

struct ThumbnailImage: View {
    let path: String
    var contentMode: ContentMode = .fill
    @StateObject private var loader = CachedImageLoader()

    var body: some View {
        Group {
            if let image = loader.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                ZStack {
                    StudioColor.panelRaised
                    Image(systemName: "photo")
                        .font(StudioFont.symbol(24))
                        .foregroundStyle(StudioColor.secondaryText)
                }
            }
        }
        .clipped()
        .background(StudioColor.panelRaised)
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
