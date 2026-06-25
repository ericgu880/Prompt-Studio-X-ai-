import SwiftUI
import PromptStudioCore
import AppKit
import ImageIO
import UniformTypeIdentifiers

struct PromptStudioView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var shortcutStore: AppShortcutStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("promptStudio.sidebarWidth") private var sidebarWidth = 220.0
    @AppStorage("promptStudio.inspectorWidth") private var inspectorWidth = 330.0
    @AppStorage("promptStudio.sidebarVisible") private var isSidebarVisible = true
    @State private var sidebarDragStartWidth: Double?
    @State private var inspectorDragStartWidth: Double?
    @State private var liveSidebarWidth: Double?
    @State private var liveInspectorWidth: Double?
    @State private var isSplitResizing = false
    @State private var isInspectorResizeActive = false
    @State private var isFileDropTargeted = false

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

                        HStack(spacing: 0) {
                            MainContentView(isSidebarVisible: $isSidebarVisible, isSplitResizing: isSplitResizing)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)

                            InspectorView()
                                .frame(width: layout.inspector)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .overlay(
                            ZStack {
                                if isFileDropTargeted {
                                    Color.white.opacity(0.30)
                                        .ignoresSafeArea()

                                    Text("将任意文件拖放至此处添加")
                                        .font(StudioFont.font(16, weight: .semibold))
                                        .foregroundStyle(StudioColor.text)
                                        .padding(.horizontal, 18)
                                        .frame(height: 42)
                                        .background(Capsule().fill(StudioColor.panel.opacity(0.76)))
                                        .overlay(Capsule().stroke(StudioColor.primaryAction.opacity(0.44), lineWidth: 1))
                                }

                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(isFileDropTargeted ? StudioColor.primaryAction.opacity(0.7) : Color.clear, lineWidth: 2)
                                    .padding(10)
                            }
                            .allowsHitTesting(false)
                        )
                        .overlay(
                            FileDropCaptureOverlay(isTargeted: $isFileDropTargeted) { urls in
                                state.importFiles(urls)
                            }
                        )
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

                    SplitResizeHotZone(showsInactiveLine: false, drawsActiveLine: false) {
                        if let liveInspectorWidth {
                            inspectorWidth = liveInspectorWidth
                        }
                        liveInspectorWidth = nil
                        inspectorDragStartWidth = nil
                        isSplitResizing = false
                        isInspectorResizeActive = false
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
                    } onActiveChanged: { active in
                        isInspectorResizeActive = active
                    }
                    .frame(width: Self.resizeHotZoneWidth, height: proxy.size.height + Self.resizeHotZoneVerticalBleed * 2)
                    .position(x: proxy.size.width - layout.inspector, y: proxy.size.height / 2)
                    .ignoresSafeArea(.container, edges: .vertical)

                    if isInspectorResizeActive {
                        Rectangle()
                            .fill(StudioColor.text.opacity(isSplitResizing ? 0.16 : 0.11))
                            .frame(width: 1, height: proxy.size.height + Self.resizeHotZoneVerticalBleed * 2)
                            .position(x: proxy.size.width - layout.inspector, y: proxy.size.height / 2)
                            .ignoresSafeArea(.container, edges: .vertical)
                            .allowsHitTesting(false)
                    }

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
            ZStack {
                StandardTextEditingShortcutMonitor()
                SpacePreviewKeyMonitor(shortcut: shortcutStore.binding(for: .preview)) {
                    state.togglePreview()
                }
                DeleteSelectionKeyMonitor(
                    canDelete: {
                        let selectedIDs = state.selectedIDs.isEmpty
                            ? state.selectedID.map { Set([$0]) } ?? []
                            : state.selectedIDs
                        return state.items.contains { selectedIDs.contains($0.id) && !$0.isDeleted }
                    },
                    onDelete: {
                        state.moveSelectedToTrash()
                    }
                )
                AppShortcutKeyMonitor(
                    backShortcut: shortcutStore.binding(for: .navigateBack),
                    forwardShortcut: shortcutStore.binding(for: .navigateForward),
                    onBack: {
                        state.navigateBack()
                    },
                    onForward: {
                        state.navigateForward()
                    }
                )
                GlobalTextFocusMonitor()
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
                .environmentObject(shortcutStore)
        case .modelFilterManager:
            ModelFilterManagerSheet()
                .environmentObject(state)
        case .folderEditor(let request):
            FolderEditorSheet(request: request)
                .environmentObject(state)
        case .folderDeleteConfirmation(let request):
            FolderDeleteConfirmationSheet(request: request)
                .environmentObject(state)
        case .externalFileOpen(let request):
            ExternalFileOpenSheet(request: request)
                .environmentObject(state)
        case .temporaryTextPreview(let request):
            TemporaryTextPreviewSheet(request: request)
                .environmentObject(state)
        case .preview:
            PreviewSheet()
                .environmentObject(state)
                .environmentObject(shortcutStore)
        case .featureDenied(let decision):
            FeatureDeniedSheet(decision: decision)
                .environmentObject(state)
        case .error(let message):
            ErrorSheet(message: message)
        }
    }
}

private struct SplitResizeHotZone: View {
    let showsInactiveLine: Bool
    let drawsActiveLine: Bool
    let onDragEnded: () -> Void
    let onDragChanged: (CGFloat) -> Void
    let onActiveChanged: ((Bool) -> Void)?
    @State private var isHovered = false
    @State private var isDragging = false

    init(
        showsInactiveLine: Bool = true,
        drawsActiveLine: Bool = true,
        onDragEnded: @escaping () -> Void,
        onDragChanged: @escaping (CGFloat) -> Void,
        onActiveChanged: ((Bool) -> Void)? = nil
    ) {
        self.showsInactiveLine = showsInactiveLine
        self.drawsActiveLine = drawsActiveLine
        self.onDragEnded = onDragEnded
        self.onDragChanged = onDragChanged
        self.onActiveChanged = onActiveChanged
    }

    var body: some View {
        let active = isHovered || isDragging
        ZStack {
            Color.clear

            if active ? drawsActiveLine : showsInactiveLine {
                Rectangle()
                    .fill(active ? StudioColor.text.opacity(isDragging ? 0.16 : 0.11) : StudioColor.hairline.opacity(0.22))
                    .frame(width: 1)
            }
        }
            .background(ResizeCursorArea())
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
                notifyActiveChanged(hovering || isDragging)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        notifyActiveChanged(true)
                        onDragChanged(value.translation.width)
                    }
                    .onEnded { _ in
                        isDragging = false
                        notifyActiveChanged(isHovered)
                        onDragEnded()
                    }
            )
    }

    private func notifyActiveChanged(_ active: Bool) {
        onActiveChanged?(active)
    }
}

private struct ResizeCursorArea: NSViewRepresentable {
    func makeNSView(context: Context) -> CursorView {
        CursorView()
    }

    func updateNSView(_ nsView: CursorView, context: Context) {}

    final class CursorView: NSView {
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func cursorUpdate(with event: NSEvent) {
            NSCursor.resizeLeftRight.set()
        }
    }
}

struct SpacePreviewKeyMonitor: NSViewRepresentable {
    let shortcut: AppShortcutBinding
    let onSpace: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(shortcut: shortcut, onSpace: onSpace)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.shortcut = shortcut
        context.coordinator.onSpace = onSpace
    }

    final class Coordinator: @unchecked Sendable {
        var shortcut: AppShortcutBinding
        var onSpace: () -> Void
        private var monitor: Any?

        init(shortcut: AppShortcutBinding, onSpace: @escaping () -> Void) {
            self.shortcut = shortcut
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
                guard !textInputActive, self?.shortcut.matches(event) == true else {
                    return event
                }
                self?.onSpace()
                return nil
            }
        }

        @MainActor
        private static var isTextInputActive: Bool {
            AppKitBridge.isTextInputActive()
        }
    }
}

struct AppShortcutKeyMonitor: NSViewRepresentable {
    let backShortcut: AppShortcutBinding
    let forwardShortcut: AppShortcutBinding
    let onBack: () -> Void
    let onForward: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(backShortcut: backShortcut, forwardShortcut: forwardShortcut, onBack: onBack, onForward: onForward)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.backShortcut = backShortcut
        context.coordinator.forwardShortcut = forwardShortcut
        context.coordinator.onBack = onBack
        context.coordinator.onForward = onForward
    }

    final class Coordinator: @unchecked Sendable {
        var backShortcut: AppShortcutBinding
        var forwardShortcut: AppShortcutBinding
        var onBack: () -> Void
        var onForward: () -> Void
        private var monitor: Any?

        init(backShortcut: AppShortcutBinding, forwardShortcut: AppShortcutBinding, onBack: @escaping () -> Void, onForward: @escaping () -> Void) {
            self.backShortcut = backShortcut
            self.forwardShortcut = forwardShortcut
            self.onBack = onBack
            self.onForward = onForward
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let useAppHistory = MainActor.assumeIsolated {
                    AppShortcutRouter.shouldUseAppHistoryForUndoRedo()
                }
                guard useAppHistory else { return event }

                if self?.forwardShortcut.matches(event) == true {
                    self?.onForward()
                    return nil
                }
                if self?.backShortcut.matches(event) == true {
                    self?.onBack()
                    return nil
                }
                return event
            }
        }
    }
}

struct DeleteSelectionKeyMonitor: NSViewRepresentable {
    let canDelete: () -> Bool
    let onDelete: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(canDelete: canDelete, onDelete: onDelete)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.canDelete = canDelete
        context.coordinator.onDelete = onDelete
    }

    final class Coordinator: @unchecked Sendable {
        var canDelete: () -> Bool
        var onDelete: () -> Void
        private var monitor: Any?

        init(canDelete: @escaping () -> Bool, onDelete: @escaping () -> Void) {
            self.canDelete = canDelete
            self.onDelete = onDelete
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
                    AppKitBridge.isTextInputActive()
                }
                guard !textInputActive,
                      Self.isCommandDelete(event),
                      self?.canDelete() == true else {
                    return event
                }
                self?.onDelete()
                return nil
            }
        }

        private static func isCommandDelete(_ event: NSEvent) -> Bool {
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            guard flags == .command else { return false }
            return event.keyCode == 51 || event.keyCode == 117
        }
    }
}

struct StandardTextEditingShortcutMonitor: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Coordinator: @unchecked Sendable {
        private var monitor: Any?

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let textInputActive = MainActor.assumeIsolated {
                    AppKitBridge.isTextInputActive()
                }
                guard textInputActive else { return event }
                let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
                guard flags.contains(.command), !flags.contains(.option), !flags.contains(.control),
                      let key = event.charactersIgnoringModifiers?.lowercased() else {
                    return event
                }
                if key == "c", !flags.contains(.shift) {
                    _ = MainActor.assumeIsolated {
                        NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                    }
                    return nil
                }
                if key == "z" {
                    _ = MainActor.assumeIsolated {
                        if flags.contains(.shift) {
                            NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
                        } else {
                            NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
                        }
                    }
                    return nil
                }
                return event
            }
        }
    }
}

struct GlobalTextFocusMonitor: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Coordinator: @unchecked Sendable {
        private var monitor: Any?

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
                let windowNumber = event.windowNumber
                let locationInWindow = event.locationInWindow
                MainActor.assumeIsolated {
                    if AppKitBridge.isTextInputActive(),
                       !Self.isClickInsideEditableTextInput(windowNumber: windowNumber, locationInWindow: locationInWindow) {
                        clearTextFocus()
                    }
                }
                return event
            }
        }

        @MainActor
        private static func isClickInsideEditableTextInput(windowNumber: Int, locationInWindow: NSPoint) -> Bool {
            guard let window = NSApp.keyWindow,
                  window.windowNumber == windowNumber,
                  let contentView = window.contentView else {
                return false
            }
            let point = contentView.convert(locationInWindow, from: nil)
            guard let hitView = contentView.hitTest(point) else { return false }
            return editableTextInputAncestor(for: hitView) != nil
        }

        @MainActor
        private static func editableTextInputAncestor(for view: NSView) -> NSView? {
            var current: NSView? = view
            while let view = current {
                if let textView = view as? NSTextView, textView.isEditable {
                    return textView
                }
                if view is NSTextField {
                    return view
                }
                current = view.superview
            }
            return nil
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
        .contentShape(Circle())
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

private struct FileDropCaptureOverlay: NSViewRepresentable {
    @Binding var isTargeted: Bool
    let onDrop: ([URL]) -> Void

    func makeNSView(context: Context) -> FileDropCaptureView {
        let view = FileDropCaptureView()
        view.onTargetChange = { targeted in
            isTargeted = targeted
        }
        view.onDrop = onDrop
        return view
    }

    func updateNSView(_ view: FileDropCaptureView, context: Context) {
        view.onTargetChange = { targeted in
            isTargeted = targeted
        }
        view.onDrop = onDrop
    }

    final class FileDropCaptureView: NSView {
        var onTargetChange: (Bool) -> Void = { _ in }
        var onDrop: ([URL]) -> Void = { _ in }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            registerForDraggedTypes([.fileURL])
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            registerForDraggedTypes([.fileURL])
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard fileURLs(from: sender).isEmpty == false else { return [] }
            onTargetChange(true)
            return .copy
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard fileURLs(from: sender).isEmpty == false else { return [] }
            onTargetChange(true)
            return .copy
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            onTargetChange(false)
        }

        override func draggingEnded(_ sender: NSDraggingInfo) {
            onTargetChange(false)
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let urls = fileURLs(from: sender)
            onTargetChange(false)
            guard !urls.isEmpty else { return false }
            onDrop(urls)
            return true
        }

        private func fileURLs(from sender: NSDraggingInfo) -> [URL] {
            let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
            return sender.draggingPasteboard
                .readObjects(forClasses: [NSURL.self], options: options)?
                .compactMap { ($0 as? URL) ?? ($0 as? NSURL)?.absoluteURL } ?? []
        }
    }
}

private struct SidebarView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settingsHovered = false

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

            SidebarHoverScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    sidebarSection(nil) {
                        VStack(alignment: .leading, spacing: 4) {
                            SidebarRow(icon: "rectangle.stack", title: "全部", countText: sidebarCountText(allCount), collection: .all)
                            SidebarRow(icon: "clock", title: "最近使用", countText: sidebarCountText(state.recentCount), collection: .recent)
                            SidebarRow(icon: "trash", title: "回收站", countText: sidebarCountText(state.trashCount), collection: .trash)
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
                .padding(.top, 24)
                .padding(.bottom, 28)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
            .contentShape(Rectangle())
            .overlay(alignment: .top) {
                SidebarBackgroundFill()
                    .frame(height: 28)
                    .padding(.trailing, 18)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .black.opacity(0.98), location: 0.00),
                                .init(color: .black.opacity(0.62), location: 0.18),
                                .init(color: .black.opacity(0.22), location: 0.45),
                                .init(color: .black.opacity(0.06), location: 0.72),
                                .init(color: .clear, location: 1.00)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                SidebarBackgroundFill()
                    .frame(height: 44)
                    .padding(.trailing, 18)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.00),
                                .init(color: .black.opacity(0.06), location: 0.28),
                                .init(color: .black.opacity(0.22), location: 0.55),
                                .init(color: .black.opacity(0.62), location: 0.82),
                                .init(color: .black.opacity(0.98), location: 1.00)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .allowsHitTesting(false)
            }

            Button {
                state.openSettings()
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
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .background(settingsHovered ? StudioColor.panelRaised : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onHover { settingsHovered = $0 }
            .animation(StudioMotion.fast(reduceMotion: reduceMotion), value: settingsHovered)
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .background {
            SidebarBackgroundFill()
                .ignoresSafeArea(.container, edges: .top)
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

    private func sidebarCountText(_ count: Int) -> String {
        state.isLibraryReady ? "\(count)" : "—"
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
    @ViewBuilder let content: () -> Content

    var body: some View {
        SidebarOverlayScrollContainer(content: content)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .contentShape(Rectangle())
    }
}

private struct SidebarOverlayScrollContainer<Content: View>: NSViewRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = HoverRevealScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.verticalScroller = TransparentOverlayScroller()
        scrollView.scrollerStyle = .overlay
        scrollView.scrollerKnobStyle = .light
        scrollView.verticalScrollElasticity = .allowed
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.scrollerInsets = NSEdgeInsetsZero
        configureTransparentScrollView(scrollView)

        let hostingView = NSHostingView(rootView: content)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        hostingView.setContentHuggingPriority(.defaultLow, for: .vertical)
        hostingView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hostingView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let documentView = SidebarScrollDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.wantsLayer = true
        documentView.layer?.backgroundColor = NSColor.clear.cgColor
        documentView.addSubview(hostingView)
        scrollView.documentView = documentView

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: documentView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            hostingView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])

        DispatchQueue.main.async {
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        configureTransparentScrollView(scrollView)
        (scrollView.documentView?.subviews.first as? NSHostingView<Content>)?.rootView = content
        scrollView.documentView?.layer?.backgroundColor = NSColor.clear.cgColor
        (scrollView.documentView?.subviews.first as? NSView)?.layer?.backgroundColor = NSColor.clear.cgColor
    }

    private func configureTransparentScrollView(_ scrollView: NSScrollView) {
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.wantsLayer = true
        scrollView.layer?.backgroundColor = NSColor.clear.cgColor
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.backgroundColor = .clear
        scrollView.contentView.wantsLayer = true
        scrollView.contentView.layer?.backgroundColor = NSColor.clear.cgColor
        scrollView.scrollerStyle = .overlay
        scrollView.scrollerKnobStyle = .light
        if !(scrollView.verticalScroller is TransparentOverlayScroller) {
            scrollView.verticalScroller = TransparentOverlayScroller()
        }
        (scrollView as? HoverRevealScrollView)?.setRevealScrollerOnHover(true)
    }
}

private final class SidebarScrollDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private struct FolderTreeView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var orderOverrides: [String: Int] = [:]
    @State private var rowFrames: [String: CGRect] = [:]
    @State private var draggingFolderID: String?
    @State private var draggingParentId: String?
    @State private var baseSiblingIDs: [String] = []
    @State private var currentSiblingIDs: [String] = []
    @State private var dragOffset: CGSize = .zero
    @State private var dragStartFrame: CGRect?

    var body: some View {
        let rows = state.folderTreeRows(orderOverrides: orderOverrides)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(rows) { row in
                let isPrimaryDragRow = draggingFolderID == row.id
                let isDragGroupMember = isPrimaryDragRow || isDescendant(row.folder.id, of: draggingFolderID)
                FolderTreeRowView(
                    row: row,
                    isPrimaryDragRow: isPrimaryDragRow,
                    isDragGroupMember: isDragGroupMember,
                    dragOffset: isDragGroupMember ? dragOffset : .zero,
                    onDragChanged: { value in
                        updateDrag(row: row, value: value)
                    },
                    onDragEnded: { _ in
                        endDrag()
                    }
                )
            }
        }
        .coordinateSpace(name: "folderTree")
        .onPreferenceChange(FolderTreeRowFramePreferenceKey.self) { rowFrames = $0 }
        .animation(StudioMotion.spring(reduceMotion: reduceMotion), value: orderOverrides)
    }

    private func updateDrag(row: AppState.FolderTreeRow, value: DragGesture.Value) {
        if draggingFolderID == nil {
            draggingFolderID = row.id
            draggingParentId = row.folder.parentId
            dragStartFrame = rowFrames[row.id]
            baseSiblingIDs = sortedSiblingIDs(parentId: row.folder.parentId)
            currentSiblingIDs = baseSiblingIDs
        }
        guard draggingFolderID == row.id else { return }
        dragOffset = compensatedOffset(for: row.id, translation: value.translation)

        let siblingsWithoutDragged = baseSiblingIDs.filter { $0 != row.id }
        let targetIndex = siblingsWithoutDragged.reduce(0) { index, folderID in
            guard let frame = rowFrames[folderID] else { return index }
            return value.location.y > frame.midY ? index + 1 : index
        }

        var nextIDs = siblingsWithoutDragged
        nextIDs.insert(row.id, at: min(max(targetIndex, 0), nextIDs.count))
        guard nextIDs != currentSiblingIDs else { return }
        currentSiblingIDs = nextIDs
        orderOverrides = Dictionary(uniqueKeysWithValues: nextIDs.enumerated().map { ($0.element, $0.offset) })
    }

    private func endDrag() {
        defer {
            draggingFolderID = nil
            draggingParentId = nil
            baseSiblingIDs = []
            currentSiblingIDs = []
            dragOffset = .zero
            dragStartFrame = nil
            orderOverrides = [:]
        }
        guard draggingFolderID != nil, !currentSiblingIDs.isEmpty else { return }
        state.reorderFolders(parentId: draggingParentId, orderedIDs: currentSiblingIDs)
    }

    private func compensatedOffset(for folderID: String, translation: CGSize) -> CGSize {
        guard let startFrame = dragStartFrame,
              let currentFrame = rowFrames[folderID] else {
            return translation
        }
        return CGSize(
            width: translation.width + startFrame.minX - currentFrame.minX,
            height: translation.height + startFrame.minY - currentFrame.minY
        )
    }

    private func sortedSiblingIDs(parentId: String?) -> [String] {
        state.folders
            .filter { $0.parentId == parentId }
            .sorted {
                if $0.sortOrder == $1.sortOrder {
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                return $0.sortOrder < $1.sortOrder
            }
            .map(\.id)
    }

    private func isDescendant(_ folderID: String, of ancestorID: String?) -> Bool {
        guard let ancestorID, folderID != ancestorID else { return false }
        let parentByID = Dictionary(uniqueKeysWithValues: state.folders.map { ($0.id, $0.parentId) })
        var currentParent = parentByID[folderID] ?? nil
        while let parent = currentParent {
            if parent == ancestorID {
                return true
            }
            currentParent = parentByID[parent] ?? nil
        }
        return false
    }
}

private struct FolderTreeRowFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private struct FolderActionsContextMenu: View {
    @EnvironmentObject private var state: AppState
    let folder: LibraryFolder
    let renameAction: () -> Void

    var body: some View {
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

        Button(action: renameAction) {
            Label("重命名", systemImage: "pencil")
        }

        moveFolderMenu

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

    private var moveFolderMenu: some View {
        Menu {
            Button {
                state.moveFolder(folder, toParentID: nil)
            } label: {
                if folder.parentId == nil {
                    Label("顶层", systemImage: "checkmark")
                } else {
                    Text("顶层")
                }
            }
            .disabled(folder.parentId == nil)

            Divider()

            ForEach(state.folderMoveDestinationRows(for: folder)) { row in
                Button {
                    state.moveFolder(folder, toParentID: row.folder.id)
                } label: {
                    let title = "\(String(repeating: "  ", count: row.level))\(row.folder.name)"
                    if folder.parentId == row.folder.id {
                        Label(title, systemImage: "checkmark")
                    } else {
                        Text(title)
                    }
                }
                .disabled(folder.parentId == row.folder.id)
            }
        } label: {
            Label("移动文件夹至", systemImage: "folder.badge.arrow.right")
        }
    }
}

private struct FolderTreeRowView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let row: AppState.FolderTreeRow
    let isPrimaryDragRow: Bool
    let isDragGroupMember: Bool
    let dragOffset: CGSize
    let onDragChanged: (DragGesture.Value) -> Void
    let onDragEnded: (DragGesture.Value) -> Void
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
        .offset(dragOffset)
        .opacity(isDragGroupMember ? 0.86 : 1)
        .zIndex(isDragGroupMember ? 8 : 0)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: FolderTreeRowFramePreferenceKey.self,
                    value: [row.id: proxy.frame(in: .named("folderTree"))]
                )
            }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .named("folderTree"))
                .onChanged { value in
                    guard !isEditingName, !isDragGroupMember || isPrimaryDragRow else { return }
                    onDragChanged(value)
                }
                .onEnded { value in
                    guard !isEditingName, !isDragGroupMember || isPrimaryDragRow else { return }
                    onDragEnded(value)
                }
        )
        .onDrop(
            of: [UTType.plainText.identifier, UTType.fileURL.identifier],
            isTargeted: $isDropTargeted,
            perform: handleDrop
        )
        .contextMenu {
            FolderActionsContextMenu(folder: row.folder) {
                startInlineRename()
            }
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

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
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
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onHover { isHovered = $0 }
            .animation(StudioMotion.fast(reduceMotion: reduceMotion), value: isHovered)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows) { row in
                    SidebarRow(
                        icon: "folder",
                        title: row.folder.name,
                        countText: "\(row.count)",
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
    let countText: String
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
            if collection == .all {
                state.resetToAll()
            } else {
                state.setCollection(collection)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .frame(width: 17)
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 16)
                Text(countText)
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
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                FolderActionsContextMenu(folder: folder) {
                    state.beginRenameFolder(folder)
                }
            }
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
    private static let contentHorizontalInset: CGFloat = 24

    var body: some View {
        VStack(spacing: 0) {
            TopToolbarView()
                .padding(.horizontal, Self.contentHorizontalInset)
                .padding(.top, StudioLayout.contentTopPadding)
                .padding(.bottom, 8)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    AppKitBridge.zoomKeyWindow()
                }

            ModelTabsView()
                .padding(.horizontal, Self.contentHorizontalInset)
                .padding(.bottom, 12)

            Group {
                if !state.isLibraryReady {
                    LibraryAccessRecoveryView()
                } else {
                    let childFolders = state.childFolderRowsForCurrentCollection()
                    if state.filteredItems.isEmpty && childFolders.isEmpty {
                        EmptyStateView()
                    } else if state.isListView && childFolders.isEmpty {
                        PromptListView(items: state.filteredItems)
                    } else {
                        MasonryGridView(
                            folders: childFolders,
                            items: state.filteredItems,
                            isSplitResizing: isSplitResizing
                        )
                        .padding(.horizontal, Self.contentHorizontalInset)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: contentFrameAlignment)
            .background(StudioColor.previewBackground)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded {
                clearTextFocus()
            })
            .id(contentStateKey)
            .transition(StudioMotion.contentTransition(reduceMotion: reduceMotion))
        }
        .background(StudioColor.previewBackground)
        .animation(StudioMotion.standard(reduceMotion: reduceMotion), value: contentStateKey)
    }

    private var contentFrameAlignment: Alignment {
        if !state.isLibraryReady {
            return .center
        }
        if state.filteredItems.isEmpty && state.childFolderRowsForCurrentCollection().isEmpty {
            return .center
        }
        return .topLeading
    }

    private var contentStateKey: String {
        if !state.isLibraryReady {
            return "library-\(state.libraryAccessState)"
        }
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
        context.coordinator.textField = textField
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
        context.coordinator.textField = textField
        if textField.stringValue != text {
            textField.stringValue = text
        }
    }

    static func dismantleNSView(_ nsView: NSTextField, coordinator: Coordinator) {
        coordinator.removeOutsideClickMonitor()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchInputField
        weak var textField: NSTextField?
        private var outsideClickMonitor: Any?

        init(_ parent: SearchInputField) {
            self.parent = parent
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.isFocused = true
            installOutsideClickMonitor()
            setWhiteInsertionPoint(for: notification.object)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.isFocused = false
            removeOutsideClickMonitor()
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

        func installOutsideClickMonitor() {
            guard outsideClickMonitor == nil else { return }
            outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let textField = self.textField, let window = textField.window else {
                    return event
                }
                guard event.window === window else { return event }
                let fieldFrame = textField.convert(textField.bounds, to: nil)
                if !fieldFrame.contains(event.locationInWindow) {
                    DispatchQueue.main.async {
                        clearTextFocus()
                    }
                }
                return event
            }
        }

        func removeOutsideClickMonitor() {
            if let outsideClickMonitor {
                NSEvent.removeMonitor(outsideClickMonitor)
                self.outsideClickMonitor = nil
            }
        }
    }
}

private struct ThumbnailScaleControl: View {
    @AppStorage("promptStudio.thumbnailScale") private var thumbnailScale = 1.0

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
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .help("调整缩略图大小")
    }
}

private struct SidebarBackgroundFill: View {
    var body: some View {
        ZStack {
            SidebarGlassBackground()
            StudioColor.sidebar.opacity(0.30)
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
    @AppStorage(FilterBarConfiguration.storageKey) private var filterBarSelection = ""
    @State private var contentWidth: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0
    @State private var pageIndex = 0
    @State private var wheelAccumulator: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ZStack {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(quickFilters) { filter in
                                CompactFilterChip(filter: filter, active: isActive(filter))
                                    .id(filter.id)
                            }

                            Button {
                                clearTextFocus()
                                state.modal = .modelFilterManager
                            } label: {
                                Image(systemName: "plus")
                                    .font(StudioFont.symbol(15))
                            }
                            .id("filter-manage")
                            .buttonStyle(IconCircleButtonStyle())
                            .foregroundStyle(StudioColor.text)
                            .help("管理筛选标签")
                            .accessibilityLabel("管理筛选标签")

                            Color.clear
                                .frame(width: 6, height: 1)
                                .id("filter-tail")
                        }
                        .background(
                            GeometryReader { contentProxy in
                                Color.clear.preference(key: FilterBarContentWidthKey.self, value: contentProxy.size.width)
                            }
                        )
                    }
                    .mask(filterBarContentMask)

                    if canPageLeft {
                        filterPagerButton(direction: .left, proxy: proxy)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if canPageRight {
                        filterPagerButton(direction: .right, proxy: proxy)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .background(
                    FilterBarWheelMonitor { delta in
                        handleWheel(delta, proxy: proxy)
                    }
                )
                .clipped()
                .onAppear {
                    viewportWidth = geometry.size.width
                }
                .onChange(of: geometry.size.width) { _, width in
                    viewportWidth = width
                    clampFilterPage()
                }
                .onChange(of: filterBarSelection) { _, _ in
                    pageIndex = 0
                    proxy.scrollTo(quickFilters.first?.id, anchor: .leading)
                }
                .onPreferenceChange(FilterBarContentWidthKey.self) { width in
                    contentWidth = width
                    clampFilterPage()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 32)
    }

    private var filterBarContentMask: some View {
        HStack(spacing: 0) {
            if canPageLeft {
                Color.clear.frame(width: 52)
                LinearGradient(
                    colors: [.clear, .black],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 48)
            }

            Color.black

            if canPageRight {
                Color.clear.frame(width: 52)
            }
        }
    }

    private var availableFilters: [FilterQuickEntry] {
        FilterBarConfiguration.availableEntries(models: state.models, tags: state.tags)
    }

    private var selectedFilterIDs: [String] {
        FilterBarConfiguration.selectedIDs(from: filterBarSelection, availableEntries: availableFilters)
    }

    private var quickFilters: [FilterQuickEntry] {
        let entriesByID = Dictionary(uniqueKeysWithValues: availableFilters.map { ($0.id, $0) })
        return selectedFilterIDs.compactMap { entriesByID[$0] }
    }

    private func isActive(_ filter: FilterQuickEntry) -> Bool {
        switch filter {
        case .all:
            state.filter.collection == .all
                && state.filter.type == nil
                && state.filter.modelId == nil
                && state.filter.textFormat == nil
                && state.filter.assetKindFilter == nil
                && state.filter.requiredTag == nil
        case .type(let type, _):
            state.filter.type == type && state.filter.modelId == nil && state.filter.textFormat == nil && state.filter.assetKindFilter == nil
        case .model(let model, _):
            state.filter.modelId == model.id
        case .textFormat(let textFormat, _):
            state.filter.textFormat == textFormat
        case .assetKind(let assetKindFilter, _):
            state.filter.assetKindFilter == assetKindFilter
        case .tag(let tag):
            state.filter.requiredTag == tag
        }
    }

    private var showsPager: Bool {
        contentWidth > viewportWidth + 4
    }

    private var canPageLeft: Bool {
        showsPager && pageIndex > 0
    }

    private var canPageRight: Bool {
        showsPager && pageIndex < maxPageIndex
    }

    private var maxPageIndex: Int {
        guard viewportWidth > 0 else { return 0 }
        return max(0, Int(ceil(contentWidth / viewportWidth)) - 1)
    }

    private var itemsPerPage: Int {
        max(1, Int(max(1, viewportWidth - 48) / 112))
    }

    private func filterPagerButton(direction: FilterBarPagerDirection, proxy: ScrollViewProxy) -> some View {
        FilterPagerButton(direction: direction) {
            pageFilters(proxy: proxy, direction: direction)
        }
    }

    private func pageFilters(proxy: ScrollViewProxy, direction: FilterBarPagerDirection) {
        let maxPage = maxPageIndex
        guard maxPage > 0 else { return }

        if direction == .right {
            pageIndex = min(maxPage, pageIndex + 1)
        } else {
            pageIndex = max(0, pageIndex - 1)
        }

        let isLastPage = pageIndex >= maxPage
        let targetID = scrollTargetID(for: pageIndex)
        withAnimation(.easeInOut(duration: 0.18)) {
            proxy.scrollTo(targetID, anchor: isLastPage ? .trailing : .leading)
        }
    }

    private func handleWheel(_ delta: CGFloat, proxy: ScrollViewProxy) {
        guard showsPager, abs(delta) > 1 else { return }

        wheelAccumulator += delta
        let threshold: CGFloat = 36
        if wheelAccumulator >= threshold {
            wheelAccumulator = 0
            if canPageRight {
                pageFilters(proxy: proxy, direction: .right)
            }
        } else if wheelAccumulator <= -threshold {
            wheelAccumulator = 0
            if canPageLeft {
                pageFilters(proxy: proxy, direction: .left)
            }
        }
    }

    private func scrollTargetID(for page: Int) -> String {
        let ids = quickFilters.map(\.id) + ["filter-manage", "filter-tail"]
        guard !ids.isEmpty else { return "filter-tail" }
        if page >= maxPageIndex {
            return ids[ids.count - 1]
        }
        let index = min(ids.count - 1, max(0, page * itemsPerPage))
        return ids[index]
    }

    private func clampFilterPage() {
        let maxPage = maxPageIndex
        if !showsPager {
            pageIndex = 0
        } else if pageIndex > maxPage {
            pageIndex = maxPage
        }
    }
}

private enum FilterBarPagerDirection {
    case left
    case right
}

private struct FilterPagerButton: View {
    let direction: FilterBarPagerDirection
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: direction == .right ? .trailing : .leading) {
            LinearGradient(
                gradient: Gradient(stops: gradientStops),
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 80, height: 36)
            .allowsHitTesting(false)

            Rectangle()
                .fill(StudioColor.previewBackground)
                .frame(width: 40, height: 36)
                .allowsHitTesting(false)

            Button(action: action) {
                Image(systemName: direction == .right ? "chevron.right" : "chevron.left")
                    .font(StudioFont.symbol(12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(isHovered ? StudioColor.control.opacity(0.88) : Color.clear))
                    .overlay(Circle().stroke(isHovered ? StudioColor.hairline : Color.clear, lineWidth: 1))
                    .frame(width: 40, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .foregroundStyle(StudioColor.text)
            .onHover { isHovered = $0 }
        }
        .frame(width: 80, height: 36)
        .allowsHitTesting(true)
    }

    private var gradientStops: [Gradient.Stop] {
        switch direction {
        case .left:
            [
                .init(color: StudioColor.previewBackground, location: 0),
                .init(color: StudioColor.previewBackground, location: 0.46),
                .init(color: StudioColor.previewBackground.opacity(0), location: 1)
            ]
        case .right:
            [
                .init(color: StudioColor.previewBackground.opacity(0), location: 0),
                .init(color: StudioColor.previewBackground, location: 0.54),
                .init(color: StudioColor.previewBackground, location: 1)
            ]
        }
    }
}

private struct FilterBarContentWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct FilterBarWheelMonitor: NSViewRepresentable {
    let onScroll: @MainActor @Sendable (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScroll: onScroll)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        DispatchQueue.main.async {
            context.coordinator.captureFrame(from: view)
        }
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.view = nsView
        context.coordinator.onScroll = onScroll
        DispatchQueue.main.async {
            context.coordinator.captureFrame(from: nsView)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class Coordinator {
        weak var view: NSView?
        var onScroll: @MainActor @Sendable (CGFloat) -> Void
        private var windowNumber: Int?
        private var screenFrame: CGRect = .zero
        private var monitor: Any?

        init(onScroll: @escaping @MainActor @Sendable (CGFloat) -> Void) {
            self.onScroll = onScroll
        }

        @MainActor
        func captureFrame(from view: NSView) {
            guard let window = view.window else {
                windowNumber = nil
                screenFrame = .zero
                return
            }
            windowNumber = window.windowNumber
            screenFrame = window.convertToScreen(view.convert(view.bounds, to: nil))
        }

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self,
                      event.windowNumber == self.windowNumber,
                      self.screenFrame.contains(NSEvent.mouseLocation) else {
                    return event
                }

                let horizontal = event.scrollingDeltaX
                let vertical = event.scrollingDeltaY == 0 ? event.deltaY : event.scrollingDeltaY
                let delta = abs(horizontal) > abs(vertical) ? horizontal : -vertical
                let onScroll = self.onScroll
                Task { @MainActor in
                    onScroll(delta)
                }
                return nil
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            removeMonitor()
        }
    }
}

private struct CompactFilterChip: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let filter: FilterQuickEntry
    let active: Bool
    @State private var isHovered = false

    var body: some View {
        Button {
            clearTextFocus()
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                switch filter {
                case .all:
                    state.resetToAll()
                case .type(let type, _):
                    state.setPromptType(type)
                case .model(let model, _):
                    state.setModel(model.id)
                case .textFormat(let textFormat, _):
                    state.setTextFormat(textFormat)
                case .assetKind(let assetKindFilter, _):
                    state.setAssetKindFilter(assetKindFilter)
                case .tag(let tag):
                    state.setRequiredTag(tag)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(filter.title)
                    .font(StudioFont.font(12))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .foregroundStyle(active || isHovered ? StudioColor.text : StudioColor.secondaryText)
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
        .contentShape(Capsule())
        .onHover { isHovered = $0 }
        .animation(StudioMotion.fast(reduceMotion: reduceMotion), value: isHovered)
        .accessibilityLabel("筛选：\(filter.title)")
    }
}

private struct MasonryGridView: View {
    @EnvironmentObject private var state: AppState
    @AppStorage("promptStudio.thumbnailScale") private var thumbnailScale = 1.0
    let folders: [AppState.FolderRow]
    let items: [PromptItem]
    let isSplitResizing: Bool
    @State private var draggedItemID: String?
    @State private var selectedFolderID: String?
    @State private var lockedColumnCount: Int?
    @State private var selectionDragStart: CGPoint?
    @State private var selectionDragCurrent: CGPoint?
    @State private var selectionDragBaseIDs: Set<String> = []
    @State private var contentOffsetY: CGFloat = 0
    @State private var layoutCache = MasonryLayoutCache()
    @State private var scrollResetID = UUID()

    var body: some View {
        GeometryReader { proxy in
            let computedColumnCount = computedColumnCount(for: proxy.size.width)
            let columnCount = lockedColumnCount ?? computedColumnCount
            let gridContentWidth = gridContentWidth(for: proxy.size.width)
            let width = (gridContentWidth - CGFloat(columnCount - 1) * 12) / CGFloat(columnCount)
            let layout = layoutCache.layout(folders: folders, items: items, columnCount: columnCount, width: width)
            let visualItemIDs = layout.visualItemIDs
            let renderRange = renderedYRange(viewportHeight: proxy.size.height)
            let renderedPlacements = layout.placements.filter { $0.intersectsYRange(renderRange) }
            let visibleThumbnailCandidateIDs = thumbnailCandidateIDs(in: renderedPlacements)
            let scrollContentHeight = max(layout.height + Self.contentBottomPadding, proxy.size.height)
            let gridContentHeight = max(1, scrollContentHeight - Self.contentBottomPadding)
            TransparentOverlayScrollView(
                resetID: scrollResetID,
                minimumContentHeight: scrollContentHeight,
                verticalScrollerRightInset: -Self.scrollbarLaneWidth,
                revealsScrollerOnHover: true,
                onOffsetChange: { offsetY in
                    contentOffsetY = offsetY
                }
            ) {
                ZStack(alignment: .topLeading) {
                    SelectionDragCaptureOverlay(
                        onBegin: { point, additive in
                            selectionDragStart = point
                            selectionDragCurrent = point
                            selectionDragBaseIDs = additive ? state.selectedIDs : []
                            selectedFolderID = nil
                        },
                        onChange: { point in
                            selectionDragCurrent = point
                            guard let selectionRect else { return }
                            let hitIDs = itemIDs(in: selectionRect, layout: layout, width: width)
                            let nextIDs = selectionDragBaseIDs.union(hitIDs)
                            state.selectItems(ids: nextIDs, primaryID: hitIDs.first ?? nextIDs.first)
                        },
                        onEnd: {
                            clearSelectionDrag()
                        }
                    )
                    .frame(
                        width: max(0, proxy.size.width),
                        height: gridContentHeight
                    )

                    ForEach(renderedPlacements) { placement in
                        switch placement.entry {
                        case .folder(let folder):
                            SubfolderCardView(
                                row: folder,
                                width: width,
                                isSelected: selectedFolderID == folder.id,
                                onSelect: {
                                    selectedFolderID = folder.id
                                    state.selectItems(ids: [])
                                }
                            )
                                .offset(x: placement.x, y: placement.y)
                                .zIndex(selectedFolderID == folder.id ? 1 : 0)
                        case .item(let item):
                            AssetCardView(
                                item: item,
                                width: width,
                                draggedItemID: $draggedItemID,
                                selectionAction: { item, modifiers in
                                    selectItem(item, modifiers: modifiers, visualItemIDs: visualItemIDs)
                                }
                            )
                            .offset(x: placement.x, y: placement.y)
                            .simultaneousGesture(TapGesture().onEnded {
                                selectedFolderID = nil
                            })
                            .zIndex(state.selectedIDs.contains(item.id) ? 1 : 0)
                        }
                    }

                    if let selectionRect {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(StudioColor.primaryAction.opacity(0.16))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(StudioColor.primaryAction.opacity(0.72), lineWidth: 1)
                            )
                            .frame(width: selectionRect.width, height: selectionRect.height)
                            .offset(x: selectionRect.minX, y: selectionRect.minY)
                            .allowsHitTesting(false)
                            .zIndex(20)
                    }
                }
                .frame(
                    width: max(0, proxy.size.width),
                    height: gridContentHeight,
                    alignment: .topLeading
                )
                .contentShape(Rectangle())
                .coordinateSpace(name: Self.gridCoordinateSpace)
                .padding(.bottom, Self.contentBottomPadding)
            }
            .onChange(of: state.filter) { _, _ in
                contentOffsetY = 0
                scrollResetID = UUID()
                selectedFolderID = nil
                clearSelectionDrag()
            }
            .task(id: visibleThumbnailCandidateIDs) {
                state.prepareVisibleThumbnails(for: visibleThumbnailCandidateIDs)
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
        let contentWidth = gridContentWidth(for: availableWidth)
        let targetWidth = 250 * CGFloat(thumbnailScale)
        let proposed = Int((contentWidth + 12) / (targetWidth + 12))
        return max(2, min(6, proposed))
    }

    private static let gridCoordinateSpace = "masonry-grid-coordinate-space"
    private static let scrollbarLaneWidth: CGFloat = 18
    private static let contentBottomPadding: CGFloat = 24

    private func gridContentWidth(for availableWidth: CGFloat) -> CGFloat {
        max(0, availableWidth)
    }

    private func renderedYRange(viewportHeight: CGFloat) -> ClosedRange<CGFloat> {
        let buffer = max(600, viewportHeight * 1.25)
        let lowerBound = max(0, contentOffsetY - buffer)
        return lowerBound...(contentOffsetY + viewportHeight + buffer)
    }

    private var selectionRect: CGRect? {
        guard let selectionDragStart, let selectionDragCurrent else { return nil }
        let minX = min(selectionDragStart.x, selectionDragCurrent.x)
        let minY = min(selectionDragStart.y, selectionDragCurrent.y)
        let maxX = max(selectionDragStart.x, selectionDragCurrent.x)
        let maxY = max(selectionDragStart.y, selectionDragCurrent.y)
        guard maxX - minX >= 3, maxY - minY >= 3 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func itemIDs(in rect: CGRect, layout: MasonryLayoutResult, width: CGFloat) -> Set<String> {
        var ids = Set<String>()
        for placement in layout.placements {
            guard case .item(let item) = placement.entry else { continue }
            let itemRect = CGRect(
                x: placement.x,
                y: placement.y,
                width: width,
                height: placement.height
            )
            if itemRect.intersects(rect) {
                ids.insert(item.id)
            }
        }
        return ids
    }

    private func selectItem(_ item: PromptItem, modifiers: NSEvent.ModifierFlags, visualItemIDs: [String]) {
        selectedFolderID = nil
        let isCommand = modifiers.contains(.command)
        let isShift = modifiers.contains(.shift)

        guard isShift,
              let anchorID = state.selectedID,
              let anchorIndex = visualItemIDs.firstIndex(of: anchorID),
              let targetIndex = visualItemIDs.firstIndex(of: item.id) else {
            if isCommand {
                state.toggleSelection(item)
            } else {
                state.select(item)
            }
            return
        }

        let lowerBound = min(anchorIndex, targetIndex)
        let upperBound = max(anchorIndex, targetIndex)
        let rangeIDs = Set(visualItemIDs[lowerBound...upperBound])
        let nextIDs = isCommand ? state.selectedIDs.union(rangeIDs) : rangeIDs
        state.selectItems(ids: nextIDs, primaryID: item.id)
    }

    private func clearSelectionDrag() {
        selectionDragStart = nil
        selectionDragCurrent = nil
        selectionDragBaseIDs = []
    }

    private func thumbnailCandidateIDs(in placements: [MasonryPlacement]) -> [String] {
        placements.compactMap { placement in
            guard case .item(let item) = placement.entry,
                  item.supportsGeneratedThumbnail,
                  !item.isTextDocumentLike,
                  item.thumbnailPath.isEmpty
                      || item.thumbnailPath == item.assetPath
                      || !FileManager.default.fileExists(atPath: item.thumbnailPath) else {
                return nil
            }
            return item.id
        }
    }
}

private final class MasonryLayoutCache {
    private var cachedKey: MasonryLayoutCacheKey?
    private var cachedResult: MasonryLayoutResult?

    func layout(
        folders: [AppState.FolderRow],
        items: [PromptItem],
        columnCount: Int,
        width: CGFloat
    ) -> MasonryLayoutResult {
        let key = MasonryLayoutCacheKey(folders: folders, items: items, columnCount: columnCount, width: width)
        if key == cachedKey, let cachedResult {
            return cachedResult
        }

        let result = makeMasonryLayout(folders: folders, items: items, columnCount: columnCount, width: width)
        cachedKey = key
        cachedResult = result
        return result
    }

    private func makeMasonryLayout(
        folders: [AppState.FolderRow],
        items: [PromptItem],
        columnCount: Int,
        width: CGFloat
    ) -> MasonryLayoutResult {
        var placements: [MasonryPlacement] = []
        guard columnCount > 0 else {
            return MasonryLayoutResult(placements: [], height: 0, visualItemIDs: [])
        }

        var heights = Array(repeating: CGFloat.zero, count: columnCount)
        let entries = folders.map(MasonryGridEntry.folder) + items.map(MasonryGridEntry.item)
        for entry in entries {
            let column = shortestColumnIndex(in: heights)
            let height = entry.totalHeight(width: width)
            placements.append(
                MasonryPlacement(
                    entry: entry,
                    x: CGFloat(column) * (width + 12),
                    y: heights[column],
                    height: height
                )
            )
            heights[column] += height + 12
        }
        return MasonryLayoutResult(
            placements: placements,
            height: max(0, (heights.max() ?? 12) - 12),
            visualItemIDs: Self.itemIDsInVisualOrder(placements)
        )
    }

    private func shortestColumnIndex(in heights: [CGFloat]) -> Int {
        heights.indices.min { lhs, rhs in
            let leftHeight = heights[lhs]
            let rightHeight = heights[rhs]
            if leftHeight == rightHeight {
                return lhs < rhs
            }
            return leftHeight < rightHeight
        } ?? 0
    }

    private static func itemIDsInVisualOrder(_ placements: [MasonryPlacement]) -> [String] {
        placements
            .compactMap { placement -> (id: String, x: CGFloat, y: CGFloat)? in
                guard case .item(let item) = placement.entry else { return nil }
                return (item.id, placement.x, placement.y)
            }
            .sorted { lhs, rhs in
                if abs(lhs.y - rhs.y) > 0.5 {
                    return lhs.y < rhs.y
                }
                return lhs.x < rhs.x
            }
            .map(\.id)
    }
}

private struct MasonryLayoutCacheKey: Equatable {
    let folderKeys: [MasonryFolderLayoutKey]
    let itemKeys: [MasonryItemLayoutKey]
    let columnCount: Int
    let widthBucket: Int

    init(folders: [AppState.FolderRow], items: [PromptItem], columnCount: Int, width: CGFloat) {
        self.folderKeys = folders.map(MasonryFolderLayoutKey.init)
        self.itemKeys = items.map(MasonryItemLayoutKey.init)
        self.columnCount = columnCount
        self.widthBucket = Int((width * 100).rounded())
    }
}

private struct MasonryFolderLayoutKey: Equatable {
    let id: String
    let name: String
    let count: Int

    init(row: AppState.FolderRow) {
        id = row.folder.id
        name = row.folder.name
        count = row.count
    }
}

private struct MasonryItemLayoutKey: Equatable {
    let id: String
    let assetKind: AssetKind
    let previewMode: AssetPreviewMode
    let width: Int
    let height: Int
    let aspectRatio: String
    let thumbnailPath: String
    let title: String
    let updatedAt: TimeInterval

    init(item: PromptItem) {
        id = item.id
        assetKind = item.assetKind
        previewMode = item.previewMode
        width = item.width
        height = item.height
        aspectRatio = item.displayAspectRatio
        thumbnailPath = item.thumbnailPath
        title = item.title
        updatedAt = item.updatedAt.timeIntervalSinceReferenceDate
    }
}

private struct MasonryLayoutResult {
    let placements: [MasonryPlacement]
    let height: CGFloat
    let visualItemIDs: [String]
}

private struct MasonryPlacement: Identifiable {
    let entry: MasonryGridEntry
    let x: CGFloat
    let y: CGFloat
    let height: CGFloat

    var id: String { entry.id }

    func intersectsYRange(_ range: ClosedRange<CGFloat>) -> Bool {
        y + height >= range.lowerBound && y <= range.upperBound
    }
}

private enum MasonryGridEntry {
    case folder(AppState.FolderRow)
    case item(PromptItem)

    var id: String {
        switch self {
        case .folder(let folder):
            "folder-\(folder.id)"
        case .item(let item):
            item.id
        }
    }

    func totalHeight(width: CGFloat) -> CGFloat {
        switch self {
        case .folder:
            SubfolderCardMetrics.totalHeight(for: width)
        case .item(let item):
            AssetCardMetrics.totalHeight(for: item, width: width)
        }
    }
}

private enum SubfolderCardMetrics {
    static let cornerRadius: CGFloat = 12
    static let selectionCornerRadius: CGFloat = 15

    static func contentWidth(for width: CGFloat) -> CGFloat {
        max(120, width - AssetCardMetrics.selectionOutset * 2)
    }

    static func contentHeight(for width: CGFloat) -> CGFloat {
        max(112, min(150, width * 0.46))
    }

    static func totalHeight(for width: CGFloat) -> CGFloat {
        contentHeight(for: contentWidth(for: width)) + AssetCardMetrics.selectionOutset * 2
    }
}

private struct SubfolderCardView: View {
    @EnvironmentObject private var state: AppState
    let row: AppState.FolderRow
    let width: CGFloat
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        let contentWidth = SubfolderCardMetrics.contentWidth(for: width)
        let height = SubfolderCardMetrics.contentHeight(for: contentWidth)
        ZStack(alignment: .bottomTrailing) {
            HStack(spacing: 16) {
                folderCover(height: height)
                    .frame(width: max(92, contentWidth * 0.40), height: height - 16)

                VStack(alignment: .leading, spacing: 5) {
                    Text(row.folder.name)
                        .font(StudioFont.font(15, weight: .semibold))
                        .foregroundStyle(StudioColor.text)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)

                    Text("\(row.count) 个文件")
                        .font(StudioFont.font(12))
                        .foregroundStyle(StudioColor.mutedText)
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 16)
                .padding(.trailing, 38)
            }
            .padding(.leading, 8)
            .padding(.trailing, 14)
            .frame(width: contentWidth, height: height)
            .background(StudioColor.panel)
            .clipShape(RoundedRectangle(cornerRadius: SubfolderCardMetrics.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: SubfolderCardMetrics.cornerRadius, style: .continuous)
                    .strokeBorder(StudioColor.hairline, lineWidth: 1)
            )
            .overlay(alignment: .bottom) {
                if isSelected {
                    LinearGradient(
                        colors: [.black.opacity(0), .black.opacity(0.28)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: height * 0.44)
                    .allowsHitTesting(false)
                }
            }

            ImmediateFolderClickCapture(
                onSingleClick: onSelect,
                onDoubleClick: {
                    onSelect()
                    state.selectFolder(row.folder)
                }
            )
            .frame(width: contentWidth, height: height)

            Button {
                onSelect()
                state.selectFolder(row.folder)
            } label: {
                Image(systemName: "arrow.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(StudioColor.text)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(StudioColor.control))
                    .overlay(
                        Circle()
                            .stroke(isSelected ? StudioColor.primaryAction.opacity(0.42) : StudioColor.hairline, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .padding(.trailing, 14)
            .padding(.bottom, 12)
        }
        .padding(AssetCardMetrics.selectionOutset)
        .frame(width: width, height: height + AssetCardMetrics.selectionOutset * 2)
        .overlay(
            RoundedRectangle(cornerRadius: SubfolderCardMetrics.selectionCornerRadius, style: .continuous)
                .strokeBorder(isSelected ? StudioColor.primaryAction.opacity(0.72) : Color.clear, lineWidth: 1.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: SubfolderCardMetrics.selectionCornerRadius, style: .continuous))
        .contextMenu {
            FolderActionsContextMenu(folder: row.folder) {
                state.beginRenameFolder(row.folder)
            }
        }
        .accessibilityLabel("进入文件夹 \(row.folder.name)，\(row.count) 个文件")
    }

    private func folderCover(height: CGFloat) -> some View {
        GeometryReader { proxy in
            let coverWidth = proxy.size.width
            let coverHeight = proxy.size.height
            ZStack(alignment: .center) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(StudioColor.controlPressed.opacity(0.92))
                    .frame(width: coverWidth * 0.88, height: coverHeight * 0.84)
                    .rotationEffect(.degrees(-3))
                    .offset(x: coverWidth * 0.12, y: coverHeight * 0.08)

                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(StudioColor.control)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(StudioColor.hairline, lineWidth: 1)
                    )
                    .overlay(coverTexture.clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)))

                Text(coverLabel)
                    .font(StudioFont.font(18, weight: .semibold))
                    .foregroundStyle(StudioColor.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.58)
                    .padding(.horizontal, 10)
            }
        }
    }

    private var coverTexture: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(0..<5, id: \.self) { _ in
                Text(coverLabel)
                    .font(StudioFont.font(20, weight: .semibold))
                    .foregroundStyle(StudioColor.text.opacity(0.035))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.leading, 9)
    }

    private var coverLabel: String {
        let trimmed = row.folder.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "PS" }
        return String(trimmed.prefix(8))
    }
}

private struct ImmediateFolderClickCapture: NSViewRepresentable {
    let onSingleClick: () -> Void
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> FolderClickCaptureView {
        let view = FolderClickCaptureView()
        view.onSingleClick = onSingleClick
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ view: FolderClickCaptureView, context: Context) {
        view.onSingleClick = onSingleClick
        view.onDoubleClick = onDoubleClick
    }

    final class FolderClickCaptureView: NSView {
        var onSingleClick: () -> Void = {}
        var onDoubleClick: () -> Void = {}

        override var acceptsFirstResponder: Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount >= 2 {
                onDoubleClick()
            } else {
                onSingleClick()
            }
        }
    }
}

private struct SelectionDragCaptureOverlay: NSViewRepresentable {
    let onBegin: (CGPoint, Bool) -> Void
    let onChange: (CGPoint) -> Void
    let onEnd: () -> Void

    func makeNSView(context: Context) -> SelectionDragCaptureView {
        let view = SelectionDragCaptureView()
        view.onBegin = onBegin
        view.onChange = onChange
        view.onEnd = onEnd
        return view
    }

    func updateNSView(_ view: SelectionDragCaptureView, context: Context) {
        view.onBegin = onBegin
        view.onChange = onChange
        view.onEnd = onEnd
    }

    final class SelectionDragCaptureView: NSView {
        var onBegin: (CGPoint, Bool) -> Void = { _, _ in }
        var onChange: (CGPoint) -> Void = { _ in }
        var onEnd: () -> Void = {}
        private var isSelecting = false

        override var isFlipped: Bool { true }

        override func mouseDown(with event: NSEvent) {
            isSelecting = false
        }

        override func mouseDragged(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            if !isSelecting {
                isSelecting = true
                onBegin(point, event.modifierFlags.contains(.command))
            }
            onChange(point)
        }

        override func mouseUp(with event: NSEvent) {
            if isSelecting {
                onEnd()
            }
            isSelecting = false
        }
    }
}

private enum AssetCardMetrics {
    static let cardCornerRadius: CGFloat = 12
    static let selectionCornerRadius: CGFloat = 15
    static let selectionOutset: CGFloat = 3

    static func contentWidth(for width: CGFloat) -> CGFloat {
        max(120, width - selectionOutset * 2)
    }

    static func contentHeight(for item: PromptItem, width: CGFloat) -> CGFloat {
        if item.isTextDocumentLike {
            return width
        }
        switch item.previewMode {
        case .audio, .document, .reference, .generic:
            return width * 0.82
        case .image, .video, .textDocument:
            break
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
    let selectionAction: (PromptItem, NSEvent.ModifierFlags) -> Void
    @State private var lastClickAt: Date?

    private var isSelected: Bool {
        state.selectedIDs.contains(item.id)
    }

    var body: some View {
        let contentWidth = AssetCardMetrics.contentWidth(for: width)
        let contentHeight = AssetCardMetrics.contentHeight(for: item, width: contentWidth)
        ZStack(alignment: .topTrailing) {
            cardContent
                .frame(width: contentWidth, height: contentHeight)
                .clipped()

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
        .onTapGesture {
            handleCardTap()
        }
        .simultaneousGesture(
            TapGesture(count: 2)
                .onEnded {
                    selectImmediately()
                    state.previewSelected()
                }
        )
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

    private func handleCardTap() {
        let now = Date()
        let isDoubleClick = lastClickAt.map { now.timeIntervalSince($0) <= 0.35 } ?? false
        lastClickAt = isDoubleClick ? nil : now
        selectImmediately()
        if isDoubleClick {
            state.previewSelected()
        }
    }

    @ViewBuilder
    private var cardContent: some View {
        AssetCardContentView(item: item)
            .equatable()
    }

    @ViewBuilder
    private var selectedCardOverlay: some View {
        if item.isTextDocumentLike {
            textDocumentSelectedCardOverlay
        } else {
            mediaSelectedCardOverlay
        }
    }

    private var mediaSelectedCardOverlay: some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                Text(item.title)
                    .font(StudioFont.font(13, weight: .semibold))
                    .foregroundStyle(StudioColor.text)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                selectedCardActions
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

    private var textDocumentSelectedCardOverlay: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                selectedCardActions
            }
            .padding(.trailing, 10)
            .padding(.bottom, 10)
        }
    }

    private var selectedCardActions: some View {
        HStack(spacing: 8) {
            if item.isPromptPrimaryAsset {
                cardAction("pencil", help: "编辑") { state.requestInlineEdit(item) }
                cardAction("doc.on.doc", help: item.isTextDocumentLike ? "复制文档信息" : "复制提示词") {
                    state.copyItemContent(item)
                }
            } else {
                cardAction("pencil", help: "编辑") { state.openSelectedInDefaultApplication() }
                cardAction("doc.on.doc", help: "复制文件") { state.copySelectedFile() }
            }
        }
        .allowsHitTesting(true)
    }

    private func selectImmediately() {
        clearTextFocus()
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            selectionAction(item, NSEvent.modifierFlags)
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

        if item.isPromptPrimaryAsset {
            Button {
                runContextAction {
                    state.modal = .export
                }
            } label: {
                Label("导出...", systemImage: "square.and.arrow.up")
            }
        }

        Divider()

        if item.isPromptPrimaryAsset {
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
                Label(item.isTextDocumentLike ? "复制文档信息" : "复制提示词", systemImage: "doc.on.doc")
            }
            .disabled(!hasPrompt)
        }

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

        if item.isPromptPrimaryAsset {
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
                Label("参考资产管理", systemImage: "photo.on.rectangle")
            }
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
        if item.isTextDocumentLike {
            return !state.markdownDocumentText(for: item).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return item.currentVersion?.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private var contextFolderRows: [AppState.FolderRow] {
        state.folderRows()
    }

    private func runContextAction(_ action: () -> Void) {
        if !state.selectedIDs.contains(item.id) {
            selectImmediately()
        }
        action()
    }

    private var dragPreview: some View {
        let previewWidth = min(138, max(88, width * 0.46))
        let previewHeight = min(156, max(72, AssetCardMetrics.contentHeight(for: item, width: previewWidth)))
        return Group {
            if item.isTextDocumentLike {
                TextAssetCardCover(item: item)
            } else {
                AssetMediaView(item: item)
            }
        }
        .frame(width: previewWidth, height: previewHeight)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.white.opacity(0.55), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.36), radius: 14, x: 0, y: 10)
        .opacity(0.78)
        .padding(8)
        .background(Color.clear)
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

private struct AssetCardContentView: View, Equatable {
    let item: PromptItem

    var body: some View {
        if item.isTextDocumentLike {
            TextAssetCardCover(item: item)
        } else {
            AssetMediaView(item: item)
        }
    }

    nonisolated static func == (lhs: AssetCardContentView, rhs: AssetCardContentView) -> Bool {
        lhs.item == rhs.item
    }
}

private extension PromptItem {
    var hasGeneratedThumbnailFile: Bool {
        thumbnailPath != assetPath
            && !thumbnailPath.isEmpty
            && FileManager.default.fileExists(atPath: thumbnailPath)
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
                            .stroke(state.selectedIDs.contains(item.id) ? StudioColor.primaryAction.opacity(0.72) : Color.clear, lineWidth: 1.5)
                    )
                    .onTapGesture {
                        clearTextFocus()
                        if NSEvent.modifierFlags.contains(.command) {
                            state.toggleSelection(item)
                        } else {
                            state.select(item)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .contentOverlayScrollbars()
    }
}

private extension View {
    func contentOverlayScrollbars() -> some View {
        background(ContentOverlayScrollbarConfigurator())
    }
}

private struct ContentOverlayScrollbarConfigurator: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        configureLater(from: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configureLater(from: nsView, coordinator: context.coordinator)
    }

    final class Coordinator {
        weak var configuredScrollView: NSScrollView?
    }

    private func configureLater(from view: NSView, coordinator: Coordinator) {
        DispatchQueue.main.async {
            configureScrollView(containing: view, coordinator: coordinator)
        }
    }

    private func configureScrollView(containing view: NSView, coordinator: Coordinator) {
        var candidate: NSView? = view
        while let current = candidate {
            if let scrollView = current as? NSScrollView {
                guard coordinator.configuredScrollView !== scrollView else { return }
                configure(scrollView)
                coordinator.configuredScrollView = scrollView
                return
            }
            candidate = current.superview
        }
    }

    private func configure(_ scrollView: NSScrollView) {
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.scrollerKnobStyle = .light
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .allowed
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.scrollerInsets = NSEdgeInsetsZero
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.backgroundColor = .clear
        if !(scrollView.verticalScroller is TransparentOverlayScroller) {
            scrollView.verticalScroller = TransparentOverlayScroller()
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
                    state.openImportAssets()
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

private struct LibraryAccessRecoveryView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: iconName)
                .font(StudioFont.symbol(42, weight: .medium))
                .foregroundStyle(iconColor)

            VStack(spacing: 8) {
                Text(title)
                    .font(StudioFont.font(16, weight: .semibold))
                    .foregroundStyle(StudioColor.text)
                Text(message)
                    .font(StudioFont.font(13))
                    .foregroundStyle(StudioColor.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 430)

            if let path = pathText {
                Text(path)
                    .font(StudioFont.font(12))
                    .foregroundStyle(StudioColor.tertiaryText)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: 430)
            }

            HStack(spacing: 12) {
                Button("重试") {
                    state.retryLoadLibrary()
                }
                .buttonStyle(CapsuleButtonStyle())

                Button("重新连接资料库") {
                    state.reconnectExistingLibrary()
                }
                .buttonStyle(CapsuleButtonStyle(filled: true))
            }
        }
        .padding(30)
        .background(StudioColor.panel.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(StudioColor.hairline, lineWidth: 1))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var title: String {
        switch state.libraryAccessState {
        case .loading:
            "正在加载资料库"
        case .needsAuthorization(let reason, _):
            reason.title
        case .missing:
            "找不到资料库"
        case .readOnly:
            "资料库不可写"
        case .invalidLibrary:
            "无效资料库"
        case .failed(let error):
            errorTitle(for: error)
        case .ready:
            "资料库已加载"
        }
    }

    private var message: String {
        switch state.libraryAccessState {
        case .loading:
            "正在检查本地数据库和素材目录。"
        case .needsAuthorization(let reason, _):
            reason.message
        case .missing:
            "原资料库可能已被移动或删除，请重新连接已有资料库。"
        case .readOnly:
            "数据库或资料库目录没有写入权限，PromptStudio 无法安全打开。"
        case .invalidLibrary(_, let message):
            message
        case .failed(let error):
            error.localizedDescription
        case .ready:
            ""
        }
    }

    private var pathText: String? {
        switch state.libraryAccessState {
        case .needsAuthorization(_, let url), .missing(let url):
            return url?.path
        case .readOnly(let url), .invalidLibrary(let url, _):
            return url.path
        case .ready(let descriptor):
            return descriptor.url.path
        case .loading, .failed:
            return nil
        }
    }

    private var iconName: String {
        switch state.libraryAccessState {
        case .loading:
            "externaldrive"
        case .needsAuthorization:
            "lock.open"
        case .missing:
            "folder.badge.questionmark"
        case .readOnly:
            "lock"
        case .invalidLibrary, .failed:
            "exclamationmark.triangle"
        case .ready:
            "checkmark.circle"
        }
    }

    private var iconColor: Color {
        switch state.libraryAccessState {
        case .loading, .ready:
            StudioColor.blue
        case .needsAuthorization, .missing, .readOnly, .invalidLibrary, .failed:
            Color(hex: 0xFF8A2A)
        }
    }

    private func errorTitle(for error: LibraryLoadError) -> String {
        switch error {
        case .databaseCorrupted:
            "数据库损坏"
        case .databaseBusy:
            "数据库正被占用"
        case .diskFull:
            "磁盘空间不足"
        case .ioFailure:
            "资料库读取失败"
        case .permissionDenied:
            "资料库访问被拒绝"
        case .notFound:
            "找不到资料库"
        case .readOnly:
            "资料库不可写"
        case .invalidLibrary, .incompatibleSchema:
            "无效资料库"
        case .bookmarkResolutionFailed:
            "资料库授权已失效"
        }
    }
}

private struct TextAssetCardCover: View {
    let item: PromptItem
    @State private var cardData: TextAssetCardData

    init(item: PromptItem) {
        self.item = item
        _cardData = State(initialValue: TextAssetCardData.placeholder(snapshot: TextAssetCardSnapshot(item: item)))
    }

    var body: some View {
        GeometryReader { proxy in
            cardContent(size: proxy.size)
        }
        .overlay(
            RoundedRectangle(cornerRadius: AssetCardMetrics.cardCornerRadius, style: .continuous)
                .stroke(TextDocumentCardPalette.border, lineWidth: 1)
        )
        .task(id: previewReloadID) {
            let loadedData = await TextAssetCardDataCache.shared.data(snapshot: TextAssetCardSnapshot(item: item))
            guard !Task.isCancelled else { return }
            cardData = loadedData
        }
    }

    @ViewBuilder
    private func cardContent(size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            TextDocumentCardPalette.background
            VStack(alignment: .leading, spacing: 10) {
                ViewThatFits(in: .vertical) {
                    titleAndSummary(summaryLimit: 3)
                    titleAndSummary(summaryLimit: 2)
                    titleAndSummary(summaryLimit: 1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()

                cardFooter
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
    }

    private func titleAndSummary(summaryLimit: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(cardData.title)
                .font(StudioFont.font(15, weight: .medium))
                .foregroundStyle(StudioColor.text)
                .lineLimit(2)
                .truncationMode(.tail)

            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(cardData.displaySummaryLines(limit: summaryLimit).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(StudioFont.font(12))
                        .foregroundStyle(StudioColor.text.opacity(0.76))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var cardFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !cardData.chips.isEmpty {
                TextAssetChipFlow(chips: cardData.chips)
            }

            Text(cardData.metadata)
                .font(StudioFont.caption(11))
                .foregroundStyle(TextDocumentCardPalette.mutedText)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(2)
    }

    private var previewReloadID: String {
        "\(item.assetPath)|\(item.updatedAt.timeIntervalSince1970)"
    }
}

private struct TextAssetCardSnapshot: Sendable {
    let title: String
    let assetPath: String
    let format: String
    let assetKindName: String
    let version: String
    let fileSize: Int64
    let tags: [String]
    let updatedAt: Date
    let fallbackText: String

    init(item: PromptItem) {
        title = item.title
        assetPath = item.assetPath
        format = item.format
        assetKindName = item.assetKind.displayName
        version = item.currentVersion?.version ?? "V1.0"
        fileSize = item.fileSize
        tags = item.tags
        updatedAt = item.updatedAt
        fallbackText = item.currentVersion?.prompt ?? ""
    }
}

private actor TextAssetCardDataCache {
    static let shared = TextAssetCardDataCache()

    private static let previewByteLimit = 32 * 1024
    private static let previewCharacterLimit = 8_000
    private var cachedDataByKey: [String: TextAssetCardData] = [:]

    func data(snapshot: TextAssetCardSnapshot) -> TextAssetCardData {
        let key = "\(snapshot.assetPath)|\(snapshot.updatedAt.timeIntervalSince1970)"
        if let cached = cachedDataByKey[key] {
            return cached
        }
        let loadedText = Self.loadPreviewText(path: snapshot.assetPath, fallback: snapshot.fallbackText)
        let data = TextAssetCardData(snapshot: snapshot, text: loadedText)
        cachedDataByKey[key] = data
        if cachedDataByKey.count > 160 {
            cachedDataByKey.removeAll(keepingCapacity: true)
            cachedDataByKey[key] = data
        }
        return data
    }

    private static func loadPreviewText(path: String, fallback: String) -> String {
        guard !path.isEmpty else { return capped(fallback) }
        let url = URL(fileURLWithPath: path)
        let documentExtensions: Set<String> = ["doc", "docx", "rtf"]
        if documentExtensions.contains(url.pathExtension.lowercased()),
           let text = AppKitBridge.readDocumentText(from: url) {
            return capped(text)
        }
        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            let data = handle.readData(ofLength: previewByteLimit)
            if let text = String(data: data, encoding: .utf8) {
                return capped(text)
            }
            if let text = String(data: data, encoding: .utf16) {
                return capped(text)
            }
        }
        return capped(fallback)
    }

    private static func capped(_ text: String) -> String {
        guard text.count > previewCharacterLimit else { return text }
        return String(text.prefix(previewCharacterLimit))
    }
}

private struct TextAssetCardData: Equatable, Sendable {
    let title: String
    let summaryLines: [String]
    let chips: [String]
    let metadata: String

    static func placeholder(snapshot: TextAssetCardSnapshot) -> TextAssetCardData {
        let cleanedTitle = cleanedFileTitle(path: snapshot.assetPath, title: snapshot.title)
        let title = snapshot.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? cleanedTitle
            : snapshot.title
        return TextAssetCardData(
            title: title,
            summaryLines: ["正在生成摘要..."],
            chips: chips(
                format: snapshot.format,
                assetKindName: snapshot.assetKindName,
                tags: snapshot.tags,
                text: "",
                title: title
            ),
            metadata: metadata(
                format: snapshot.format,
                assetKindName: snapshot.assetKindName,
                version: snapshot.version,
                fileSize: snapshot.fileSize,
                text: ""
            )
        )
    }

    init(snapshot: TextAssetCardSnapshot, text: String) {
        let source = text
        let cleanedTitle = Self.cleanedFileTitle(path: snapshot.assetPath, title: snapshot.title)
        let headingTitle = Self.firstMarkdownTitle(in: source)
        title = headingTitle ?? (!snapshot.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? snapshot.title : cleanedTitle)
        summaryLines = Self.summaryLines(from: source, excludingTitle: title)
        chips = Self.chips(
            format: snapshot.format,
            assetKindName: snapshot.assetKindName,
            tags: snapshot.tags,
            text: source,
            title: title
        )
        metadata = Self.metadata(
            format: snapshot.format,
            assetKindName: snapshot.assetKindName,
            version: snapshot.version,
            fileSize: snapshot.fileSize,
            text: source
        )
    }

    private init(title: String, summaryLines: [String], chips: [String], metadata: String) {
        self.title = title
        self.summaryLines = summaryLines
        self.chips = chips
        self.metadata = metadata
    }

    func displaySummaryLines(limit: Int) -> [String] {
        let limit = max(1, limit)
        var lines = Array(summaryLines.prefix(limit))
        guard !lines.isEmpty else { return ["暂无文档摘要"] }
        guard summaryLines.count > limit, let lastIndex = lines.indices.last else {
            return lines
        }

        var lastLine = lines[lastIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        lastLine = lastLine.truncated(to: limit == 1 ? 78 : 82)
        if !lastLine.hasSuffix("...") {
            lastLine += "..."
        }
        lines[lastIndex] = lastLine
        return lines
    }

    private static func firstMarkdownTitle(in text: String) -> String? {
        text.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("# "), !trimmed.hasPrefix("## ") else { return nil }
            return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .first { !$0.isEmpty }
    }

    private static func summaryLines(from text: String, excludingTitle title: String) -> [String] {
        let titleNormalized = normalized(title)
        let lines = text.components(separatedBy: .newlines).compactMap { rawLine -> String? in
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return nil }
            guard !isFrontMatter(line), !isTableSeparator(line), !isLongPath(line) else { return nil }
            line = line.replacingOccurrences(of: #"^#{1,6}\s*"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^[-*+]\s+"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^\d+[\.)]\s+"#, with: "", options: .regularExpression)
            line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, normalized(line) != titleNormalized else { return nil }
            return line.truncated(to: 86)
        }
        var result = Array(lines.prefix(3))
        if result.count == 3 {
            result[2] = result[2].trimmingCharacters(in: .whitespacesAndNewlines).truncated(to: 82)
            if !result[2].hasSuffix("...") {
                result[2] += "..."
            }
        }
        return result.isEmpty ? ["暂无文档摘要"] : result
    }

    private static func chips(format: String, assetKindName: String, tags: [String], text: String, title: String) -> [String] {
        let format = format.isEmpty ? assetKindName.uppercased() : format.uppercased()
        var chips: [String] = [format]
        let haystack = "\(title)\n\(text.prefix(2_000))".lowercased()
        let purposeCandidates: [(String, [String])] = [
            ("视频分镜", ["分镜", "镜头", "seedance", "kling", "可灵"]),
            ("角色设定", ["角色", "人物", "人设"]),
            ("规则", ["规则", "约束", "检查", "规范"]),
            ("Agent handoff", ["agent", "handoff", "schema_version", "writers_room"]),
            ("Prompt", ["prompt", "提示词"])
        ]
        for candidate in purposeCandidates where candidate.1.contains(where: { haystack.contains($0.lowercased()) }) {
            if chips.count < 4 {
                chips.append(candidate.0)
            }
        }
        let tagLimit = max(0, 5 - chips.count)
        chips.append(contentsOf: tags.prefix(tagLimit))
        let remaining = tags.count - min(tags.count, tagLimit)
        if remaining > 0 {
            chips.append("+\(remaining)")
        }
        return Array(chips.prefix(6))
    }

    private static func metadata(format: String, assetKindName: String, version: String, fileSize: Int64, text: String) -> String {
        let format = format.isEmpty ? assetKindName.uppercased() : format.uppercased()
        let lineCount = text.isEmpty ? 0 : text.components(separatedBy: .newlines).count
        if lineCount > 0 {
            return "\(format) · \(lineCount) 行 · \(version)"
        }
        return "\(format) · \(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)) · \(version)"
    }

    private static func cleanedFileTitle(path: String, title: String) -> String {
        let pathTitle = path.isEmpty
            ? title
            : URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let pattern = #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}-"#
        let cleaned = pathTitle.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        return cleaned.isEmpty ? "未命名文档" : cleaned
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func isFrontMatter(_ line: String) -> Bool {
        line == "---" || line == "==="
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let stripped = line.replacingOccurrences(of: "|", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ":", with: "")
            .trimmingCharacters(in: .whitespaces)
        return stripped.isEmpty && line.contains("-")
    }

    private static func isLongPath(_ line: String) -> Bool {
        guard line.count > 48 else { return false }
        return line.hasPrefix("/") || line.contains("/Volumes/") || line.contains("://")
    }
}

private struct TextAssetChipFlow: View {
    let chips: [String]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(chips.prefix(3), id: \.self) { chip in
                chipView(chip)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    private func chipView(_ title: String) -> some View {
        Text(title)
            .font(StudioFont.caption(10))
            .foregroundStyle(StudioColor.text.opacity(0.82))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Capsule().fill(StudioColor.panelRaised.opacity(0.92)))
            .overlay(Capsule().stroke(StudioColor.hairline.opacity(0.7), lineWidth: 1))
    }
}

private extension String {
    func truncated(to maxCount: Int) -> String {
        guard count > maxCount else { return self }
        return String(prefix(maxCount)) + "..."
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
        let tokens = TextSyntaxRules.tokenKinds(in: line, mode: .markdown)
        if tokens.contains(.negativeConstraint) {
            return Text(line).foregroundColor(TextDocumentCardPalette.red)
        }
        if tokens.contains(.heading) {
            return Text(line).foregroundColor(TextDocumentCardPalette.blue)
        }
        if tokens.contains(.quoteMarker) {
            let indent = String(line.prefix { $0 == " " || $0 == "\t" })
            let rest = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            return Text(indent)
                + Text(">").foregroundColor(TextDocumentCardPalette.green)
                + Text(" " + rest).foregroundColor(TextDocumentCardPalette.text)
        }
        if tokens.contains(.listMarker), let marker = listMarker(in: trimmed) {
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
        if item.supportsGeneratedThumbnail, let thumbnailPath {
            ThumbnailImage(path: thumbnailPath, contentMode: contentMode)
        } else {
            FileKindPlaceholder(assetKind: item.assetKind, format: item.format)
        }
    }

    private var thumbnailPath: String? {
        if item.thumbnailPath != item.assetPath,
           !item.thumbnailPath.isEmpty,
           FileManager.default.fileExists(atPath: item.thumbnailPath) {
            return item.thumbnailPath
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
        case .source:
            "hammer"
        case .raw:
            "camera.aperture"
        case .threeD:
            "cube"
        case .texture:
            "square.grid.3x3"
        case .font:
            "textformat"
        case .web:
            "link"
        case .unknown:
            "doc"
        }
    }
}

struct ThumbnailImage: View {
    let path: String
    var contentMode: ContentMode = .fill
    @Environment(\.displayScale) private var displayScale
    @StateObject private var loader = CachedImageLoader()

    var body: some View {
        GeometryReader { proxy in
            let maxPixelSize = Self.maxPixelSize(for: proxy.size, displayScale: displayScale)
            let cachedImage = CachedImageLoader.cachedImage(for: path, maxPixelSize: maxPixelSize)
            Group {
                if let image = loader.image ?? cachedImage {
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
            .task(id: "\(path)|\(maxPixelSize)") {
                await loader.load(path, maxPixelSize: maxPixelSize)
            }
        }
    }

    private static func maxPixelSize(for size: CGSize, displayScale: CGFloat) -> Int {
        let longestSide = max(size.width, size.height)
        guard longestSide > 0 else { return 900 }
        return max(240, min(1024, Int((longestSide * displayScale).rounded(.up))))
    }
}

@MainActor
private final class CachedImageLoader: ObservableObject {
    @Published var image: NSImage?

    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 360
        cache.totalCostLimit = 160 * 1024 * 1024
        return cache
    }()
    private static var inFlightLoads: [NSString: Task<NSImage?, Never>] = [:]
    private var path: String = ""
    private var maxPixelSize: Int = 0
    private var task: Task<Void, Never>?

    static func cachedImage(for path: String, maxPixelSize: Int) -> NSImage? {
        cache.object(forKey: cacheKey(path: path, maxPixelSize: maxPixelSize))
    }

    func load(_ path: String, maxPixelSize: Int) async {
        task?.cancel()
        self.path = path
        self.maxPixelSize = maxPixelSize
        guard !path.isEmpty else {
            image = nil
            return
        }

        let key = Self.cacheKey(path: path, maxPixelSize: maxPixelSize)
        if let cached = Self.cache.object(forKey: key) {
            image = cached
            return
        }

        image = nil
        task = Task {
            let loaded = await Self.loadImage(at: path, maxPixelSize: maxPixelSize, cacheKey: key)
            guard !Task.isCancelled, self.path == path, self.maxPixelSize == maxPixelSize else { return }
            if let loaded {
                Self.cache.setObject(loaded, forKey: key, cost: Self.cacheCost(for: loaded))
            }
            image = loaded
        }
    }

    private static func loadImage(at path: String, maxPixelSize: Int, cacheKey: NSString) async -> NSImage? {
        if let task = inFlightLoads[cacheKey] {
            return await task.value
        }

        let task = Task.detached(priority: .utility) {
            decodeThumbnail(at: path, maxPixelSize: maxPixelSize)
        }
        inFlightLoads[cacheKey] = task
        let image = await task.value
        inFlightLoads[cacheKey] = nil
        return image
    }

    private nonisolated static func decodeThumbnail(at path: String, maxPixelSize: Int) -> NSImage? {
        let url = URL(fileURLWithPath: path)
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return nil
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private static func cacheKey(path: String, maxPixelSize: Int) -> NSString {
        let modification = ((try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date)?
            .timeIntervalSinceReferenceDate ?? 0
        return "\(path)|\(maxPixelSize)|\(modification)" as NSString
    }

    private static func cacheCost(for image: NSImage) -> Int {
        if let representation = image.representations.first {
            return max(1, representation.pixelsWide * representation.pixelsHigh * 4)
        }
        return max(1, Int(image.size.width * image.size.height * 4))
    }
}
