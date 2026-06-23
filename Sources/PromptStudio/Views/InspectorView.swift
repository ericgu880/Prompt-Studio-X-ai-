import SwiftUI
import AppKit
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
    @State private var mediaPromptHovered = false
    @State private var mediaPromptCopyFeedback = false
    @State private var markdownPreviewHovered = false
    @State private var markdownPreviewCopyFeedback = false

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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(StudioColor.panel)
        .onChange(of: state.selectedID) { _, selectedID in
            stopEditing()
            if let item = state.items.first(where: { $0.id == selectedID }), item.isTextDocumentLike {
                loadMarkdownDocument(item)
            } else {
                markdownDocumentText = ""
                markdownDocumentItemID = ""
            }
            isPromptExpanded = false
            isNegativePromptExpanded = false
            mediaPromptCopyFeedback = false
            markdownPreviewCopyFeedback = false
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
        if item.isTextDocumentLike {
            markdownInspector(for: item)
        } else if isEditing {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(item)
                    Divider().overlay(StudioColor.hairline)
                    if !item.referenceAssets.isEmpty {
                        referenceSection(item)
                    }
                    promptSection(item)
                    negativeSection(item)
                    tagSection(item)
                    actionSection(item)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .padding(.top, 24)
            }
            .transparentScrollArea()
        } else if item.isPromptPrimaryAsset {
            mediaReadOnlyInspector(item)
        } else {
            fileReadOnlyInspector(item)
        }
    }

    private func mediaReadOnlyInspector(_ item: PromptItem) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(item.title)
                .font(StudioFont.font(14, weight: .bold))
                .foregroundStyle(StudioColor.text)
                .lineLimit(3)

            VStack(alignment: .leading, spacing: 10) {
                mediaPreviewThumbnail(item)
                mediaTopChips(item)
            }

            if !item.referenceAssets.isEmpty {
                mediaReferenceSection(item)
            }

            HStack(alignment: .center, spacing: 10) {
                SidePanelSectionTitle(title: "Prompt")

                Spacer(minLength: 12)

                SidePanelActionRow(actions: mediaPromptActions(item))
            }

            mediaPromptContent(item)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 28)
        .padding(.top, 24)
    }

    private func fileReadOnlyInspector(_ item: PromptItem) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(item.title)
                .font(StudioFont.font(14, weight: .bold))
                .foregroundStyle(StudioColor.text)
                .lineLimit(3)

            VStack(alignment: .leading, spacing: 10) {
                filePreviewSummary(item)
                fileTopChips(item)
            }

            HStack(alignment: .center, spacing: 10) {
                SidePanelSectionTitle(title: "文件信息")

                Spacer(minLength: 12)

                fileActionButtons(item)
            }

            fileDetailSection(item)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 28)
        .padding(.top, 24)
    }

    private func filePreviewSummary(_ item: PromptItem) -> some View {
        mediaPreviewThumbnail(item)
    }

    private func fileTopChips(_ item: PromptItem) -> some View {
        SidePanelChipFlow(texts: fileTopChipTexts(item))
    }

    private func fileTopChipTexts(_ item: PromptItem) -> [String] {
        var chips = [fileFormatText(item)]
        if item.width > 0, item.height > 0 {
            chips.append(item.displaySize)
        }
        chips.append(fileSizeText(item.fileSize))
        chips.append("附件")
        return chips.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func fileActionButtons(_ item: PromptItem) -> some View {
        SidePanelActionRow(actions: [
            SidePanelAction(icon: .externalLink, help: "打开") { state.openSelectedInDefaultApplication() },
            SidePanelAction(icon: .copy, help: "复制文件") { state.copySelectedFile() },
            SidePanelAction(icon: .link, help: "复制路径") { state.copySelectedFilePath() }
        ])
    }

    private func fileDetailSection(_ item: PromptItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            infoLine("格式", fileFormatText(item))
            if item.width > 0, item.height > 0 {
                infoLine("尺寸", item.displaySize)
            }
            infoLine("大小", fileSizeText(item.fileSize))
            infoLine("文件名", URL(fileURLWithPath: item.assetPath).lastPathComponent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func markdownInspector(for item: PromptItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            markdownHeader(item)
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 14)

            ZStack(alignment: .topLeading) {
                MarkdownDocumentEditor(
                    text: $markdownDocumentText,
                    isEditable: false,
                    scrollResetID: item.id,
                    contentFontSize: 13,
                    syntaxMode: TextSyntaxMode.infer(for: item),
                    revealsScrollerOnHover: true,
                    onCopyAll: copyMarkdownPreviewText,
                    onCopySelection: copyMarkdownPreviewFragment
                )

                if activeMarkdownText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("暂无文档信息")
                        .font(StudioFont.font(13))
                        .foregroundStyle(StudioColor.tertiaryText)
                        .padding(.leading, 58)
                        .padding(.top, 16)
                        .allowsHitTesting(false)
                }

                markdownPreviewCopyHint
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onHover { hovering in
                markdownPreviewHovered = hovering
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: item.id) {
            loadMarkdownDocument(item)
        }
    }

    @ViewBuilder
    private var markdownPreviewCopyHint: some View {
        if markdownPreviewHovered && !activeMarkdownText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    HStack(spacing: 5) {
                        LucideIcon(kind: .copy)
                            .frame(width: 12, height: 12)
                        Text(markdownPreviewCopyFeedback ? "已复制文档信息" : "点击文档复制")
                    }
                    .font(StudioFont.font(11))
                    .foregroundStyle(StudioColor.secondaryText)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(Capsule().fill(StudioColor.control.opacity(0.94)))
                    .padding(8)
                    .transition(.opacity)
                }
            }
            .allowsHitTesting(false)
        }
    }

    private func markdownHeader(_ item: PromptItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item.title)
                .font(StudioFont.font(14, weight: .bold))
                .foregroundStyle(StudioColor.text)
                .lineLimit(3)

            markdownHeaderChips(item)

            HStack(alignment: .center, spacing: 12) {
                Text("文本信息")
                    .font(StudioFont.caption(12))
                    .foregroundStyle(StudioColor.secondaryText)
                    .tracking(1.2)

                Spacer(minLength: 12)

                markdownActionButtons(item)
            }
            .padding(.top, 4)
        }
    }

    private func markdownActionButtons(_ item: PromptItem) -> some View {
        HStack(spacing: 10) {
            mediaActionButton("pencil", help: "编辑") {
                state.openMarkdownEditor(for: item)
            }
            mediaActionButton("doc.on.doc", help: "复制文档信息") {
                state.copyMarkdownDocumentText(activeMarkdownText)
            }
            mediaActionButton("arrow.down.circle", help: "导出") {
                state.modal = .export
            }
            mediaActionButton("clock", help: "历史版本") {
                state.modal = .versionHistory
            }
        }
    }

    private func markdownHeaderChips(_ item: PromptItem) -> some View {
        FlowLayout(spacing: 8) {
            metadataChip(item.format.isEmpty ? "MD" : item.format.uppercased())
            metadataChip("\(max(1, activeMarkdownText.components(separatedBy: .newlines).count)) 行")
            metadataChip(item.currentVersion?.version ?? "V1.0")
            ForEach(item.tags.prefix(4), id: \.self) { tag in
                metadataChip(tag)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metadataChip(_ text: String) -> some View {
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

            VStack(alignment: .leading, spacing: 5) {
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

    private func mediaPreviewThumbnail(_ item: PromptItem) -> some View {
        GeometryReader { proxy in
            let availableWidth = max(1, min(Self.mediaPreviewMaxWidth, proxy.size.width))
            let size = mediaPreviewSize(for: item, maxWidth: availableWidth)
            ZStack(alignment: .leading) {
                Color.clear

                AssetMediaView(item: item, contentMode: .fit)
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(StudioColor.hairline, lineWidth: 1)
                    )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(height: Self.mediaPreviewHeight)
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private func mediaPreviewSize(for item: PromptItem, maxWidth: CGFloat) -> CGSize {
        let aspectRatio: CGFloat
        if item.width > 0, item.height > 0 {
            aspectRatio = max(0.15, CGFloat(item.width) / CGFloat(item.height))
        } else {
            aspectRatio = 16.0 / 9.0
        }
        let widthAtMaxHeight = Self.mediaPreviewHeight * aspectRatio
        if widthAtMaxHeight <= maxWidth {
            return CGSize(width: widthAtMaxHeight, height: Self.mediaPreviewHeight)
        }
        return CGSize(width: maxWidth, height: maxWidth / aspectRatio)
    }

    private static let mediaPreviewMaxWidth: CGFloat = 260
    private static let mediaPreviewHeight: CGFloat = 80

    @ViewBuilder
    private func mediaPromptContent(_ item: PromptItem) -> some View {
        if hasPrompt(item) {
            GeometryReader { proxy in
                mediaPromptBox(item, maxHeight: proxy.size.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        } else {
            Text("暂无提示词")
                .font(StudioFont.font(12))
                .foregroundStyle(StudioColor.tertiaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private func mediaPromptBox(_ item: PromptItem, maxHeight: CGFloat) -> some View {
        GeometryReader { _ in
            SidePanelPromptTextBox(
                text: mediaPromptText(item),
                maxHeight: maxHeight,
                resetID: item.id,
                isPlaceholder: (item.currentVersion?.prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                isInteractive: hasPrompt(item),
                isHovered: mediaPromptHovered,
                copyFeedback: mediaPromptCopyFeedback,
                onCopyAll: copyMediaPrompt,
                onCopySelection: copyMediaPromptFragment
            )
        }
        .frame(maxWidth: .infinity)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovering in
            mediaPromptHovered = hovering
        }
        .animation(StudioMotion.fast(reduceMotion: reduceMotion), value: mediaPromptHovered)
    }

    private func copyMediaPrompt() {
        state.copySelectedPrompt()
        mediaPromptCopyFeedback = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            mediaPromptCopyFeedback = false
        }
    }

    private func copyMediaPromptFragment(_ fragment: String) {
        state.copyPromptFragment(fragment)
        mediaPromptCopyFeedback = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            mediaPromptCopyFeedback = false
        }
    }

    private func copyMarkdownPreviewText() {
        state.copyMarkdownDocumentText(activeMarkdownText)
        markdownPreviewCopyFeedback = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            markdownPreviewCopyFeedback = false
        }
    }

    private func copyMarkdownPreviewFragment(_ fragment: String) {
        state.copyMarkdownDocumentText(fragment)
        markdownPreviewCopyFeedback = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            markdownPreviewCopyFeedback = false
        }
    }

    private func mediaPromptText(_ item: PromptItem) -> String {
        let prompt = item.currentVersion?.prompt.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return prompt.isEmpty ? "暂无 Prompt" : prompt
    }

    private func mediaTopChips(_ item: PromptItem) -> some View {
        SidePanelChipFlow(texts: mediaTopChipTexts(item))
    }

    private func mediaBottomChips(_ item: PromptItem) -> some View {
        SidePanelChipFlow(texts: mediaBottomChipTexts(item), spacing: 10)
    }

    private func mediaTopChipTexts(_ item: PromptItem) -> [String] {
        [
            item.format.isEmpty ? item.assetKind.displayName : item.format.uppercased(),
            item.width > 0 && item.height > 0 ? item.displaySize : fileSizeText(item.fileSize),
            item.currentVersion?.version ?? "V1.0",
            item.tags.first ?? item.category
        ]
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .prefix(4)
        .map { $0 }
    }

    private func mediaBottomChipTexts(_ item: PromptItem) -> [String] {
        var chips: [String] = []
        chips.append(item.currentVersion?.version ?? "V1.0")
        chips.append(item.format.isEmpty ? item.assetKind.displayName : item.format.uppercased())
        if item.width > 0, item.height > 0 {
            chips.append(item.displayAspectRatio)
        } else {
            chips.append(fileSizeText(item.fileSize))
        }
        chips.append(item.tags.first ?? item.category)
        return chips.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func mediaPromptActions(_ item: PromptItem) -> [SidePanelAction] {
        [
            SidePanelAction(icon: .pencil, help: "编辑") { state.requestInlineEdit(item) },
            SidePanelAction(icon: .copy, help: "复制提示词") { state.copySelectedPrompt() },
            SidePanelAction(icon: .circleArrowDown, help: "下载") { state.modal = .export },
            SidePanelAction(icon: .history, help: "历史版本") { state.modal = .versionHistory }
        ]
    }

    private func mediaActionButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
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
        case "arrow.up.right.square":
            .externalLink
        case "clock":
            .history
        case "link":
            .link
        default:
            .copy
        }
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
            sectionTitle("参考资产")
            HStack(spacing: 10) {
                ForEach(item.referenceAssets.prefix(4)) { reference in
                    ReferenceAssetPreview(reference: reference)
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioColor.hairline, lineWidth: 1))
                }
            }
        }
    }

    private func mediaReferenceSection(_ item: PromptItem) -> some View {
        SidePanelReferenceSection(references: item.referenceAssets)
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
                    LucideIcon(kind: .pencil)
                        .frame(width: 14, height: 14)
                        .accessibilityLabel("编辑")
                }
                .buttonStyle(IconCircleButtonStyle())
                .help("编辑")

                Button {
                    state.modal = .export
                } label: {
                    LucideIcon(kind: .circleArrowDown)
                        .frame(width: 14, height: 14)
                        .accessibilityLabel("导出")
                }
                .buttonStyle(IconCircleButtonStyle())
                .help("导出")

                Button {
                    if item.isTextDocumentLike {
                        state.copyMarkdownDocumentText(activeMarkdownText)
                    } else {
                        state.copySelectedPrompt()
                    }
                } label: {
                    Text(item.isTextDocumentLike ? "复制文档信息" : "复制提示词").frame(maxWidth: .infinity)
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

    private func fileFormatText(_ item: PromptItem) -> String {
        item.format.isEmpty ? item.assetKind.displayName : item.format.uppercased()
    }

    private func startEditing(_ item: PromptItem) {
        if item.isTextDocumentLike {
            state.openMarkdownEditor(for: item)
            return
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
        if item.isTextDocumentLike {
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
        guard item.isTextDocumentLike, markdownDocumentItemID != item.id else { return }
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

private struct MidjourneyPromptInfoPanel: View {
    let item: PromptItem
    let copyAction: () -> Void
    let editAction: () -> Void
    let downloadAction: () -> Void
    let historyAction: () -> Void

    private var prompt: String {
        item.currentVersion?.prompt.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var body: some View {
        GeometryReader { proxy in
            ViewThatFits(in: .vertical) {
                panelContent(prompt: promptText)

                panelContent(prompt: scrollingPrompt)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func panelContent<PromptContent: View>(prompt: PromptContent) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(item.title)
                    .font(StudioFont.font(14, weight: .semibold))
                    .foregroundStyle(StudioColor.text)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                HStack(spacing: 12) {
                    iconButton("pencil", help: "编辑", action: editAction)
                    iconButton("doc.on.doc", help: "复制提示词", action: copyAction)
                    iconButton("arrow.down.circle", help: "下载", action: downloadAction)
                    iconButton("clock", help: "历史版本", action: historyAction)
                }
            }

            prompt

            if !metadataChips.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(metadataChips, id: \.self) { chip in
                        Text(chip)
                            .font(StudioFont.font(11))
                            .foregroundStyle(StudioColor.secondaryText)
                            .padding(.horizontal, 9)
                            .frame(height: 24)
                            .background(Capsule().fill(StudioColor.control.opacity(0.78)))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var promptText: some View {
        if prompt.isEmpty {
            Text("暂无 Prompt")
                .font(StudioFont.font(14))
                .foregroundStyle(StudioColor.tertiaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .promptContainer()
        } else {
            Text(prompt)
                .font(StudioFont.font(14))
                .lineSpacing(5)
                .foregroundStyle(StudioColor.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(14)
                .promptContainer()
        }
    }

    private var scrollingPrompt: some View {
        TransparentOverlayScrollView {
            Text(prompt.isEmpty ? "暂无 Prompt" : prompt)
                .font(StudioFont.font(14))
                .lineSpacing(5)
                .foregroundStyle(prompt.isEmpty ? StudioColor.tertiaryText : StudioColor.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(14)
                .padding(.trailing, 10)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .promptContainer()
    }

    private var metadataChips: [String] {
        var chips: [String] = []
        chips.append(item.currentVersion?.version ?? "V1.0")
        chips.append(item.format.isEmpty ? item.assetKind.displayName : item.format.uppercased())
        if item.width > 0, item.height > 0 {
            chips.append(item.displayAspectRatio)
        }
        if let parameters = item.currentVersion?.parameters {
            chips.append(contentsOf: parameters.sorted(by: { $0.key < $1.key }).prefix(3).map { "\($0.key) \($0.value)" })
        }
        chips.append(contentsOf: item.tags.prefix(2))
        return chips.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func iconButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            LucideIcon(kind: lucideKind(for: systemName))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
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
                TransparentOverlayScrollView {
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
