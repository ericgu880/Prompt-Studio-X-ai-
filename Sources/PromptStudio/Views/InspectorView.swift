import SwiftUI
import PromptStudioCore

struct InspectorView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var thumbnailHovered = false
    @State private var isEditing = false
    @State private var draftPrompt = ""
    @State private var draftNegativePrompt = ""
    @State private var markdownDocumentText = ""
    @State private var markdownDocumentItemID = ""
    @State private var isPromptExpanded = false
    @State private var isNegativePromptExpanded = false

    var body: some View {
        Group {
            if let item = state.selectedItem {
                inspector(for: item)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("未选择素材")
                        .font(StudioFont.font(14))
                    Text("选择瀑布流中的图片后，这里会显示 Prompt、参数、标签和文件信息。")
                        .foregroundStyle(StudioColor.secondaryText)
                    Spacer()
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 22)
                .padding(.top, StudioLayout.contentTopPadding)
                .foregroundStyle(StudioColor.text)
            }
        }
        .background(StudioColor.panel)
        .onChange(of: state.selectedID) { _, _ in
            stopEditing()
            markdownDocumentText = ""
            markdownDocumentItemID = ""
            isPromptExpanded = false
            isNegativePromptExpanded = false
        }
        .onChange(of: state.inspectorEditRequest) { _, request in
            guard let request,
                  let item = state.selectedItem,
                  request.itemID == item.id else { return }
            startEditing(item)
        }
    }

    @ViewBuilder
    private func inspector(for item: PromptItem) -> some View {
        if item.assetKind == .markdown {
            markdownInspector(for: item)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(item)
                    Divider().overlay(StudioColor.hairline)
                    if !item.referenceAssets.isEmpty {
                        referenceSection(item)
                    }
                    if isEditing || hasPrompt(item) {
                        promptSection(item)
                    }
                    if isEditing || hasNegativePrompt(item) {
                        negativeSection(item)
                    }
                    if isEditing || !item.tags.isEmpty {
                        tagSection(item)
                    }
                    actionSection(item)
                    if !isEditing {
                        versionSection(item)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
                .padding(.top, StudioLayout.contentTopPadding)
            }
        }
    }

    private func markdownInspector(for item: PromptItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            markdownHeader(item)
                .padding(.horizontal, 20)
                .padding(.top, StudioLayout.contentTopPadding)
                .padding(.bottom, 14)

            ZStack(alignment: .topLeading) {
                MarkdownDocumentEditor(
                    text: isEditing ? $draftPrompt : $markdownDocumentText,
                    isEditable: isEditing
                )

                if activeMarkdownText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("暂无文档信息")
                        .font(StudioFont.font(13))
                        .foregroundStyle(StudioColor.tertiaryText)
                        .padding(.leading, 58)
                        .padding(.top, 16)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 20)

            actionSection(item)
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 18)
                .background(StudioColor.panel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: item.id) {
            loadMarkdownDocument(item)
        }
    }

    private func markdownHeader(_ item: PromptItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title)
                .font(StudioFont.font(14, weight: .semibold))
                .foregroundStyle(StudioColor.text)
                .lineLimit(2)

            Text(markdownMetadata(for: item))
                .font(StudioFont.font(11))
                .foregroundStyle(StudioColor.tertiaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func header(_ item: PromptItem) -> some View {
        HStack(alignment: .top, spacing: 14) {
            AssetMediaView(item: item)
                .frame(width: 112, height: 112)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(thumbnailHovered ? StudioColor.primaryAction.opacity(0.42) : StudioColor.hairline, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .onHover { thumbnailHovered = $0 }
                .animation(StudioMotion.fast(reduceMotion: reduceMotion), value: thumbnailHovered)
                .onTapGesture { state.previewSelected() }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Text(item.title)
                        .font(StudioFont.font(14))
                        .lineLimit(2)
                    Spacer()
                }
                infoLine("素材", item.assetKind.displayName)
                infoLine("模型", item.modelName)
                if item.width > 0, item.height > 0 {
                    infoLine("尺寸", "\(item.displayAspectRatio) (\(item.width) x \(item.height))")
                } else {
                    infoLine("格式", item.format.isEmpty ? item.assetKind.displayName : item.format)
                }
                infoLine("创建时间", item.createdAt.formatted(date: .numeric, time: .shortened))
            }
        }
        .foregroundStyle(StudioColor.text)
    }

    private func tagSection(_ item: PromptItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("分类 / 标签")
            FlowLayout(spacing: 8) {
                ForEach(item.tags, id: \.self) { tag in
                    Text("\(tag) ×")
                        .font(StudioFont.font(12))
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(Capsule().fill(StudioColor.control))
                        .overlay(Capsule().stroke(StudioColor.hairline, lineWidth: 1))
                }
                Button {
                    state.modal = .tagManager
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 30, height: 28)
                }
                .buttonStyle(IconCircleButtonStyle())
            }
        }
    }

    private func promptSection(_ item: PromptItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("提示词 (Prompt)")
            if isEditing {
                InlinePromptEditor(text: $draftPrompt, minHeight: 150, maxHeight: 320, placeholder: "输入 Prompt")
            } else {
                CollapsiblePromptPanel(
                    text: item.currentVersion?.prompt ?? "",
                    collapsedLineLimit: 7,
                    expandedMaxHeight: 320,
                    minHeight: 96,
                    textColor: StudioColor.text,
                    isExpanded: $isPromptExpanded
                )
            }
        }
    }

    private func negativeSection(_ item: PromptItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("负面提示词（可选）")
            if isEditing {
                InlinePromptEditor(text: $draftNegativePrompt, minHeight: 96, maxHeight: 220, placeholder: "输入负面提示词")
            } else {
                CollapsiblePromptPanel(
                    text: item.currentVersion?.negativePrompt ?? "",
                    collapsedLineLimit: 5,
                    expandedMaxHeight: 220,
                    minHeight: 62,
                    textColor: StudioColor.secondaryText,
                    isExpanded: $isNegativePromptExpanded
                )
            }
        }
    }

    private func referenceSection(_ item: PromptItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("参考图")
            HStack(spacing: 10) {
                ForEach(item.referenceAssets.prefix(4)) { reference in
                    ThumbnailImage(path: reference.path)
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioColor.hairline, lineWidth: 1))
                }
            }
        }
    }

    private func actionSection(_ item: PromptItem) -> some View {
        HStack(spacing: 8) {
            if isEditing {
                Button {
                    saveInlineEdit(item)
                } label: {
                    Text("保存")
                        .frame(width: 92)
                }
                .buttonStyle(CapsuleButtonStyle(filled: true))

                Button {
                    stopEditing()
                } label: {
                    Text("取消").frame(maxWidth: .infinity)
                }
                .buttonStyle(CapsuleButtonStyle())
            } else {
                Button {
                    startEditing(item)
                } label: {
                    Image(systemName: "pencil")
                        .accessibilityLabel("编辑")
                }
                .buttonStyle(IconCircleButtonStyle())
                .help("编辑")

                Button {
                    state.modal = .export
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .accessibilityLabel("导出")
                }
                .buttonStyle(IconCircleButtonStyle())
                .help("导出")

                Button {
                    if item.assetKind == .markdown {
                        state.copyMarkdownDocumentText(activeMarkdownText)
                    } else {
                        state.copySelectedPrompt()
                    }
                } label: {
                    Text(item.assetKind == .markdown ? "复制文档信息" : "复制提示词").frame(maxWidth: .infinity)
                }
                .buttonStyle(CapsuleButtonStyle(filled: true))
            }
        }
    }

    private func versionSection(_ item: PromptItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("历史版本")
                Spacer()
                Button("查看全部版本") { state.modal = .versionHistory }
                    .buttonStyle(TextHoverButtonStyle())
            }
            HStack(spacing: 8) {
                ForEach(item.versions.prefix(4)) { version in
                    Text(version.version)
                        .font(StudioFont.font(14))
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(Capsule().fill(version.id == item.currentVersion?.id ? StudioColor.selection : StudioColor.control))
                        .overlay(Capsule().stroke(version.id == item.currentVersion?.id ? StudioColor.primaryAction.opacity(0.72) : StudioColor.hairline, lineWidth: 1))
                }
            }
        }
    }

    private func fileInfoSection(_ item: PromptItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("文件信息")
            VStack(spacing: 10) {
                infoGrid("文件尺寸", fileSizeText(item.fileSize), "素材类型", item.assetKind.displayName)
                if item.width > 0, item.height > 0 {
                    infoGrid("格式", item.format, "分辨率", item.displaySize)
                } else {
                    infoGrid("格式", item.format.isEmpty ? "FILE" : item.format, "路径", URL(fileURLWithPath: item.assetPath).lastPathComponent)
                }
            }
            Button {
                state.modal = .export
            } label: {
                Label("导出", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(CapsuleButtonStyle())
        }
    }

    private func infoLine(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(StudioFont.font(11))
                .foregroundStyle(StudioColor.tertiaryText)
            Text(value)
                .font(StudioFont.font(14))
                .foregroundStyle(StudioColor.text)
                .lineLimit(2)
        }
    }

    private func infoGrid(_ a: String, _ b: String, _ c: String, _ d: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            infoPair(a, b)
            infoPair(c, d)
        }
    }

    private func infoPair(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(StudioFont.font(11))
                .foregroundStyle(StudioColor.secondaryText)
            Text(value)
                .font(StudioFont.font(14))
                .foregroundStyle(StudioColor.text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(StudioFont.caption(12))
            .tracking(1.2)
            .foregroundStyle(StudioColor.secondaryText)
    }

    private func hasPrompt(_ item: PromptItem) -> Bool {
        item.currentVersion?.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private func hasNegativePrompt(_ item: PromptItem) -> Bool {
        item.currentVersion?.negativePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private func fileSizeText(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 KB" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func startEditing(_ item: PromptItem) {
        if item.assetKind == .markdown {
            let text = state.markdownDocumentText(for: item)
            markdownDocumentText = text
            markdownDocumentItemID = item.id
            draftPrompt = text
        } else {
            draftPrompt = item.currentVersion?.prompt ?? ""
        }
        draftNegativePrompt = item.currentVersion?.negativePrompt ?? ""
        withAnimation(StudioMotion.fast(reduceMotion: reduceMotion)) {
            isEditing = true
        }
    }

    private func stopEditing() {
        withAnimation(StudioMotion.fast(reduceMotion: reduceMotion)) {
            isEditing = false
        }
        draftPrompt = ""
        draftNegativePrompt = ""
    }

    private func saveInlineEdit(_ item: PromptItem) {
        if item.assetKind == .markdown {
            markdownDocumentText = draftPrompt
            markdownDocumentItemID = item.id
            state.saveMarkdownDocument(draftPrompt, for: item)
            stopEditing()
            return
        }

        state.savePrompt(
            title: item.title,
            type: item.type,
            modelId: item.modelId,
            prompt: draftPrompt,
            negativePrompt: draftNegativePrompt,
            tags: item.tags,
            parameters: item.currentVersion?.parameters ?? [:],
            note: "右侧栏快速编辑",
            saveAsNewVersion: true
        )
        stopEditing()
    }

    private var activeMarkdownText: String {
        isEditing ? draftPrompt : markdownDocumentText
    }

    private func loadMarkdownDocument(_ item: PromptItem) {
        guard item.assetKind == .markdown, markdownDocumentItemID != item.id else { return }
        markdownDocumentText = state.markdownDocumentText(for: item)
        markdownDocumentItemID = item.id
    }

    private func markdownMetadata(for item: PromptItem) -> String {
        let lineCount = max(1, activeMarkdownText.components(separatedBy: .newlines).count)
        let fileName = URL(fileURLWithPath: item.assetPath).lastPathComponent
        let format = item.format.isEmpty ? "MD" : item.format
        return [format, "\(lineCount) 行", fileSizeText(item.fileSize), fileName]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

private struct CollapsiblePromptPanel: View {
    let text: String
    let collapsedLineLimit: Int
    let expandedMaxHeight: CGFloat
    let minHeight: CGFloat
    let textColor: Color
    @Binding var isExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var panelWidth: CGFloat = 0
    @State private var fullTextHeight: CGFloat = 0
    @State private var collapsedTextHeight: CGFloat = 0
    @State private var isHovered = false

    private let horizontalPadding: CGFloat = 12
    private let verticalPadding: CGFloat = 12
    private let lineSpacing: CGFloat = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isExpanded && isOverflowing {
                ScrollView {
                    promptText(lineLimit: nil)
                        .padding(.horizontal, horizontalPadding)
                        .padding(.vertical, verticalPadding)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: expandedTextHeight)
            } else {
                promptText(lineLimit: collapsedLineLimit)
                    .padding(.horizontal, horizontalPadding)
                    .padding(.vertical, verticalPadding)
                    .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
            }

            if isOverflowing {
                HStack {
                    Spacer()
                    Button {
                        withAnimation(StudioMotion.fast(reduceMotion: reduceMotion)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(isExpanded ? "收起" : "展开")
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(StudioFont.symbol(9, weight: .medium))
                        }
                        .font(StudioFont.font(11))
                        .foregroundStyle(StudioColor.secondaryText)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(Capsule().fill(StudioColor.control))
                        .overlay(Capsule().stroke(StudioColor.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovered ? StudioColor.panelRaised : StudioColor.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isHovered ? StudioColor.primaryAction.opacity(0.18) : StudioColor.hairline, lineWidth: 1)
        )
        .background(widthReader)
        .overlay(alignment: .topLeading) {
            measurementViews
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovered = $0 }
        .onChange(of: text) { _, _ in
            isExpanded = false
        }
        .animation(StudioMotion.fast(reduceMotion: reduceMotion), value: isHovered)
    }

    private var isOverflowing: Bool {
        fullTextHeight > collapsedTextHeight + 1
    }

    private var textWidth: CGFloat {
        max(0, panelWidth - horizontalPadding * 2)
    }

    private var expandedTextHeight: CGFloat {
        max(minHeight, expandedMaxHeight - 42)
    }

    private var widthReader: some View {
        GeometryReader { proxy in
            Color.clear
                .preference(key: PromptPanelWidthPreferenceKey.self, value: proxy.size.width)
        }
        .onPreferenceChange(PromptPanelWidthPreferenceKey.self) { width in
            panelWidth = width
        }
    }

    @ViewBuilder
    private var measurementViews: some View {
        if textWidth > 0 {
            ZStack(alignment: .topLeading) {
                measuredPromptText(lineLimit: nil, key: "full")
                measuredPromptText(lineLimit: collapsedLineLimit, key: "collapsed")
            }
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onPreferenceChange(PromptTextHeightPreferenceKey.self) { heights in
                fullTextHeight = heights["full"] ?? fullTextHeight
                collapsedTextHeight = heights["collapsed"] ?? collapsedTextHeight
            }
        }
    }

    private func promptText(lineLimit: Int?) -> some View {
        Text(text)
            .font(StudioFont.font(14))
            .lineSpacing(lineSpacing)
            .foregroundStyle(textColor)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func measuredPromptText(lineLimit: Int?, key: String) -> some View {
        promptText(lineLimit: lineLimit)
            .frame(width: textWidth, alignment: .leading)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: PromptTextHeightPreferenceKey.self,
                        value: [key: proxy.size.height]
                    )
                }
            )
    }
}

private struct PromptPanelWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct PromptTextHeightPreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct InlinePromptEditor: View {
    @Binding var text: String
    let minHeight: CGFloat
    let maxHeight: CGFloat
    let placeholder: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(StudioFont.font(14))
                    .foregroundStyle(StudioColor.tertiaryText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 15)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(StudioFont.font(14))
                .lineSpacing(3)
                .foregroundStyle(StudioColor.text)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: minHeight, maxHeight: maxHeight)
                .background(Color.clear)
        }
        .background(isHovered ? StudioColor.panelRaised : StudioColor.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isHovered ? StudioColor.primaryAction.opacity(0.32) : StudioColor.hairline, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovered = $0 }
        .animation(StudioMotion.fast(reduceMotion: reduceMotion), value: isHovered)
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
