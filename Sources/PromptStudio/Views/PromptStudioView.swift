import SwiftUI
import PromptStudioCore
import AppKit
import UniformTypeIdentifiers

struct PromptStudioView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ZStack(alignment: .bottom) {
            HStack(spacing: 0) {
                SidebarView()
                    .frame(width: 220)

                Divider().overlay(StudioColor.hairline)

                MainContentView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider().overlay(StudioColor.hairline)

                InspectorView()
                    .frame(width: 330)
            }
            .background(StudioColor.appBackground)

            if let toast = state.toast {
                Text(toast)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StudioColor.text)
                    .padding(.horizontal, 16)
                    .frame(height: 38)
                    .background(Capsule().fill(Color.black.opacity(0.78)))
                    .overlay(Capsule().stroke(StudioColor.hairline, lineWidth: 1))
                    .padding(.bottom, 22)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(item: $state.modal) { modal in
            sheet(for: modal)
        }
    }

    @ViewBuilder
    private func sheet(for modal: AppState.Modal) -> some View {
        switch modal {
        case .newPrompt:
            NewPromptSheet()
                .environmentObject(state)
        case .editPrompt:
            if let item = state.selectedItem {
                EditPromptSheet(item: item)
                    .environmentObject(state)
            }
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
        case .preview:
            PreviewSheet()
                .environmentObject(state)
        case .error(let message):
            ErrorSheet(message: message)
        }
    }
}

private struct SidebarView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            windowChrome

            Button {
                state.modal = .newPrompt
            } label: {
                Label("新建 Prompt", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(CapsuleButtonStyle(filled: true))
            .padding(.horizontal, 14)
            .padding(.top, 18)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    sidebarSection("资源库") {
                        SidebarRow(icon: "rectangle.stack", title: "全部", count: allCount, collection: .all)
                        SidebarDisclosure(title: "图片 Prompt", icon: "photo", rows: imageRows)
                        SidebarDisclosure(title: "视频 Prompt", icon: "video", rows: videoRows)
                    }

                    sidebarSection(nil) {
                        SidebarRow(icon: "star.fill", title: "收藏", count: state.favoriteCount, collection: .favorites, tint: StudioColor.orange)
                    }

                    sidebarSection("最近使用") {
                        ForEach(recentItems.prefix(3)) { item in
                            RecentRow(item: item)
                                .onTapGesture { state.select(item) }
                        }
                    }

                    sidebarSection("标签") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), spacing: 8)], spacing: 8) {
                            ForEach(state.tags.prefix(6)) { tag in
                                Button {
                                    state.setCollection(.tag(tag.name))
                                } label: {
                                    Text("# \(tag.name)  \(tag.count)")
                                        .lineLimit(1)
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                .buttonStyle(CapsuleButtonStyle())
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 18)
                .padding(.bottom, 120)
            }

            Spacer(minLength: 0)

            Button {
                state.setCollection(.trash)
            } label: {
                HStack {
                    Image(systemName: "trash")
                    Text("回收站")
                    Spacer()
                    Text("\(state.trashCount)")
                        .foregroundStyle(StudioColor.secondaryText)
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(StudioColor.text)
                .frame(height: 42)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
        }
        .background(StudioColor.sidebar)
    }

    private var windowChrome: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Circle().fill(Color.red).frame(width: 12, height: 12)
                Circle().fill(Color.orange).frame(width: 12, height: 12)
                Circle().fill(Color.green).frame(width: 12, height: 12)
                Spacer()
            }
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(Color.white)
                    Text("P")
                        .font(.system(size: 16, weight: .heavy))
                        .foregroundStyle(Color.black)
                }
                .frame(width: 26, height: 26)
                Text("PromptStudio")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(StudioColor.text)
            }
        }
        .padding(.top, 18)
        .padding(.horizontal, 18)
    }

    private var imageRows: [(String, Int, LibraryCollection)] {
        [
            ("PromptStudio", folderCount("PromptStudio"), .folder("PromptStudio")),
            ("UX Pro Max Skill", folderCount("UX Pro Max Skill"), .folder("UX Pro Max Skill")),
            ("G-Stack 实战方法", folderCount("G-Stack 实战方法"), .folder("G-Stack 实战方法")),
            ("Inshennx/优化合集", folderCount("Inshennx/优化合集"), .folder("Inshennx/优化合集")),
            ("灵感实验室", folderCount("灵感实验室"), .folder("灵感实验室"))
        ]
    }

    private var allCount: Int {
        state.items.filter { !$0.isDeleted }.count
    }

    private var videoRows: [(String, Int, LibraryCollection)] {
        [
            ("PromptStudio-X AI", folderCount("PromptStudio-X AI"), .folder("PromptStudio-X AI")),
            ("完整项目框架开发", folderCount("完整项目框架开发"), .folder("完整项目框架开发")),
            ("讨论跟踪 AIGC 平台", folderCount("讨论跟踪 AIGC 平台"), .folder("讨论跟踪 AIGC 平台")),
            ("视频创作实验室", folderCount("视频创作实验室"), .folder("视频创作实验室"))
        ]
    }

    private var recentItems: [PromptItem] {
        state.items
            .filter { !$0.isDeleted }
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    private func folderCount(_ name: String) -> Int {
        state.items.filter { !$0.isDeleted && $0.folderName == name }.count
    }

    @ViewBuilder
    private func sidebarSection<Content: View>(_ title: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(StudioColor.tertiaryText)
            }
            content()
        }
    }
}

private struct SidebarDisclosure: View {
    let title: String
    let icon: String
    let rows: [(String, Int, LibraryCollection)]
    @EnvironmentObject private var state: AppState
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon).frame(width: 18)
                    Text(title)
                    Spacer()
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 0 : 180))
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(StudioColor.text)
            }
            .buttonStyle(.plain)

            if expanded {
                ForEach(rows, id: \.0) { row in
                    SidebarRow(icon: "folder", title: row.0, count: row.1, collection: row.2)
                        .padding(.leading, 16)
                }
            }
        }
    }
}

private struct SidebarRow: View {
    @EnvironmentObject private var state: AppState
    let icon: String
    let title: String
    let count: Int
    let collection: LibraryCollection
    var isActive = false
    var tint: Color = StudioColor.secondaryText

    var body: some View {
        let active = isActive || state.filter.collection == collection
        Button {
            state.setCollection(collection)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .frame(width: 17)
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Text("\(count)")
                    .foregroundStyle(StudioColor.secondaryText)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(StudioColor.text)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(active ? StudioColor.blue.opacity(0.48) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct RecentRow: View {
    let item: PromptItem

    var body: some View {
        HStack(spacing: 8) {
            ThumbnailImage(path: item.thumbnailPath)
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(item.title)
                .lineLimit(1)
                .font(.system(size: 12, weight: .medium))
            Spacer()
            Text(item.lastUsedAt.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 11))
                .foregroundStyle(StudioColor.secondaryText)
        }
        .foregroundStyle(StudioColor.text)
        .frame(height: 28)
    }
}

private struct MainContentView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            TopToolbarView()
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 14)

            ModelTabsView()
                .padding(.horizontal, 24)
                .padding(.bottom, 16)

            if state.filteredItems.isEmpty {
                EmptyStateView()
            } else if state.isListView {
                PromptListView(items: state.filteredItems)
            } else {
                MasonryGridView(items: state.filteredItems)
            }
        }
        .background(StudioColor.appBackground)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            Task { @MainActor in
                var urls: [URL] = []
                for provider in providers {
                    if let item = try? await provider.loadItem(forTypeIdentifier: "public.file-url") as? Data,
                       let url = URL(dataRepresentation: item, relativeTo: nil) {
                        urls.append(url)
                    }
                }
                if !urls.isEmpty { state.importFiles(urls) }
            }
            return true
        }
    }
}

private struct TopToolbarView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(StudioColor.secondaryText)
                TextField("全能搜索：名称、提示词、分类、标签、描述", text: Binding(
                    get: { state.filter.query },
                    set: { state.filter.query = $0 }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(StudioColor.text)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .studioPanel(radius: 8)

            Button {
                state.modal = .filters
            } label: {
                Label("筛选", systemImage: "line.3.horizontal.decrease")
                    .frame(minWidth: 72)
            }
            .buttonStyle(CapsuleButtonStyle())

            Button {
                state.isListView = false
            } label: {
                Image(systemName: "square.grid.2x2")
            }
            .buttonStyle(CapsuleButtonStyle(accent: !state.isListView))

            Button {
                state.isListView = true
            } label: {
                Image(systemName: "list.bullet")
            }
            .buttonStyle(CapsuleButtonStyle(accent: state.isListView))
        }
    }
}

private struct ModelTabsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                ForEach(state.models) { model in
                    Button {
                        state.setModel(model.id)
                    } label: {
                        Text(model.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(state.filter.modelId == model.id || (state.filter.modelId == nil && model.id == "all") ? Color.white : StudioColor.secondaryText)
                            .padding(.horizontal, model.id == "all" ? 12 : 4)
                            .frame(height: 32)
                            .background(
                                Capsule()
                                    .fill(model.id == "all" && state.filter.modelId == nil ? StudioColor.blueSoft : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    state.modal = .settings
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(StudioColor.text)
            }
        }
    }
}

private struct MasonryGridView: View {
    @EnvironmentObject private var state: AppState
    let items: [PromptItem]

    var body: some View {
        GeometryReader { proxy in
            let columnCount = max(2, min(4, Int(proxy.size.width / 250)))
            let width = (proxy.size.width - CGFloat(columnCount - 1) * 12 - 48) / CGFloat(columnCount)
            let columns = distribute(items, columnCount: columnCount)
            ScrollView {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                        VStack(spacing: 12) {
                            ForEach(column) { item in
                                AssetCardView(item: item, width: width)
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }

    private func distribute(_ items: [PromptItem], columnCount: Int) -> [[PromptItem]] {
        var columns = Array(repeating: [PromptItem](), count: columnCount)
        var heights = Array(repeating: CGFloat.zero, count: columnCount)
        for item in items {
            let index = heights.enumerated().min(by: { $0.element < $1.element })?.offset ?? 0
            columns[index].append(item)
            heights[index] += estimatedHeight(for: item)
        }
        return columns
    }

    private func estimatedHeight(for item: PromptItem) -> CGFloat {
        switch item.displayAspectRatio {
        case "16:9": 176
        case "1:1": 245
        case "4:5": 310
        default: 365
        }
    }
}

private struct AssetCardView: View {
    @EnvironmentObject private var state: AppState
    let item: PromptItem
    let width: CGFloat

    private var isSelected: Bool {
        state.selectedID == item.id
    }

    var body: some View {
        let height = cardHeight(for: item, width: width)
        ZStack(alignment: .topLeading) {
            ThumbnailImage(path: item.thumbnailPath)
                .frame(width: width, height: height)
                .clipped()

            Text(item.format)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(Capsule().fill(Color.black.opacity(0.72)))
                .padding(12)

            LinearGradient(
                colors: [.clear, Color.black.opacity(isSelected ? 0.82 : 0.66)],
                startPoint: .center,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 8) {
                Spacer()
                Text(item.title)
                    .font(.system(size: 14, weight: .bold))
                    .lineLimit(1)
                Text("\(item.modelName) · \(item.displayAspectRatio)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.78))

                if isSelected {
                    HStack(spacing: 8) {
                        ForEach(item.tags.prefix(3), id: \.self) { tag in
                            Text(tag)
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 9)
                                .frame(height: 24)
                                .background(Capsule().fill(Color.white.opacity(0.12)))
                        }
                    }

                    HStack(spacing: 14) {
                        cardAction("pencil") { state.modal = .editPrompt }
                        cardAction("doc.on.doc") { state.copySelectedPrompt() }
                        cardAction(item.favorite ? "star.fill" : "star") { state.toggleFavorite(item) }
                        cardAction("clock") { state.modal = .versionHistory }
                        Spacer()
                        cardAction("ellipsis") { state.modal = .export }
                    }
                    .padding(.top, 2)
                }
            }
            .foregroundStyle(Color.white)
            .padding(14)

            if isSelected {
                VStack {
                    HStack {
                        Spacer()
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(StudioColor.blue))
                            .padding(12)
                    }
                    Spacer()
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? StudioColor.blue : Color.white.opacity(0.08), lineWidth: isSelected ? 2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture {
            state.select(item)
        }
        .onTapGesture(count: 2) {
            state.select(item)
            state.previewSelected()
        }
    }

    private func cardAction(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
        }
        .buttonStyle(IconCircleButtonStyle())
    }

    private func cardHeight(for item: PromptItem, width: CGFloat) -> CGFloat {
        let parts = item.displayAspectRatio.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0 else { return width * 1.25 }
        return max(170, min(430, width * CGFloat(parts[1] / parts[0])))
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
                        ThumbnailImage(path: item.thumbnailPath)
                            .frame(width: 66, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.system(size: 14, weight: .bold))
                            Text("\(item.modelName) · \(item.displayAspectRatio) · \(item.tags.joined(separator: " / "))")
                                .font(.system(size: 12))
                                .foregroundStyle(StudioColor.secondaryText)
                        }
                        Spacer()
                        Text(item.updatedAt.formatted(date: .numeric, time: .shortened))
                            .font(.system(size: 12))
                            .foregroundStyle(StudioColor.tertiaryText)
                    }
                    .padding(12)
                    .studioPanel(radius: 10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(state.selectedID == item.id ? StudioColor.blue : Color.clear, lineWidth: 2)
                    )
                    .onTapGesture { state.select(item) }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }
}

private struct EmptyStateView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44))
                .foregroundStyle(StudioColor.secondaryText)
            Text("没有找到素材")
                .font(.system(size: 24, weight: .bold))
            Text("调整搜索或导入图片、视频、Prompt 文本。")
                .foregroundStyle(StudioColor.secondaryText)
            Button("导入素材") {
                state.modal = .importAssets
            }
            .buttonStyle(CapsuleButtonStyle(filled: true))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(StudioColor.text)
    }
}

struct ThumbnailImage: View {
    let path: String

    var body: some View {
        Group {
            if !path.isEmpty, let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    StudioColor.panelRaised
                    Image(systemName: "photo")
                        .font(.system(size: 24))
                        .foregroundStyle(StudioColor.secondaryText)
                }
            }
        }
    }
}
