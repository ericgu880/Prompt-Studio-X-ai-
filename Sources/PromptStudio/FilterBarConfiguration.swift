import Foundation
import PromptStudioCore

enum FilterQuickEntry: Identifiable, Equatable {
    case all
    case type(PromptType, title: String)
    case model(ModelProfile, title: String?)
    case textFormat(TextFormatFilter, title: String?)
    case assetKind(AssetKindFilter, title: String?)
    case tag(String)

    var id: String {
        switch self {
        case .all:
            "all"
        case .type(let type, _):
            "type-\(type.rawValue)"
        case .model(let model, _):
            "model-\(model.id)"
        case .textFormat(let textFormat, _):
            "format-\(textFormat.rawValue)"
        case .assetKind(let assetKindFilter, _):
            "asset-\(assetKindFilter.rawValue)"
        case .tag(let tag):
            "tag-\(tag)"
        }
    }

    var title: String {
        switch self {
        case .all:
            "全部"
        case .type(_, let title):
            title
        case .model(let model, let title):
            title ?? model.name
        case .textFormat(let textFormat, let title):
            title ?? textFormat.displayName
        case .assetKind(let assetKindFilter, let title):
            title ?? assetKindFilter.displayName
        case .tag(let tag):
            tag
        }
    }

    var categoryTitle: String {
        switch self {
        case .all:
            "基础"
        case .type:
            "类型"
        case .model:
            "模型"
        case .textFormat:
            "格式"
        case .assetKind:
            "素材"
        case .tag:
            "标签"
        }
    }
}

enum FilterBarConfiguration {
    static let storageKey = "promptStudio.filterBarSelection"

    static let defaultSelectedIDs = [
        "all",
        "type-image",
        "type-video",
        "type-text",
        "model-image_2",
        "model-nano_banana_2",
        "model-seedance_2",
        "model-kling_3",
        "format-markdown",
        "format-json",
        "format-text",
        "format-word",
        "asset-audio",
        "asset-document",
        "asset-source",
        "asset-raw",
        "asset-threeD",
        "asset-font"
    ]

    static func availableEntries(models: [ModelProfile], tags: [Tag]) -> [FilterQuickEntry] {
        var entries: [FilterQuickEntry] = [
            .all,
            .type(.image, title: "picture"),
            .type(.video, title: "video"),
            .type(.text, title: "text")
        ]

        let preferredModelTitles = [
            "image_2": "Image 2",
            "nano_banana_2": "Nano Banana 2",
            "seedance_2": "Seedance 2.0",
            "kling_3": "可灵3.0"
        ]
        let sortedModels = models
            .filter { $0.id != "all" }
            .sorted { lhs, rhs in
                let lhsIndex = defaultSelectedIDs.firstIndex(of: "model-\(lhs.id)") ?? Int.max
                let rhsIndex = defaultSelectedIDs.firstIndex(of: "model-\(rhs.id)") ?? Int.max
                if lhsIndex != rhsIndex { return lhsIndex < rhsIndex }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        entries.append(contentsOf: sortedModels.map { model in
            .model(model, title: preferredModelTitles[model.id])
        })

        entries.append(contentsOf: [
            .textFormat(.markdown, title: "MD"),
            .textFormat(.json, title: "JSON"),
            .textFormat(.text, title: "TXT"),
            .textFormat(.word, title: "WORD")
        ])

        entries.append(contentsOf: [
            .assetKind(.image, title: "图片"),
            .assetKind(.video, title: "视频"),
            .assetKind(.audio, title: "音频"),
            .assetKind(.promptDocument, title: "Prompt 文档"),
            .assetKind(.document, title: "办公/PDF"),
            .assetKind(.source, title: "源文件"),
            .assetKind(.raw, title: "RAW"),
            .assetKind(.threeD, title: "3D"),
            .assetKind(.texture, title: "贴图"),
            .assetKind(.font, title: "字体"),
            .assetKind(.web, title: "网页"),
            .assetKind(.other, title: "其他")
        ])

        let tagEntries = tags
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            .map { FilterQuickEntry.tag($0.name) }
        entries.append(contentsOf: tagEntries)

        return entries.uniquedByID()
    }

    static func selectedIDs(from rawValue: String, availableEntries: [FilterQuickEntry]) -> [String] {
        let availableIDs = Set(availableEntries.map(\.id))
        let decoded = decode(rawValue).filter { availableIDs.contains($0) }
        let base = decoded.isEmpty ? defaultSelectedIDs.filter { availableIDs.contains($0) } : decoded
        return base.isEmpty ? availableEntries.prefix(1).map(\.id) : base
    }

    static func encode(_ ids: [String]) -> String {
        guard let data = try? JSONEncoder().encode(ids),
              let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }

    private static func decode(_ rawValue: String) -> [String] {
        guard let data = rawValue.data(using: .utf8),
              let ids = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return ids
    }
}

private extension Array where Element == FilterQuickEntry {
    func uniquedByID() -> [FilterQuickEntry] {
        var seen = Set<String>()
        return filter { entry in
            seen.insert(entry.id).inserted
        }
    }
}
