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

            if item.assetKind == .markdown {
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
        } else if item.assetKind == .image {
            OverlayImagePreview(path: item.assetPath, scale: imageScale)
        } else {
            PreviewDocumentBlock(title: item.title, text: textSummary(for: item), minHeight: 520)
                .frame(maxWidth: 820)
        }
    }

    private var previewInspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 12) {
                    PreviewCloseButton {
                        state.isPreviewPresented = false
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
                }

                metadataChips

                if item.assetKind != .image && item.assetKind != .video {
                    PreviewDocumentBlock(title: "文件摘要", text: textSummary(for: item), minHeight: 160)
                }

                if let prompt = item.currentVersion?.prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    PreviewDocumentBlock(title: "Prompt", text: prompt, minHeight: 180)
                }

                if let negative = item.currentVersion?.negativePrompt, !negative.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    PreviewDocumentBlock(title: "Negative Prompt", text: negative, minHeight: 112)
                }

                if let parameters = item.currentVersion?.parameters, !parameters.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("参数")
                            .font(StudioFont.caption(12))
                            .tracking(1.2)
                            .foregroundStyle(StudioColor.secondaryText)
                        FlowLayout(spacing: 8) {
                            ForEach(parameters.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                                Text("\(key) \(value)")
                                    .font(StudioFont.font(11))
                                    .foregroundStyle(StudioColor.text)
                                    .padding(.horizontal, 10)
                                    .frame(height: 26)
                                    .background(Capsule().fill(StudioColor.control))
                                    .overlay(Capsule().stroke(StudioColor.hairline, lineWidth: 1))
                            }
                        }
                    }
                }

                Button {
                    if item.assetKind == .markdown {
                        state.copyMarkdownDocumentText(state.markdownDocumentText(for: item))
                    } else {
                        state.copySelectedPrompt()
                    }
                } label: {
                    Label(item.assetKind == .markdown ? "复制文档信息" : "复制提示词", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(CapsuleButtonStyle(filled: true))
            }
            .padding(.top, 58)
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
    }

    private var metadataChips: some View {
        FlowLayout(spacing: 8) {
            chip(item.format.isEmpty ? item.assetKind.displayName : item.format.uppercased())
            chip(item.displaySize)
            chip(item.currentVersion?.version ?? "V1.0")
            ForEach(item.tags.prefix(4), id: \.self) { tag in
                chip(tag)
            }
        }
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

    private func textSummary(for item: PromptItem) -> String {
        guard [.markdown, .json, .text, .data].contains(item.assetKind),
              let data = try? Data(contentsOf: URL(fileURLWithPath: item.assetPath), options: [.mappedIfSafe]) else {
            return "\(item.assetKind.displayName) 文件，可通过右键菜单用默认应用打开。"
        }
        let previewData = Data(data.prefix(8_000))
        let text = String(data: previewData, encoding: .utf8)
            ?? String(data: previewData, encoding: .utf16)
            ?? String(data: previewData, encoding: .isoLatin1)
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "\(item.assetKind.displayName) 文件无可读取文本摘要。" : trimmed
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
            MarkdownDocumentEditor(text: $text, isEditable: false, scrollResetID: item.id)

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
                HStack(alignment: .top, spacing: 12) {
                    PreviewCloseButton {
                        state.isPreviewPresented = false
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
    }

    private var metadataChips: some View {
        FlowLayout(spacing: 8) {
            chip(item.format.isEmpty ? "MD" : item.format.uppercased())
            chip("\(max(1, text.components(separatedBy: .newlines).count)) 行")
            chip(item.currentVersion?.version ?? "V1.0")
            ForEach(item.tags.prefix(4), id: \.self) { tag in
                chip(tag)
            }
        }
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
            MarkdownDocumentEditor(text: $draftText, isEditable: true, scrollResetID: item.id)

            if draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("开始编写 Markdown 文档")
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
                    Button {
                        requestClose()
                    } label: {
                        Image(systemName: "xmark")
                            .font(StudioFont.symbol(13, weight: .semibold))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .background(Circle().fill(StudioColor.control))
                    .overlay(Circle().stroke(StudioColor.hairline, lineWidth: 1))
                    .help("取消")

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
    }

    private var metadataChips: some View {
        FlowLayout(spacing: 8) {
            chip(item.format.isEmpty ? "MD" : item.format.uppercased())
            chip("\(lineCount) 行")
            chip(item.currentVersion?.version ?? "V1.0")
            ForEach(item.tags.prefix(4), id: \.self) { tag in
                chip(tag)
            }
        }
    }

    private var lineCount: Int {
        max(1, draftText.components(separatedBy: .newlines).count)
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

struct PromptComposerOverlay: View {
    @EnvironmentObject private var state: AppState
    let mode: AppState.PromptComposerMode
    @State private var title = ""
    @State private var type: PromptType = .image
    @State private var modelId = "nano_banana_2"
    @State private var prompt = ""
    @State private var negativePrompt = ""
    @State private var tags: [String] = []
    @State private var tagDraft = ""
    @State private var parameters = ""
    @State private var note = ""
    @State private var saveAsNewVersion = true
    @State private var referenceURLs: [URL] = []
    @State private var initialSignature = ""
    @State private var showCloseConfirmation = false
    @State private var isReferenceDropTarget = false

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
        ZStack {
            StudioColor.appBackground
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                HStack(spacing: 0) {
                    editorPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    sidePane
                        .frame(width: 350)
                        .frame(maxHeight: .infinity)
                        .background(StudioColor.panel)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(StudioColor.hairline).frame(width: 1)
                        }
                }
            }
        }
        .foregroundStyle(StudioColor.text)
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

    private var header: some View {
        HStack(spacing: 14) {
            Button {
                requestClose()
            } label: {
                Image(systemName: "xmark")
                    .font(StudioFont.symbol(13, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .background(Circle().fill(StudioColor.control))
            .overlay(Circle().stroke(StudioColor.hairline, lineWidth: 1))
            .help("关闭")

            VStack(alignment: .leading, spacing: 3) {
                Text(isEditing ? "编辑 Prompt" : "新建 Prompt")
                    .font(StudioFont.font(15, weight: .semibold))
                Text(isEditing ? "默认保存为新版本，保留历史记录" : "创建一条新的本地 Prompt 资产")
                    .font(StudioFont.font(12))
                    .foregroundStyle(StudioColor.secondaryText)
            }

            Spacer()

            Button("取消") { requestClose() }
                .buttonStyle(TextHoverButtonStyle())

            Button {
                save()
            } label: {
                Text(isEditing ? "保存版本" : "创建 Prompt")
                    .frame(minWidth: 96)
            }
            .buttonStyle(CapsuleButtonStyle(filled: true))
        }
        .padding(.horizontal, 24)
        .padding(.top, StudioLayout.contentTopPadding)
        .padding(.bottom, 14)
        .background(StudioColor.appBackground)
        .overlay(alignment: .bottom) {
            Rectangle().fill(StudioColor.hairline).frame(height: 1)
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

                composerSection("参考图") {
                    referenceDropZone
                }
            }
            .padding(20)
        }
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
                .font(StudioFont.caption(12))
                .tracking(1.2)
                .foregroundStyle(StudioColor.secondaryText)
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
                    .background(Capsule().fill(StudioColor.control))
                    .overlay(Capsule().stroke(StudioColor.hairline, lineWidth: 1))
                }
            }

            TextField("输入标签后回车", text: $tagDraft)
                .textFieldStyle(.plain)
                .font(StudioFont.font(13))
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(StudioColor.control)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioColor.hairline, lineWidth: 1))
                .onSubmit(addTag)
        }
    }

    private var referenceDropZone: some View {
        Button {
            appendReferenceImages(AppKitBridge.chooseReferenceImages())
        } label: {
            VStack(spacing: 9) {
                Image(systemName: "photo.on.rectangle")
                    .font(StudioFont.symbol(20))
                Text(referenceSummary)
                    .font(StudioFont.font(12))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            .foregroundStyle(StudioColor.secondaryText)
            .frame(maxWidth: .infinity)
            .frame(height: 96)
            .background(isReferenceDropTarget ? StudioColor.blueSoft : StudioColor.control.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(isReferenceDropTarget ? StudioColor.blue : StudioColor.hairline)
            )
        }
        .buttonStyle(.plain)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isReferenceDropTarget, perform: handleReferenceDrop)
    }

    private var referenceSummary: String {
        if !referenceURLs.isEmpty {
            return "已选择 \(referenceURLs.count) 张参考图"
        }
        if let editingItem, !editingItem.referenceAssets.isEmpty {
            return "已有 \(editingItem.referenceAssets.count) 张参考图"
        }
        return "拖拽或点击添加参考图"
    }

    private var modelOptions: [ModelProfile] {
        let matching = state.models.filter { $0.id != "all" && $0.type == type }
        return matching.isEmpty ? state.models.filter { $0.id != "all" } : matching
    }

    private var estimatedTokenCount: Int {
        let text = [prompt, negativePrompt].joined(separator: " ")
        let latinWords = text.split { $0.isWhitespace || $0.isPunctuation }.count
        let cjkCount = text.unicodeScalars.filter { $0.value >= 0x4E00 && $0.value <= 0x9FFF }.count
        return max(0, latinWords + Int(Double(cjkCount) / 1.7))
    }

    private func counter(_ title: String, _ value: Int) -> some View {
        Text("\(title) \(value)")
            .font(StudioFont.font(12))
            .foregroundStyle(StudioColor.secondaryText)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Capsule().fill(StudioColor.panel))
            .overlay(Capsule().stroke(StudioColor.hairline, lineWidth: 1))
    }

    private func loadDraft() {
        switch mode {
        case .create:
            title = ""
            type = .image
            modelId = defaultModelID(for: .image)
            prompt = ""
            negativePrompt = ""
            tags = []
            parameters = ""
            note = ""
            saveAsNewVersion = true
            referenceURLs = []
        case .edit:
            guard let item = editingItem else { return }
            title = item.title
            type = item.type
            modelId = item.modelId
            prompt = item.currentVersion?.prompt ?? ""
            negativePrompt = item.currentVersion?.negativePrompt ?? ""
            tags = item.tags
            parameters = (item.currentVersion?.parameters ?? [:]).map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n")
            note = ""
            saveAsNewVersion = true
            referenceURLs = []
        }
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
                parameters: parsedParameters,
                note: note,
                saveAsNewVersion: saveAsNewVersion
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
            prompt,
            negativePrompt,
            tags.joined(separator: "\u{1f}"),
            parameters,
            note,
            "\(saveAsNewVersion)",
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

    private func defaultModelID(for type: PromptType) -> String {
        state.models.first(where: { $0.id != "all" && $0.type == type })?.id ?? "nano_banana_2"
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
        let imageExtensions = Set(["png", "jpg", "jpeg", "webp"])
        let next = urls.filter { imageExtensions.contains($0.pathExtension.lowercased()) }
        for url in next where !referenceURLs.contains(url) {
            referenceURLs.append(url)
        }
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

private struct PreviewCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(StudioFont.symbol(13, weight: .semibold))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .background(Circle().fill(StudioColor.control))
        .overlay(Circle().stroke(StudioColor.hairline, lineWidth: 1))
        .help("关闭")
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
