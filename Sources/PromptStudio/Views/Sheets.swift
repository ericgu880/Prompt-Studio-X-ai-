import AVKit
import SwiftUI
import PromptStudioCore
import UniformTypeIdentifiers

struct NewPromptSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var type: PromptType = .image
    @State private var modelId = "image_2"
    @State private var prompt = ""
    @State private var negativePrompt = ""
    @State private var tags = ["风景", "人物"]
    @State private var tagDraft = ""
    @State private var referenceURLs: [URL] = []
    @State private var isReferenceDropTarget = false

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                form
                    .padding(.horizontal, 28)
                    .padding(.vertical, 22)
            }
            .transparentScrollArea()

            footer
        }
        .foregroundStyle(StudioColor.text)
        .background(
            LinearGradient(
                colors: [StudioColor.panelRaised.opacity(0.96), StudioColor.panel.opacity(0.98)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(StudioColor.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(width: 940, height: 790)
        .onChange(of: type) { _, newValue in
            if !modelOptions.contains(where: { $0.id == modelId }) {
                modelId = defaultModelID(for: newValue)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 18) {
            Image(systemName: "wand.and.stars")
                .font(StudioFont.symbol(28, weight: .medium))
                .foregroundStyle(StudioColor.blue)
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 6) {
                Text("新建 Prompt")
                    .font(StudioFont.font(14, weight: .semibold))
                Text("创建一条新的图片或视频 Prompt，并保存到资源库")
                    .font(StudioFont.font(14))
                    .foregroundStyle(StudioColor.tertiaryText)
            }

            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 22) {
            NewPromptField(title: "标题", help: "为这条 Prompt 起一个清晰、易识别的名称") {
                NewPromptTextField(placeholder: "例如：日落海滩全景", text: $title)
            }

            HStack(alignment: .top, spacing: 22) {
                NewPromptField(title: "类型", help: "选择 Prompt 的应用类型") {
                    NewPromptMenuField(
                        icon: type == .video ? "video" : "photo",
                        title: type.displayName,
                        accent: StudioColor.blue
                    ) {
                        Button("图片 Prompt") { type = .image }
                        Button("视频 Prompt") { type = .video }
                    }
                }

                NewPromptField(title: "模型", help: "选择使用的模型") {
                    NewPromptMenuField(
                        icon: "cube",
                        title: activeModelName,
                        accent: StudioColor.dusk
                    ) {
                        ForEach(modelOptions) { model in
                            Button(model.name) { modelId = model.id }
                        }
                    }
                }
            }

            NewPromptField(title: "Prompt", help: "描述你想要生成的画面或内容，越详细越好") {
                NewPromptEditor(placeholder: "请输入 Prompt 内容...", text: $prompt, minHeight: 130)
            }

            NewPromptField(title: "负面提示词", help: "描述你不希望在生成结果中出现的内容") {
                NewPromptEditor(placeholder: "请输入负面提示词（可选）", text: $negativePrompt, minHeight: 96)
            }

            NewPromptField(title: "标签", help: "添加关键词标签，便于分类与检索") {
                tagInput
            }

            NewPromptField(title: "参考资产（可选）", help: "上传图片、音频或视频参考，帮助 Prompt 保持上下文。") {
                referenceUpload
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Spacer()
            Button("取消") { dismiss() }
                .buttonStyle(NewPromptSecondaryButtonStyle())
            Button("创建") {
                state.createPrompt(
                    title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名 Prompt" : title,
                    type: type,
                    modelId: modelId,
                    prompt: prompt,
                    negativePrompt: negativePrompt,
                    tags: tags,
                    referenceURLs: referenceURLs
                )
                dismiss()
            }
            .buttonStyle(NewPromptPrimaryButtonStyle())
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .background(StudioColor.panel.opacity(0.96))
    }

    private var tagInput: some View {
        HStack(spacing: 8) {
            ForEach(tags, id: \.self) { tag in
                HStack(spacing: 7) {
                    Text(tag)
                    Button {
                        tags.removeAll { $0 == tag }
                    } label: {
                        Image(systemName: "xmark")
                            .font(StudioFont.symbol(10, weight: .medium))
                    }
                    .buttonStyle(.plain)
                }
                .font(StudioFont.font(12))
                .foregroundStyle(StudioColor.text)
                .padding(.horizontal, 11)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(StudioColor.blueSoft))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(StudioColor.blue.opacity(0.55), lineWidth: 1))
            }

            TextField("输入后回车创建标签", text: $tagDraft)
                .textFieldStyle(.plain)
                .font(StudioFont.font(12))
                .onSubmit(addTagFromDraft)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 50)
        .background(StudioColor.control.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(StudioColor.hairline)
        )
    }

    private var referenceUpload: some View {
        Button {
            appendReferenceImages(AppKitBridge.chooseReferenceAssets())
        } label: {
            VStack(spacing: 12) {
                Image(systemName: "square.and.arrow.up")
                    .font(StudioFont.symbol(24))
                    .frame(width: 48, height: 48)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(StudioColor.control))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(StudioColor.hairline, lineWidth: 1))

                VStack(spacing: 5) {
                    Text(referenceURLs.isEmpty ? "将参考资产拖拽到此处，或点击上传" : "已选择 \(referenceURLs.count) 个参考资产")
                        .font(StudioFont.font(14, weight: .medium))
                    Text(referenceURLs.isEmpty ? "支持图片、音频、视频" : referenceURLs.map(\.lastPathComponent).joined(separator: "、"))
                        .font(StudioFont.font(14))
                        .foregroundStyle(StudioColor.tertiaryText)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 118)
            .background(isReferenceDropTarget ? StudioColor.blueSoft.opacity(0.9) : StudioColor.control.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(isReferenceDropTarget ? StudioColor.blue : StudioColor.blue.opacity(0.75))
            )
        }
        .buttonStyle(.plain)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isReferenceDropTarget, perform: handleReferenceDrop)
    }

    private var modelOptions: [ModelProfile] {
        let matching = state.models.filter { $0.id != "all" && $0.type == type }
        return matching.isEmpty ? state.models.filter { $0.id != "all" } : matching
    }

    private var activeModelName: String {
        state.models.first(where: { $0.id == modelId })?.name ?? defaultModelID(for: type)
    }

    private func defaultModelID(for type: PromptType) -> String {
        state.models.first(where: { $0.id != "all" && $0.type == type })?.id ?? "nano_banana_2"
    }

    private func addTagFromDraft() {
        let next = tagDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !next.isEmpty, !tags.contains(next) else {
            tagDraft = ""
            return
        }
        tags.append(next)
        tagDraft = ""
    }

    private func appendReferenceImages(_ urls: [URL]) {
        let next = urls.filter { url in
            switch AppKitBridge.assetKind(for: url) {
            case .image, .audio, .video:
                true
            default:
                false
            }
        }
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

private struct NewPromptField<Content: View>: View {
    let title: String
    let help: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text(title)
                    .font(StudioFont.font(14, weight: .semibold))
                Image(systemName: "info.circle")
                    .font(StudioFont.symbol(12))
                    .foregroundStyle(StudioColor.tertiaryText)
                Text(help)
                    .font(StudioFont.font(14))
                    .foregroundStyle(StudioColor.tertiaryText)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NewPromptTextField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(StudioFont.font(14))
            .padding(.horizontal, 14)
            .frame(height: 44)
            .frame(maxWidth: .infinity)
            .background(StudioColor.control.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(StudioColor.hairline, lineWidth: 1))
    }
}

private struct NewPromptMenuField<Content: View>: View {
    let icon: String
    let title: String
    let accent: Color
    @ViewBuilder let menu: Content

    var body: some View {
        Menu {
            menu
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(StudioFont.symbol(16, weight: .medium))
                    .foregroundStyle(accent)
                    .frame(width: 22)
                Text(title)
                    .font(StudioFont.font(14, weight: .medium))
                    .foregroundStyle(StudioColor.text)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(StudioFont.symbol(10, weight: .medium))
                    .foregroundStyle(StudioColor.tertiaryText)
            }
            .padding(.horizontal, 16)
            .frame(height: 46)
            .frame(maxWidth: .infinity)
            .background(StudioColor.control.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(StudioColor.hairline, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }
}

private struct NewPromptEditor: View {
    let placeholder: String
    @Binding var text: String
    let minHeight: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(StudioFont.font(13.5))
                    .foregroundStyle(StudioColor.tertiaryText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(StudioFont.font(13.5))
                .lineSpacing(3)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: minHeight)
        }
        .background(StudioColor.control.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(StudioColor.hairline, lineWidth: 1))
    }
}

private struct NewPromptPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(StudioFont.button(12))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 28)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(configuration.isPressed ? StudioColor.blue.opacity(0.72) : StudioColor.blue))
            .opacity(configuration.isPressed ? 0.86 : 1)
    }
}

private struct NewPromptSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(StudioFont.button(12))
            .foregroundStyle(StudioColor.text)
            .padding(.horizontal, 26)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(configuration.isPressed ? StudioColor.controlPressed : StudioColor.control))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(StudioColor.hairline, lineWidth: 1))
    }
}

struct ImportSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PromptFormShell(title: "导入素材") {
            VStack(spacing: 12) {
                Image(systemName: "tray.and.arrow.down")
                    .font(StudioFont.symbol(42))
                Text("拖拽图片、视频、文本到主窗口，或点击下方选择文件")
                    .font(StudioFont.font(14))
                Text("导入后会复制到本地资料库，并进入待完善信息状态。")
                    .foregroundStyle(StudioColor.secondaryText)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 320)
        } footer: {
            Button("取消") { dismiss() }
                .buttonStyle(TextHoverButtonStyle())
            Button("选择文件") {
                let urls = AppKitBridge.chooseImportFiles()
                if !urls.isEmpty {
                    state.importFiles(urls)
                    dismiss()
                }
            }
            .buttonStyle(CapsuleButtonStyle(filled: true))
        }
        .frame(width: 640, height: 500)
    }
}

struct FilterSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var hasPromptOnly = false
    @State private var hasReferenceOnly = false
    @State private var type: PromptType?

    var body: some View {
        PromptFormShell(title: "高级筛选") {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    FilterToggle(title: "图片 Prompt", active: type == .image) { type = type == .image ? nil : .image }
                    FilterToggle(title: "视频 Prompt", active: type == .video) { type = type == .video ? nil : .video }
                }
                Toggle("仅有 Prompt", isOn: $hasPromptOnly)
                Toggle("仅有参考资产", isOn: $hasReferenceOnly)
                Text("模型、标签和文件夹筛选可通过顶部 Tab 与左侧导航组合使用。")
                    .foregroundStyle(StudioColor.secondaryText)
            }
        } footer: {
            Button("清空") {
                state.filter = PromptFilter()
                dismiss()
            }
            .buttonStyle(TextHoverButtonStyle())
            Button("应用") {
                state.filter.type = type
                state.filter.favoriteOnly = false
                state.filter.hasPromptOnly = hasPromptOnly
                state.filter.hasReferenceOnly = hasReferenceOnly
                dismiss()
            }
            .buttonStyle(CapsuleButtonStyle(filled: true))
        }
        .frame(width: 520, height: 420)
    }
}

struct TagManagerSheet: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        PromptFormShell(title: "标签管理") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(state.tags) { tag in
                    HStack {
                        Circle().fill(StudioColor.primaryAction).frame(width: 8, height: 8)
                        Text(tag.name)
                        Spacer()
                        Text("\(tag.count)")
                            .foregroundStyle(StudioColor.secondaryText)
                        Button("筛选") { state.setCollection(.tag(tag.name)) }
                            .buttonStyle(TextHoverButtonStyle())
                    }
                    .frame(height: 34)
                    Divider().overlay(StudioColor.hairline)
                }
                Text("MVP 支持标签查看和筛选；重命名、合并和颜色将在下一步接入。")
                    .font(StudioFont.font(14))
                    .foregroundStyle(StudioColor.secondaryText)
            }
        } footer: {
            Button("关闭") { state.modal = nil }
                .buttonStyle(CapsuleButtonStyle(filled: true))
        }
        .frame(width: 520, height: 520)
    }
}

struct VersionHistorySheet: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        PromptFormShell(title: "历史版本") {
            if let item = state.selectedItem {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(item.versions.reversed()) { version in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(version.version)
                                        .font(StudioFont.font(14))
                                    Spacer()
                                    Text(version.createdAt.formatted(date: .numeric, time: .shortened))
                                        .font(StudioFont.font(14))
                                        .foregroundStyle(StudioColor.secondaryText)
                                }
                                Text(version.prompt)
                                    .lineLimit(4)
                                    .font(StudioFont.font(13))
                                    .foregroundStyle(StudioColor.secondaryText)
                                HStack {
                                    Button("复制") {
                                        AppKitBridge.copyToPasteboard(version.prompt)
                                        state.toast = "已复制版本 Prompt"
                                    }
                                    .buttonStyle(TextHoverButtonStyle())
                                    Button("恢复为新版本") {
                                        state.restoreVersion(version)
                                    }
                                    .buttonStyle(TextHoverButtonStyle())
                                }
                            }
                            .padding(14)
                            .studioPanel(radius: 8)
                        }
                    }
                }
            }
        } footer: {
            Button("关闭") { state.modal = nil }
                .buttonStyle(CapsuleButtonStyle(filled: true))
        }
        .frame(width: 720, height: 620)
    }
}

struct ReferencesSheet: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        PromptFormShell(title: "参考资产管理") {
            if let item = state.selectedItem {
                VStack(alignment: .leading, spacing: 18) {
                    if item.referenceAssets.isEmpty {
                        Text("当前素材还没有参考资产。")
                            .font(StudioFont.font(13))
                            .foregroundStyle(StudioColor.secondaryText)
                    }

                    LazyVGrid(columns: referenceColumns, alignment: .leading, spacing: 16) {
                        ForEach(item.referenceAssets) { reference in
                            ReferenceAssetCard(reference: reference)
                        }
                        AddReferenceCard {
                            state.openImportAssets()
                        }
                    }
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } footer: {
            Button("关闭") { state.modal = nil }
                .buttonStyle(CapsuleButtonStyle(filled: true))
        }
        .frame(width: 760, height: 560)
    }

    private var referenceColumns: [GridItem] {
        [
            GridItem(.adaptive(minimum: 170, maximum: 190), spacing: 16, alignment: .top)
        ]
    }
}

private struct ReferenceAssetCard: View {
    let reference: ReferenceAsset

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ReferenceAssetPreview(reference: reference)
                .frame(maxWidth: .infinity)
                .frame(height: 108)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(reference.label)
                    .font(StudioFont.font(13, weight: .medium))
                    .foregroundStyle(StudioColor.text)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 36, alignment: .topLeading)

                Text(reference.type.isEmpty ? "参考资产" : reference.type)
                    .font(StudioFont.font(14))
                    .foregroundStyle(StudioColor.secondaryText)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .frame(height: 198, alignment: .top)
        .frame(maxWidth: .infinity)
        .studioPanel(radius: 8)
    }
}

private struct AddReferenceCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(StudioFont.symbol(24, weight: .regular))
                Text("添加参考资产")
                    .font(StudioFont.font(13, weight: .medium))
            }
            .foregroundStyle(StudioColor.text)
            .frame(maxWidth: .infinity)
            .frame(height: 198)
            .background(StudioColor.control)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(StudioColor.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

struct VariantSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PromptFormShell(title: "生成变体") {
            VStack(alignment: .leading, spacing: 14) {
                Text("MVP 不调用外部生图 API。这里会基于当前 Prompt 保存一个本地文本变体版本，后续可接入真实模型。")
                    .foregroundStyle(StudioColor.secondaryText)
                if let prompt = state.selectedItem?.currentVersion?.prompt {
                    Text(prompt)
                        .lineLimit(8)
                        .padding(12)
                        .studioPanel(radius: 8)
                }
            }
        } footer: {
            Button("取消") { dismiss() }
                .buttonStyle(TextHoverButtonStyle())
            Button("生成文本变体") {
                state.generateTextVariant()
                dismiss()
            }
            .buttonStyle(CapsuleButtonStyle(filled: true))
        }
        .frame(width: 620, height: 420)
    }
}

struct ExportSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PromptFormShell(title: "导出") {
            VStack(alignment: .leading, spacing: 16) {
                Text("选择导出格式。图片格式只适用于图片素材；Prompt 导出会保留完整内容。")
                    .foregroundStyle(StudioColor.secondaryText)
                if let item = state.selectedItem {
                    Text(item.title)
                        .font(StudioFont.font(14))
                    HStack(alignment: .top, spacing: 14) {
                        exportColumn(
                            title: "图片",
                            formats: [.imagePNG, .imageJPEG, .imagePDF],
                            item: item
                        )
                        exportColumn(
                            title: "Prompt",
                            formats: [.promptText, .promptMarkdown, .promptWord],
                            item: item
                        )
                    }
                    .padding(.top, 6)
                }
            }
        } footer: {
            Button("取消") { dismiss() }
                .buttonStyle(TextHoverButtonStyle())
        }
        .frame(width: 560, height: 390)
    }

    private func exportColumn(title: String, formats: [PromptStudioExportFormat], item: PromptItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(StudioFont.font(14, weight: .semibold))
                .foregroundStyle(StudioColor.text)
            ForEach(formats) { format in
                let enabled = !format.requiresImage || item.assetKind == .image
                Button {
                    dismiss()
                    DispatchQueue.main.async {
                        state.exportSelected(format: format)
                    }
                } label: {
                    HStack {
                        Text(format.title)
                        Spacer()
                        Image(systemName: "square.and.arrow.up")
                            .font(StudioFont.symbol(12, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(CapsuleButtonStyle())
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.45)
                .help(enabled ? "导出 \(format.title)" : "当前素材不是图片")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .studioPanel(radius: 8)
    }
}


struct SettingsSheet: View {
    @EnvironmentObject private var state: AppState
    @State private var selectedPage: SettingsPage = .library
    @AppStorage("promptStudio.thumbnailScale") private var thumbnailScale = 1.0

    var body: some View {
        HStack(spacing: 0) {
            settingsSidebar
                .frame(width: 236)
                .background(StudioColor.panel)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(StudioColor.hairline).frame(width: 1)
                }

            VStack(spacing: 0) {
                settingsTopBar
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        pageHeader
                        pageContent
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 24)
                }
                .transparentScrollArea()
                .background(StudioColor.appBackground)
            }
        }
        .foregroundStyle(StudioColor.text)
        .background(StudioColor.appBackground)
        .frame(width: 1180, height: 760)
        .onAppear {
            if let pageID = state.preferredSettingsPageID,
               let page = SettingsPage(rawValue: pageID) {
                selectedPage = page
                state.preferredSettingsPageID = nil
            }
        }
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(SettingsPage.Section.allCases) { section in
                        let pages = filteredPages(in: section)
                        if !pages.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(section.title)
                                    .font(StudioFont.font(11))
                                    .tracking(1.1)
                                    .foregroundStyle(StudioColor.tertiaryText)
                                    .padding(.horizontal, 6)
                                ForEach(pages) { page in
                                    settingsNavRow(page)
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 20)
                .padding(.top, 22)
            }
        }
        .padding(.horizontal, 14)
    }

    private var settingsTopBar: some View {
        HStack(spacing: 12) {
            Spacer()
            Button("恢复本页默认") {
                resetCurrentPage()
            }
            .buttonStyle(CapsuleButtonStyle())
            .disabled(!selectedPage.supportsReset)
            .opacity(selectedPage.supportsReset ? 1 : 0.52)
            Button("完成") {
                state.modal = nil
            }
            .buttonStyle(CapsuleButtonStyle(filled: true))
            Button {
                state.modal = nil
            } label: {
                Image(systemName: "xmark")
                    .font(StudioFont.symbol(12, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(StudioColor.secondaryText)
            .background(Circle().fill(StudioColor.control))
            .overlay(Circle().stroke(StudioColor.hairline, lineWidth: 1))
            .help("关闭设置")
        }
        .padding(.horizontal, 28)
        .frame(height: 58)
        .background(StudioColor.appBackground)
        .overlay(alignment: .bottom) {
            Rectangle().fill(StudioColor.hairline).frame(height: 1)
        }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(selectedPage.title)
                .font(StudioFont.font(18, weight: .semibold))
            Text(selectedPage.description)
                .font(StudioFont.font(13))
                .foregroundStyle(StudioColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var pageContent: some View {
        switch selectedPage {
        case .library:
            settingsGroup("当前资料库", detail: "Prompt、素材、附件和缓存都保存在本机资料库中。") {
                settingsPathRow("资料库路径", path: libraryPath, revealPath: libraryPath)
                settingsPathRow("本地数据库", path: databasePath, revealPath: databasePath)
                settingsPathRow("资产目录", path: assetsPath, revealPath: assetsPath)
            }
        case .displayPreview:
            settingsGroup("显示方式", detail: "这些设置会立即影响主界面的素材浏览体验。") {
                ViewModeSettingsRow(isListView: $state.isListView)
                thumbnailScaleRow
            }
        case .promptWorkflow:
            settingsGroup("主 Prompt 格式", detail: "PromptStudio 当前只把图片、视频、文本和声音作为主 Prompt 资产。") {
                formatRow("图片 Prompt", count: imageCount, detail: "png · jpg · jpeg · webp · heic · gif · tiff · svg")
                formatRow("视频 Prompt", count: videoCount, detail: "mp4 · mov · m4v · webm · mkv · avi")
                formatRow("文本 Prompt", count: textDocumentCount, detail: "md · txt · json · yaml · toml · xml · csv · log · docx")
                formatRow("声音 Prompt", count: audioCount, detail: "mp3 · wav · m4a · aac · flac · ogg · opus · aiff")
            }
            settingsGroup("筛选标签", detail: "首页顶部只突出高频入口，低频格式统一进入附件/其他。") {
                settingsValueRow("筛选模型数量", value: "\(max(0, state.models.count - 1))")
                settingsAction("管理首页筛选标签", detail: "选择哪些筛选项显示在主界面顶部，并调整排序。", button: "管理", filled: true) {
                    state.modal = .modelFilterManager
                }
            }
            .transparentScrollArea()
        case .shortcutsPrivacy:
            settingsGroup("快捷键", detail: "当前快捷键由 App 提供，设置页只展示已可用的操作。") {
                shortcutRow("新建 Prompt", value: "⌘N")
                shortcutRow("复制内容", value: "⌘C")
                shortcutRow("沉浸预览", value: "Space")
                shortcutRow("返回上一步", value: "⌘Z")
                shortcutRow("前进一步", value: "⇧⌘Z")
            }
            settingsGroup("本地数据", detail: "不提供云端同步、API Key 和自动上传设置，避免把本地 Prompt 管理工具做成 API 控制台。") {
                settingsValueRow("数据保存", value: "本机资料库")
                settingsValueRow("附件策略", value: "保存和引用，不进入 Prompt 编辑流程")
            }
        case .license:
            LicenseSettingsView()
                .environmentObject(state)
        }
    }

    private var thumbnailScaleRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                settingText("缩略图大小", "控制瀑布流卡片的目标宽度。")
                Spacer()
                Text("\(Int((thumbnailScale * 100).rounded()))%")
                    .font(StudioFont.font(12, weight: .medium))
                    .foregroundStyle(StudioColor.secondaryText)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Capsule().fill(StudioColor.control))
                    .overlay(Capsule().stroke(StudioColor.hairline, lineWidth: 1))
            }
            Slider(value: $thumbnailScale, in: 0.72...1.36)
                .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioColor.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioColor.hairline, lineWidth: 1))
    }

    private func settingsNavRow(_ page: SettingsPage) -> some View {
        Button {
            selectedPage = page
        } label: {
            HStack(spacing: 10) {
                Image(systemName: page.icon)
                    .frame(width: 17)
                Text(page.title)
                Spacer()
                Text(page.badge)
                    .font(StudioFont.font(11))
                    .foregroundStyle(selectedPage == page ? StudioColor.secondaryText : StudioColor.tertiaryText)
            }
            .font(StudioFont.font(13, weight: selectedPage == page ? .semibold : .regular))
            .foregroundStyle(selectedPage == page ? StudioColor.text : StudioColor.secondaryText)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(selectedPage == page ? StudioColor.selection : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func filteredPages(in section: SettingsPage.Section) -> [SettingsPage] {
        SettingsPage.allCases.filter { $0.section == section }
    }

    private func settingsGroup<Content: View>(_ title: String, detail: String = "", @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(StudioFont.font(14, weight: .semibold))
                if !detail.isEmpty {
                    Text(detail)
                        .font(StudioFont.font(12))
                        .foregroundStyle(StudioColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioColor.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioColor.hairline, lineWidth: 1))
    }

    private func settingsValueRow(_ title: String, value: String, detail: String = "") -> some View {
        HStack(alignment: .center, spacing: 16) {
            settingText(title, detail)
            Spacer()
            Text(value)
                .font(StudioFont.font(12, weight: .medium))
                .foregroundStyle(StudioColor.secondaryText)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Capsule().fill(StudioColor.control))
                .overlay(Capsule().stroke(StudioColor.hairline, lineWidth: 1))
        }
        .padding(16)
        .overlay(alignment: .top) { Rectangle().fill(StudioColor.hairline).frame(height: 1) }
    }

    private func settingsPathRow(_ title: String, path: String, revealPath: String) -> some View {
        HStack(alignment: .center, spacing: 14) {
            settingText(title, path)
            Spacer()
            HStack(spacing: 8) {
                Button {
                    copyPath(path)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(StudioFont.symbol(12, weight: .medium))
                }
                .buttonStyle(IconCircleButtonStyle())
                .help("复制路径")

                Button {
                    AppKitBridge.revealInFinder(path: revealPath)
                } label: {
                    Image(systemName: "folder")
                        .font(StudioFont.symbol(12, weight: .medium))
                }
                .buttonStyle(IconCircleButtonStyle())
                .help("在 Finder 中显示")
            }
        }
        .padding(16)
        .overlay(alignment: .top) { Rectangle().fill(StudioColor.hairline).frame(height: 1) }
    }

    private func settingsAction(_ title: String, detail: String, button: String, filled: Bool = false, action: (() -> Void)? = nil) -> some View {
        HStack(alignment: .center, spacing: 16) {
            settingText(title, detail)
            Spacer()
            Button(button) {
                action?()
            }
            .buttonStyle(CapsuleButtonStyle(filled: filled))
        }
        .padding(16)
        .overlay(alignment: .top) { Rectangle().fill(StudioColor.hairline).frame(height: 1) }
    }

    private func shortcutRow(_ title: String, value: String) -> some View {
        HStack {
            settingText(title, "当前快捷键")
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Capsule().fill(StudioColor.control))
                .overlay(Capsule().stroke(StudioColor.hairline, lineWidth: 1))
        }
        .padding(16)
        .overlay(alignment: .top) { Rectangle().fill(StudioColor.hairline).frame(height: 1) }
    }

    private func formatRow(_ title: String, count: Int, detail: String) -> some View {
        HStack(alignment: .center, spacing: 16) {
            settingText(title, detail)
            Spacer()
            Text("\(count)")
                .font(StudioFont.font(13, weight: .semibold))
                .foregroundStyle(StudioColor.text)
                .frame(minWidth: 42)
                .frame(height: 30)
                .background(Capsule().fill(StudioColor.control))
                .overlay(Capsule().stroke(StudioColor.hairline, lineWidth: 1))
        }
        .padding(16)
        .overlay(alignment: .top) { Rectangle().fill(StudioColor.hairline).frame(height: 1) }
    }

    private func settingText(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(StudioFont.font(13, weight: .semibold))
            if !detail.isEmpty {
                Text(detail)
                    .font(StudioFont.font(12))
                    .foregroundStyle(StudioColor.secondaryText)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
    }

    private var activeItems: [PromptItem] {
        state.items.filter { !$0.isDeleted }
    }

    private var imageCount: Int {
        activeItems.filter { $0.assetKind == .image }.count
    }

    private var videoCount: Int {
        activeItems.filter { $0.assetKind == .video }.count
    }

    private var audioCount: Int {
        activeItems.filter { $0.assetKind == .audio }.count
    }

    private var textDocumentCount: Int {
        activeItems.filter { $0.isTextDocumentLike }.count
    }

    private var libraryPath: String {
        state.libraryURL.path
    }

    private var databasePath: String {
        state.libraryURL.appendingPathComponent("database/promptstudio.sqlite").path
    }

    private var assetsPath: String {
        state.libraryURL.appendingPathComponent("assets").path
    }

    private func copyPath(_ path: String) {
        AppKitBridge.copyToPasteboard(path)
        state.toast = "已复制路径"
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if state.toast == "已复制路径" {
                state.toast = nil
            }
        }
    }

    private func resetCurrentPage() {
        switch selectedPage {
        case .displayPreview:
            thumbnailScale = 1.0
            state.isListView = false
        default:
            break
        }
    }
}

private enum SettingsPage: String, CaseIterable, Identifiable {
    case library
    case displayPreview
    case promptWorkflow
    case shortcutsPrivacy
    case license

    enum Section: CaseIterable, Identifiable {
        case storage
        case workflow
        case system

        var id: String { title }

        var title: String {
            switch self {
            case .storage: "资料库"
            case .workflow: "PROMPT"
            case .system: "系统"
            }
        }
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: "资料库"
        case .displayPreview: "显示与预览"
        case .promptWorkflow: "Prompt 工作流"
        case .shortcutsPrivacy: "快捷键与隐私"
        case .license: "授权"
        }
    }

    var description: String {
        switch self {
        case .library: "查看并复制当前本地资料库、数据库和资产目录路径。"
        case .displayPreview: "调整素材浏览方式、瀑布流密度和缩略图尺寸。"
        case .promptWorkflow: "确认主格式范围，并管理首页筛选标签。"
        case .shortcutsPrivacy: "查看常用快捷键和当前本地数据策略。"
        case .license: "激活、刷新或停用当前设备授权。"
        }
    }

    var icon: String {
        switch self {
        case .library: "externaldrive"
        case .displayPreview: "rectangle.grid.2x2"
        case .promptWorkflow: "slider.horizontal.3"
        case .shortcutsPrivacy: "keyboard"
        case .license: "key"
        }
    }

    var badge: String {
        switch self {
        case .library: "本地"
        case .displayPreview: "界面"
        case .promptWorkflow: "核心"
        case .shortcutsPrivacy: "效率"
        case .license: "Pro"
        }
    }

    var supportsReset: Bool {
        self == .displayPreview
    }

    var searchText: String {
        "\(title) \(description) \(badge)"
    }

    var section: Section {
        switch self {
        case .library:
            .storage
        case .displayPreview, .promptWorkflow:
            .workflow
        case .shortcutsPrivacy, .license:
            .system
        }
    }
}

/*
Legacy compact settings rows remain below for older sheets and small reusable controls.
*/

private struct LegacySettingsSheetPlaceholder: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        PromptFormShell(title: "设置") {
            VStack(alignment: .leading, spacing: 16) {
                SettingsRow(title: "资料库位置", value: state.libraryURL.path)
                SettingsRow(title: "默认导入方式", value: "复制到资料库")
                ViewModeSettingsRow(isListView: $state.isListView)
                SettingsRow(title: "本地数据库", value: state.libraryURL.appendingPathComponent("database/promptstudio.sqlite").path)
                SettingsRow(title: "模型数量", value: "\(state.models.count - 1)")
                SettingsRow(title: "隐私", value: "不经授权不上传图片、Prompt 或 API Key")
                Text("API Key 后续接入 macOS Keychain；MVP 保持本地数据闭环。")
                    .foregroundStyle(StudioColor.secondaryText)
            }
        } footer: {
            Button("在 Finder 打开资料库") {
                AppKitBridge.revealInFinder(path: state.libraryURL.path)
            }
            .buttonStyle(CapsuleButtonStyle())
            Button("关闭") { state.modal = nil }
                .buttonStyle(CapsuleButtonStyle(filled: true))
        }
        .frame(width: 680, height: 560)
    }
}

struct ModelFilterManagerSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @AppStorage(FilterBarConfiguration.storageKey) private var storedSelection = ""
    @State private var selectedIDs: [String] = []
    @State private var draggedPreviewID: String?

    private var availableEntries: [FilterQuickEntry] {
        FilterBarConfiguration.availableEntries(models: state.models, tags: state.tags)
    }

    private var selectedEntries: [FilterQuickEntry] {
        let entriesByID = Dictionary(uniqueKeysWithValues: availableEntries.map { ($0.id, $0) })
        return selectedIDs.compactMap { entriesByID[$0] }
    }

    var body: some View {
        PromptFormShell(title: "筛选标签管理") {
            VStack(alignment: .leading, spacing: 18) {
                Text("勾选首页筛选栏要显示的维度，下方预览区可拖拽调整顺序。未勾选的标签维度来自已有素材标签。")
                    .font(StudioFont.font(13))
                    .foregroundStyle(StudioColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 12) {
                    Text("可选维度")
                        .font(StudioFont.font(12, weight: .semibold))
                        .foregroundStyle(StudioColor.secondaryText)

                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], alignment: .leading, spacing: 10) {
                            ForEach(availableEntries) { entry in
                                FilterDimensionToggle(
                                    entry: entry,
                                    isSelected: selectedIDs.contains(entry.id)
                                ) {
                                    toggle(entry)
                                }
                            }
                        }
                        .padding(12)
                    }
                    .frame(height: 230)
                    .background(StudioColor.control.opacity(0.42))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(StudioColor.hairline, lineWidth: 1))
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("筛选栏预览")
                            .font(StudioFont.font(12, weight: .semibold))
                            .foregroundStyle(StudioColor.secondaryText)
                        Spacer()
                        Text("拖拽排序")
                            .font(StudioFont.font(12))
                            .foregroundStyle(StudioColor.tertiaryText)
                    }

                    ScrollView(.horizontal, showsIndicators: true) {
                        HStack(spacing: 8) {
                            ForEach(selectedEntries) { entry in
                                FilterPreviewChip(entry: entry)
                                    .onDrag {
                                        draggedPreviewID = entry.id
                                        return NSItemProvider(object: entry.id as NSString)
                                    }
                                    .onDrop(
                                        of: [UTType.plainText],
                                        delegate: FilterPreviewDropDelegate(
                                            targetID: entry.id,
                                            selectedIDs: $selectedIDs,
                                            draggedID: $draggedPreviewID
                                        )
                                    )
                            }
                        }
                        .padding(12)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .frame(height: 72)
                    .background(StudioColor.control.opacity(0.42))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(StudioColor.hairline, lineWidth: 1))
                }
            }
        } footer: {
            Button("恢复默认") {
                selectedIDs = FilterBarConfiguration.defaultSelectedIDs.filter { id in
                    availableEntries.contains { $0.id == id }
                }
            }
            .buttonStyle(TextHoverButtonStyle())

            Button("保存并关闭") {
                save()
                dismiss()
            }
                .buttonStyle(CapsuleButtonStyle(filled: true))
        }
        .onAppear(perform: loadSelection)
        .frame(width: 760, height: 620)
    }

    private func loadSelection() {
        selectedIDs = FilterBarConfiguration.selectedIDs(from: storedSelection, availableEntries: availableEntries)
    }

    private func toggle(_ entry: FilterQuickEntry) {
        if selectedIDs.contains(entry.id) {
            selectedIDs.removeAll { $0 == entry.id }
        } else {
            selectedIDs.append(entry.id)
        }
    }

    private func save() {
        let validIDs = Set(availableEntries.map(\.id))
        let ids = selectedIDs.filter { validIDs.contains($0) }
        storedSelection = FilterBarConfiguration.encode(ids.isEmpty ? FilterBarConfiguration.defaultSelectedIDs : ids)
    }
}

private struct FilterDimensionToggle: View {
    let entry: FilterQuickEntry
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(StudioFont.symbol(13, weight: .semibold))
                    .foregroundStyle(isSelected ? StudioColor.primaryAction : StudioColor.secondaryText)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(StudioFont.font(12, weight: .medium))
                        .foregroundStyle(StudioColor.text)
                        .lineLimit(1)
                    Text(entry.categoryTitle)
                        .font(StudioFont.font(11))
                        .foregroundStyle(StudioColor.tertiaryText)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 44)
            .background(StudioColor.panel.opacity(isSelected ? 0.86 : 0.38))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? StudioColor.primaryAction.opacity(0.42) : StudioColor.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private struct FilterPreviewChip: View {
    let entry: FilterQuickEntry

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .font(StudioFont.symbol(10, weight: .semibold))
                .foregroundStyle(StudioColor.tertiaryText)
            Text(entry.title)
                .font(StudioFont.font(12))
                .foregroundStyle(StudioColor.text)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Capsule().fill(StudioColor.selection))
        .overlay(Capsule().stroke(StudioColor.hairline, lineWidth: 1))
    }
}

private struct FilterPreviewDropDelegate: DropDelegate {
    let targetID: String
    @Binding var selectedIDs: [String]
    @Binding var draggedID: String?

    func dropEntered(info: DropInfo) {
        guard let draggedID, draggedID != targetID,
              let fromIndex = selectedIDs.firstIndex(of: draggedID),
              let toIndex = selectedIDs.firstIndex(of: targetID) else {
            return
        }

        withAnimation(.easeInOut(duration: 0.16)) {
            selectedIDs.move(
                fromOffsets: IndexSet(integer: fromIndex),
                toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex
            )
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedID = nil
        return true
    }
}

struct FolderEditorSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let request: AppState.FolderEditorRequest
    @State private var name: String

    init(request: AppState.FolderEditorRequest) {
        self.request = request
        self._name = State(initialValue: request.initialName)
    }

    var body: some View {
        PromptFormShell(title: request.title) {
            VStack(alignment: .leading, spacing: 14) {
                Text("文件夹用于整理本地 Prompt 素材，不会创建或移动 Finder 里的真实目录。")
                    .font(StudioFont.font(13))
                    .foregroundStyle(StudioColor.secondaryText)

                LabeledField("位置") {
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .foregroundStyle(StudioColor.secondaryText)
                        Text(request.parentName ?? "根目录")
                            .foregroundStyle(StudioColor.text)
                        Spacer()
                    }
                }

                LabeledField("文件夹名称") {
                    TextField("输入文件夹名称", text: $name)
                }
            }
        } footer: {
            Button("取消") { dismiss() }
                .buttonStyle(TextHoverButtonStyle())
            Button(primaryButtonTitle) {
                if state.submitFolderEditor(request, name: name) {
                    dismiss()
                }
            }
            .buttonStyle(CapsuleButtonStyle(filled: true))
        }
        .frame(width: 460, height: 330)
    }

    private var primaryButtonTitle: String {
        switch request.mode {
        case .create:
            "新增"
        case .rename:
            "保存"
        }
    }
}

struct FolderDeleteConfirmationSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let request: AppState.FolderDeleteRequest

    var body: some View {
        PromptFormShell(title: "删除文件夹") {
            VStack(alignment: .leading, spacing: 14) {
                Text("确定删除「\(request.folderName)」？")
                    .font(StudioFont.font(14, weight: .semibold))
                Text("文件夹及其子文件夹内 \(request.itemCount) 个素材将移入回收站，可从回收站恢复。文件夹树会从侧栏中移除。")
                    .font(StudioFont.font(13))
                    .foregroundStyle(StudioColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            Button("取消") { dismiss() }
                .buttonStyle(TextHoverButtonStyle())
            Button("移入回收站并删除") {
                state.deleteFolderMovingItemsToTrash(id: request.folderID)
                dismiss()
            }
            .buttonStyle(CapsuleButtonStyle(filled: true))
        }
        .frame(width: 500, height: 300)
    }
}

private struct ModelFilterEditorRow: View {
    @EnvironmentObject private var state: AppState
    let model: ModelProfile
    @State private var name: String
    @State private var type: PromptType

    init(model: ModelProfile) {
        self.model = model
        self._name = State(initialValue: model.name)
        self._type = State(initialValue: model.type)
    }

    var body: some View {
        HStack(spacing: 10) {
            TextField("筛选标签名称", text: $name)
                .textFieldStyle(.plain)
                .font(StudioFont.font(13))
                .foregroundStyle(StudioColor.text)
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(StudioColor.control)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioColor.hairline, lineWidth: 1))

            PromptTypeSegment(type: $type)

            Button {
                state.saveModelFilterLabel(id: model.id, name: name, type: type)
            } label: {
                Text("保存").frame(minWidth: 56)
            }
            .buttonStyle(CapsuleButtonStyle(accent: hasChanges))
        }
        .padding(12)
        .studioPanel(radius: 8)
    }

    private var hasChanges: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines) != model.name || type != model.type
    }
}

private struct PromptTypeSegment: View {
    @Binding var type: PromptType

    var body: some View {
        HStack(spacing: 6) {
            typeButton("图片", .image)
            typeButton("视频", .video)
            typeButton("文本", .text)
            typeButton("音频", .audio)
        }
        .padding(4)
        .background(StudioColor.control)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(StudioColor.hairline, lineWidth: 1))
    }

    private func typeButton(_ title: String, _ value: PromptType) -> some View {
        Button {
            type = value
        } label: {
            Text(title)
                .font(StudioFont.font(14))
                .foregroundStyle(type == value ? StudioColor.primaryActionText : StudioColor.text)
                .frame(width: 44, height: 28)
                .background(Capsule().fill(type == value ? StudioColor.primaryAction : Color.clear))
        }
        .buttonStyle(.plain)
    }
}

struct ExternalFileOpenSheet: View {
    @EnvironmentObject private var state: AppState
    let request: ExternalFileOpenRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(StudioFont.font(18, weight: .semibold))
                    .foregroundStyle(StudioColor.text)
                Text("这个文件还不在 PromptStudio 资料库中。")
                    .font(StudioFont.font(13))
                    .foregroundStyle(StudioColor.secondaryText)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(request.urls.prefix(3), id: \.path) { url in
                    Text(url.lastPathComponent)
                        .font(StudioFont.font(13))
                        .foregroundStyle(StudioColor.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if request.urls.count > 3 {
                    Text("+\(request.urls.count - 3) 个文件")
                        .font(StudioFont.caption(12))
                        .foregroundStyle(StudioColor.secondaryText)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .studioPanel(radius: 8)

            HStack(spacing: 10) {
                Button("取消") {
                    state.modal = nil
                }
                .buttonStyle(CapsuleButtonStyle())

                Button("仅临时预览") {
                    state.previewExternalFileTemporarily(request)
                }
                .buttonStyle(CapsuleButtonStyle())

                Button("导入到资料库") {
                    state.importExternalFiles(request)
                }
                .buttonStyle(CapsuleButtonStyle(filled: true))
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(StudioColor.appBackground)
    }

    private var title: String {
        request.urls.count == 1 ? "打开外部文本文档" : "打开 \(request.urls.count) 个外部文本文档"
    }
}

struct TemporaryTextPreviewSheet: View {
    @EnvironmentObject private var state: AppState
    let request: TemporaryTextPreviewRequest
    @State private var text: String

    init(request: TemporaryTextPreviewRequest) {
        self.request = request
        _text = State(initialValue: request.text)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(request.title)
                        .font(StudioFont.font(14, weight: .semibold))
                        .foregroundStyle(StudioColor.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(request.format.isEmpty ? "TEXT" : request.format) · \(fileSizeText(request.fileSize)) · 临时预览")
                        .font(StudioFont.caption(12))
                        .foregroundStyle(StudioColor.secondaryText)
                }
                Spacer()
                Button("关闭") { state.modal = nil }
                    .buttonStyle(TextHoverButtonStyle())
            }
            .padding()

            Divider().overlay(StudioColor.hairline)

            MarkdownDocumentEditor(
                text: $text,
                isEditable: false,
                scrollResetID: request.id.uuidString,
                contentFontSize: 13,
                syntaxMode: TextSyntaxMode.infer(assetPath: request.url.path, format: request.format)
            )
            .padding(18)
        }
        .frame(width: 920, height: 680)
        .background(StudioColor.appBackground)
    }

    private func fileSizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

struct PreviewSheet: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(state.selectedItem?.title ?? "预览")
                    .font(StudioFont.font(14))
                Spacer()
                Button("关闭") { state.modal = nil }
                    .buttonStyle(TextHoverButtonStyle())
            }
            .padding()
            Divider().overlay(StudioColor.hairline)
            if let item = state.selectedItem {
                HStack(spacing: 0) {
                    mediaPreview(item)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(18)

                    Divider().overlay(StudioColor.hairline)

                    previewPromptPanel(item)
                        .frame(width: 320)
                        .padding(18)
                }
            }
        }
        .frame(width: 1040, height: 720)
        .background(StudioColor.appBackground)
        .background {
            SpacePreviewKeyMonitor {
                state.togglePreview()
            }
        }
    }

    @ViewBuilder
    private func mediaPreview(_ item: PromptItem) -> some View {
        if item.isTextDocumentLike {
            TextDocumentSheetPreview(item: item)
        } else if item.assetKind == .video {
            VideoPreviewPlayer(path: item.assetPath)
        } else if item.assetKind == .audio {
            AudioPreviewPlayer(item: item)
        } else if item.assetKind == .image {
            ImagePreview(path: item.assetPath)
        } else {
            FilePreview(item: item)
        }
    }

    private func previewPromptPanel(_ item: PromptItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title)
                        .font(StudioFont.font(14))
                        .lineLimit(3)
                    Text("\(item.modelName) · \(item.displayAspectRatio) · \(item.format)")
                        .font(StudioFont.font(14))
                        .foregroundStyle(StudioColor.secondaryText)
                }

                if item.assetKind != .image && item.assetKind != .video {
                    previewSection("文件摘要", textSummary(for: item), minHeight: 140)
                }

                if item.currentVersion?.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    previewSection("提示词 (Prompt)", item.currentVersion?.prompt ?? "", minHeight: 140)
                }
                if item.currentVersion?.negativePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    previewSection("负面提示词", item.currentVersion?.negativePrompt ?? "", minHeight: 84)
                }

                if let parameters = item.currentVersion?.parameters, !parameters.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        previewTitle("参数")
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], alignment: .leading, spacing: 8) {
                            ForEach(parameters.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                                Text("\(key) \(value)")
                                    .font(StudioFont.font(11))
                                    .padding(.horizontal, 10)
                                    .frame(height: 26)
                                    .frame(maxWidth: .infinity)
                                    .background(Capsule().fill(StudioColor.control))
                                    .overlay(Capsule().stroke(StudioColor.hairline, lineWidth: 1))
                            }
                        }
                    }
                }

                Button {
                    state.copySelectedPrompt()
                } label: {
                    Label("复制提示词", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(CapsuleButtonStyle(filled: true))
            }
        }
        .foregroundStyle(StudioColor.text)
    }

    private func previewSection(_ title: String, _ text: String, minHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            previewTitle(title)
            Text(text.isEmpty ? "未填写" : text)
                .font(StudioFont.font(14))
                .lineSpacing(3)
                .foregroundStyle(text.isEmpty ? StudioColor.tertiaryText : StudioColor.text)
                .padding(12)
                .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
                .studioPanel(radius: 8)
        }
    }

    private func previewTitle(_ title: String) -> some View {
        Text(title)
            .font(StudioFont.caption(12))
            .tracking(1.2)
            .foregroundStyle(StudioColor.secondaryText)
    }

    private func textSummary(for item: PromptItem) -> String {
        guard item.canExtractPromptFromAsset else {
            return fileFallbackSummary(for: item)
        }
        if let text = AppKitBridge.readDocumentText(from: URL(fileURLWithPath: item.assetPath)) {
            let trimmed = String(text.prefix(6_000)).trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? fileFallbackSummary(for: item) : trimmed
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: item.assetPath), options: [.mappedIfSafe]) else {
            return fileFallbackSummary(for: item)
        }
        let previewData = Data(data.prefix(6000))
        let text = String(data: previewData, encoding: .utf8)
            ?? String(data: previewData, encoding: .utf16)
            ?? String(data: previewData, encoding: .isoLatin1)
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !trimmed.isEmpty
            ? trimmed
            : fileFallbackSummary(for: item)
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

private struct TextDocumentSheetPreview: View {
    let item: PromptItem
    @State private var text = ""

    var body: some View {
        MarkdownDocumentEditor(
            text: $text,
            isEditable: false,
            scrollResetID: item.id,
            contentFontSize: 13,
            syntaxMode: TextSyntaxMode.infer(for: item)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: loadText)
        .onChange(of: item.id) { _, _ in loadText() }
    }

    private func loadText() {
        if !item.assetPath.isEmpty,
           let documentText = AppKitBridge.readDocumentText(from: URL(fileURLWithPath: item.assetPath)) {
            text = documentText
            return
        }
        text = item.currentVersion?.prompt ?? ""
    }
}

private struct FilePreview: View {
    let item: PromptItem

    var body: some View {
        VStack(spacing: 18) {
            FileKindPlaceholderForPreview(assetKind: item.assetKind, format: item.format)
                .frame(width: 180, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioColor.hairline, lineWidth: 1))
            VStack(spacing: 6) {
                Text(item.title)
                    .font(StudioFont.font(14))
                    .lineLimit(2)
                Text("\(item.assetKind.displayName) · \(item.format.isEmpty ? "FILE" : item.format)")
                    .font(StudioFont.font(14))
                    .foregroundStyle(StudioColor.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StudioColor.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioColor.hairline, lineWidth: 1))
    }
}

private struct FileKindPlaceholderForPreview: View {
    let assetKind: AssetKind
    let format: String

    var body: some View {
        ZStack {
            StudioColor.panelRaised
            VStack(spacing: 10) {
                Image(systemName: symbolName)
                    .font(StudioFont.symbol(42))
                Text(format.isEmpty ? assetKind.displayName.uppercased() : format.uppercased())
                    .font(StudioFont.caption(12))
                    .foregroundStyle(StudioColor.secondaryText)
            }
        }
        .foregroundStyle(StudioColor.text)
    }

    private var symbolName: String {
        switch assetKind {
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
        case .image:
            "photo"
        case .video:
            "film"
        }
    }
}

private struct ImagePreview: View {
    let path: String
    @StateObject private var loader = PreviewImageLoader()

    var body: some View {
        ZStack {
            StudioColor.panel
            if let image = loader.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
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
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioColor.hairline, lineWidth: 1))
        .task(id: path) {
            await loader.load(path)
        }
    }
}

@MainActor
private final class PreviewImageLoader: ObservableObject {
    @Published var image: NSImage?

    func load(_ path: String) async {
        image = await Task.detached(priority: .utility) {
            NSImage(contentsOfFile: path)
        }.value
    }
}

private struct VideoPreviewPlayer: View {
    let path: String

    var body: some View {
        Group {
            if FileManager.default.fileExists(atPath: path) {
                NativeVideoPlayer(path: path)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioColor.hairline, lineWidth: 1))
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "video.slash")
                        .font(StudioFont.symbol(34))
                    Text("视频文件不存在")
                        .font(StudioFont.font(14))
                }
                .foregroundStyle(StudioColor.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .studioPanel(radius: 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct NativeVideoPlayer: NSViewRepresentable {
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

struct ErrorSheet: View {
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(StudioFont.symbol(34))
                .foregroundStyle(StudioColor.orange)
            Text("操作失败")
                .font(StudioFont.font(14))
            Text(message)
                .foregroundStyle(StudioColor.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(30)
        .frame(width: 420, height: 260)
        .background(StudioColor.panel)
    }
}

private struct PromptFormShell<Content: View, Footer: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    init(title: String, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.title = title
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(StudioFont.font(14))
                Spacer()
            }
            .padding(22)

            ScrollView {
                content
                    .padding(22)
            }
            .transparentScrollArea()

            HStack {
                Spacer()
                footer
            }
            .padding(18)
        }
        .foregroundStyle(StudioColor.text)
        .background(StudioColor.panel)
    }
}

private struct LabeledField<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(StudioFont.caption(12))
                .tracking(1.2)
                .foregroundStyle(StudioColor.secondaryText)
            content
                .textFieldStyle(.plain)
                .font(StudioFont.font(13))
                .foregroundStyle(StudioColor.text)
                .padding(.horizontal, 10)
                .frame(minHeight: 36)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(StudioColor.control)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(StudioColor.hairline, lineWidth: 1)
                )
        }
    }
}

private struct LabeledEditor: View {
    let title: String
    @Binding var text: String
    let minHeight: CGFloat

    init(_ title: String, text: Binding<String>, minHeight: CGFloat) {
        self.title = title
        self._text = text
        self.minHeight = minHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(StudioFont.caption(12))
                .tracking(1.2)
                .foregroundStyle(StudioColor.secondaryText)
            TextEditor(text: $text)
                .font(StudioFont.font(13))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: minHeight)
                .studioPanel(radius: 8)
        }
    }
}

private struct FilterToggle: View {
    let title: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(CapsuleButtonStyle(filled: active, accent: active))
    }
}

private struct SettingsRow: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(StudioFont.caption(12))
                .tracking(1.2)
                .foregroundStyle(StudioColor.secondaryText)
            Text(value)
                .font(StudioFont.font(13))
                .lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .studioPanel(radius: 8)
    }
}

private struct ViewModeSettingsRow: View {
    @Binding var isListView: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("视图模式")
                .font(StudioFont.caption(12))
                .tracking(1.2)
                .foregroundStyle(StudioColor.secondaryText)

            HStack(spacing: 10) {
                Button {
                    setListView(false)
                } label: {
                    Label("网格", systemImage: "square.grid.2x2")
                        .frame(minWidth: 86)
                }
                .buttonStyle(CapsuleButtonStyle(accent: !isListView))

                Button {
                    setListView(true)
                } label: {
                    Label("列表", systemImage: "list.bullet")
                        .frame(minWidth: 86)
                }
                .buttonStyle(CapsuleButtonStyle(accent: isListView))

                Spacer()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .studioPanel(radius: 8)
    }

    private func setListView(_ value: Bool) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isListView = value
        }
    }
}
