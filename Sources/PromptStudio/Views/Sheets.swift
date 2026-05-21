import SwiftUI
import PromptStudioCore

struct NewPromptSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var type: PromptType = .image
    @State private var modelId = "nano_banana_2"
    @State private var prompt = ""
    @State private var negativePrompt = ""
    @State private var tags = "风景, 人物"

    var body: some View {
        PromptFormShell(title: "新建 Prompt") {
            form
        } footer: {
            Button("取消") { dismiss() }
            Button("创建") {
                state.createPrompt(
                    title: title.isEmpty ? "未命名 Prompt" : title,
                    type: type,
                    modelId: modelId,
                    prompt: prompt,
                    negativePrompt: negativePrompt,
                    tags: parsedTags
                )
                dismiss()
            }
            .buttonStyle(CapsuleButtonStyle(filled: true))
        }
        .frame(width: 720, height: 680)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            LabeledField("标题") {
                TextField("这里是一个标题", text: $title)
            }
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
            LabeledEditor("负面提示词", text: $negativePrompt, minHeight: 86)
            LabeledField("标签（逗号分隔）") {
                TextField("风景, 人物, 写实", text: $tags)
            }
        }
    }

    private var parsedTags: [String] {
        tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
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
            VStack(spacing: 18) {
                VStack(spacing: 12) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 42))
                    Text("拖拽图片、视频、文本到主窗口，或点击下方选择文件")
                        .font(.system(size: 15, weight: .semibold))
                    Text("导入后会复制到本地资料库，并进入待完善信息状态。")
                        .foregroundStyle(StudioColor.secondaryText)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 220)
                .studioPanel(radius: 12)

                HStack(spacing: 12) {
                    ImportStep(title: "1", text: "复制到资料库")
                    ImportStep(title: "2", text: "生成缩略图")
                    ImportStep(title: "3", text: "补充 Prompt")
                }
            }
        } footer: {
            Button("取消") { dismiss() }
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
    @State private var favoriteOnly = false
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
                Toggle("仅收藏", isOn: $favoriteOnly)
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
            Button("应用") {
                state.filter.type = type
                state.filter.favoriteOnly = favoriteOnly
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
                        Circle().fill(StudioColor.blue).frame(width: 8, height: 8)
                        Text(tag.name)
                        Spacer()
                        Text("\(tag.count)")
                            .foregroundStyle(StudioColor.secondaryText)
                        Button("筛选") { state.setCollection(.tag(tag.name)) }
                    }
                    .frame(height: 34)
                    Divider().overlay(StudioColor.hairline)
                }
                Text("MVP 支持标签查看和筛选；重命名、合并和颜色将在下一步接入。")
                    .font(.system(size: 12))
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
                                        .font(.system(size: 16, weight: .bold))
                                    Spacer()
                                    Text(version.createdAt.formatted(date: .numeric, time: .shortened))
                                        .font(.system(size: 12))
                                        .foregroundStyle(StudioColor.secondaryText)
                                }
                                Text(version.prompt)
                                    .lineLimit(4)
                                    .font(.system(size: 13))
                                    .foregroundStyle(StudioColor.secondaryText)
                                HStack {
                                    Button("复制") {
                                        AppKitBridge.copyToPasteboard(version.prompt)
                                        state.toast = "已复制版本 Prompt"
                                    }
                                    Button("恢复为新版本") {
                                        state.restoreVersion(version)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(14)
                            .studioPanel(radius: 10)
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
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], spacing: 12) {
                    ForEach(item.referenceAssets) { reference in
                        VStack(alignment: .leading, spacing: 8) {
                            ThumbnailImage(path: reference.path)
                                .frame(height: 100)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            Text(reference.label)
                                .font(.system(size: 13, weight: .semibold))
                            Text(reference.type)
                                .font(.system(size: 12))
                                .foregroundStyle(StudioColor.secondaryText)
                        }
                        .padding(10)
                        .studioPanel(radius: 10)
                    }
                    Button {
                        state.modal = .importAssets
                    } label: {
                        VStack(spacing: 10) {
                            Image(systemName: "plus")
                            Text("添加参考图")
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 160)
                    }
                    .buttonStyle(.plain)
                    .studioPanel(radius: 10)
                }
            }
        } footer: {
            Button("关闭") { state.modal = nil }
                .buttonStyle(CapsuleButtonStyle(filled: true))
        }
        .frame(width: 680, height: 520)
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
            VStack(alignment: .leading, spacing: 12) {
                Text("导出当前素材副本和 Markdown Prompt 文件。")
                    .foregroundStyle(StudioColor.secondaryText)
                if let item = state.selectedItem {
                    Text(item.title)
                        .font(.system(size: 18, weight: .bold))
                    Text(item.assetPath)
                        .font(.system(size: 12))
                        .foregroundStyle(StudioColor.tertiaryText)
                        .lineLimit(2)
                }
            }
        } footer: {
            Button("取消") { dismiss() }
            Button("选择目录并导出") {
                state.exportSelected()
                dismiss()
            }
            .buttonStyle(CapsuleButtonStyle(filled: true))
        }
        .frame(width: 560, height: 360)
    }
}

struct SettingsSheet: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        PromptFormShell(title: "设置") {
            VStack(alignment: .leading, spacing: 16) {
                SettingsRow(title: "资料库位置", value: state.libraryURL.path)
                SettingsRow(title: "默认导入方式", value: "复制到资料库")
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
            Button("关闭") { state.modal = nil }
                .buttonStyle(CapsuleButtonStyle(filled: true))
        }
        .frame(width: 680, height: 520)
    }
}

struct PreviewSheet: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(state.selectedItem?.title ?? "预览")
                    .font(.system(size: 16, weight: .bold))
                Spacer()
                Button("关闭") { state.modal = nil }
            }
            .padding()
            Divider().overlay(StudioColor.hairline)
            if let path = state.selectedItem?.assetPath {
                ThumbnailImage(path: path)
                    .scaledToFit()
                    .padding(18)
            }
        }
        .frame(width: 920, height: 720)
        .background(StudioColor.appBackground)
    }
}

struct ErrorSheet: View {
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34))
                .foregroundStyle(StudioColor.orange)
            Text("操作失败")
                .font(.system(size: 20, weight: .bold))
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
                    .font(.system(size: 22, weight: .bold))
                Spacer()
            }
            .padding(22)

            Divider().overlay(StudioColor.hairline)

            ScrollView {
                content
                    .padding(22)
            }

            Divider().overlay(StudioColor.hairline)

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
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(StudioColor.secondaryText)
            content
                .textFieldStyle(.roundedBorder)
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
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(StudioColor.secondaryText)
            TextEditor(text: $text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: minHeight)
                .studioPanel(radius: 8)
        }
    }
}

private struct ImportStep: View {
    let title: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .frame(width: 28, height: 28)
                .background(Circle().fill(StudioColor.blue))
            Text(text)
                .font(.system(size: 13, weight: .semibold))
        }
        .padding(12)
        .studioPanel(radius: 10)
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
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(StudioColor.secondaryText)
            Text(value)
                .font(.system(size: 13))
                .lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .studioPanel(radius: 10)
    }
}
