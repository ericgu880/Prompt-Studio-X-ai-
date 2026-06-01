import AVKit
import SwiftUI
import PromptStudioCore
import UniformTypeIdentifiers

struct NewPromptSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var type: PromptType = .image
    @State private var modelId = "nano_banana_2"
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

            NewPromptField(title: "参考图（可选）", help: "上传参考图可帮助模型更好地理解你的意图") {
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
            appendReferenceImages(AppKitBridge.chooseReferenceImages())
        } label: {
            VStack(spacing: 12) {
                Image(systemName: "square.and.arrow.up")
                    .font(StudioFont.symbol(24))
                    .frame(width: 48, height: 48)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(StudioColor.control))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(StudioColor.hairline, lineWidth: 1))

                VStack(spacing: 5) {
                    Text(referenceURLs.isEmpty ? "将图片拖拽到此处，或点击上传" : "已选择 \(referenceURLs.count) 张参考图")
                        .font(StudioFont.font(14, weight: .medium))
                    Text(referenceURLs.isEmpty ? "支持 JPG、PNG、WEBP，单张不超过 20MB" : referenceURLs.map(\.lastPathComponent).joined(separator: "、"))
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

struct EditPromptSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let item: PromptItem
    @State private var title: String
    @State private var type: PromptType
    @State private var modelId: String
    @State private var prompt: String
    @State private var negativePrompt: String
    @State private var tags: String
    @State private var parameters: String
    @State private var note = ""
    @State private var saveAsNewVersion = true

    init(item: PromptItem) {
        self.item = item
        _title = State(initialValue: item.title)
        _type = State(initialValue: item.type)
        _modelId = State(initialValue: item.modelId)
        _prompt = State(initialValue: item.currentVersion?.prompt ?? "")
        _negativePrompt = State(initialValue: item.currentVersion?.negativePrompt ?? "")
        _tags = State(initialValue: item.tags.joined(separator: ", "))
        _parameters = State(initialValue: (item.currentVersion?.parameters ?? [:]).map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n"))
    }

    var body: some View {
        PromptFormShell(title: "编辑 Prompt") {
            VStack(alignment: .leading, spacing: 14) {
                LabeledField("标题") { TextField("标题", text: $title) }
                HStack(spacing: 12) {
                    LabeledField("类型") {
                        Picker("", selection: $type) {
                            ForEach(PromptType.allCases) { type in
                                Text(type.displayName).tag(type)
                            }
                        }
                        .labelsHidden()
                    }
                    LabeledField("模型") {
                        Picker("", selection: $modelId) {
                            ForEach(state.models.filter { $0.id != "all" }) { model in
                                Text(model.name).tag(model.id)
                            }
                        }
                        .labelsHidden()
                    }
                }
                LabeledEditor("Prompt", text: $prompt, minHeight: 140)
                LabeledEditor("负面提示词", text: $negativePrompt, minHeight: 80)
                LabeledEditor("参数（每行 key=value）", text: $parameters, minHeight: 72)
                LabeledField("标签") { TextField("风景, 人物", text: $tags) }
                LabeledField("版本备注") { TextField("例如：增强光影", text: $note) }
                Toggle("保存为新版本", isOn: $saveAsNewVersion)
            }
        } footer: {
            Button("取消") { dismiss() }
                .buttonStyle(TextHoverButtonStyle())
            Button("保存") {
                state.savePrompt(
                    title: title,
                    type: type,
                    modelId: modelId,
                    prompt: prompt,
                    negativePrompt: negativePrompt,
                    tags: parsedTags,
                    parameters: parsedParameters,
                    note: note,
                    saveAsNewVersion: saveAsNewVersion
                )
                dismiss()
            }
            .buttonStyle(CapsuleButtonStyle(filled: true))
        }
        .frame(width: 760, height: 760)
    }

    private var parsedTags: [String] {
        tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
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
            .frame(height: 240)
            .studioPanel(radius: 8)
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
                Toggle("仅有参考图", isOn: $hasReferenceOnly)
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
        PromptFormShell(title: "参考图管理") {
            if let item = state.selectedItem {
                VStack(alignment: .leading, spacing: 18) {
                    if item.referenceAssets.isEmpty {
                        Text("当前素材还没有参考图。")
                            .font(StudioFont.font(13))
                            .foregroundStyle(StudioColor.secondaryText)
                    }

                    LazyVGrid(columns: referenceColumns, alignment: .leading, spacing: 16) {
                        ForEach(item.referenceAssets) { reference in
                            ReferenceAssetCard(reference: reference)
                        }
                        AddReferenceCard {
                            state.modal = .importAssets
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
            ThumbnailImage(path: reference.path)
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

                Text(reference.type.isEmpty ? "参考图" : reference.type)
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
                Text("添加参考图")
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
    @State private var selectedPage: SettingsPage = .home
    @State private var query = ""
    @AppStorage("promptStudio.thumbnailScale") private var thumbnailScale = 1.0
    @AppStorage("promptStudio.settings.localFirst") private var localFirst = true
    @AppStorage("promptStudio.settings.showPromptSummary") private var showPromptSummary = false
    @AppStorage("promptStudio.settings.longPromptExpanded") private var longPromptExpanded = true
    @AppStorage("promptStudio.settings.defaultCopyFormat") private var defaultCopyFormat = "纯文本"
    @AppStorage("promptStudio.settings.autoBackup") private var autoBackup = false

    var body: some View {
        HStack(spacing: 0) {
            settingsSidebar
                .frame(width: 250)
                .background(StudioColor.panel)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(StudioColor.hairline).frame(width: 1)
                }

            VStack(spacing: 0) {
                settingsTopBar
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        settingsHero
                        pageContent
                    }
                    .padding(28)
                }
                .background(StudioColor.appBackground)
            }
        }
        .foregroundStyle(StudioColor.text)
        .background(StudioColor.appBackground)
        .frame(width: 1180, height: 760)
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text("PS")
                    .font(StudioFont.font(13, weight: .semibold))
                    .foregroundStyle(StudioColor.primaryActionText)
                    .frame(width: 38, height: 38)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(StudioColor.primaryAction))
                VStack(alignment: .leading, spacing: 3) {
                    Text("PromptStudio")
                        .font(StudioFont.font(15, weight: .semibold))
                    Text("设置中心 · 本地优先")
                        .font(StudioFont.font(12))
                        .foregroundStyle(StudioColor.secondaryText)
                }
            }
            .padding(.top, 22)

            TextField("搜索设置页面...", text: $query)
                .textFieldStyle(.plain)
                .font(StudioFont.font(13))
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(StudioColor.control)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioColor.hairline, lineWidth: 1))

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
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 5) {
                Text("PromptStudio Library")
                    .font(StudioFont.font(12, weight: .semibold))
                Text(state.libraryURL.path)
                    .font(StudioFont.font(11))
                    .foregroundStyle(StudioColor.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(StudioColor.control)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(StudioColor.hairline, lineWidth: 1))
            .padding(.bottom, 18)
        }
        .padding(.horizontal, 14)
    }

    private var settingsTopBar: some View {
        HStack(spacing: 12) {
            Text("设置")
                .font(StudioFont.font(13))
                .foregroundStyle(StudioColor.secondaryText)
            Image(systemName: "chevron.right")
                .font(StudioFont.symbol(10))
                .foregroundStyle(StudioColor.mutedText)
            Text(selectedPage.title)
                .font(StudioFont.font(14, weight: .semibold))
            Spacer()
            Button("恢复默认") {
                resetCurrentPage()
            }
            .buttonStyle(CapsuleButtonStyle())
            Button("保存设置") {
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

    private var settingsHero: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(selectedPage.title)
                .font(StudioFont.font(24, weight: .semibold))
            Text(selectedPage.description)
                .font(StudioFont.font(13))
                .foregroundStyle(StudioColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                statusPill("本地优先")
                statusPill(selectedPage.priority)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [StudioColor.panelRaised, StudioColor.panel],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(StudioColor.hairline, lineWidth: 1))
    }

    @ViewBuilder
    private var pageContent: some View {
        switch selectedPage {
        case .home:
            overviewGrid
            settingsGroup("快捷操作") {
                settingsAction("立即备份当前库", detail: "生成一个包含数据库、附件、缩略图索引的完整备份。", button: "即将支持", disabled: true)
                settingsAction("重建索引", detail: "搜索不准确、导入大量文件或标签规则变更后使用。", button: "即将支持", disabled: true)
                settingsAction("打开库文件夹", detail: "在系统文件管理器中打开当前 PromptStudio Library。", button: "打开") {
                    AppKitBridge.revealInFinder(path: state.libraryURL.path)
                }
            }
        case .general:
            settingsGroup("基础偏好") {
                settingPicker("启动时打开", detail: "当前版本固定打开上次使用资料库。", value: "上次使用库", disabled: true)
                ViewModeSettingsRow(isListView: $state.isListView)
                settingToggle("自动备份提醒", detail: "保存偏好，备份任务将在后续接入。", isOn: $autoBackup)
            }
        case .library:
            settingsGroup("当前库") {
                settingsReadOnly("资料库路径", value: state.libraryURL.path)
                settingsReadOnly("本地数据库", value: state.libraryURL.appendingPathComponent("database/promptstudio.sqlite").path)
                settingsAction("打开库文件夹", detail: "查看数据库、附件和缩略图缓存。", button: "打开") {
                    AppKitBridge.revealInFinder(path: state.libraryURL.path)
                }
            }
        case .promptEditor:
            settingsGroup("Prompt 编辑器") {
                settingPicker("默认保存规则", detail: "编辑 Prompt 时默认保存为新版本。", value: "每次保存生成版本", disabled: true)
                settingToggle("长 Prompt 默认展开", detail: "右侧详情和预览中的长文本默认展示更多内容。", isOn: $longPromptExpanded)
                settingPicker("复制格式", detail: "影响后续复制/运行工作流默认格式。", value: defaultCopyFormat)
            }
        case .models:
            settingsGroup("模型与 API") {
                settingsReadOnly("筛选模型数量", value: "\(max(0, state.models.count - 1))")
                settingPicker("API Key 存储", detail: "后续使用系统钥匙串保存密钥。", value: "Keychain 即将支持", disabled: true)
                settingsAction("管理首页模型筛选标签", detail: "编辑素材区顶部的模型筛选项。", button: "管理") {
                    state.modal = .modelFilterManager
                }
            }
        case .search:
            settingsGroup("搜索与索引") {
                settingPicker("全文索引", detail: "标题、Prompt、描述、备注、标签。", value: "已启用", disabled: true)
                settingToggle("本地优先搜索", detail: "禁用云端语义搜索和遥测。", isOn: $localFirst)
                settingsAction("重建全文索引", detail: "索引服务后续接入。", button: "即将支持", disabled: true)
            }
        case .cards:
            settingsGroup("卡片与预览") {
                ViewModeSettingsRow(isListView: $state.isListView)
                VStack(alignment: .leading, spacing: 10) {
                    Text("缩略图大小")
                        .font(StudioFont.caption(12))
                        .tracking(1.2)
                        .foregroundStyle(StudioColor.secondaryText)
                    Slider(value: $thumbnailScale, in: 0.72...1.36)
                }
                .padding(12)
                .studioPanel(radius: 8)
                settingToggle("显示 Prompt 摘要", detail: "卡片底部显示 Prompt 前两行。", isOn: $showPromptSummary)
            }
        case .shortcuts:
            settingsGroup("快捷键") {
                shortcutRow("新建 Prompt", value: "⌘N")
                shortcutRow("复制提示词", value: "⌘C")
                shortcutRow("预览", value: "Space")
                settingsAction("自定义快捷键", detail: "快捷键录入和冲突检测后续接入。", button: "即将支持", disabled: true)
            }
        case .backup:
            settingsGroup("导出、备份与同步") {
                settingToggle("自动备份提醒", detail: "当前保存偏好，不自动创建备份文件。", isOn: $autoBackup)
                settingPicker("导出默认格式", detail: "用于导出 Prompt 的默认格式。", value: defaultCopyFormat)
                settingsAction("立即备份", detail: "备份打包能力后续接入。", button: "即将支持", disabled: true)
            }
        case .privacy:
            settingsGroup("隐私与安全") {
                settingToggle("本地优先模式", detail: "禁止未授权的联网 AI 分析。", isOn: $localFirst)
                settingPicker("API Key 安全", detail: "后续接入 macOS Keychain。", value: "不明文保存", disabled: true)
                settingsAction("清除运行痕迹", detail: "运行历史和搜索历史清理后续接入。", button: "即将支持", disabled: true)
            }
        }
    }

    private var overviewGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 14)], spacing: 14) {
            overviewCard("Prompt 数量", "\(state.items.filter { !$0.isDeleted }.count)", "当前库已整理 Prompt")
            overviewCard("附件素材", "\(state.items.count)", "图片、视频、文档和参考素材")
            overviewCard("模型标签", "\(max(0, state.models.count - 1))", "可用于顶部筛选")
            overviewCard("标签数量", "\(state.tags.count)", "本地分类标签")
        }
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
                    .foregroundStyle(selectedPage == page ? StudioColor.primaryActionText.opacity(0.72) : StudioColor.tertiaryText)
            }
            .font(StudioFont.font(13, weight: selectedPage == page ? .semibold : .regular))
            .foregroundStyle(selectedPage == page ? StudioColor.primaryActionText : StudioColor.secondaryText)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(selectedPage == page ? StudioColor.primaryAction : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func filteredPages(in section: SettingsPage.Section) -> [SettingsPage] {
        SettingsPage.allCases.filter { page in
            page.section == section && (query.isEmpty || page.title.localizedCaseInsensitiveContains(query) || page.description.localizedCaseInsensitiveContains(query))
        }
    }

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(StudioFont.font(15, weight: .semibold))
                Text("P0 可用项会立即保存；未接入能力以禁用状态展示。")
                    .font(StudioFont.font(12))
                    .foregroundStyle(StudioColor.secondaryText)
            }
            .padding(16)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioColor.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(StudioColor.hairline, lineWidth: 1))
    }

    private func settingToggle(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack {
            settingText(title, detail)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(16)
        .overlay(alignment: .top) { Rectangle().fill(StudioColor.hairline).frame(height: 1) }
    }

    private func settingPicker(_ title: String, detail: String = "", value: String, disabled: Bool = false) -> some View {
        HStack {
            settingText(title, detail)
            Spacer()
            Text(value)
                .font(StudioFont.font(12, weight: .medium))
                .foregroundStyle(disabled ? StudioColor.tertiaryText : StudioColor.text)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Capsule().fill(StudioColor.control))
                .overlay(Capsule().stroke(StudioColor.hairline, lineWidth: 1))
        }
        .padding(16)
        .opacity(disabled ? 0.62 : 1)
        .overlay(alignment: .top) { Rectangle().fill(StudioColor.hairline).frame(height: 1) }
    }

    private func settingsReadOnly(_ title: String, value: String) -> some View {
        HStack(alignment: .top) {
            settingText(title, value)
            Spacer()
        }
        .padding(16)
        .overlay(alignment: .top) { Rectangle().fill(StudioColor.hairline).frame(height: 1) }
    }

    private func settingsAction(_ title: String, detail: String, button: String, disabled: Bool = false, action: (() -> Void)? = nil) -> some View {
        HStack {
            settingText(title, detail)
            Spacer()
            Button(button) {
                action?()
            }
            .buttonStyle(disabled ? CapsuleButtonStyle() : CapsuleButtonStyle(filled: button == "打开"))
            .disabled(disabled)
            .opacity(disabled ? 0.56 : 1)
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

    private func settingText(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(StudioFont.font(13, weight: .semibold))
            if !detail.isEmpty {
                Text(detail)
                    .font(StudioFont.font(12))
                    .foregroundStyle(StudioColor.secondaryText)
                    .lineLimit(2)
            }
        }
    }

    private func overviewCard(_ title: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(StudioFont.font(13, weight: .semibold))
            Text(value)
                .font(StudioFont.font(24, weight: .semibold))
            Text(detail)
                .font(StudioFont.font(12))
                .foregroundStyle(StudioColor.secondaryText)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        .background(StudioColor.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(StudioColor.hairline, lineWidth: 1))
    }

    private func statusPill(_ text: String) -> some View {
        Text(text)
            .font(StudioFont.font(11))
            .foregroundStyle(StudioColor.secondaryText)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(StudioColor.control))
            .overlay(Capsule().stroke(StudioColor.hairline, lineWidth: 1))
    }

    private func resetCurrentPage() {
        switch selectedPage {
        case .general:
            state.isListView = false
            autoBackup = false
        case .promptEditor:
            longPromptExpanded = true
            defaultCopyFormat = "纯文本"
        case .search, .privacy:
            localFirst = true
        case .cards:
            thumbnailScale = 1.0
            showPromptSummary = false
            state.isListView = false
        case .backup:
            autoBackup = false
            defaultCopyFormat = "纯文本"
        default:
            break
        }
    }
}

private enum SettingsPage: String, CaseIterable, Identifiable {
    case home
    case general
    case library
    case promptEditor
    case models
    case search
    case cards
    case shortcuts
    case backup
    case privacy

    enum Section: CaseIterable, Identifiable {
        case overview
        case basics
        case workflow
        case system

        var id: String { title }

        var title: String {
            switch self {
            case .overview: "概览"
            case .basics: "基础"
            case .workflow: "PROMPT 工作流"
            case .system: "系统"
            }
        }
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "设置首页"
        case .general: "通用"
        case .library: "素材库与存储"
        case .promptEditor: "Prompt 编辑器"
        case .models: "模型与 API"
        case .search: "搜索与索引"
        case .cards: "卡片与预览"
        case .shortcuts: "快捷键"
        case .backup: "导出、备份与同步"
        case .privacy: "隐私与安全"
        }
    }

    var description: String {
        switch self {
        case .home: "把设置中心设计成 Prompt 工作流中控台，先确认库是否安全、索引是否健康、模型是否可用。"
        case .general: "控制启动、视图和基础操作偏好。"
        case .library: "查看当前本地资料库、数据库和附件存储。"
        case .promptEditor: "配置 Prompt 编辑、版本保存、复制格式和长文本显示。"
        case .models: "管理模型筛选、API Key 与本地模型连接状态。"
        case .search: "控制全文索引、本地优先和未来语义搜索。"
        case .cards: "控制瀑布流卡片、缩略图、详情和预览呈现。"
        case .shortcuts: "查看效率操作快捷键，后续支持自定义。"
        case .backup: "管理导出格式、备份策略和同步偏好。"
        case .privacy: "保护 Prompt、图片、API Key 和本地工作流隐私。"
        }
    }

    var icon: String {
        switch self {
        case .home: "house"
        case .general: "gearshape"
        case .library: "square.stack.3d.up"
        case .promptEditor: "pencil.line"
        case .models: "shippingbox"
        case .search: "magnifyingglass"
        case .cards: "rectangle.grid.2x2"
        case .shortcuts: "keyboard"
        case .backup: "arrow.up.doc"
        case .privacy: "lock"
        }
    }

    var badge: String {
        switch self {
        case .home: "状态"
        case .general: "应用"
        case .library: "库级"
        case .promptEditor, .models, .search: "核心"
        case .cards: "界面"
        case .shortcuts: "效率"
        case .backup, .privacy: "安全"
        }
    }

    var priority: String {
        switch self {
        case .home, .general, .library, .promptEditor, .models, .search, .shortcuts, .backup, .privacy:
            "P0"
        case .cards:
            "P1"
        }
    }

    var section: Section {
        switch self {
        case .home:
            .overview
        case .general, .library:
            .basics
        case .promptEditor, .models, .search, .cards:
            .workflow
        case .shortcuts, .backup, .privacy:
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
    @State private var newName = ""
    @State private var newType: PromptType = .image

    private var editableModels: [ModelProfile] {
        state.models.filter { $0.id != "all" }
    }

    var body: some View {
        PromptFormShell(title: "筛选标签管理") {
            VStack(alignment: .leading, spacing: 16) {
                Text("管理首页模型筛选栏中显示的标签。已有标签可修改名称和类型，新标签会保存到本地资料库。")
                    .font(StudioFont.font(13))
                    .foregroundStyle(StudioColor.secondaryText)

                VStack(alignment: .leading, spacing: 10) {
                    Text("现有筛选标签")
                        .font(StudioFont.caption(12))
                        .tracking(1.2)
                        .foregroundStyle(StudioColor.secondaryText)

                    ForEach(editableModels) { model in
                        ModelFilterEditorRow(model: model)
                            .environmentObject(state)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("新增筛选标签")
                        .font(StudioFont.caption(12))
                        .tracking(1.2)
                        .foregroundStyle(StudioColor.secondaryText)

                    HStack(spacing: 10) {
                        TextField("例如：Flux 1.1 Pro", text: $newName)
                            .textFieldStyle(.plain)
                            .font(StudioFont.font(13))
                            .foregroundStyle(StudioColor.text)
                            .padding(.horizontal, 12)
                            .frame(height: 38)
                            .background(StudioColor.control)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioColor.hairline, lineWidth: 1))

                        PromptTypeSegment(type: $newType)

                        Button {
                            state.createModelFilterLabel(name: newName, type: newType)
                            newName = ""
                        } label: {
                            Label("新增", systemImage: "plus")
                                .frame(minWidth: 76)
                        }
                        .buttonStyle(CapsuleButtonStyle(filled: true))
                    }
                    .padding(12)
                    .studioPanel(radius: 8)
                }
            }
        } footer: {
            Button("关闭") { dismiss() }
                .buttonStyle(CapsuleButtonStyle(filled: true))
        }
        .frame(width: 760, height: 620)
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
        if item.assetKind == .video {
            VideoPreviewPlayer(path: item.assetPath)
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
        guard [.markdown, .json, .text, .data].contains(item.assetKind),
              let data = try? Data(contentsOf: URL(fileURLWithPath: item.assetPath), options: [.mappedIfSafe]) else {
            return "\(item.assetKind.displayName) 文件，可通过右键菜单用默认应用打开。"
        }
        let previewData = Data(data.prefix(6000))
        let text = String(data: previewData, encoding: .utf8)
            ?? String(data: previewData, encoding: .utf16)
            ?? String(data: previewData, encoding: .isoLatin1)
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !trimmed.isEmpty
            ? trimmed
            : "\(item.assetKind.displayName) 文件无可读取文本摘要。"
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
