import AVKit
import AppKit
import SwiftUI
import PromptStudioCore
import UniformTypeIdentifiers

struct ImmersivePreviewOverlay: View {
    @EnvironmentObject private var state: AppState
    let item: PromptItem
    @State private var imageScale: CGFloat = 1.0

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            StudioColor.appBackground
                .ignoresSafeArea()

            if item.isTextDocumentLike {
                MarkdownDocumentPreviewContent(item: item)
                    .environmentObject(state)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    previewMedia
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.leading, 42)
                        .padding(.trailing, 34)
                        .padding(.vertical, 42)

                    previewInspector
                        .frame(width: 360)
                        .frame(maxHeight: .infinity)
                        .background(StudioColor.panel.opacity(0.96))
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(StudioColor.hairline)
                                .frame(width: 1)
                        }
                }

                if item.assetKind == .image {
                    PreviewZoomControl(
                        scale: imageScale,
                        onZoomOut: { adjustImageScale(by: -0.15) },
                        onZoomIn: { adjustImageScale(by: 0.15) },
                        onReset: { imageScale = 1.0 }
                    )
                    .padding(.leading, 56)
                    .padding(.bottom, 36)
                }
            }

            OverlayCloseButton {
                state.isPreviewPresented = false
            }
            .padding(.top, 28)
            .padding(.trailing, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .transition(.opacity)
        .background {
            PreviewInputMonitor(
                onExit: {
                    state.isPreviewPresented = false
                },
                onZoom: { delta in
                    guard item.assetKind == .image else { return }
                    adjustImageScale(by: delta)
                }
            )
        }
    }

    private func adjustImageScale(by delta: CGFloat) {
        imageScale = min(3.0, max(0.25, imageScale + delta))
    }

    @ViewBuilder
    private var previewMedia: some View {
        if item.assetKind == .video {
            OverlayVideoPlayer(path: item.assetPath)
        } else if item.assetKind == .audio {
            AudioPreviewPlayer(item: item)
        } else if item.assetKind == .image {
            OverlayImagePreview(path: item.assetPath, scale: imageScale)
        } else {
            PreviewDocumentBlock(title: item.title, text: textSummary(for: item), minHeight: 520)
                .frame(maxWidth: 820)
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
                Text("Prompt")
                    .font(StudioFont.caption(12))
                    .foregroundStyle(StudioColor.secondaryText)
                    .tracking(1.2)

                Spacer()

                HStack(spacing: 10) {
                    previewActionButton("pencil", help: "编辑") {
                        state.requestInlineEdit(item)
                    }
                    previewActionButton("doc.on.doc", help: "复制提示词") {
                        state.copySelectedPrompt()
                    }
                    previewActionButton("arrow.down.circle", help: "下载") {
                        state.isPreviewPresented = false
                        state.modal = .export
                    }
                    previewActionButton("clock", help: "历史版本") {
                        state.isPreviewPresented = false
                        state.modal = .versionHistory
                    }
                }
            }

            previewPromptContent
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.top, 58)
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
        ViewThatFits(in: .vertical) {
            previewPromptTextView
                .fixedSize(horizontal: false, vertical: true)
                .promptContainer()

            ScrollView {
                previewPromptTextView
            }
            .frame(height: max(72, maxHeight))
            .transparentScrollArea()
            .promptContainer()
        }
        .frame(maxWidth: .infinity)
    }

    private var previewPromptTextView: some View {
        Text(previewPromptText)
            .font(StudioFont.font(13))
            .lineSpacing(4)
            .foregroundStyle(previewPromptText.isEmpty ? StudioColor.tertiaryText : StudioColor.text)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(14)
    }

    private var previewPromptText: String {
        let prompt = item.currentVersion?.prompt.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return prompt.isEmpty ? "暂无 Prompt" : prompt
    }

    private var previewHasPrompt: Bool {
        !(item.currentVersion?.prompt.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
    }

    private var previewTopChips: some View {
        FlowLayout(spacing: 8) {
            ForEach(previewTopChipTexts, id: \.self) { text in
                chip(text)
            }
        }
    }

    private var previewReferenceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("参考资产")
                .font(StudioFont.caption(12))
                .foregroundStyle(StudioColor.secondaryText)
                .tracking(1.2)

            LazyVGrid(columns: previewReferenceColumns, alignment: .leading, spacing: 8) {
                ForEach(item.referenceAssets.prefix(8)) { reference in
                    ReferenceAssetPreview(reference: reference)
                        .frame(width: 62, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(StudioColor.hairline, lineWidth: 1))
                }
            }
        }
    }

    private var previewBottomChips: some View {
        FlowLayout(spacing: 10) {
            ForEach(previewBottomChipTexts, id: \.self) { text in
                chip(text)
            }
        }
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

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(StudioFont.font(11))
            .foregroundStyle(StudioColor.secondaryText)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(StudioColor.control))
            .overlay(Capsule().stroke(StudioColor.hairline, lineWidth: 1))
    }

    private func previewActionButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
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
        case "arrow.down.circle":
            .circleArrowDown
        case "clock":
            .history
        default:
            .copy
        }
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
    @State private var text = ""
    @State private var loadedItemID = ""

    var body: some View {
        HStack(spacing: 0) {
            editorPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.leading, 42)
                .padding(.trailing, 34)
                .padding(.vertical, 42)

            inspectorPane
                .frame(width: 360)
                .frame(maxHeight: .infinity)
                .background(StudioColor.panel.opacity(0.96))
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(StudioColor.hairline)
                        .frame(width: 1)
                }
        }
        .onAppear(perform: loadText)
        .onChange(of: item.id) { _, _ in loadText() }
    }

    private var editorPane: some View {
        ZStack(alignment: .topLeading) {
            MarkdownDocumentEditor(
                text: $text,
                isEditable: false,
                scrollResetID: item.id,
                contentFontSize: 13,
                syntaxMode: TextSyntaxMode.infer(for: item)
            )

            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("暂无文档信息")
                    .font(StudioFont.font(13))
                    .foregroundStyle(StudioColor.tertiaryText)
                    .padding(.leading, 62)
                    .padding(.top, 18)
                    .allowsHitTesting(false)
            }
        }
    }

    private var inspectorPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.title)
                        .font(StudioFont.font(15, weight: .semibold))
                        .foregroundStyle(StudioColor.text)
                        .lineLimit(3)

                    Text("\(item.modelName) · \(item.assetKind.displayName) · \(item.displayAspectRatio)")
                        .font(StudioFont.font(12))
                        .foregroundStyle(StudioColor.secondaryText)
                        .lineLimit(2)
                }

                metadataChips

                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("文档信息")
                    infoRow("行数", "\(max(1, text.components(separatedBy: .newlines).count))")
                    infoRow("字符", "\(text.count)")
                    infoRow("文件大小", fileSizeText(item.fileSize))
                    infoRow("文件名", URL(fileURLWithPath: item.assetPath).lastPathComponent)
                }

                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("操作")
                    HStack(spacing: 10) {
                        Button {
                            state.openMarkdownEditor(for: item)
                        } label: {
                            Label("编辑", systemImage: "pencil")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(CapsuleButtonStyle())

                        Button {
                            state.isPreviewPresented = false
                            state.modal = .export
                        } label: {
                            Label("导出", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(CapsuleButtonStyle())
                    }

                    Button {
                        state.copyMarkdownDocumentText(text)
                    } label: {
                        Label("复制文档信息", systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(CapsuleButtonStyle(filled: true))
                }
            }
            .padding(.top, 58)
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .transparentScrollArea()
    }

    private var metadataChips: some View {
        FlowLayout(spacing: 8) {
            DocumentSemanticChip(text: item.format.isEmpty ? "MD" : item.format.uppercased(), role: .format)
            DocumentSemanticChip(text: "\(max(1, text.components(separatedBy: .newlines).count)) 行", role: .count)
            DocumentSemanticChip(text: item.currentVersion?.version ?? "V1.0", role: .version)
            ForEach(item.tags.prefix(4), id: \.self) { tag in
                DocumentSemanticChip(text: tag, role: .tag)
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(StudioFont.caption(12))
            .tracking(1.2)
            .foregroundStyle(StudioColor.secondaryText)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(StudioFont.font(11))
                .foregroundStyle(StudioColor.tertiaryText)
            Text(value)
                .font(StudioFont.font(13))
                .foregroundStyle(StudioColor.text)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private func loadText() {
        guard loadedItemID != item.id else { return }
        text = state.markdownDocumentText(for: item)
        loadedItemID = item.id
    }

    private func fileSizeText(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 KB" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

struct MarkdownEditorOverlay: View {
    @EnvironmentObject private var state: AppState
    let item: PromptItem
    @State private var draftText = ""
    @State private var initialText = ""
    @State private var loadedItemID = ""
    @State private var showCloseConfirmation = false

    var body: some View {
        ZStack {
            StudioColor.appBackground
                .ignoresSafeArea()

            HStack(spacing: 0) {
                editorPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.leading, 42)
                    .padding(.trailing, 34)
                    .padding(.vertical, 42)

                inspectorPane
                    .frame(width: 360)
                    .frame(maxHeight: .infinity)
                    .background(StudioColor.panel.opacity(0.96))
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(StudioColor.hairline)
                            .frame(width: 1)
                    }
            }

            OverlayCloseButton(help: "取消") {
                requestClose()
            }
            .padding(.top, 28)
            .padding(.trailing, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(StudioColor.text)
        .transition(.opacity)
        .onAppear(perform: loadDraft)
        .onChange(of: item.id) { _, _ in loadDraft() }
        .confirmationDialog("放弃未保存的修改？", isPresented: $showCloseConfirmation) {
            Button("放弃修改", role: .destructive) {
                state.closeMarkdownEditor(returnToPreview: true)
            }
            Button("继续编辑", role: .cancel) {}
        }
        .background {
            MarkdownEditorKeyMonitor(
                onEscape: requestClose,
                onSave: save
            )
        }
    }

    private var editorPane: some View {
        ZStack(alignment: .topLeading) {
            MarkdownDocumentEditor(
                text: $draftText,
                isEditable: true,
                scrollResetID: item.id,
                syntaxMode: TextSyntaxMode.infer(for: item)
            )

            if draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("开始编写文档内容")
                    .font(StudioFont.font(13))
                    .foregroundStyle(StudioColor.tertiaryText)
                    .padding(.leading, 62)
                    .padding(.top, 18)
                    .allowsHitTesting(false)
            }
        }
    }

    private var inspectorPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Spacer()

                    Text(draftText == initialText ? "已保存" : "未保存")
                        .font(StudioFont.font(11))
                        .foregroundStyle(draftText == initialText ? StudioColor.tertiaryText : StudioColor.secondaryText)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(item.title)
                        .font(StudioFont.font(15, weight: .semibold))
                        .foregroundStyle(StudioColor.text)
                        .lineLimit(3)

                    Text("\(item.modelName) · \(item.assetKind.displayName) · \(item.displayAspectRatio)")
                        .font(StudioFont.font(12))
                        .foregroundStyle(StudioColor.secondaryText)
                        .lineLimit(2)
                }

                metadataChips

                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("文档信息")
                    infoRow("行数", "\(lineCount)")
                    infoRow("字符", "\(draftText.count)")
                    infoRow("文件大小", fileSizeText(item.fileSize))
                    infoRow("文件名", URL(fileURLWithPath: item.assetPath).lastPathComponent)
                }

                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("操作")
                    Button {
                        save()
                    } label: {
                        Label("保存", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(CapsuleButtonStyle(filled: true))
                    .disabled(draftText == initialText)

                    Button {
                        requestClose()
                    } label: {
                        Label("取消", systemImage: "xmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(CapsuleButtonStyle())
                }
            }
            .padding(.top, 58)
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .transparentScrollArea()
    }

    private var metadataChips: some View {
        FlowLayout(spacing: 8) {
            DocumentSemanticChip(text: item.format.isEmpty ? "MD" : item.format.uppercased(), role: .format)
            DocumentSemanticChip(text: "\(lineCount) 行", role: .count)
            DocumentSemanticChip(text: item.currentVersion?.version ?? "V1.0", role: .version)
            ForEach(item.tags.prefix(4), id: \.self) { tag in
                DocumentSemanticChip(text: tag, role: .tag)
            }
        }
    }

    private var lineCount: Int {
        max(1, draftText.components(separatedBy: .newlines).count)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(StudioFont.caption(12))
            .tracking(1.2)
            .foregroundStyle(StudioColor.secondaryText)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(StudioFont.font(11))
                .foregroundStyle(StudioColor.tertiaryText)
            Text(value)
                .font(StudioFont.font(13))
                .foregroundStyle(StudioColor.text)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private func loadDraft() {
        guard loadedItemID != item.id else { return }
        let text = state.markdownDocumentText(for: item)
        draftText = text
        initialText = text
        loadedItemID = item.id
    }

    private func save() {
        guard draftText != initialText else { return }
        state.saveMarkdownDocument(draftText, for: item)
        initialText = draftText
    }

    private func requestClose() {
        if draftText == initialText {
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

private struct PromptFormatOption: Identifiable, Equatable {
    let id: String
    let title: String

    static func options(for type: PromptType) -> [PromptFormatOption] {
        switch type {
        case .image:
            return [
                PromptFormatOption(id: "image_general", title: "通用图片"),
                PromptFormatOption(id: "image_character", title: "角色设定"),
                PromptFormatOption(id: "image_product", title: "产品图"),
                PromptFormatOption(id: "image_midjourney", title: "Midjourney 参数"),
                PromptFormatOption(id: "image_nano_banana", title: "Nano Banana 格式")
            ]
        case .video:
            return [
                PromptFormatOption(id: "video_general", title: "通用视频"),
                PromptFormatOption(id: "video_storyboard", title: "分镜脚本"),
                PromptFormatOption(id: "video_seedance_api_block", title: "Seedance API block"),
                PromptFormatOption(id: "video_kling_shot", title: "Kling 镜头"),
                PromptFormatOption(id: "video_shot_table", title: "镜头表")
            ]
        case .text:
            return [
                PromptFormatOption(id: "text_markdown", title: "Markdown"),
                PromptFormatOption(id: "text_json", title: "JSON"),
                PromptFormatOption(id: "text_yaml", title: "YAML"),
                PromptFormatOption(id: "text_txt", title: "TXT"),
                PromptFormatOption(id: "text_agent_handoff", title: "Agent handoff")
            ]
        case .audio:
            return [
                PromptFormatOption(id: "audio_voiceover", title: "旁白"),
                PromptFormatOption(id: "audio_voice_reference", title: "音色参考"),
                PromptFormatOption(id: "audio_music_mood", title: "音乐氛围"),
                PromptFormatOption(id: "audio_sound_effect", title: "音效"),
                PromptFormatOption(id: "audio_spoken_script", title: "口播稿")
            ]
        }
    }
}

struct PromptComposerOverlay: View {
    @EnvironmentObject private var state: AppState
    let mode: AppState.PromptComposerMode
    @State private var title = ""
    @State private var type: PromptType = .image
    @State private var modelId = "nano_banana_2"
    @State private var promptFormatID = ""
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
    @FocusState private var focusedCreateInput: CreateComposerInputField?

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

    var body: some View {
        createComposerBody
        .foregroundStyle(OPSColor.bodyText)
        .transition(.opacity)
        .onAppear(perform: loadDraft)
        .onChange(of: mode.id) { _, _ in loadDraft() }
        .confirmationDialog("放弃未保存的修改？", isPresented: $showCloseConfirmation) {
            Button("放弃修改", role: .destructive) {
                state.closePromptComposer()
            }
            Button("继续编辑", role: .cancel) {}
        }
        .background {
            EscapeKeyMonitor {
                requestClose()
            }
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
            let horizontalPadding: CGFloat = 42
            let verticalPadding: CGFloat = 42
            let headerHeight: CGFloat = 34
            let headerGap: CGFloat = 18
            let panelPadding: CGFloat = 24
            let columnSpacing: CGFloat = geometry.size.width >= 1_250 ? 40 : 28
            let panelWidth = max(0, geometry.size.width - horizontalPadding * 2)
            let panelHeight = max(0, geometry.size.height - verticalPadding * 2 - headerHeight - headerGap)
            let contentWidth = max(0, panelWidth - panelPadding * 2)
            let contentHeight = max(0, panelHeight - panelPadding * 2)
            let showsUploadColumn = type != .text
            let uploadWidth = showsUploadColumn ? min(360, max(300, contentWidth * 0.34)) : 0
            let leftWidth = showsUploadColumn ? max(0, contentWidth - columnSpacing - uploadWidth) : contentWidth
            let promptHeight = max(220, contentHeight - 226)
            let uploadBoxHeight = max(150, (contentHeight - 76) / 2)

            ZStack {
                CreateComposerColor.workspace
                    .ignoresSafeArea()

                VStack(alignment: .leading, spacing: headerGap) {
                    HStack(alignment: .center) {
                        Text(composerTitle)
                            .font(StudioFont.font(14, weight: .semibold))
                            .foregroundStyle(CreateComposerColor.primaryText)
                        Spacer()
                        Button(primaryActionTitle) {
                            save()
                        }
                        .buttonStyle(CreateComposerPrimaryButtonStyle())
                    }
                    .frame(width: panelWidth, height: headerHeight, alignment: .center)

                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .top, spacing: columnSpacing) {
                            VStack(alignment: .leading, spacing: 28) {
                                createHeaderControls(width: leftWidth)
                                .frame(width: leftWidth, alignment: .leading)

                                createPromptColumn(promptHeight: promptHeight)
                                    .frame(width: leftWidth, alignment: .topLeading)
                            }

                            if showsUploadColumn {
                                createUploadColumn(boxHeight: uploadBoxHeight)
                                    .frame(width: uploadWidth, alignment: .topLeading)
                            }
                        }
                        .frame(width: contentWidth, height: contentHeight, alignment: .topLeading)
                    }
                    .padding(panelPadding)
                    .frame(width: panelWidth, height: panelHeight, alignment: .topLeading)
                    .background(CreateComposerColor.documentBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(CreateComposerColor.documentBorder, lineWidth: 1)
                    )
                }
                .frame(width: panelWidth, height: headerHeight + headerGap + panelHeight, alignment: .topLeading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
    }

    private func createHeaderControls(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            createTypeTabs
                .frame(width: width, alignment: .leading)

            HStack(alignment: .center, spacing: 14) {
                createModelMenu
                    .frame(maxWidth: .infinity)
                createFormatMenu
                    .frame(maxWidth: .infinity)
            }
            .frame(width: width)
        }
    }

    private func createPromptColumn(promptHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            createField("标题") {
                createTextInput("请输入标题", text: $title)
            }

            createField("Prompt（提示词）") {
                createPromptTextArea(height: promptHeight)
            }
        }
    }

    private func createUploadColumn(boxHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            createField("上传提示词预览图") {
                previewImageDropZone(height: boxHeight)
            }

            createField("上传参考资产") {
                referenceImagesDropZone(height: boxHeight)
            }
        }
    }

    private var createTypeTabs: some View {
        HStack(spacing: 14) {
            ForEach(PromptType.allCases) { option in
                createTypeTab(option)
            }
        }
    }

    private func createTypeTab(_ option: PromptType) -> some View {
        let active = type == option
        let title = option.displayName.replacingOccurrences(of: " Prompt", with: "")
        return Button {
            type = option
            ensureModelMatchesType()
            ensurePromptFormatMatchesType()
        } label: {
            Text(title)
                .font(StudioFont.font(12, weight: .medium))
                .foregroundStyle(active ? CreateComposerColor.activeTabText : CreateComposerColor.secondaryText)
                .frame(width: 70, height: 34)
                .background(active ? StudioColor.primaryAction : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(active ? Color.clear : CreateComposerColor.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(title)
    }

    private var createModelMenu: some View {
        Menu {
            ForEach(modelOptions) { model in
                Button(model.name) {
                    modelId = model.id
                }
            }
        } label: {
            HStack(spacing: 12) {
                Text(activeModelName.isEmpty ? "选择模型" : activeModelName)
                    .font(StudioFont.font(13))
                    .foregroundStyle(activeModelName.isEmpty ? CreateComposerColor.placeholderText : CreateComposerColor.primaryText)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(StudioFont.symbol(11, weight: .semibold))
                    .foregroundStyle(CreateComposerColor.primaryText)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(CreateComposerColor.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(CreateComposerColor.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var createFormatMenu: some View {
        Menu {
            ForEach(promptFormatOptions) { option in
                Button(option.title) {
                    promptFormatID = option.id
                }
            }
        } label: {
            HStack(spacing: 12) {
                Text(activePromptFormatTitle)
                    .font(StudioFont.font(13))
                    .foregroundStyle(CreateComposerColor.primaryText)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(StudioFont.symbol(11, weight: .semibold))
                    .foregroundStyle(CreateComposerColor.primaryText)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(CreateComposerColor.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(CreateComposerColor.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }


    private func createField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(StudioFont.font(14))
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
        .frame(height: 46)
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
            TextEditor(text: $prompt)
                .font(StudioFont.font(13))
                .lineSpacing(4)
                .foregroundStyle(CreateComposerColor.primaryText)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: height)
                .background(Color.clear)
                .focused($focusedCreateInput, equals: .prompt)
        }
        .background(CreateComposerColor.fieldBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(CreateComposerColor.border, lineWidth: 1))
    }

    private func previewImageDropZone(height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isPreviewImageDropTarget ? CreateComposerColor.dropActive : CreateComposerColor.fieldBackground)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(CreateComposerColor.border, lineWidth: 1))

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
                    createUploadPlaceholder("拖拽或点击添加预览图")
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: height)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isPreviewImageDropTarget, perform: handlePreviewImageDrop)
    }

    private func referenceImagesDropZone(height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isReferenceDropTarget ? CreateComposerColor.dropActive : CreateComposerColor.fieldBackground)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(CreateComposerColor.border, lineWidth: 1))

            if existingReferenceAssets.isEmpty && referenceURLs.isEmpty {
                Button {
                    appendReferenceImages(AppKitBridge.chooseReferenceAssets())
                } label: {
                    createUploadPlaceholder("拖拽或点击添加参考资产")
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
                .padding(18)
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isReferenceDropTarget, perform: handleReferenceDrop)
    }

    private func createUploadPlaceholder(_ text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle")
                .font(StudioFont.symbol(20))
                .foregroundStyle(CreateComposerColor.secondaryText)
            Text(text)
                .font(StudioFont.font(13))
                .foregroundStyle(CreateComposerColor.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var createPreviewPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center) {
                Text("预览窗口")
                    .font(StudioFont.font(16, weight: .semibold))
                    .foregroundStyle(StudioColor.text)
                Spacer()
                OverlayCloseButton {
                    requestClose()
                }
            }

            if hasCreatePreviewContent {
                if hasTitle {
                    Text(previewTitle)
                        .font(StudioFont.font(15, weight: .semibold))
                        .foregroundStyle(StudioColor.text)
                        .lineLimit(3)
                }

                if let previewImageURL {
                    ComposerPreviewImage(path: previewImageURL.path, contentMode: .fit)
                        .frame(width: previewImageSize.width, height: previewImageSize.height)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(StudioColor.hairline, lineWidth: 1)
                        )
                }

                if !previewMetadataChips.isEmpty {
                    FlowLayout(spacing: 8) {
                        ForEach(previewMetadataChips, id: \.self) { chip in
                            composerPreviewChip(chip)
                        }
                    }
                }

                if !referenceURLs.isEmpty {
                    createPreviewReferenceSection
                }

                if hasPrompt {
                    Text("Prompt")
                        .font(StudioFont.caption(12))
                        .foregroundStyle(StudioColor.secondaryText)
                        .tracking(1.2)
                        .padding(.top, 6)

                    GeometryReader { proxy in
                        createPromptPreviewBox(maxHeight: proxy.size.height)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 34)
        .padding(.horizontal, 24)
        .padding(.bottom, 28)
        .background(StudioColor.panel)
    }

    private var createPreviewReferenceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("参考资产")
                .font(StudioFont.caption(12))
                .foregroundStyle(StudioColor.secondaryText)
                .tracking(1.2)

            LazyVGrid(columns: previewReferenceColumns, alignment: .leading, spacing: 8) {
                ForEach(allReferencePreviewAssets) { reference in
                    ReferenceAssetPreview(reference: reference)
                        .frame(width: 62, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
        }
    }

    private var hasTitle: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private var hasPrompt: Bool {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private var hasCreatePreviewContent: Bool {
        hasTitle || hasPrompt || previewImageURL != nil || !allReferencePreviewAssets.isEmpty || !previewMetadataChips.isEmpty
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
        ViewThatFits(in: .vertical) {
            createPromptPreviewText
                .fixedSize(horizontal: false, vertical: true)
                .promptContainer()

            ScrollView {
                createPromptPreviewText
            }
            .frame(height: max(72, maxHeight))
            .transparentScrollArea()
            .promptContainer()
        }
        .frame(maxWidth: .infinity)
    }

    private var createPromptPreviewText: some View {
        Text(prompt.trimmingCharacters(in: .whitespacesAndNewlines))
            .font(StudioFont.font(13))
            .lineSpacing(4)
            .foregroundStyle(StudioColor.text)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(14)
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

            HStack(spacing: 8) {
                typeSegmentedControl.frame(width: 146)
                modelMenu.frame(width: 166)
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
            counter(type.displayName.replacingOccurrences(of: " Prompt", with: ""), 0, showValue: false)
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

                composerField("类型") {
                    Picker("", selection: $type) {
                        ForEach(PromptType.allCases) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .labelsHidden()
                }

                composerField("模型") {
                    Picker("", selection: $modelId) {
                        ForEach(modelOptions) { model in
                            Text(model.name).tag(model.id)
                        }
                    }
                    .labelsHidden()
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

    private var activeModelName: String {
        modelOptions.first(where: { $0.id == modelId })?.name ?? ""
    }

    private var activePromptFormat: PromptFormatOption {
        promptFormatOptions.first(where: { $0.id == promptFormatID }) ?? promptFormatOptions[0]
    }

    private var activePromptFormatTitle: String {
        activePromptFormat.title
    }

    private var promptFormatOptions: [PromptFormatOption] {
        PromptFormatOption.options(for: type)
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
        if !activeModelName.isEmpty {
            chips.append(activeModelName)
        }
        chips.append(activePromptFormatTitle)
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
        isEditing ? "编辑Prompt" : "新建Prompt"
    }

    private var primaryActionTitle: String {
        isEditing ? "保存" : "创建"
    }

    private func composerPreviewChip(_ text: String) -> some View {
        Text(text)
            .font(StudioFont.font(12))
            .foregroundStyle(StudioColor.secondaryText)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Capsule().fill(StudioColor.control))
    }

    private var modelOptions: [ModelProfile] {
        let matching = state.models.filter { $0.id != "all" && $0.type == type }
        if !matching.isEmpty {
            return matching
        }
        return [ModelProfile(id: "local_asset", name: "Local Asset", type: type, parameters: [])]
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

    private var typeSegmentedControl: some View {
        HStack(spacing: 4) {
            ForEach(PromptType.allCases) { option in
                Button {
                    type = option
                    ensureModelMatchesType()
                } label: {
                    Text(option.displayName.replacingOccurrences(of: " Prompt", with: ""))
                        .font(StudioFont.font(12, weight: type == option ? .semibold : .regular))
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .foregroundStyle(type == option ? Color.white : OPSColor.buttonText)
                        .background(type == option ? Color(hex: 0x6C6C6C) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(OPSColor.buttonBackground)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private var modelMenu: some View {
        Menu {
            ForEach(modelOptions) { model in
                Button(model.name) {
                    modelId = model.id
                }
            }
        } label: {
            HStack {
                Text(modelOptions.first(where: { $0.id == modelId })?.name ?? "选择模型")
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(StudioFont.symbol(10))
            }
            .font(StudioFont.font(12))
            .foregroundStyle(OPSColor.buttonText)
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(OPSColor.buttonBackground)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain)
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

    private func ensureModelMatchesType() {
        let options = modelOptions
        if !options.contains(where: { $0.id == modelId }), let first = options.first {
            modelId = first.id
        }
    }

    private func ensurePromptFormatMatchesType() {
        let options = promptFormatOptions
        if !options.contains(where: { $0.id == promptFormatID }), let first = options.first {
            promptFormatID = first.id
        }
    }

    private func loadDraft() {
        switch mode {
        case .create:
            title = ""
            type = .image
            modelId = defaultModelID(for: .image)
            promptFormatID = PromptFormatOption.options(for: .image)[0].id
            prompt = ""
            negativePrompt = ""
            tags = []
            parameters = ""
            note = ""
            saveAsNewVersion = true
            previewImageURL = nil
            referenceURLs = []
        case .edit:
            guard let item = editingItem else { return }
            title = item.title
            type = item.type
            modelId = item.modelId
            promptFormatID = existingPromptFormatID(for: item)
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
        }
        ensureModelMatchesType()
        ensurePromptFormatMatchesType()
        initialSignature = draftSignature
    }

    private func save() {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        switch mode {
        case .create:
            state.createPrompt(
                title: cleanTitle.isEmpty ? "未命名 Prompt" : cleanTitle,
                type: type,
                modelId: modelId,
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
                type: type,
                modelId: modelId,
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
            type.rawValue,
            modelId,
            promptFormatID,
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
        var result = parsedParameters
        result["prompt_format_id"] = activePromptFormat.id
        result["prompt_format"] = activePromptFormat.title
        return result
    }

    private func defaultModelID(for type: PromptType) -> String {
        state.models.first(where: { $0.id != "all" && $0.type == type })?.id ?? "local_asset"
    }

    private func existingPromptFormatID(for item: PromptItem) -> String {
        let options = PromptFormatOption.options(for: item.type)
        let parameters = item.currentVersion?.parameters ?? [:]
        if let id = parameters["prompt_format_id"], options.contains(where: { $0.id == id }) {
            return id
        }
        if let title = parameters["prompt_format"], let match = options.first(where: { $0.title == title }) {
            return match.id
        }
        return options[0].id
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
    static let documentBorder = Color(hex: 0x363A3F)
    static let inputBackground = StudioColor.control
    static let fieldBackground = Color(hex: 0x2D2D2D)
    static let dropActive = StudioColor.panelRaised
    static let border = Color(hex: 0x3E3E3E)
    static let primaryText = StudioColor.text
    static let secondaryText = StudioColor.secondaryText.opacity(0.92)
    static let placeholderText = StudioColor.tertiaryText
    static let activeTabText = StudioColor.primaryActionText
}

private struct CreateComposerPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(StudioFont.font(12, weight: .medium))
            .foregroundStyle(StudioColor.primaryActionText)
            .frame(width: 120, height: 34)
            .background(configuration.isPressed ? Color.white.opacity(0.82) : StudioColor.primaryAction)
            .clipShape(Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
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
    @StateObject private var loader = OverlayImageLoader()

    var body: some View {
        ZStack {
            if let image = loader.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
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
    @Published var image: NSImage?

    func load(_ path: String) async {
        image = await Task.detached(priority: .utility) {
            NSImage(contentsOfFile: path)
        }.value
    }
}

private struct OverlayCloseButton: View {
    var help = "关闭"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(StudioFont.symbol(12, weight: .semibold))
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .background(Circle().fill(StudioColor.control.opacity(0.92)))
        .overlay(Circle().stroke(StudioColor.hairline, lineWidth: 1))
        .help(help)
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
    let onZoom: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onExit: onExit, onZoom: onZoom)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onExit = onExit
        context.coordinator.onZoom = onZoom
    }

    final class Coordinator {
        var onExit: () -> Void
        var onZoom: (CGFloat) -> Void
        private var keyMonitor: Any?
        private var scrollMonitor: Any?

        init(onExit: @escaping () -> Void, onZoom: @escaping (CGFloat) -> Void) {
            self.onExit = onExit
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
                    return event
                }
            }

            if scrollMonitor == nil {
                scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    guard event.modifierFlags.contains(.command) else { return event }
                    let rawDelta = event.scrollingDeltaY == 0 ? -event.deltaY : event.scrollingDeltaY
                    guard rawDelta != 0 else { return nil }
                    let normalized = max(-0.28, min(0.28, CGFloat(rawDelta) / 240))
                    self?.onZoom(normalized)
                    return nil
                }
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
        HStack(spacing: spacing) {
            content
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
