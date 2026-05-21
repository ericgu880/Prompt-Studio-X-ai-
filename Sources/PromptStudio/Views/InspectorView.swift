import SwiftUI
import PromptStudioCore

struct InspectorView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Group {
            if let item = state.selectedItem {
                inspector(for: item)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("未选择素材")
                        .font(.system(size: 20, weight: .semibold))
                    Text("选择瀑布流中的图片后，这里会显示 Prompt、参数、标签和文件信息。")
                        .foregroundStyle(StudioColor.secondaryText)
                    Spacer()
                }
                .padding(22)
                .padding(.top, 16)
                .foregroundStyle(StudioColor.text)
            }
        }
        .background(StudioColor.panel)
    }

    private func inspector(for item: PromptItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(item)
                Divider().overlay(StudioColor.hairline)
                tagSection(item)
                promptSection(item)
                negativeSection(item)
                referenceSection(item)
                actionSection(item)
                versionSection(item)
                fileInfoSection(item)
            }
            .padding(20)
            .padding(.top, 24)
        }
    }

    private func header(_ item: PromptItem) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ThumbnailImage(path: item.thumbnailPath)
                .frame(width: 112, height: 112)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(StudioColor.hairline, lineWidth: 1))
                .onTapGesture { state.previewSelected() }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Text(item.title)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(2)
                    Spacer()
                    Button {
                        state.toggleFavorite(item)
                    } label: {
                        Image(systemName: item.favorite ? "star.fill" : "star")
                            .foregroundStyle(item.favorite ? StudioColor.orange : StudioColor.text)
                    }
                    .buttonStyle(.plain)
                }
                infoLine("模型", item.modelName)
                infoLine("尺寸", "\(item.displayAspectRatio) (\(item.width) x \(item.height))")
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
                        .font(.system(size: 12, weight: .semibold))
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
                .buttonStyle(.plain)
                .background(Capsule().fill(StudioColor.control))
                .overlay(Capsule().stroke(StudioColor.hairline, lineWidth: 1))
            }
        }
    }

    private func promptSection(_ item: PromptItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("提示词 (Prompt)")
            Text(item.currentVersion?.prompt ?? "未填写 Prompt")
                .font(.system(size: 12.5))
                .lineSpacing(3)
                .foregroundStyle(StudioColor.text)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 96)
                .studioPanel(radius: 8)
            HStack {
                Spacer()
                Text("\((item.currentVersion?.prompt.count ?? 0))/2000")
                    .font(.system(size: 11))
                    .foregroundStyle(StudioColor.secondaryText)
            }
        }
    }

    private func negativeSection(_ item: PromptItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("负面提示词（可选）")
            Text(item.currentVersion?.negativePrompt ?? "")
                .font(.system(size: 12.5))
                .lineSpacing(3)
                .foregroundStyle(StudioColor.secondaryText)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 62)
                .studioPanel(radius: 8)
        }
    }

    private func referenceSection(_ item: PromptItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("参考图")
            HStack(spacing: 10) {
                ForEach(item.referenceAssets.prefix(3)) { reference in
                    ThumbnailImage(path: reference.path)
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioColor.hairline, lineWidth: 1))
                }
                Button {
                    state.modal = .references
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 52, height: 48)
                }
                .buttonStyle(.plain)
                .studioPanel(radius: 8)
            }
        }
    }

    private func actionSection(_ item: PromptItem) -> some View {
        HStack(spacing: 8) {
            Button {
                state.modal = .editPrompt
            } label: {
                Text("编辑").frame(maxWidth: .infinity)
            }
                .buttonStyle(CapsuleButtonStyle(filled: true))
            Button {
                state.copySelectedPrompt()
            } label: {
                Text("复制提示词").frame(maxWidth: .infinity)
            }
                .buttonStyle(CapsuleButtonStyle())
            Button {
                state.modal = .variants
            } label: {
                Text("生成变体").frame(maxWidth: .infinity)
            }
                .buttonStyle(CapsuleButtonStyle())
        }
    }

    private func versionSection(_ item: PromptItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("历史版本")
                Spacer()
                Button("查看全部版本") { state.modal = .versionHistory }
                    .buttonStyle(.plain)
                    .foregroundStyle(StudioColor.secondaryText)
                    .font(.system(size: 11))
            }
            HStack(spacing: 8) {
                ForEach(item.versions.prefix(4)) { version in
                    Text(version.version)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(Capsule().fill(version.id == item.currentVersion?.id ? StudioColor.selection : StudioColor.control))
                        .overlay(Capsule().stroke(version.id == item.currentVersion?.id ? StudioColor.blue : StudioColor.hairline, lineWidth: 1))
                }
            }
        }
    }

    private func fileInfoSection(_ item: PromptItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("图片信息")
            VStack(spacing: 10) {
                infoGrid("文件尺寸", fileSizeText(item.fileSize), "分辨率", item.displaySize)
                infoGrid("格式", item.format, "颜色空间", "sRGB")
            }
            Button {
                state.exportSelected()
            } label: {
                Label("导出图片", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(CapsuleButtonStyle())
            Button {
                state.revealSelectedInFinder()
            } label: {
                Label("在 Finder 中显示", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .foregroundStyle(StudioColor.secondaryText)
        }
    }

    private func infoLine(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(StudioColor.tertiaryText)
            Text(value)
                .font(.system(size: 12, weight: .medium))
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
                .font(.system(size: 11))
                .foregroundStyle(StudioColor.secondaryText)
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(StudioColor.text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(StudioColor.secondaryText)
    }

    private func fileSizeText(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 KB" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
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
