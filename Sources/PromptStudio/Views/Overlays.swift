import AVKit
import AppKit
import ImageIO
import SwiftUI
import PromptStudioCore
import UniformTypeIdentifiers

struct PreviewRailItem: Identifiable, Equatable {
    let id: String
    let item: PromptItem
    let isCurrent: Bool
    let positionIndex: Int

    init(item: PromptItem, isCurrent: Bool, positionIndex: Int) {
        self.id = item.id
        self.item = item
        self.isCurrent = isCurrent
        self.positionIndex = positionIndex
    }
}

enum PreviewStepDirection: Equatable {
    case previous
    case next
}

private enum ImmersivePreviewLayoutMetrics {
    static let contentInset: CGFloat = 42
}

struct ImmersivePreviewOverlay: View {
    @EnvironmentObject private var state: AppState
    let item: PromptItem
    let inspectorWidth: CGFloat
    let railItems: [PreviewRailItem]
    let onSelectRailItemID: (String) -> Void
    let onNavigateStep: (PreviewStepDirection) -> Void
    @State private var imageScale: CGFloat = 1.0
    @State private var imageOffset: CGSize = .zero
    @State private var previewPromptHovered = false
    @State private var previewPromptCopyFeedback = false
    @State private var lastPreviewStepDirection: PreviewStepDirection?
    @GestureState private var imageDragTranslation: CGSize = .zero

    init(
        item: PromptItem,
        inspectorWidth: CGFloat,
        railItems: [PreviewRailItem] = [],
        onSelectRailItemID: @escaping (String) -> Void = { _ in },
        onNavigateStep: @escaping (PreviewStepDirection) -> Void = { _ in }
    ) {
        self.item = item
        self.inspectorWidth = inspectorWidth
        self.railItems = railItems
        self.onSelectRailItemID = onSelectRailItemID
        self.onNavigateStep = onNavigateStep
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            StudioColor.appBackground
                .ignoresSafeArea()

            if item.isTextDocumentLike {
                MarkdownDocumentPreviewContent(
                    item: item,
                    inspectorWidth: inspectorWidth,
                    railItems: railItems,
                    onSelectRailItemID: selectPreviewRailItem,
                    onNavigateStep: navigatePreviewStep
                )
                    .environmentObject(state)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { proxy in
                    let showsRail = shouldShowRail(size: proxy.size)
                    let visibleRailItems = PreviewRailVisibleWindow.items(
                        from: railItems,
                        currentItemID: item.id,
                        availableHeight: proxy.size.height
                    )
                    let railThumbnailPrefetchIDs = PreviewRailVisibleWindow.prefetchItemIDs(
                        from: railItems,
                        currentItemID: item.id,
                        visibleItemIDs: visibleRailItems.map(\.id)
                    )
                    HStack(spacing: 0) {
                        previewMedia
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(.leading, 42)
                            .padding(.trailing, showsRail ? 18 : 34)
                            .padding(.vertical, ImmersivePreviewLayoutMetrics.contentInset)

                        if showsRail {
                            PreviewThumbnailRail(
                                items: visibleRailItems,
                                currentItemID: item.id,
                                onSelect: selectPreviewRailItem
                            )
                            .frame(width: PreviewThumbnailRail.railWidth)
                            .frame(maxHeight: .infinity)
                            .task(id: railThumbnailPrefetchIDs) {
                                DebugPerformanceProbe.record("preview.rail.thumbnail.prefetch.count", value: Double(railThumbnailPrefetchIDs.count))
                                state.prepareVisibleThumbnails(for: railThumbnailPrefetchIDs)
                            }
                        }

                        previewInspector
                            .frame(width: inspectorWidth)
                            .frame(maxHeight: .infinity)
                            .background(StudioColor.panel.opacity(0.96))
                            .overlay(alignment: .leading) {
                                Rectangle()
                                    .fill(StudioColor.hairline)
                                    .frame(width: 1)
                            }
                        }
                }

                if item.assetKind == .image {
                    PreviewZoomControl(
                        scale: imageScale,
                        onZoomOut: { adjustImageScale(by: -0.25) },
                        onZoomIn: { adjustImageScale(by: 0.25) },
                        onReset: { resetImageTransform() }
                    )
                    .padding(.leading, 56)
                    .padding(.bottom, 36)
                }
            }

        }
        .studioTopTrailingCloseButton(isPresented: !item.isTextDocumentLike) {
            state.isPreviewPresented = false
        }
        .transition(.opacity)
        .background {
            if !item.isTextDocumentLike {
                PreviewInputMonitor(
                    onExit: {
                        state.isPreviewPresented = false
                    },
                    onNavigateStep: navigatePreviewStep,
                    onZoom: { delta in
                        guard item.assetKind == .image else { return }
                        adjustImageScale(by: delta)
                    }
                )
            }
        }
        .onChange(of: item.id) { _, _ in
            resetImageTransform()
        }
        .task(id: previewImagePreloadPaths(currentID: item.id)) {
            await OverlayImageLoader.preload(paths: previewImagePreloadPaths(currentID: item.id))
        }
    }

    private func shouldShowRail(size: CGSize) -> Bool {
        !railItems.isEmpty && size.width >= 1_180 && size.height >= 620
    }

    private func adjustImageScale(by delta: CGFloat) {
        imageScale = min(3.0, max(0.25, imageScale + delta))
    }

    private func resetImageTransform() {
        imageScale = 1.0
        imageOffset = .zero
    }

    private func navigatePreviewStep(_ direction: PreviewStepDirection) {
        lastPreviewStepDirection = direction
        onNavigateStep(direction)
    }

    private func selectPreviewRailItem(_ itemID: String) {
        if let current = railItems.first(where: { $0.id == item.id })?.positionIndex,
           let target = railItems.first(where: { $0.id == itemID })?.positionIndex,
           target != current {
            lastPreviewStepDirection = target > current ? .next : .previous
        }
        onSelectRailItemID(itemID)
    }

    private func previewImagePreloadPaths(currentID: String) -> [String] {
        guard item.assetKind == .image,
              let currentIndex = railItems.firstIndex(where: { $0.id == currentID }) else {
            return []
        }

        let lowerPadding: Int
        let upperPadding: Int
        switch lastPreviewStepDirection {
        case .previous:
            lowerPadding = 6
            upperPadding = 2
        case .next:
            lowerPadding = 2
            upperPadding = 6
        case nil:
            lowerPadding = 3
            upperPadding = 3
        }
        let lowerBound = max(0, currentIndex - lowerPadding)
        let upperBound = min(railItems.count - 1, currentIndex + upperPadding)
        var paths: [String] = []
        var seen = Set<String>()
        for railItem in railItems[lowerBound...upperBound] where railItem.item.assetKind == .image {
            let path = railItem.item.assetPath
            guard !path.isEmpty, seen.insert(path).inserted else { continue }
            paths.append(path)
        }
        return paths
    }

    private var activeImageOffset: CGSize {
        CGSize(
            width: imageOffset.width + imageDragTranslation.width,
            height: imageOffset.height + imageDragTranslation.height
        )
    }

    @ViewBuilder
    private var previewMedia: some View {
        if item.assetKind == .video {
            OverlayVideoPlayer(path: item.assetPath)
        } else if item.assetKind == .audio {
            AudioPreviewPlayer(item: item)
        } else if item.assetKind == .image {
            OverlayImagePreview(path: item.assetPath, scale: imageScale, offset: activeImageOffset)
                .contentShape(Rectangle())
                .gesture(imagePanGesture)
        } else {
            PreviewDocumentBlock(title: item.title, text: textSummary(for: item), minHeight: 520)
                .frame(maxWidth: 820)
        }
    }

    private var imagePanGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($imageDragTranslation) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                imageOffset.width += value.translation.width
                imageOffset.height += value.translation.height
            }
    }

    private var previewInspector: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(item.title)
                .font(StudioFont.font(15, weight: .semibold))
                .foregroundStyle(StudioColor.text)
                .lineLimit(3)

            previewTopChips

            if !item.referenceAssets.isEmpty {
                previewReferenceSection
            }

            HStack(alignment: .center, spacing: 10) {
                SidePanelSectionTitle(title: "Prompt")

                Spacer()

                SidePanelActionRow(actions: previewPromptActions)
            }

            previewPromptContent
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.top, ImmersivePreviewLayoutMetrics.contentInset)
        .padding(.horizontal, 24)
        .padding(.bottom, 28)
    }

    @ViewBuilder
    private var previewPromptContent: some View {
        if previewHasPrompt {
            GeometryReader { proxy in
                previewPromptBox(maxHeight: proxy.size.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        } else {
            Text("暂无提示词")
                .font(StudioFont.font(12))
                .foregroundStyle(StudioColor.tertiaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private func previewPromptBox(maxHeight: CGFloat) -> some View {
        GeometryReader { _ in
            SidePanelPromptTextBox(
                text: previewPromptText,
                maxHeight: maxHeight,
                resetID: item.id,
                isPlaceholder: !previewHasPrompt,
                isInteractive: previewHasPrompt,
                isHovered: previewPromptHovered,
                copyFeedback: previewPromptCopyFeedback,
                onCopyAll: copyPreviewPrompt,
                onCopySelection: copyPreviewPromptFragment
            )
        }
        .frame(maxWidth: .infinity)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovering in
            previewPromptHovered = hovering
        }
    }

    private var previewPromptText: String {
        let prompt = item.currentVersion?.prompt.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return prompt.isEmpty ? "暂无 Prompt" : prompt
    }

    private var previewHasPrompt: Bool {
        !(item.currentVersion?.prompt.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
    }

    private func copyPreviewPrompt() {
        state.copySelectedPrompt()
        previewPromptCopyFeedback = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            previewPromptCopyFeedback = false
        }
    }

    private func copyPreviewPromptFragment(_ fragment: String) {
        state.copyPromptFragment(fragment)
        previewPromptCopyFeedback = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            previewPromptCopyFeedback = false
        }
    }

    private var previewTopChips: some View {
        SidePanelChipFlow(texts: previewTopChipTexts)
    }

    private var previewReferenceSection: some View {
        SidePanelReferenceSection(references: item.referenceAssets)
    }

    private var previewBottomChips: some View {
        SidePanelChipFlow(texts: previewBottomChipTexts, spacing: 10)
    }

    private var previewReferenceColumns: [GridItem] {
        Array(repeating: GridItem(.fixed(62), spacing: 8), count: 4)
    }

    private var previewTopChipTexts: [String] {
        [
            item.format.isEmpty ? item.assetKind.displayName : item.format.uppercased(),
            item.displaySize,
            item.currentVersion?.version ?? "V1.0",
            item.tags.first ?? item.category
        ]
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .prefix(4)
        .map { $0 }
    }

    private var previewBottomChipTexts: [String] {
        [
            item.currentVersion?.version ?? "V1.0",
            item.format.isEmpty ? item.assetKind.displayName : item.format.uppercased(),
            item.displayAspectRatio,
            item.tags.first ?? item.category
        ].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var previewPromptActions: [SidePanelAction] {
        [
            SidePanelAction(icon: .pencil, help: "编辑") {
                state.requestInlineEdit(item)
            },
            SidePanelAction(icon: .copy, help: "复制提示词") {
                state.copySelectedPrompt()
            },
            SidePanelAction(icon: .circleArrowDown, help: "下载") {
                state.isPreviewPresented = false
                state.modal = .export
            },
            SidePanelAction(icon: .history, help: "历史版本") {
                state.isPreviewPresented = false
                state.modal = .versionHistory
            }
        ]
    }

    private func textSummary(for item: PromptItem) -> String {
        guard item.canExtractPromptFromAsset else {
            return fileFallbackSummary(for: item)
        }
        if let text = AppKitBridge.readDocumentText(from: URL(fileURLWithPath: item.assetPath)) {
            let trimmed = String(text.prefix(8_000)).trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? fileFallbackSummary(for: item) : trimmed
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: item.assetPath), options: [.mappedIfSafe]) else {
            return fileFallbackSummary(for: item)
        }
        let previewData = Data(data.prefix(8_000))
        let text = String(data: previewData, encoding: .utf8)
            ?? String(data: previewData, encoding: .utf16)
            ?? String(data: previewData, encoding: .isoLatin1)
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fileFallbackSummary(for: item) : trimmed
    }

    private func fileFallbackSummary(for item: PromptItem) -> String {
        switch item.previewMode {
        case .audio:
            return "音频文件，可通过默认应用播放，也可以作为音色、旁白或音乐 Prompt 参考。"
        case .document:
            return "\(item.assetKind.displayName) 文件，可通过默认应用或系统预览打开。"
        case .reference:
            return "\(item.assetKind.displayName) 参考资产已入库，可管理标签、Prompt 和文件路径。"
        case .generic:
            return "通用文件已入库，可通过默认应用打开。"
        case .image, .video, .textDocument:
            return "\(item.assetKind.displayName) 文件无可读取文本摘要。"
        }
    }
}

private struct MarkdownDocumentPreviewContent: View {
    @EnvironmentObject private var state: AppState
    let item: PromptItem
    let inspectorWidth: CGFloat
    let railItems: [PreviewRailItem]
    let onSelectRailItemID: (String) -> Void
    let onNavigateStep: (PreviewStepDirection) -> Void
    @State private var text = ""
    @State private var savedText = ""
    @State private var loadedItemID = ""
    @State private var showCloseConfirmation = false

    private var isEditing: Bool {
        state.markdownEditorItemID == item.id
    }

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                let showsRail = !isEditing && shouldShowRail(size: proxy.size)
                let visibleRailItems = PreviewRailVisibleWindow.items(
                    from: railItems,
                    currentItemID: item.id,
                    availableHeight: proxy.size.height
                )
                let railThumbnailPrefetchIDs = PreviewRailVisibleWindow.prefetchItemIDs(
                    from: railItems,
                    currentItemID: item.id,
                    visibleItemIDs: visibleRailItems.map(\.id)
                )
                HStack(spacing: 0) {
                    editorPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.leading, 42)
                        .padding(.trailing, showsRail ? 18 : 34)
                        .padding(.vertical, ImmersivePreviewLayoutMetrics.contentInset)

                    if showsRail {
                        PreviewThumbnailRail(
                            items: visibleRailItems,
                            currentItemID: item.id,
                            onSelect: onSelectRailItemID
                        )
                        .frame(width: PreviewThumbnailRail.railWidth)
                        .frame(maxHeight: .infinity)
                        .task(id: railThumbnailPrefetchIDs) {
                            DebugPerformanceProbe.record("preview.rail.thumbnail.prefetch.count", value: Double(railThumbnailPrefetchIDs.count))
                            state.prepareVisibleThumbnails(for: railThumbnailPrefetchIDs)
                        }
                    }

                    inspectorPane
                        .frame(width: inspectorWidth)
                        .frame(maxHeight: .infinity)
                        .background(StudioColor.panel.opacity(0.96))
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(StudioColor.hairline)
                                .frame(width: 1)
                        }
                }
            }

        }
        .studioTopTrailingCloseButton(help: isEditing ? "取消" : "关闭") {
            requestClose()
        }
        .foregroundStyle(StudioColor.text)
        .transaction { transaction in
            transaction.animation = nil
        }
        .onAppear(perform: loadText)
        .onChange(of: item.id) { _, _ in loadText() }
        .confirmationDialog("放弃未保存的修改？", isPresented: $showCloseConfirmation) {
            Button("放弃修改", role: .destructive) {
                text = savedText
                state.closeMarkdownEditor(returnToPreview: true)
            }
            Button("继续编辑", role: .cancel) {}
        }
        .background {
            if isEditing {
                MarkdownEditorKeyMonitor(
                    onEscape: requestClose,
                    onSave: save
                )
            } else {
                PreviewInputMonitor(
                    onExit: requestClose,
                    onNavigateStep: onNavigateStep,
                    onZoom: { _ in }
                )
            }
        }
    }

    private func shouldShowRail(size: CGSize) -> Bool {
        !railItems.isEmpty && size.width >= 1_180 && size.height >= 620
    }

    private var editorPane: some View {
        ZStack(alignment: .topLeading) {
            MarkdownDocumentEditor(
                text: $text,
                isEditable: isEditing,
                scrollResetID: item.id,
                contentFontSize: 13,
                syntaxMode: TextSyntaxMode.infer(for: item),
                onBoundaryScroll: isEditing ? nil : onNavigateStep
            )

            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(isEditing ? "开始编写文档内容" : "暂无文档信息")
                    .font(StudioFont.font(13))
                    .foregroundStyle(StudioColor.tertiaryText)
                    .padding(.leading, MarkdownDocumentLayout.placeholderLeadingPadding)
                    .padding(.top, 18)
                    .allowsHitTesting(false)
            }
        }
    }

    private var inspectorPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(item.title)
                    .font(StudioFont.font(15, weight: .semibold))
                    .foregroundStyle(StudioColor.text)
                    .lineLimit(3)

                metadataChips

                HStack(alignment: .center, spacing: 12) {
                    sectionTitle("文档信息")
                    Spacer(minLength: 12)

                    HStack(spacing: 10) {
                        if isEditing {
                            documentSystemActionButton(
                                "checkmark",
                                help: "保存",
                                action: save
                            )
                            documentSystemActionButton("xmark", help: "取消编辑", action: requestClose)
                        } else {
                            documentActionButton(.pencil, help: "编辑") {
                                state.requestInlineEdit(item)
                            }
                            documentActionButton(.copy, help: "复制文档信息") {
                                state.copyMarkdownDocumentText(text)
                            }
                            documentActionButton(.circleArrowDown, help: "下载") {
                                state.isPreviewPresented = false
                                state.modal = .export
                            }
                            documentActionButton(.history, help: "历史版本") {
                                state.isPreviewPresented = false
                                state.modal = .versionHistory
                            }
                        }
                    }
                }
                .padding(.top, 6)

                documentFileInfo
            }
            .padding(.top, ImmersivePreviewLayoutMetrics.contentInset)
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .transparentScrollArea()
    }

    private var metadataChips: some View {
        FlowLayout(spacing: 8) {
            documentMetadataChip(item.format.isEmpty ? "MD" : item.format.uppercased())
            documentMetadataChip("\(lineCount) 行")
            documentMetadataChip(fileSizeText(item.fileSize))
            documentMetadataChip(item.currentVersion?.version ?? "V1.0")
            ForEach(item.tags.prefix(4), id: \.self) { tag in
                documentMetadataChip(tag)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var lineCount: Int {
        max(1, text.components(separatedBy: .newlines).count)
    }

    private func documentMetadataChip(_ text: String) -> some View {
        Text(text)
            .font(StudioFont.font(11))
            .foregroundStyle(StudioColor.secondaryText)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(StudioColor.control))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(StudioColor.hairline, lineWidth: 1))
    }

    private var documentFileInfo: some View {
        VStack(alignment: .leading, spacing: 8) {
            infoLine("格式", item.format.isEmpty ? "MD" : item.format.uppercased())
            infoLine("行数", "\(lineCount) 行")
            infoLine("大小", fileSizeText(item.fileSize))
            infoLine("文件名", URL(fileURLWithPath: item.assetPath).lastPathComponent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func documentActionButton(_ kind: LucideIcon.Kind, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            LucideIcon(kind: kind)
                .frame(width: 14, height: 14)
        }
        .buttonStyle(IconCircleButtonStyle())
        .help(help)
        .accessibilityLabel(help)
    }

    private func documentSystemActionButton(
        _ systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 14, height: 14)
        }
        .buttonStyle(IconCircleButtonStyle())
        .help(help)
        .accessibilityLabel(help)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(StudioFont.caption(12))
            .tracking(1.2)
            .foregroundStyle(StudioColor.secondaryText)
    }

    private func infoLine(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text("\(title)：")
                .font(StudioFont.font(11))
                .foregroundStyle(StudioColor.tertiaryText)
                .fixedSize(horizontal: true, vertical: false)
            Text(value)
                .font(StudioFont.font(13))
                .foregroundStyle(StudioColor.text)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func loadText() {
        guard loadedItemID != item.id else { return }
        let documentText = state.markdownDocumentText(for: item)
        text = documentText
        savedText = documentText
        loadedItemID = item.id
    }

    private func save() {
        guard text != savedText else {
            state.showToast("内容已保存")
            state.closeMarkdownEditor(returnToPreview: true)
            return
        }
        state.saveMarkdownDocument(text, for: item)
        savedText = text
        state.closeMarkdownEditor(returnToPreview: true)
    }

    private func requestClose() {
        guard isEditing else {
            state.isPreviewPresented = false
            return
        }

        if text == savedText {
            state.closeMarkdownEditor(returnToPreview: true)
        } else {
            showCloseConfirmation = true
        }
    }

    private func fileSizeText(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 KB" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private enum CreateComposerInputField: Hashable {
    case title
    case prompt
}

private enum SmartPasteLayoutMetrics {
    static let smartPasteBarHeight: CGFloat = 44
    static let smartPastePromptHeightBudget: CGFloat = 218
    static let regularPromptHeightBudget: CGFloat = 166
}

struct PromptComposerOverlay: View {
    @EnvironmentObject private var state: AppState
    let mode: AppState.PromptComposerMode
    @State private var title = ""
    @State private var typeDecision = PromptComposerTypeDecision.unresolved(reason: "请输入 Prompt 后自动识别")
    @State private var typeMode: PromptComposerTypeMode = .automatic
    @State private var modelId: String?
    @State private var modelHint: String?
    @State private var formatHint: String?
    @State private var prompt = ""
    @State private var negativePrompt = ""
    @State private var tags: [String] = []
    @State private var tagDraft = ""
    @State private var parameters = ""
    @State private var note = ""
    @State private var saveAsNewVersion = true
    @State private var previewImageURL: URL?
    @State private var referenceURLs: [URL] = []
    @State private var initialSignature = ""
    @State private var showCloseConfirmation = false
    @State private var isPreviewImageDropTarget = false
    @State private var isReferenceDropTarget = false
    @State private var isPreviewImageHovered = false
    @State private var isReferenceHovered = false
    @State private var smartPasteInterpretation: PromptClipboardInterpretation?
    @State private var smartPasteAppliedPrompt: String?
    @State private var pendingSmartPasteInterpretation: PromptClipboardInterpretation?
    @State private var smartPasteSnapshot: PromptComposerDraftSnapshot?
    @State private var showSmartPasteDetails = false
    @State private var showSmartPasteReplaceConfirmation = false
    @FocusState private var focusedCreateInput: CreateComposerInputField?

    private struct PromptComposerDraftSnapshot {
        let title: String
        let typeDecision: PromptComposerTypeDecision
        let typeMode: PromptComposerTypeMode
        let modelId: String?
        let modelHint: String?
        let formatHint: String?
        let prompt: String
        let negativePrompt: String
        let tags: [String]
        let tagDraft: String
        let parameters: String
        let note: String
        let saveAsNewVersion: Bool
        let previewImageURL: URL?
        let referenceURLs: [URL]
        let smartPasteInterpretation: PromptClipboardInterpretation?
        let smartPasteAppliedPrompt: String?
    }

    private var editingItem: PromptItem? {
        if case .edit = mode {
            return state.selectedItem
        }
        return nil
    }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var resolvedType: PromptType? {
        typeDecision.type
    }

    private var canSubmitPrompt: Bool {
        resolvedType != nil
    }

    private var shouldShowPreviewImage: Bool {
        resolvedType != .text
    }

    private var typeStatusTitle: String {
        switch typeDecision {
        case .automatic(let type, _, _):
            return "已识别：\(typeTitle(type))"
        case .manual(let type):
            return "已选择：\(typeTitle(type))"
        case .unresolved:
            return "请选择类型"
        }
    }

    private var typeStatusIcon: String {
        switch typeDecision {
        case .automatic:
            return "wand.and.stars"
        case .manual:
            return "checkmark.circle"
        case .unresolved:
            return "questionmark.circle"
        }
    }

    private var typeModeSignature: String {
        switch typeMode {
        case .automatic:
            return "automatic"
        case .manual(let type):
            return "manual:\(type.rawValue)"
        }
    }

    private var automaticInferenceTaskID: String {
        if smartPasteInterpretation != nil, prompt == smartPasteAppliedPrompt {
            return "smart-paste-managed"
        }
        return prompt
    }

    var body: some View {
        createComposerBody
        .foregroundStyle(OPSColor.bodyText)
        .transition(.opacity)
        .onAppear(perform: loadDraft)
        .onChange(of: mode.id) { _, _ in loadDraft() }
        .onChange(of: state.pendingSmartPasteRequest?.token) { _, _ in
            handlePendingSmartPasteRequest()
        }
        .task(id: automaticInferenceTaskID) {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            updateAutomaticTypeDecision()
        }
        .confirmationDialog("放弃未保存的修改？", isPresented: $showCloseConfirmation) {
            Button("放弃修改", role: .destructive) {
                state.closePromptComposer()
            }
            Button("继续编辑", role: .cancel) {}
        }
        .confirmationDialog("覆盖当前草稿？", isPresented: $showSmartPasteReplaceConfirmation) {
            Button("覆盖并智能填充", role: .destructive) {
                guard let pendingSmartPasteInterpretation else { return }
                self.pendingSmartPasteInterpretation = nil
                applySmartPaste(pendingSmartPasteInterpretation)
            }
            Button("取消", role: .cancel) {
                pendingSmartPasteInterpretation = nil
            }
        } message: {
            Text("当前草稿已有内容，覆盖前会保留完整快照，可用“撤销填充”恢复。")
        }
        .background {
            EscapeKeyMonitor {
                requestClose()
            }
        }
        .studioTopTrailingCloseButton {
            requestClose()
        }
    }

    private var createComposerBody: some View {
        GeometryReader { geometry in
            let previewWidth: CGFloat = geometry.size.width >= 1_700 ? 420 : 360
            let workspaceWidth = max(720, geometry.size.width - previewWidth)

            HStack(spacing: 0) {
                createWorkspacePane
                    .frame(width: workspaceWidth, height: geometry.size.height)
                createPreviewPane
                    .frame(width: previewWidth)
                    .frame(maxHeight: .infinity)
            }
        }
        .background(StudioColor.appBackground)
    }

    private var createWorkspacePane: some View {
        GeometryReader { geometry in
            let horizontalPadding: CGFloat = 36
            let verticalPadding: CGFloat = 32
            let headerHeight: CGFloat = 40
            let headerGap: CGFloat = 22
            let columnSpacing: CGFloat = geometry.size.width >= 1_250 ? 32 : 24
            let panelWidth = max(0, geometry.size.width - horizontalPadding * 2)
            let panelHeight = max(0, geometry.size.height - verticalPadding * 2 - headerHeight - headerGap)
            let contentWidth = panelWidth
            let contentHeight = panelHeight
            let uploadWidth = min(320, max(280, contentWidth * 0.28))
            let leftWidth = max(0, contentWidth - columnSpacing - uploadWidth)
            let promptHeightBudget = isEditing
                ? SmartPasteLayoutMetrics.regularPromptHeightBudget
                : SmartPasteLayoutMetrics.smartPastePromptHeightBudget
            let promptHeight = max(240, contentHeight - promptHeightBudget)

            ZStack {
                CreateComposerColor.workspace
                    .ignoresSafeArea()

                VStack(alignment: .leading, spacing: headerGap) {
                    HStack(alignment: .center) {
                        Text(composerTitle)
                            .font(StudioFont.font(16, weight: .semibold))
                            .foregroundStyle(CreateComposerColor.primaryText)
                        Spacer()
                        Button(primaryActionTitle) {
                            save()
                        }
                        .buttonStyle(CreateComposerPrimaryButtonStyle())
                        .disabled(!canSubmitPrompt)
                    }
                    .frame(width: panelWidth, height: headerHeight, alignment: .center)

                    HStack(alignment: .top, spacing: columnSpacing) {
                        VStack(alignment: .leading, spacing: 22) {
                            createHeaderControls(width: leftWidth)
                                .frame(width: leftWidth, alignment: .leading)

                            createPromptColumn(promptHeight: promptHeight)
                                .frame(width: leftWidth, alignment: .topLeading)
                        }

                        createUploadColumn(availableHeight: contentHeight)
                            .frame(width: uploadWidth, alignment: .topLeading)
                            .overlay(alignment: .leading) {
                                Rectangle()
                                    .fill(StudioColor.hairline)
                                    .frame(width: 1, height: contentHeight)
                                    .offset(x: -columnSpacing / 2)
                            }
                    }
                    .frame(width: contentWidth, height: contentHeight, alignment: .topLeading)
                }
                .frame(width: panelWidth, height: headerHeight + headerGap + panelHeight, alignment: .topLeading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
    }

    private func createHeaderControls(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            createTypeStatusMenu
                .frame(width: width, alignment: .leading)

            if !isEditing {
                smartPasteBar
                    .frame(width: width, height: SmartPasteLayoutMetrics.smartPasteBarHeight)
            }
        }
    }

    private var smartPasteBar: some View {
        HStack(spacing: 9) {
            Image(systemName: smartPasteInterpretation == nil ? "doc.on.clipboard" : "wand.and.stars")
                .font(StudioFont.symbol(14, weight: .medium))
                .foregroundStyle(CreateComposerColor.primaryText)

            VStack(alignment: .leading, spacing: 1) {
                Text(smartPasteInterpretation == nil
                     ? "粘贴 Prompt 文本 ⌘V"
                     : "已智能填充 · \(smartPasteFieldCount) 个字段")
                    .font(StudioFont.font(12, weight: .semibold))
                    .foregroundStyle(CreateComposerColor.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(smartPasteInterpretation == nil
                     ? "从剪贴板识别标题、Prompt、标签和参数"
                     : smartPasteSuggestion)
                    .font(StudioFont.font(10))
                    .foregroundStyle(CreateComposerColor.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(smartPasteInterpretation == nil ? "粘贴" : "重新粘贴") {
                requestSmartPaste()
            }
            .buttonStyle(.plain)
            .font(StudioFont.font(11, weight: .semibold))
            .foregroundStyle(CreateComposerColor.primaryText)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(CreateComposerColor.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(CreateComposerColor.border, lineWidth: 1))
            .accessibilityLabel(smartPasteInterpretation == nil ? "粘贴 Prompt 文本" : "重新粘贴 Prompt 文本")
            .accessibilityHint("从剪贴板读取并解析 Prompt 文本")

            if smartPasteInterpretation != nil {
                Menu {
                    Button("查看原文与识别详情") {
                        showSmartPasteDetails = true
                    }
                    Button("撤销填充") {
                        undoSmartPaste()
                    }
                    Divider()
                    Button("清除智能填充") {
                        clearSmartPaste()
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(StudioFont.symbol(13, weight: .semibold))
                        .foregroundStyle(CreateComposerColor.secondaryText)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("智能粘贴更多操作")
                .accessibilityHint("查看详情、撤销或清除智能填充")
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CreateComposerColor.documentBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(CreateComposerColor.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .popover(isPresented: $showSmartPasteDetails) {
            smartPasteDetails
        }
    }

    private var smartPasteDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("智能粘贴详情")
                    .font(StudioFont.font(14, weight: .semibold))
                    .foregroundStyle(CreateComposerColor.primaryText)
                Spacer()
                Button("关闭") {
                    showSmartPasteDetails = false
                }
                .buttonStyle(.plain)
                .font(StudioFont.font(11))
                .foregroundStyle(CreateComposerColor.secondaryText)
                .accessibilityLabel("关闭智能粘贴详情")
            }

            if let interpretation = smartPasteInterpretation {
                Text("原始文本")
                    .font(StudioFont.font(11, weight: .semibold))
                    .foregroundStyle(CreateComposerColor.secondaryText)
                ScrollView {
                    Text(interpretation.originalText)
                        .font(StudioFont.font(11))
                        .foregroundStyle(CreateComposerColor.primaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .accessibilityLabel("原始剪贴板文本")
                }
                .frame(maxWidth: .infinity, minHeight: 96, maxHeight: 140, alignment: .topLeading)
                .padding(8)
                .background(CreateComposerColor.fieldBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                Text("Negative Prompt")
                    .font(StudioFont.font(11, weight: .semibold))
                    .foregroundStyle(CreateComposerColor.secondaryText)
                TextEditor(text: $negativePrompt)
                    .font(StudioFont.font(11))
                    .foregroundStyle(CreateComposerColor.primaryText)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 72)
                    .background(CreateComposerColor.fieldBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .accessibilityLabel("负面提示词")
                    .accessibilityHint("编辑智能粘贴识别出的负面提示词")

                Text("标签")
                    .font(StudioFont.font(11, weight: .semibold))
                    .foregroundStyle(CreateComposerColor.secondaryText)
                tagEditor
                    .accessibilityElement(children: .contain)

                Text("参数")
                    .font(StudioFont.font(11, weight: .semibold))
                    .foregroundStyle(CreateComposerColor.secondaryText)
                TextEditor(text: $parameters)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(CreateComposerColor.primaryText)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 72)
                    .background(CreateComposerColor.fieldBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .accessibilityLabel("Prompt 参数")
                    .accessibilityHint("每行编辑一个 key=value 参数")
            } else {
                Text("尚未进行智能粘贴")
                    .font(StudioFont.font(12))
                    .foregroundStyle(CreateComposerColor.secondaryText)
            }
        }
        .padding(16)
        .frame(width: 380)
        .background(CreateComposerColor.workspace)
    }

    private func createPromptColumn(promptHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            createField("标题") {
                createTextInput("请输入标题", text: $title)
            }

            createField("Prompt（提示词）") {
                createPromptTextArea(height: promptHeight)
            }
        }
    }

    private func createUploadColumn(availableHeight: CGFloat) -> some View {
        let showsPreviewImage = shouldShowPreviewImage
        let previewHeight = showsPreviewImage ? min(236, max(180, availableHeight * 0.30)) : 0
        let referenceHeight = showsPreviewImage
            ? min(280, max(180, availableHeight - previewHeight - 82))
            : min(420, max(240, availableHeight - 30))
        return VStack(alignment: .leading, spacing: 22) {
            if showsPreviewImage {
                createField("预览图") {
                    previewImageDropZone(height: previewHeight)
                }
            }

            createField("参考资产") {
                referenceImagesDropZone(height: referenceHeight)
            }
        }
    }

    private var createTypeStatusMenu: some View {
        Menu {
            ForEach(PromptType.allCases) { option in
                Button(typeTitle(option)) {
                    chooseTypeManually(option)
                }
            }
            if case .manual = typeDecision {
                Divider()
                Button("恢复自动识别") {
                    typeMode = .automatic
                    updateAutomaticTypeDecision()
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: typeStatusIcon)
                    .font(StudioFont.symbol(12, weight: .semibold))
                Text(typeStatusTitle)
                    .font(StudioFont.font(12, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(StudioFont.symbol(9, weight: .semibold))
            }
            .foregroundStyle(resolvedType == nil ? StudioColor.primaryAction : CreateComposerColor.primaryText)
            .padding(.horizontal, 11)
            .frame(height: 32)
            .background(CreateComposerColor.inputBackground)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(CreateComposerColor.border, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(typeStatusTitle)
        .accessibilityHint("选择 Prompt 类型或恢复自动识别")
    }


    private func createField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(StudioFont.font(12, weight: .semibold))
                .foregroundStyle(CreateComposerColor.secondaryText)
            content()
        }
    }

    private func createTextInput(_ placeholder: String, text: Binding<String>) -> some View {
        ZStack(alignment: .leading) {
            if text.wrappedValue.isEmpty && focusedCreateInput != .title {
                Text(placeholder)
                    .font(StudioFont.font(13))
                    .foregroundStyle(CreateComposerColor.placeholderText)
                    .padding(.leading, 16)
                    .allowsHitTesting(false)
            }
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(StudioFont.font(13))
                .foregroundStyle(CreateComposerColor.primaryText)
                .padding(.horizontal, 16)
                .focused($focusedCreateInput, equals: .title)
        }
        .frame(height: 42)
        .background(CreateComposerColor.fieldBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(CreateComposerColor.border, lineWidth: 1))
    }

    private func createPromptTextArea(height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            if prompt.isEmpty && focusedCreateInput != .prompt {
                Text("请输入提示词内容")
                    .font(StudioFont.font(13))
                    .foregroundStyle(CreateComposerColor.placeholderText)
                    .padding(.leading, 14)
                    .padding(.top, 14)
                    .allowsHitTesting(false)
            }
            TransparentOverlayTextEditor(
                text: $prompt,
                font: NSFont.systemFont(ofSize: 13, weight: .regular),
                textColor: NSColor(CreateComposerColor.primaryText),
                insertionPointColor: NSColor(CreateComposerColor.primaryText),
                textContainerInset: NSSize(width: 14, height: 14),
                lineSpacing: 4
            )
                .frame(height: height)
        }
        .background(CreateComposerColor.fieldBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(CreateComposerColor.border, lineWidth: 1))
    }

    private func previewImageDropZone(height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isPreviewImageDropTarget || isPreviewImageHovered ? CreateComposerColor.dropActive : CreateComposerColor.documentBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            isPreviewImageDropTarget ? StudioColor.primaryAction.opacity(0.55) : CreateComposerColor.border,
                            style: StrokeStyle(lineWidth: 1, dash: previewImageURL == nil ? [6, 5] : [])
                        )
                )

            if let previewImageURL {
                GeometryReader { proxy in
                    ZStack(alignment: .topTrailing) {
                        ComposerPreviewImage(path: previewImageURL.path, contentMode: .fit)
                            .frame(
                                width: max(0, proxy.size.width - 36),
                                height: max(0, proxy.size.height - 36)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

                        if !isEditing {
                            composerRemoveButton {
                                self.previewImageURL = nil
                            }
                            .padding(14)
                        }
                    }
                }
            } else if isEditing {
                createUploadPlaceholder("当前素材无预览图")
            } else {
                Button {
                    setPreviewImage(AppKitBridge.chooseReferenceImages())
                } label: {
                    createUploadPlaceholder("添加预览图")
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: height)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isPreviewImageHovered = $0 }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isPreviewImageDropTarget, perform: handlePreviewImageDrop)
    }

    private func referenceImagesDropZone(height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isReferenceDropTarget || isReferenceHovered ? CreateComposerColor.dropActive : CreateComposerColor.documentBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            isReferenceDropTarget ? StudioColor.primaryAction.opacity(0.55) : CreateComposerColor.border,
                            style: StrokeStyle(
                                lineWidth: 1,
                                dash: existingReferenceAssets.isEmpty && referenceURLs.isEmpty ? [6, 5] : []
                            )
                        )
                )

            if existingReferenceAssets.isEmpty && referenceURLs.isEmpty {
                Button {
                    appendReferenceImages(AppKitBridge.chooseReferenceAssets())
                } label: {
                    createUploadPlaceholder("添加参考资产")
                }
                .buttonStyle(.plain)
            } else {
                LazyVGrid(columns: createReferenceColumns, alignment: .leading, spacing: 12) {
                    ForEach(existingReferenceAssets) { reference in
                        ComposerUploadThumb(reference: reference, width: 96, height: 78, removable: false)
                    }
                    ForEach(referenceURLs, id: \.path) { url in
                        ComposerUploadThumb(path: url.path, width: 96, height: 78) {
                            referenceURLs.removeAll { $0 == url }
                        }
                    }
                    Button {
                        appendReferenceImages(AppKitBridge.chooseReferenceAssets())
                    } label: {
                        Image(systemName: "plus")
                            .font(StudioFont.symbol(16, weight: .medium))
                            .foregroundStyle(CreateComposerColor.primaryText)
                            .frame(width: 96, height: 78)
                            .background(CreateComposerColor.inputBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(CreateComposerColor.border, style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(14)
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isReferenceHovered = $0 }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isReferenceDropTarget, perform: handleReferenceDrop)
    }

    private func createUploadPlaceholder(_ text: String) -> some View {
        VStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill(CreateComposerColor.inputBackground)
                    .frame(width: 38, height: 38)
                Image(systemName: "plus")
                    .font(StudioFont.symbol(14, weight: .medium))
                    .foregroundStyle(CreateComposerColor.primaryText)
            }
            Text(text)
                .font(StudioFont.font(12, weight: .medium))
                .foregroundStyle(CreateComposerColor.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var createPreviewPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("实时预览")
                        .font(StudioFont.font(15, weight: .semibold))
                        .foregroundStyle(StudioColor.text)
                    Text(isEditing ? "编辑 Prompt" : "新建 Prompt")
                        .font(StudioFont.font(11))
                        .foregroundStyle(StudioColor.tertiaryText)
                }
                Spacer()
            }

            if hasMeaningfulPreviewContent {
                if hasTitle {
                    Text(previewTitle)
                        .font(StudioFont.font(15, weight: .semibold))
                        .foregroundStyle(StudioColor.text)
                        .lineLimit(3)
                }

                if shouldShowPreviewImage, let previewImageURL {
                    ComposerPreviewImage(path: previewImageURL.path, contentMode: .fit)
                        .frame(width: previewImageSize.width, height: previewImageSize.height)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(StudioColor.hairline, lineWidth: 1)
                        )
                }

                if !previewMetadataChips.isEmpty {
                    SidePanelChipFlow(texts: previewMetadataChips)
                }

                if !allReferencePreviewAssets.isEmpty {
                    createPreviewReferenceSection
                }

                if hasPrompt {
                    SidePanelSectionTitle(title: "Prompt")
                        .padding(.top, allReferencePreviewAssets.isEmpty ? 6 : 12)

                    GeometryReader { proxy in
                        createPromptPreviewBox(maxHeight: proxy.size.height)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                }
            } else {
                if !previewMetadataChips.isEmpty {
                    SidePanelChipFlow(texts: previewMetadataChips)
                }

                Rectangle()
                    .fill(StudioColor.hairline)
                    .frame(height: 1)

                VStack(spacing: 12) {
                    Image(systemName: "rectangle.and.pencil.and.ellipsis")
                        .font(StudioFont.symbol(24, weight: .regular))
                        .foregroundStyle(StudioColor.tertiaryText)
                    Text("尚无预览内容")
                        .font(StudioFont.font(12, weight: .medium))
                        .foregroundStyle(StudioColor.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 32)
        .padding(.horizontal, 24)
        .padding(.bottom, 28)
        .background(StudioColor.panel)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(StudioColor.hairline)
                .frame(width: 1)
        }
    }

    private var createPreviewReferenceSection: some View {
        SidePanelReferenceSection(references: allReferencePreviewAssets)
        .padding(.bottom, 4)
    }

    private var hasTitle: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private var hasPrompt: Bool {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private var hasMeaningfulPreviewContent: Bool {
        hasTitle || hasPrompt || (shouldShowPreviewImage && previewImageURL != nil) || !allReferencePreviewAssets.isEmpty
    }

    private var previewImageSize: CGSize {
        let maxHeight: CGFloat = 80
        let maxWidth: CGFloat = 260
        let aspectRatio: CGFloat
        if let previewImageInfo, previewImageInfo.width > 0, previewImageInfo.height > 0 {
            aspectRatio = max(0.15, CGFloat(previewImageInfo.width) / CGFloat(previewImageInfo.height))
        } else {
            aspectRatio = 16.0 / 9.0
        }
        let widthAtMaxHeight = maxHeight * aspectRatio
        if widthAtMaxHeight <= maxWidth {
            return CGSize(width: widthAtMaxHeight, height: maxHeight)
        }
        return CGSize(width: maxWidth, height: maxWidth / aspectRatio)
    }

    private func createPromptPreviewBox(maxHeight: CGFloat) -> some View {
        GeometryReader { _ in
            SidePanelPromptTextBox(
                text: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                maxHeight: maxHeight,
                isPlaceholder: prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Text("OPS/OpenPromptStudio")
                    .font(.custom("JetBrains Mono", size: 14))
                    .foregroundStyle(OPSColor.mutedText)
                Image(systemName: "seal")
                    .font(StudioFont.symbol(13))
                    .foregroundStyle(OPSColor.mutedText)
            }

            Spacer()

            Button {
                state.toast = "提示词词典将在后续接入"
            } label: {
                Text("提示词词典")
            }
            .buttonStyle(.plain)
            .font(StudioFont.font(13))
            .foregroundStyle(Color(hex: 0x5352C6))

            Button {
                save()
            } label: {
                Text(isEditing ? "保存版本" : "创建 Prompt")
            }
            .buttonStyle(OPSComposerButtonStyle())

        }
        .padding(.leading, 32)
        .padding(.trailing, 64)
        .frame(height: 64)
        .background(OPSColor.pageBackground)
        .overlay(alignment: .bottom) {
            Rectangle().fill(OPSColor.divider).frame(height: 1)
        }
    }

    private var editorPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PromptComposerTextEditor(
                    title: "Prompt",
                    placeholder: "描述你想生成的画面、镜头、主体、风格、光线和构图...",
                    text: $prompt,
                    minHeight: 360
                )

                PromptComposerTextEditor(
                    title: "Negative Prompt",
                    placeholder: "输入不希望出现的内容，例如 watermark, low quality, blurry...",
                    text: $negativePrompt,
                    minHeight: 150
                )

                HStack(spacing: 12) {
                    counter("字符", prompt.count + negativePrompt.count)
                    counter("词数估算", estimatedTokenCount)
                    Spacer()
                }
            }
            .padding(24)
        }
        .background(StudioColor.previewBackground)
    }

    private var opsWorkspacePane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("untitled", text: $title)
                        .textFieldStyle(.plain)
                        .font(.custom("JetBrains Mono", size: 14).weight(.semibold))
                        .foregroundStyle(OPSColor.workTitle)
                        .frame(maxWidth: 320)
                }

                OPSComposerTextArea(
                    placeholder: "输入提示词",
                    text: $prompt,
                    minHeight: 178,
                    fill: OPSColor.inputBackground,
                    textColor: OPSColor.inputText
                )
                .frame(width: 320)

                opsOutputCard
                opsToolbar
                opsNegativeCard
                opsCounters
            }
            .padding(.leading, 20)
            .padding(.top, 28)
            .padding(.bottom, 28)
            .frame(width: 360, alignment: .leading)
        }
        .background(OPSColor.pageBackground)
    }

    private var opsOutputCard: some View {
        Text(outputPreviewText)
            .font(.custom("JetBrains Mono", size: 14))
            .lineSpacing(4)
            .foregroundStyle(prompt.isEmpty ? OPSColor.outputPlaceholder : OPSColor.outputGreen)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(8)
            .frame(minHeight: 74, alignment: .topLeading)
            .background(OPSColor.outputBackground)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .shadow(color: .black.opacity(0.24), radius: 4, y: 2)
            .frame(width: 320)
    }

    private var opsToolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    AppKitBridge.copyToPasteboard(outputPreviewText)
                    state.toast = "已复制 Prompt"
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
                .buttonStyle(OPSComposerButtonStyle())

                HStack(spacing: 4) {
                    opsIconTool("circle.slash", help: "全部禁用")
                    opsIconTool("arrow.up", help: "用输出替换输入") {
                        prompt = outputPreviewText
                    }
                    opsIconTool("trash", help: "清空输入") {
                        prompt = ""
                    }
                }
                .padding(.horizontal, 4)
                .frame(height: 32)
                .background(OPSColor.buttonBackground)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                HStack(spacing: 4) {
                    opsIconTool("photo", help: "添加参考资产") {
                        appendReferenceImages(AppKitBridge.chooseReferenceAssets())
                    }
                    opsIconTool("rectangle.badge.hd", help: "高清参数") {
                        appendParameterLine("quality=high")
                    }
                }
                .padding(.horizontal, 4)
                .frame(height: 32)
                .background(OPSColor.buttonBackground)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }

        }
        .frame(width: 320, alignment: .leading)
    }

    private var opsNegativeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Negative Prompt")
                .font(StudioFont.font(14, weight: .semibold))
                .foregroundStyle(OPSColor.workTitle)
            OPSComposerTextArea(
                placeholder: "输入不希望出现的内容，例如 watermark, low quality, blurry...",
                text: $negativePrompt,
                minHeight: 150,
                fill: OPSColor.inputBackground,
                textColor: OPSColor.inputText
            )
            Text(negativePrompt.isEmpty ? "输出与输入相同" : negativePrompt)
                .font(.custom("JetBrains Mono", size: 13))
                .foregroundStyle(negativePrompt.isEmpty ? OPSColor.outputPlaceholder : OPSColor.outputGreen)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .background(OPSColor.outputBackground)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .frame(width: 320)
    }

    private var opsCounters: some View {
        HStack(spacing: 10) {
            counter("字符", prompt.count + negativePrompt.count)
            counter("词数估算", estimatedTokenCount)
            counter("参考资产", referenceURLs.count + (editingItem?.referenceAssets.count ?? 0))
            if let resolvedType {
                counter(typeTitle(resolvedType), 0, showValue: false)
            }
            Spacer()
        }
        .frame(width: 320)
    }

    private var sidePane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                composerField("标题") {
                    TextField("未命名 Prompt", text: $title)
                }

                composerSection("标签") {
                    tagEditor
                }

                composerSection("参数") {
                    PromptComposerTextEditor(
                        title: nil,
                        placeholder: "每行一个 key=value，例如：\nar=16:9\nquality=high",
                        text: $parameters,
                        minHeight: 96,
                        compact: true
                    )
                }

                composerField("版本备注") {
                    TextField("例如：增强光影", text: $note)
                }

                if isEditing {
                    Toggle("保存为新版本", isOn: $saveAsNewVersion)
                        .toggleStyle(.switch)
                        .font(StudioFont.font(13))
                }

                composerSection("参考资产") {
                    referenceDropZone
                }
            }
            .padding(20)
        }
    }

    private var opsParserPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                opsPromptTokenGroups
                opsReferencePanel
                opsCompactSettingsPanel
            }
            .padding(24)
        }
    }

    private var opsPromptTokenGroups: some View {
        VStack(alignment: .leading, spacing: 13) {
            opsParserGroup(title: "权重组", subtitle: "-1", tokens: promptTokens.filter { $0.kind == .negative })
            opsParserGroup(title: "权重组", subtitle: "2", tokens: promptTokens.filter { $0.kind == .weighted })
            opsParserGroup(title: "参数", subtitle: nil, tokens: promptTokens.filter { $0.kind == .normal || $0.kind == .command })
        }
    }

    private func opsParserGroup(title: String, subtitle: String?, tokens: [OPSParsedPromptToken]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.custom("JetBrains Mono", size: 12))
                if let subtitle {
                    Text(subtitle)
                        .font(.custom("JetBrains Mono", size: 12))
                        .padding(.horizontal, 6)
                        .frame(height: 20)
                        .background(Color(hex: 0xC4C4C4).opacity(0.56))
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                }
            }
            .foregroundStyle(Color(hex: 0x757985).opacity(0.72))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Color(hex: 0xE6E6E6))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            FlowLayout(spacing: 8) {
                if tokens.isEmpty {
                    Text("等待输入")
                        .font(StudioFont.font(12))
                        .foregroundStyle(OPSColor.mutedText)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(Capsule().fill(Color(hex: 0xE9E9E9)))
                } else {
                    ForEach(tokens) { token in
                        OPSPromptTokenChip(token: token)
                    }
                }
            }
            .padding(.leading, 12)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(groupAccent(tokens: tokens))
                    .frame(width: 4)
            }
        }
    }

    private var opsReferencePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("参考资产")
                    .font(StudioFont.font(13, weight: .semibold))
                    .foregroundStyle(OPSColor.bodyText)
                Spacer()
                Text("\(referenceURLs.count + (editingItem?.referenceAssets.count ?? 0)) 个")
                    .font(StudioFont.font(12))
                    .foregroundStyle(OPSColor.mutedText)
            }
            referenceDropZone
        }
    }

    private var opsCompactSettingsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            composerSection("标题") {
                composerInputField("未命名 Prompt", text: $title)
            }
            composerSection("参数") {
                OPSComposerTextArea(
                    placeholder: "ar=16:9\nquality=high",
                    text: $parameters,
                    minHeight: 84,
                    fill: OPSColor.inputBackground,
                    textColor: OPSColor.inputText,
                    compact: true
                )
            }
            composerSection("版本备注") {
                composerInputField("例如：增强光影", text: $note)
            }
            composerSection("标签") {
                tagEditor
            }
            if isEditing {
                Toggle("保存为新版本", isOn: $saveAsNewVersion)
                    .toggleStyle(.switch)
                    .font(StudioFont.font(13))
            }
        }
        .padding(14)
        .background(Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(OPSColor.divider, lineWidth: 1))
    }

    @ViewBuilder
    private func composerField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        composerSection(title) {
            content()
                .textFieldStyle(.plain)
                .font(StudioFont.font(13))
                .foregroundStyle(StudioColor.text)
                .padding(.horizontal, 10)
                .frame(minHeight: 36)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(StudioColor.control)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioColor.hairline, lineWidth: 1))
        }
    }

    private func composerSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(StudioFont.font(12))
                .foregroundStyle(OPSColor.mutedText)
            content()
        }
    }

    private var tagEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlowLayout(spacing: 8) {
                ForEach(tags, id: \.self) { tag in
                    HStack(spacing: 6) {
                        Text(tag)
                        Button {
                            tags.removeAll { $0 == tag }
                        } label: {
                            Image(systemName: "xmark")
                                .font(StudioFont.symbol(9, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                    }
                    .font(StudioFont.font(12))
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Capsule().fill(OPSColor.buttonBackground))
                }
            }

            TextField("输入标签后回车", text: $tagDraft)
                .textFieldStyle(.plain)
                .font(StudioFont.font(13))
                .foregroundStyle(OPSColor.inputText)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(OPSColor.buttonBackground)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .onSubmit(addTag)
        }
    }

    private func composerInputField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(StudioFont.font(13))
            .foregroundStyle(OPSColor.inputText)
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(OPSColor.buttonBackground)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private var referenceDropZone: some View {
        VStack(spacing: 10) {
            if existingReferenceAssets.isEmpty && referenceURLs.isEmpty {
                Button {
                    appendReferenceImages(AppKitBridge.chooseReferenceAssets())
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle")
                            .font(StudioFont.symbol(24))
                        Text("拖拽或点击添加参考资产")
                            .font(StudioFont.font(13))
                        Text("支持图片、音频、视频")
                            .font(StudioFont.font(11))
                            .foregroundStyle(OPSColor.mutedText)
                    }
                    .foregroundStyle(OPSColor.bodyText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
                    .background(isReferenceDropTarget ? Color(hex: 0xE0E0E0) : OPSColor.buttonBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .foregroundStyle(OPSColor.divider)
                    )
                }
                .buttonStyle(.plain)
            } else {
                LazyVGrid(columns: referenceColumns, alignment: .leading, spacing: 8) {
                    ForEach(existingReferenceAssets) { reference in
                        OPSReferenceThumb(reference: reference, removable: false)
                    }
                    ForEach(referenceURLs, id: \.path) { url in
                        OPSReferenceThumb(path: url.path, removable: true) {
                            referenceURLs.removeAll { $0 == url }
                        }
                    }
                    Button {
                        appendReferenceImages(AppKitBridge.chooseReferenceAssets())
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "plus")
                                .font(StudioFont.symbol(18))
                            Text("添加")
                                .font(StudioFont.font(11))
                        }
                        .foregroundStyle(OPSColor.bodyText)
                        .frame(maxWidth: .infinity)
                        .frame(height: 78)
                        .background(OPSColor.buttonBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                .foregroundStyle(OPSColor.divider)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isReferenceDropTarget, perform: handleReferenceDrop)
    }

    private var referenceSummary: String {
        if !referenceURLs.isEmpty {
            return "已选择 \(referenceURLs.count) 个参考资产"
        }
        if let editingItem, !editingItem.referenceAssets.isEmpty {
            return "已有 \(editingItem.referenceAssets.count) 个参考资产"
        }
        return "拖拽或点击添加参考资产"
    }

    private var previewTitle: String {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleanTitle.isEmpty ? "未命名 Prompt" : cleanTitle
    }

    private var previewImageInfo: (width: Int, height: Int, fileSize: Int64, format: String)? {
        guard let previewImageURL else { return nil }
        return AppKitBridge.fileInfo(for: previewImageURL, assetKind: .image)
    }

    private var previewMetadataChips: [String] {
        var chips: [String] = []
        if let resolvedType {
            let metadata = currentMetadata(for: resolvedType)
            if shouldDisplayModelMetadata(metadata.model) {
                chips.append(metadata.model.name)
            }
        }
        if let resolution = previewResolutionText {
            chips.append(resolution)
        }
        if let format = previewFormatText {
            chips.append(format)
        }
        if let style = extractedStyleTag {
            chips.append(style)
        }
        return chips
    }

    private func shouldDisplayModelMetadata(_ model: ModelProfile) -> Bool {
        let hiddenIDs: Set<String> = [PromptComposerMetadataPolicy.unspecifiedModelID, "local_asset"]
        let hiddenNames: Set<String> = [PromptComposerMetadataPolicy.unspecifiedModelName.lowercased(), "local asset"]
        return !hiddenIDs.contains(model.id.lowercased()) && !hiddenNames.contains(model.name.lowercased())
    }

    private var previewResolutionText: String? {
        guard let previewImageInfo, previewImageInfo.width > 0, previewImageInfo.height > 0 else {
            return nil
        }
        return "\(previewImageInfo.width) x \(previewImageInfo.height)"
    }

    private var previewFormatText: String? {
        guard let previewImageInfo else { return nil }
        return previewImageInfo.format.isEmpty ? "IMG" : previewImageInfo.format.uppercased()
    }

    private var extractedStyleTag: String? {
        let source = "\(title) \(prompt) \(tags.joined(separator: " "))".lowercased()
        let rules: [([String], String)] = [
            (["写实", "真实", "摄影", "photography", "realistic", "cinematic"], "写实"),
            (["插画", "illustration", "illustrated"], "插画"),
            (["角色", "人物", "portrait", "character"], "人物"),
            (["风景", "landscape", "scene"], "风景"),
            (["极简", "minimal", "minimalist"], "极简"),
            (["时装", "服装", "fashion"], "时装")
        ]
        return rules.first { rule in
            rule.0.contains { source.contains($0) }
        }?.1
    }

    private var createReferenceColumns: [GridItem] {
        [
            GridItem(.adaptive(minimum: 96, maximum: 96), spacing: 12)
        ]
    }

    private var previewReferenceColumns: [GridItem] {
        Array(repeating: GridItem(.fixed(62), spacing: 8), count: 4)
    }

    private var composerTitle: String {
        isEditing ? "编辑 Prompt" : "新建 Prompt"
    }

    private var primaryActionTitle: String {
        isEditing ? "保存" : "创建"
    }

    private var estimatedTokenCount: Int {
        let text = [prompt, negativePrompt].joined(separator: " ")
        let latinWords = text.split { $0.isWhitespace || $0.isPunctuation }.count
        let cjkCount = text.unicodeScalars.filter { $0.value >= 0x4E00 && $0.value <= 0x9FFF }.count
        return max(0, latinWords + Int(Double(cjkCount) / 1.7))
    }

    private func counter(_ title: String, _ value: Int) -> some View {
        counter(title, value, showValue: true)
    }

    private func counter(_ title: String, _ value: Int, showValue: Bool) -> some View {
        Text(showValue ? "\(title) \(value)" : title)
            .font(StudioFont.font(12))
            .foregroundStyle(OPSColor.buttonText)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Capsule().fill(OPSColor.buttonBackground))
    }

    private var outputPreviewText: String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "输出与输入相同" : trimmed
    }

    private func opsIconTool(_ systemName: String, help: String, action: @escaping () -> Void = {}) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(StudioFont.symbol(12))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .foregroundStyle(OPSColor.buttonText)
        .background(OPSColor.buttonBackground)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .help(help)
    }

    private var promptTokens: [OPSParsedPromptToken] {
        parsePromptTokens(prompt)
    }

    private var existingReferenceAssets: [ReferenceAsset] {
        editingItem?.referenceAssets ?? []
    }

    private var allReferencePreviewAssets: [ReferenceAsset] {
        existingReferenceAssets + referenceURLs.map(referenceAssetPreview)
    }

    private var referenceColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 8),
            GridItem(.flexible(), spacing: 8),
            GridItem(.flexible(), spacing: 8)
        ]
    }

    private func groupAccent(tokens: [OPSParsedPromptToken]) -> Color {
        switch tokens.first?.kind {
        case .negative:
            Color(hex: 0xDA4927)
        case .weighted:
            Color(hex: 0x9EC9C6)
        case .command:
            Color(hex: 0xD6D3EC)
        case .normal:
            Color(hex: 0xCECECE)
        case nil:
            Color(hex: 0xCECECE)
        }
    }

    private func appendParameterLine(_ line: String) {
        if parameters.split(separator: "\n").map(String.init).contains(line) {
            return
        }
        parameters = parameters.isEmpty ? line : "\(parameters)\n\(line)"
    }

    private func typeTitle(_ type: PromptType) -> String {
        switch type {
        case .image: return "图片"
        case .video: return "视频"
        case .audio: return "音频"
        case .text: return "文本"
        }
    }

    private func chooseTypeManually(_ type: PromptType) {
        let previousType = resolvedType
        typeMode = .manual(type)
        typeDecision = .manual(type: type)
        if previousType != type {
            modelId = PromptComposerMetadataPolicy.unspecifiedModelID
            modelHint = nil
            formatHint = nil
            if type == .text {
                moveUnsavedPreviewImageToReferencesIfNeeded()
            }
        }
    }

    private func moveUnsavedPreviewImageToReferencesIfNeeded() {
        guard let previewImageURL else { return }
        if !referenceURLs.contains(previewImageURL), editingItem?.assetPath != previewImageURL.path {
            referenceURLs.append(previewImageURL)
        }
        self.previewImageURL = nil
    }

    private func updateAutomaticTypeDecision() {
        guard case .automatic = typeMode else { return }
        guard smartPasteInterpretation == nil || prompt != smartPasteAppliedPrompt else { return }
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            typeDecision = .unresolved(reason: "请输入 Prompt 后自动识别")
            modelId = nil
            return
        }
        let interpretation = PromptClipboardInterpreter.interpret(prompt)
        typeDecision = PromptComposerTypeDecision.resolve(interpretation: interpretation, mode: typeMode)
        if let nextModelHint = interpretation.modelHint {
            modelHint = nextModelHint
        } else if smartPasteInterpretation == nil {
            modelHint = nil
        }
        if let nextFormatHint = interpretation.formatHint {
            formatHint = nextFormatHint
        } else if smartPasteInterpretation == nil {
            formatHint = nil
        }
        modelId = resolvedType.map { currentMetadata(for: $0).model.id }
    }

    private func currentMetadata(for type: PromptType) -> PromptComposerMetadataDecision {
        if let item = editingItem, item.type == type {
            var preservedParameters = parsedParameters
            let existingParameters = item.currentVersion?.parameters ?? [:]
            if let formatID = existingParameters["prompt_format_id"] {
                preservedParameters["prompt_format_id"] = formatID
            }
            if let format = existingParameters["prompt_format"] {
                preservedParameters["prompt_format"] = format
            }
            return PromptComposerMetadataDecision(
                model: ModelProfile(
                    id: item.modelId,
                    name: item.modelName,
                    type: item.type,
                    parameters: []
                ),
                promptFormatID: preservedParameters["prompt_format_id"],
                promptFormat: preservedParameters["prompt_format"],
                parameters: preservedParameters
            )
        }

        let changingExistingType = editingItem.map { $0.type != type } ?? false
        return PromptComposerMetadataPolicy.resolve(
            type: type,
            modelHint: modelHint,
            formatHint: formatHint,
            parameters: changingExistingType ? [:] : parsedParameters,
            localModels: state.models
        )
    }

    private func loadDraft() {
        switch mode {
        case .create:
            title = ""
            typeMode = .automatic
            typeDecision = .unresolved(reason: "请输入 Prompt 后自动识别")
            modelId = nil
            modelHint = nil
            formatHint = nil
            prompt = ""
            negativePrompt = ""
            tags = []
            parameters = ""
            note = ""
            saveAsNewVersion = true
            previewImageURL = nil
            referenceURLs = []
            smartPasteInterpretation = nil
            smartPasteAppliedPrompt = nil
            pendingSmartPasteInterpretation = nil
            smartPasteSnapshot = nil
        case .edit:
            guard let item = editingItem else { return }
            title = item.title
            typeMode = .manual(item.type)
            typeDecision = .manual(type: item.type)
            modelId = item.modelId
            modelHint = nil
            formatHint = nil
            prompt = item.currentVersion?.prompt ?? ""
            negativePrompt = item.currentVersion?.negativePrompt ?? ""
            tags = item.tags
            parameters = visibleParameters(from: item.currentVersion?.parameters ?? [:])
                .map { "\($0.key)=\($0.value)" }
                .sorted()
                .joined(separator: "\n")
            note = ""
            saveAsNewVersion = true
            if item.assetKind == .image, !item.assetPath.isEmpty, FileManager.default.fileExists(atPath: item.assetPath) {
                previewImageURL = URL(fileURLWithPath: item.assetPath)
            } else {
                previewImageURL = nil
            }
            referenceURLs = []
            smartPasteInterpretation = nil
            smartPasteAppliedPrompt = nil
            pendingSmartPasteInterpretation = nil
            smartPasteSnapshot = nil
        }
        // Capture the clean create/edit baseline before applying any smart-paste prefill.
        initialSignature = draftSignature
        if case .create(let prefill) = mode, let prefill {
            applySmartPaste(prefill.interpretation)
        }
    }

    private var smartPasteFieldCount: Int {
        [
            title,
            prompt,
            negativePrompt,
            tags.joined(separator: ", "),
            parameters
        ].reduce(into: 0) { count, value in
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                count += 1
            }
        }
    }

    private var smartPasteSuggestion: String {
        guard smartPasteInterpretation != nil else { return "" }
        if let resolvedType {
            return "已识别 \(typeTitle(resolvedType)) · \(typeDecision.reason)"
        }
        return "类型待确认 · \(typeDecision.reason)"
    }

    private var isDraftBlankForSmartPaste: Bool {
        draftSignature == initialSignature &&
            title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            negativePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            tags.isEmpty &&
            parameters.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            previewImageURL == nil &&
            referenceURLs.isEmpty
    }

    private func requestSmartPaste() {
        guard let interpretation = state.readSmartPasteFromPasteboard() else { return }
        handleIncomingSmartPaste(interpretation)
    }

    private func handlePendingSmartPasteRequest() {
        guard case .create = mode,
              let request = state.pendingSmartPasteRequest else { return }
        handleIncomingSmartPaste(request.interpretation)
        state.consumeSmartPasteRequest(token: request.token)
    }

    private func handleIncomingSmartPaste(_ interpretation: PromptClipboardInterpretation) {
        guard !isEditing else {
            state.showToast("编辑模式不支持智能粘贴")
            return
        }
        if isDraftBlankForSmartPaste {
            applySmartPaste(interpretation)
        } else {
            pendingSmartPasteInterpretation = interpretation
            showSmartPasteReplaceConfirmation = true
        }
    }

    private func captureDraft() -> PromptComposerDraftSnapshot {
        PromptComposerDraftSnapshot(
            title: title,
            typeDecision: typeDecision,
            typeMode: typeMode,
            modelId: modelId,
            modelHint: modelHint,
            formatHint: formatHint,
            prompt: prompt,
            negativePrompt: negativePrompt,
            tags: tags,
            tagDraft: tagDraft,
            parameters: parameters,
            note: note,
            saveAsNewVersion: saveAsNewVersion,
            previewImageURL: previewImageURL,
            referenceURLs: referenceURLs,
            smartPasteInterpretation: smartPasteInterpretation,
            smartPasteAppliedPrompt: smartPasteAppliedPrompt
        )
    }

    private func restoreDraft(_ snapshot: PromptComposerDraftSnapshot) {
        title = snapshot.title
        typeDecision = snapshot.typeDecision
        typeMode = snapshot.typeMode
        modelId = snapshot.modelId
        modelHint = snapshot.modelHint
        formatHint = snapshot.formatHint
        prompt = snapshot.prompt
        negativePrompt = snapshot.negativePrompt
        tags = snapshot.tags
        tagDraft = snapshot.tagDraft
        parameters = snapshot.parameters
        note = snapshot.note
        saveAsNewVersion = snapshot.saveAsNewVersion
        previewImageURL = snapshot.previewImageURL
        referenceURLs = snapshot.referenceURLs
        smartPasteInterpretation = snapshot.smartPasteInterpretation
        smartPasteAppliedPrompt = snapshot.smartPasteAppliedPrompt
    }

    private func applySmartPaste(_ interpretation: PromptClipboardInterpretation) {
        smartPasteSnapshot = captureDraft()

        modelHint = interpretation.modelHint
        formatHint = interpretation.formatHint
        typeDecision = PromptComposerTypeDecision.resolve(interpretation: interpretation, mode: typeMode)
        if resolvedType == .text {
            moveUnsavedPreviewImageToReferencesIfNeeded()
        }
        if let resolvedType {
            modelId = currentMetadata(for: resolvedType).model.id
        } else {
            modelId = nil
        }

        title = interpretation.title
        prompt = interpretation.prompt
        smartPasteAppliedPrompt = interpretation.prompt
        negativePrompt = interpretation.negativePrompt
        tags = interpretation.tags
        parameters = visibleParameters(from: interpretation.parameters)
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .joined(separator: "\n")
        smartPasteInterpretation = interpretation
        showSmartPasteDetails = false
    }

    private func undoSmartPaste() {
        guard let snapshot = smartPasteSnapshot else { return }
        restoreDraft(snapshot)
        smartPasteSnapshot = nil
        pendingSmartPasteInterpretation = nil
        showSmartPasteDetails = false
    }

    private func clearSmartPaste() {
        // Clearing a session restores the complete pre-fill snapshot. In particular,
        // preview and reference assets remain untouched when they existed beforehand.
        if let snapshot = smartPasteSnapshot {
            restoreDraft(snapshot)
        }
        smartPasteSnapshot = nil
        pendingSmartPasteInterpretation = nil
        showSmartPasteDetails = false
    }

    private func save() {
        guard let resolvedType else {
            state.showToast("请先选择 Prompt 类型")
            return
        }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let metadata = currentMetadata(for: resolvedType)
        switch mode {
        case .create(_):
            state.createPrompt(
                title: cleanTitle.isEmpty ? "未命名 Prompt" : cleanTitle,
                type: resolvedType,
                modelId: metadata.model.id,
                prompt: prompt,
                negativePrompt: negativePrompt,
                tags: tags,
                parameters: savedParameters,
                previewImageURL: previewImageURL,
                referenceURLs: referenceURLs
            )
        case .edit:
            state.savePrompt(
                title: cleanTitle.isEmpty ? "未命名 Prompt" : cleanTitle,
                type: resolvedType,
                modelId: metadata.model.id,
                prompt: prompt,
                negativePrompt: negativePrompt,
                tags: tags,
                parameters: savedParameters,
                note: note,
                saveAsNewVersion: saveAsNewVersion,
                referenceURLs: referenceURLs
            )
        }
        initialSignature = draftSignature
        state.closePromptComposer()
    }

    private func requestClose() {
        if draftSignature == initialSignature {
            state.closePromptComposer()
        } else {
            showCloseConfirmation = true
        }
    }

    private var draftSignature: String {
        [
            title,
            resolvedType?.rawValue ?? "unresolved",
            typeModeSignature,
            modelId ?? "",
            modelHint ?? "",
            formatHint ?? "",
            prompt,
            negativePrompt,
            tags.joined(separator: "\u{1f}"),
            parameters,
            note,
            "\(saveAsNewVersion)",
            previewImageURL?.path ?? "",
            referenceURLs.map(\.path).joined(separator: "\u{1f}")
        ].joined(separator: "\u{1e}")
    }

    private var parsedParameters: [String: String] {
        parameters
            .split(separator: "\n")
            .reduce(into: [String: String]()) { result, line in
                let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    result[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
                }
            }
    }

    private var savedParameters: [String: String] {
        guard let resolvedType else { return parsedParameters }
        return currentMetadata(for: resolvedType).parameters
    }

    private func visibleParameters(from parameters: [String: String]) -> [String: String] {
        parameters.filter { key, _ in
            key != "prompt_format_id" && key != "prompt_format"
        }
    }

    private func addTag() {
        let next = tagDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !next.isEmpty, !tags.contains(next) else {
            tagDraft = ""
            return
        }
        tags.append(next)
        tagDraft = ""
    }

    private func appendReferenceImages(_ urls: [URL]) {
        let next = urls.filter(isSupportedReferenceAsset)
        for url in next where !referenceURLs.contains(url) {
            referenceURLs.append(url)
        }
    }

    private func setPreviewImage(_ urls: [URL]) {
        guard !isEditing else { return }
        let imageExtensions = Set(["png", "jpg", "jpeg", "webp"])
        previewImageURL = urls.first { imageExtensions.contains($0.pathExtension.lowercased()) }
    }

    private func handlePreviewImageDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !isEditing else { return false }
        var handled = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            handled = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let itemURL = item as? URL {
                    url = itemURL
                } else if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = nil
                }
                guard let url else { return }
                DispatchQueue.main.async {
                    setPreviewImage([url])
                }
            }
        }
        return handled
    }

    private func handleReferenceDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            handled = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let itemURL = item as? URL {
                    url = itemURL
                } else if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = nil
                }
                guard let url else { return }
                DispatchQueue.main.async {
                    appendReferenceImages([url])
                }
            }
        }
        return handled
    }

    private func isSupportedReferenceAsset(_ url: URL) -> Bool {
        switch AppKitBridge.assetKind(for: url) {
        case .image, .audio, .video:
            true
        default:
            false
        }
    }

    private func referenceAssetPreview(for url: URL) -> ReferenceAsset {
        ReferenceAsset(
            type: url.pathExtension.uppercased(),
            path: url.path,
            label: url.deletingPathExtension().lastPathComponent
        )
    }
}

private struct PromptComposerTextEditor: View {
    let title: String?
    let placeholder: String
    @Binding var text: String
    let minHeight: CGFloat
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                HStack {
                    Text(title)
                        .font(StudioFont.caption(12))
                        .tracking(1.2)
                        .foregroundStyle(StudioColor.secondaryText)
                    Spacer()
                    Text("\(text.count) 字符")
                        .font(StudioFont.font(11))
                        .foregroundStyle(StudioColor.mutedText)
                }
            }

            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(StudioFont.font(compact ? 12 : 13))
                        .foregroundStyle(StudioColor.tertiaryText)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .font(StudioFont.font(compact ? 12 : 13))
                    .lineSpacing(compact ? 2 : 4)
                    .foregroundStyle(StudioColor.text)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: minHeight)
                    .background(Color.clear)
            }
            .background(StudioColor.panel)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioColor.hairline, lineWidth: 1))
        }
    }
}

private enum OPSColor {
    static let pageBackground = Color(hex: 0xF7F7F7)
    static let divider = Color(hex: 0xD7D7D7)
    static let bodyText = Color(hex: 0x484644)
    static let mutedText = Color(hex: 0x8E8E8E)
    static let workTitle = Color(hex: 0x5F5C5C)
    static let inputBackground = Color(hex: 0xE9E9E9)
    static let inputText = Color(hex: 0x252525).opacity(0.81)
    static let inputRing = Color(hex: 0xBDB8B8).opacity(0.50)
    static let outputBackground = Color(hex: 0x2B2828)
    static let outputGreen = Color(hex: 0x4DC177)
    static let outputPlaceholder = Color(hex: 0x7A8B7E)
    static let buttonBackground = Color(hex: 0xE9E9E9)
    static let buttonHover = Color(hex: 0xE0E0E0)
    static let buttonPressed = Color(hex: 0xD7D7D7)
    static let buttonText = Color(hex: 0x484644)
}

private enum OPSLayout {
    static let p1: CGFloat = 4
    static let p2: CGFloat = 8
    static let p3: CGFloat = 16
    static let p4: CGFloat = 22
    static let radius: CGFloat = 4
    static let workWidth: CGFloat = 320
}

private struct OPSComposerTextArea: View {
    let placeholder: String
    @Binding var text: String
    let minHeight: CGFloat
    let fill: Color
    let textColor: Color
    var compact = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(.custom("JetBrains Mono", size: compact ? 12 : 14))
                    .foregroundStyle(OPSColor.mutedText)
                    .padding(OPSLayout.p2)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(.custom("JetBrains Mono", size: compact ? 12 : 14))
                .lineSpacing(compact ? 2 : 4)
                .foregroundStyle(textColor)
                .scrollContentBackground(.hidden)
                .padding(OPSLayout.p1)
                .frame(minHeight: minHeight)
                .background(Color.clear)
        }
        .background(fill)
        .clipShape(RoundedRectangle(cornerRadius: OPSLayout.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: OPSLayout.radius).stroke(OPSColor.inputRing, lineWidth: 2))
    }
}

private struct OPSParsedPromptToken: Identifiable {
    enum Kind {
        case normal
        case weighted
        case negative
        case command
    }

    let id = UUID()
    let text: String
    let weight: String?
    let kind: Kind
}

private func parsePromptTokens(_ prompt: String) -> [OPSParsedPromptToken] {
    prompt
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .flatMap { segment -> [OPSParsedPromptToken] in
            if segment.hasPrefix("--") {
                return [OPSParsedPromptToken(text: segment, weight: nil, kind: .command)]
            }

            let parts = segment.components(separatedBy: "::")
            if parts.count == 2 {
                let text = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let weight = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                let value = Double(weight) ?? 1
                return [OPSParsedPromptToken(text: text, weight: weight, kind: value < 0 ? .negative : .weighted)]
            }

            return [OPSParsedPromptToken(text: segment, weight: nil, kind: .normal)]
        }
}

private struct OPSPromptTokenChip: View {
    let token: OPSParsedPromptToken

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(token.text)
                    .font(.custom("JetBrains Mono", size: 12))
                    .lineLimit(1)
                if let weight = token.weight {
                    Text(weight)
                        .font(.custom("JetBrains Mono", size: 11))
                        .foregroundStyle(Color(hex: 0x262626))
                        .padding(.horizontal, 5)
                        .frame(height: 18)
                        .background(Color.white.opacity(0.92))
                        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(primaryFill)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            if let translatedLabel {
                Text(translatedLabel)
                    .font(StudioFont.font(12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .frame(height: 30)
                    .background(secondaryFill)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
        }
        .shadow(color: .black.opacity(0.22), radius: 3, y: 2)
    }

    private var primaryFill: LinearGradient {
        LinearGradient(colors: baseColors, startPoint: .top, endPoint: .bottom)
    }

    private var secondaryFill: LinearGradient {
        LinearGradient(colors: descColors, startPoint: .top, endPoint: .bottom)
    }

    private var baseColors: [Color] {
        switch token.kind {
        case .normal:
            [Color(hex: 0x606060), Color(hex: 0x6C6C6C)]
        case .weighted:
            [Color(hex: 0x406E6D), Color(hex: 0x749B98)]
        case .negative:
            [Color(hex: 0x844444), Color(hex: 0x7C6C6C)]
        case .command:
            [Color(hex: 0x584589), Color(hex: 0x7774A0)]
        }
    }

    private var descColors: [Color] {
        switch token.kind {
        case .normal:
            [Color(hex: 0xA0B181), Color(hex: 0x57B049)]
        case .weighted:
            [Color(hex: 0x75A19F), Color(hex: 0x31AAA3)]
        case .negative:
            [Color(hex: 0xDA4927), Color(hex: 0xC78A6E)]
        case .command:
            [Color(hex: 0x8D79C0), Color(hex: 0x7A78DC)]
        }
    }

    private var translatedLabel: String? {
        let table = [
            "apple": "苹果",
            "forest": "森林",
            "big bad wolf": "大灰狼",
            "wood": "木料",
            "cinematic lighting": "电影光效",
            "unreal engine": "虚幻引擎",
            "super detail": "非常详细",
            "uhd": "超高清",
            "--aspect 2:3": "宽高比 2:3"
        ]
        return table[token.text.lowercased()]
    }
}

private struct OPSReferenceThumb: View {
    let path: String
    let type: String
    var removable = false
    var onRemove: () -> Void = {}

    init(path: String, type: String = "", removable: Bool = false, onRemove: @escaping () -> Void = {}) {
        self.path = path
        self.type = type
        self.removable = removable
        self.onRemove = onRemove
    }

    init(reference: ReferenceAsset, removable: Bool = false, onRemove: @escaping () -> Void = {}) {
        self.path = reference.path
        self.type = reference.type
        self.removable = removable
        self.onRemove = onRemove
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ReferenceAssetPreview(path: path, type: type)
            .frame(maxWidth: .infinity)
            .frame(height: 78)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: OPSLayout.radius, style: .continuous))

            if removable {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(StudioFont.symbol(9, weight: .semibold))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(Circle().fill(Color.black.opacity(0.72)))
                .padding(5)
            }
        }
    }
}

private enum CreateComposerColor {
    static let workspace = StudioColor.appBackground
    static let documentBackground = Color(hex: 0x141414)
    static let inputBackground = StudioColor.control
    static let fieldBackground = Color(hex: 0x2D2D2D)
    static let dropActive = StudioColor.panelRaised
    static let border = Color(hex: 0x3E3E3E)
    static let primaryText = StudioColor.text
    static let secondaryText = StudioColor.secondaryText.opacity(0.92)
    static let placeholderText = StudioColor.tertiaryText
}

private struct CreateComposerPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CreateComposerPrimaryButton(configuration: configuration)
    }
}

private struct CreateComposerPrimaryButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let configuration: ButtonStyle.Configuration
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(StudioFont.font(12, weight: .medium))
            .foregroundStyle(StudioColor.primaryActionText)
            .frame(width: 104, height: 36)
            .background(configuration.isPressed ? Color.white.opacity(0.82) : (isHovered ? Color.white.opacity(0.90) : StudioColor.primaryAction))
            .clipShape(Capsule())
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
            .onHover { isHovered = $0 }
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.98 : 1))
            .animation(StudioMotion.fast(reduceMotion: reduceMotion), value: isHovered)
            .animation(StudioMotion.fast(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

private struct ComposerUploadThumb: View {
    let path: String
    let type: String
    let width: CGFloat
    let height: CGFloat
    let removable: Bool
    let onRemove: () -> Void

    init(path: String, width: CGFloat, height: CGFloat, removable: Bool = true, onRemove: @escaping () -> Void = {}) {
        self.path = path
        self.type = ""
        self.width = width
        self.height = height
        self.removable = removable
        self.onRemove = onRemove
    }

    init(reference: ReferenceAsset, width: CGFloat, height: CGFloat, removable: Bool = true, onRemove: @escaping () -> Void = {}) {
        self.path = reference.path
        self.type = reference.type
        self.width = width
        self.height = height
        self.removable = removable
        self.onRemove = onRemove
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ReferenceAssetPreview(path: path, type: type)
                .frame(width: width, height: height)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            if removable {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(StudioFont.symbol(9, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(StudioColor.text)
                .background(Circle().fill(Color.black.opacity(0.76)))
                .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                .contentShape(Circle())
                .padding(4)
                .zIndex(2)
            }
        }
    }
}

@MainActor
private func composerRemoveButton(action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: "xmark")
            .font(StudioFont.symbol(9, weight: .semibold))
            .frame(width: 30, height: 30)
    }
    .buttonStyle(.plain)
    .foregroundStyle(StudioColor.text)
    .background(Circle().fill(Color.black.opacity(0.76)))
    .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
    .contentShape(Circle())
    .zIndex(2)
}

private struct ComposerPreviewImage: View {
    enum ContentMode {
        case fill
        case fit
    }

    let path: String
    var contentMode: ContentMode = .fill
    @StateObject private var loader = OverlayImageLoader()

    var body: some View {
        ZStack {
            if let image = loader.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode == .fill ? .fill : .fit)
            } else {
                StudioColor.panelRaised
                Image(systemName: "photo")
                    .font(StudioFont.symbol(18))
                    .foregroundStyle(StudioColor.tertiaryText)
            }
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .task(id: path) {
            await loader.load(path)
        }
    }
}

private struct OPSComposerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(StudioFont.font(14))
            .foregroundStyle(OPSColor.buttonText)
            .padding(.horizontal, OPSLayout.p3)
            .frame(height: 32)
            .background(configuration.isPressed ? OPSColor.buttonPressed : OPSColor.buttonBackground)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    }
}

private struct PreviewDocumentBlock: View {
    let title: String
    let text: String
    let minHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(StudioFont.caption(12))
                .tracking(1.2)
                .foregroundStyle(StudioColor.secondaryText)
            ScrollView {
                Text(text.isEmpty ? "未填写" : text)
                    .font(StudioFont.font(13))
                    .lineSpacing(4)
                    .foregroundStyle(text.isEmpty ? StudioColor.tertiaryText : StudioColor.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .frame(minHeight: minHeight)
            .background(StudioColor.panel)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioColor.hairline, lineWidth: 1))
        }
    }
}

private struct OverlayImagePreview: View {
    let path: String
    let scale: CGFloat
    let offset: CGSize
    @StateObject private var loader = OverlayImageLoader()

    var body: some View {
        ZStack {
            if let image = loader.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "photo")
                        .font(StudioFont.symbol(34))
                    Text("图片无法预览")
                        .font(StudioFont.font(14))
                }
                .foregroundStyle(StudioColor.secondaryText)
            }
        }
        .task(id: path) {
            await loader.load(path)
        }
    }
}

@MainActor
private final class OverlayImageLoader: ObservableObject {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 24
        cache.totalCostLimit = 180 * 1_024 * 1_024
        return cache
    }()

    @Published var image: NSImage?
    private var loadedPath: String?

    func load(_ path: String) async {
        guard !path.isEmpty else {
            if loadedPath != path || image != nil {
                loadedPath = path
                image = nil
            }
            return
        }
        if loadedPath == path, image != nil {
            return
        }

        let key = path as NSString
        if let cached = Self.cache.object(forKey: key) {
            DebugPerformanceProbe.record("preview.image.cache.hit")
            if loadedPath != path || image !== cached {
                loadedPath = path
                image = cached
            }
            return
        }

        let start = DebugPerformanceProbe.now()
        let loaded = await Task.detached(priority: .userInitiated) {
            Self.decodedImage(path: path)
        }.value
        guard !Task.isCancelled else { return }
        if let loaded {
            Self.cache.setObject(loaded, forKey: key, cost: Self.imageCost(loaded))
        }
        DebugPerformanceProbe.recordDuration("preview.image.decode.ms", startedAt: start)
        loadedPath = path
        image = loaded
    }

    static func preload(paths: [String]) async {
        guard !paths.isEmpty else { return }
        DebugPerformanceProbe.record("preview.image.prefetch.count", value: Double(paths.count))
        for path in paths {
            let key = path as NSString
            guard cache.object(forKey: key) == nil else { continue }
            let loaded = await Task.detached(priority: .utility) {
                Self.decodedImage(path: path)
            }.value
            guard !Task.isCancelled else { return }
            if let loaded {
                cache.setObject(loaded, forKey: key, cost: Self.imageCost(loaded))
            }
        }
    }

    nonisolated private static func decodedImage(path: String) -> NSImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url, sourceOptions) else {
            return NSImage(contentsOfFile: path)
        }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2_400,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return NSImage(contentsOfFile: path)
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    nonisolated private static func imageCost(_ image: NSImage) -> Int {
        let width = max(1, Int(image.size.width))
        let height = max(1, Int(image.size.height))
        return width * height * 4
    }
}

private enum PreviewRailVisibleWindow {
    private static let bufferItemCount = 5
    private static let fadeHeight: CGFloat = 78
    private static let buttonSize: CGFloat = 68
    private static let itemSpacing: CGFloat = 11
    private static let itemStride = buttonSize + itemSpacing

    static func items(
        from items: [PreviewRailItem],
        currentItemID: String,
        availableHeight: CGFloat
    ) -> [PreviewRailItem] {
        guard items.count > 1,
              let currentIndex = items.firstIndex(where: { $0.id == currentItemID }) else {
            return []
        }

        let visibleHalfSpan = max(itemStride, availableHeight / 2 + fadeHeight)
        let itemsEachSide = max(1, Int(ceil(visibleHalfSpan / itemStride)) + bufferItemCount)
        let lowerBound = max(0, currentIndex - itemsEachSide)
        let upperBound = min(items.count - 1, currentIndex + itemsEachSide)
        return Array(items[lowerBound...upperBound])
    }

    static func prefetchItemIDs(
        from items: [PreviewRailItem],
        currentItemID: String,
        visibleItemIDs: [String]
    ) -> [String] {
        guard let currentIndex = items.firstIndex(where: { $0.id == currentItemID }) else {
            return visibleItemIDs
        }

        var orderedIDs: [String] = []
        var seen = Set<String>()
        func append(_ id: String) {
            guard seen.insert(id).inserted else { return }
            orderedIDs.append(id)
        }

        visibleItemIDs.forEach(append)
        let lowerBound = max(0, currentIndex - 8)
        let upperBound = min(items.count - 1, currentIndex + 8)
        items[lowerBound...upperBound].map(\.id).forEach(append)
        return orderedIDs
    }
}

private struct PreviewThumbnailRail: View {
    static let railWidth: CGFloat = 82
    static let fadeHeight: CGFloat = 78
    static let itemStride: CGFloat = buttonSize + itemSpacing

    private static let thumbnailSize: CGFloat = 60
    private static let buttonSize: CGFloat = 68
    private static let itemSpacing: CGFloat = 11
    private static let cornerRadius: CGFloat = 11

    let items: [PreviewRailItem]
    let currentItemID: String
    let onSelect: (String) -> Void
    @State private var hoveredItemID: String?

    var body: some View {
        GeometryReader { proxy in
            let currentPositionIndex = items.first { $0.id == currentItemID }?.positionIndex
            let itemByPosition = Dictionary(uniqueKeysWithValues: items.map { ($0.positionIndex, $0) })
            let positionIndices = railPositionIndices
            let railCenterY = proxy.size.height / 2

            ZStack {
                Group {
                    if let currentPositionIndex {
                        ForEach(positionIndices, id: \.self) { positionIndex in
                            if let railItem = itemByPosition[positionIndex] {
                                railButton(for: railItem)
                                    .position(
                                        x: proxy.size.width / 2,
                                        y: railCenterY + CGFloat(positionIndex - currentPositionIndex) * Self.itemStride
                                    )
                                    .transition(.opacity.animation(.easeOut(duration: 0.08)))
                            }
                        }
                    }
                }
                .animation(
                    .interactiveSpring(response: 0.22, dampingFraction: 0.92, blendDuration: 0.02),
                    value: currentPositionIndex
                )

                fixedSelectionFrame
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .overlay(alignment: .top) {
                fadeOverlay(edge: .top)
                    .frame(height: Self.fadeHeight)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                fadeOverlay(edge: .bottom)
                    .frame(height: Self.fadeHeight)
                    .allowsHitTesting(false)
            }
        }
    }

    private var railPositionIndices: [Int] {
        guard let lowerBound = items.map(\.positionIndex).min(),
              let upperBound = items.map(\.positionIndex).max() else {
            return []
        }
        return Array(lowerBound...upperBound)
    }

    private var fixedSelectionFrame: some View {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            .stroke(StudioColor.primaryAction.opacity(0.84), lineWidth: 1.5)
            .shadow(color: StudioColor.primaryAction.opacity(0.18), radius: 5, x: 0, y: 0)
            .frame(width: Self.buttonSize, height: Self.buttonSize)
            .allowsHitTesting(false)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private enum FadeEdge {
        case top
        case bottom
    }

    private func fadeOverlay(edge: FadeEdge) -> some View {
        let stops: [Gradient.Stop] = switch edge {
        case .top:
            [
                .init(color: Color.black.opacity(0.82), location: 0.00),
                .init(color: Color.black.opacity(0.56), location: 0.30),
                .init(color: Color.black.opacity(0.18), location: 0.68),
                .init(color: .clear, location: 1.00)
            ]
        case .bottom:
            [
                .init(color: .clear, location: 0.00),
                .init(color: Color.black.opacity(0.18), location: 0.32),
                .init(color: Color.black.opacity(0.56), location: 0.70),
                .init(color: Color.black.opacity(0.82), location: 1.00)
            ]
        }
        return LinearGradient(
            stops: stops,
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func railButton(for railItem: PreviewRailItem) -> some View {
        let isCurrent = railItem.id == currentItemID || railItem.isCurrent
        let isHovered = hoveredItemID == railItem.id

        return Button {
            guard !isCurrent else { return }
            onSelect(railItem.id)
        } label: {
            ZStack(alignment: .bottomTrailing) {
                AssetMediaView(item: railItem.item, contentMode: .fill)
                    .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
                    .background(StudioColor.panelRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .opacity(isHovered && !isCurrent ? 0.86 : 1)

                if railItem.item.assetKind == .video {
                    Image(systemName: "play.fill")
                        .font(StudioFont.symbol(8, weight: .semibold))
                        .foregroundStyle(StudioColor.text)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.black.opacity(0.54)))
                        .padding(4)
                }
            }
            .frame(width: Self.buttonSize, height: Self.buttonSize)
            .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredItemID = hovering ? railItem.id : nil
        }
        .accessibilityLabel(railItem.item.title)
    }
}

private struct PreviewZoomControl: View {
    let scale: CGFloat
    let onZoomOut: () -> Void
    let onZoomIn: () -> Void
    let onReset: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            zoomButton(systemName: "plus", help: "放大", action: onZoomIn)

            Button(action: onReset) {
                Text(zoomLabel)
                    .font(StudioFont.font(13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(StudioColor.text)
                    .frame(width: 58, height: 32)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("重置缩放")

            zoomButton(systemName: "minus", help: "缩小", action: onZoomOut)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(isHovered ? 0.74 : 0.62))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.white.opacity(isHovered ? 0.18 : 0.10), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.34), radius: 18, x: 0, y: 10)
        .onHover { isHovered = $0 }
        .help("按住 Command 滚轮也可以缩放")
    }

    private func zoomButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(StudioFont.symbol(13, weight: .semibold))
                .foregroundStyle(StudioColor.text)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.white.opacity(0.08)))
                .overlay(Circle().stroke(Color.white.opacity(0.08), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var zoomLabel: String {
        "\(Int((scale * 100).rounded()))%"
    }
}

private struct OverlayVideoPlayer: NSViewRepresentable {
    let path: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        context.coordinator.configure(view, path: path)
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        context.coordinator.configure(nsView, path: path)
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        coordinator.stop()
        nsView.player = nil
    }

    @MainActor
    final class Coordinator {
        private var currentPath: String?
        private var player: AVPlayer?

        @MainActor
        func configure(_ view: AVPlayerView, path: String) {
            guard currentPath != path else { return }
            stop()
            currentPath = path
            let player = AVPlayer(url: URL(fileURLWithPath: path))
            self.player = player
            view.player = player
            player.play()
        }

        @MainActor
        func stop() {
            player?.pause()
            player = nil
            currentPath = nil
        }
    }
}

private struct EscapeKeyMonitor: NSViewRepresentable {
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onEscape: onEscape)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onEscape = onEscape
    }

    final class Coordinator {
        var onEscape: () -> Void
        private var monitor: Any?

        init(onEscape: @escaping () -> Void) {
            self.onEscape = onEscape
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53 else { return event }
                self?.onEscape()
                return nil
            }
        }
    }
}

private struct MarkdownEditorKeyMonitor: NSViewRepresentable {
    let onEscape: () -> Void
    let onSave: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onEscape: onEscape, onSave: onSave)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onEscape = onEscape
        context.coordinator.onSave = onSave
    }

    final class Coordinator {
        var onEscape: () -> Void
        var onSave: () -> Void
        private var monitor: Any?

        init(onEscape: @escaping () -> Void, onSave: @escaping () -> Void) {
            self.onEscape = onEscape
            self.onSave = onSave
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == 53 {
                    self?.onEscape()
                    return nil
                }
                if event.modifierFlags.contains(.command),
                   event.charactersIgnoringModifiers?.lowercased() == "s" {
                    self?.onSave()
                    return nil
                }
                return event
            }
        }
    }
}

private struct PreviewInputMonitor: NSViewRepresentable {
    let onExit: () -> Void
    let onNavigateStep: (PreviewStepDirection) -> Void
    let onZoom: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onExit: onExit, onNavigateStep: onNavigateStep, onZoom: onZoom)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onExit = onExit
        context.coordinator.onNavigateStep = onNavigateStep
        context.coordinator.onZoom = onZoom
    }

    final class Coordinator: @unchecked Sendable {
        var onExit: () -> Void
        var onNavigateStep: (PreviewStepDirection) -> Void
        var onZoom: (CGFloat) -> Void
        private var keyMonitor: Any?
        private var scrollMonitor: Any?
        private var scrollNavigationAccumulator: CGFloat = 0
        private var scrollNavigationSign: CGFloat = 0
        private var lastScrollNavigationTime: TimeInterval = 0
        private var pendingNavigationDirection: PreviewStepDirection?
        private var isNavigationDispatchScheduled = false
        private static let scrollNavigationThreshold: CGFloat = 8
        private static let scrollNavigationCooldown: TimeInterval = 0.055

        init(
            onExit: @escaping () -> Void,
            onNavigateStep: @escaping (PreviewStepDirection) -> Void,
            onZoom: @escaping (CGFloat) -> Void
        ) {
            self.onExit = onExit
            self.onNavigateStep = onNavigateStep
            self.onZoom = onZoom
        }

        deinit {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
            }
            if let scrollMonitor {
                NSEvent.removeMonitor(scrollMonitor)
            }
        }

        func install() {
            if keyMonitor == nil {
                keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    if event.keyCode == 53 || event.keyCode == 49 {
                        self?.onExit()
                        return nil
                    }
                    if let direction = Self.stepDirection(for: event) {
                        guard !Self.isTextInputActive() else { return event }
                        self?.onNavigateStep(direction)
                        return nil
                    }
                    return event
                }
            }

            if scrollMonitor == nil {
                scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    guard let self else { return event }
                    DebugPerformanceProbe.record("preview.scroll.event")
                    if event.modifierFlags.contains(.command) {
                        self.resetScrollNavigation()
                        guard !Self.isTextInputActive() else { return event }
                        let rawDelta = Self.verticalScrollDelta(for: event)
                        guard rawDelta != 0 else { return nil }
                        let normalized = max(-0.45, min(0.45, CGFloat(rawDelta) / 120))
                        self.onZoom(normalized)
                        return nil
                    }

                    guard Self.isPlainScroll(event) else {
                        self.resetScrollNavigation()
                        return event
                    }
                    guard !Self.isTextInputActive(),
                          !Self.shouldPreserveScrollableTarget(for: event) else {
                        self.resetScrollNavigation()
                        return event
                    }
                    let navigationDelta = Self.navigationScrollDelta(for: event)
                    self.handleScrollNavigation(delta: navigationDelta, timestamp: event.timestamp)
                    return nil
                }
            }
        }

        private func handleScrollNavigation(delta: CGFloat, timestamp: TimeInterval) {
            guard delta != 0 else { return }
            let sign: CGFloat = delta < 0 ? -1 : 1
            if sign != scrollNavigationSign {
                scrollNavigationAccumulator = 0
                scrollNavigationSign = sign
            }

            scrollNavigationAccumulator += delta
            guard abs(scrollNavigationAccumulator) >= Self.scrollNavigationThreshold else { return }

            if timestamp - lastScrollNavigationTime >= Self.scrollNavigationCooldown {
                scheduleNavigation(scrollNavigationAccumulator < 0 ? .next : .previous)
                lastScrollNavigationTime = timestamp
                scrollNavigationAccumulator = 0
            } else {
                scrollNavigationAccumulator = sign * Self.scrollNavigationThreshold
            }
        }

        private func scheduleNavigation(_ direction: PreviewStepDirection) {
            pendingNavigationDirection = direction
            guard !isNavigationDispatchScheduled else { return }
            isNavigationDispatchScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isNavigationDispatchScheduled = false
                guard let direction = self.pendingNavigationDirection else { return }
                self.pendingNavigationDirection = nil
                DebugPerformanceProbe.record("preview.scroll.navigate")
                DebugPerformanceProbe.record("preview.scroll.coalesced")
                self.onNavigateStep(direction)
            }
        }

        private func resetScrollNavigation() {
            scrollNavigationAccumulator = 0
            scrollNavigationSign = 0
            pendingNavigationDirection = nil
        }

        private static func isTextInputActive() -> Bool {
            return MainActor.assumeIsolated {
                AppKitBridge.isTextInputActive()
            }
        }

        private static func isPlainScroll(_ event: NSEvent) -> Bool {
            let reservedModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
            return event.modifierFlags.intersection(reservedModifiers).isEmpty
        }

        private static func verticalScrollDelta(for event: NSEvent) -> CGFloat {
            let delta = event.scrollingDeltaY == 0 ? -event.deltaY : event.scrollingDeltaY
            return CGFloat(delta)
        }

        private static func navigationScrollDelta(for event: NSEvent) -> CGFloat {
            let rawDelta = verticalScrollDelta(for: event)
            guard rawDelta != 0 else { return 0 }
            guard !event.hasPreciseScrollingDeltas else { return rawDelta }
            let magnitude = max(abs(rawDelta), scrollNavigationThreshold)
            return rawDelta < 0 ? -magnitude : magnitude
        }

        private static func shouldPreserveScrollableTarget(for event: NSEvent) -> Bool {
            let window = event.window
            let location = event.locationInWindow
            return MainActor.assumeIsolated {
                guard let contentView = window?.contentView,
                      let hitView = contentView.hitTest(location) else {
                    return false
                }
                if hitView is NSTextView || hitView.enclosingScrollView?.documentView is NSTextView {
                    return true
                }
                return hitView.enclosingScrollView != nil
            }
        }

        private static func stepDirection(for event: NSEvent) -> PreviewStepDirection? {
            let reservedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
            guard event.modifierFlags.intersection(reservedModifiers).isEmpty else { return nil }
            switch event.keyCode {
            case 123, 126:
                return .previous
            case 124, 125:
                return .next
            default:
                return nil
            }
        }
    }
}

private struct FlowLayout<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: Content

    init(spacing: CGFloat, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        WrappingLayout(spacing: spacing) {
            content
        }
    }
}

private struct WrappingLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        guard maxWidth.isFinite else {
            let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
            let width = sizes.reduce(CGFloat.zero) { $0 + $1.width } + CGFloat(max(0, sizes.count - 1)) * spacing
            let height = sizes.map(\.height).max() ?? 0
            return CGSize(width: width, height: height)
        }

        var currentX: CGFloat = 0
        var currentRowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var measuredWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            if currentX > 0, currentX + spacing + size.width > maxWidth {
                totalHeight += currentRowHeight + spacing
                currentX = 0
                currentRowHeight = 0
            }

            if currentX > 0 {
                currentX += spacing
            }
            currentX += min(size.width, maxWidth)
            currentRowHeight = max(currentRowHeight, size.height)
            measuredWidth = max(measuredWidth, currentX)
        }

        totalHeight += currentRowHeight
        return CGSize(width: maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var currentX = bounds.minX
        var currentY = bounds.minY
        var currentRowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            if currentX > bounds.minX, currentX + spacing + size.width > bounds.maxX {
                currentX = bounds.minX
                currentY += currentRowHeight + spacing
                currentRowHeight = 0
            }

            subview.place(
                at: CGPoint(x: currentX, y: currentY),
                proposal: ProposedViewSize(width: min(size.width, maxWidth), height: size.height)
            )
            currentX += min(size.width, maxWidth) + spacing
            currentRowHeight = max(currentRowHeight, size.height)
        }
    }
}

private extension View {
    func promptContainer() -> some View {
        self
            .background(Color(hex: 0x2D2D2D))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(hex: 0x3E3E3E), lineWidth: 1)
            )
    }
}
