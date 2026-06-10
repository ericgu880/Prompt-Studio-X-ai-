import Foundation
import PromptStudioCore

enum SeedData {
    static let rootFolderID = "folder-project"
    static let defaultFolderID = "folder-promptstudio"
    static let uncategorizedFolderID = "folder-uncategorized"

    static let models: [ModelProfile] = [
        ModelProfile(id: "all", name: "全部模型", type: .image, parameters: []),
        ModelProfile(id: "image_2", name: "GPT Image 2", type: .image, parameters: ["aspectRatio", "style", "quality"]),
        ModelProfile(id: "nano_banana_2", name: "Nano Banana 2", type: .image, parameters: ["aspectRatio", "style", "seed", "quality"]),
        ModelProfile(id: "nano_banana_pro", name: "Nano Banana Pro", type: .image, parameters: ["aspectRatio", "style", "quality"]),
        ModelProfile(id: "midjourney", name: "Midjourney", type: .image, parameters: ["ar", "v", "style", "seed"]),
        ModelProfile(id: "seedream_7", name: "Seedream 5.0 Lite", type: .image, parameters: ["aspectRatio", "style", "color"]),
        ModelProfile(id: "stable_diffusion_sdxl", name: "Stable Diffusion / SDXL", type: .image, parameters: ["aspectRatio", "style", "seed"]),
        ModelProfile(id: "flux", name: "FLUX", type: .image, parameters: ["aspectRatio", "style", "seed"]),
        ModelProfile(id: "qwen_z_image", name: "千问Z-Image", type: .image, parameters: ["aspectRatio", "style", "quality"]),
        ModelProfile(id: "seedance_2", name: "Seedance 2.0", type: .video, parameters: ["duration", "camera", "motion"]),
        ModelProfile(id: "kling_3", name: "Kling / 可灵", type: .video, parameters: ["duration", "motion", "camera"]),
        ModelProfile(id: "google_veo", name: "Google Veo", type: .video, parameters: ["duration", "camera", "motion"]),
        ModelProfile(id: "runway", name: "Runway", type: .video, parameters: ["duration", "camera", "motion"]),
        ModelProfile(id: "sora", name: "Sora", type: .video, parameters: ["duration", "camera", "motion"]),
        ModelProfile(id: "ltx_2_3", name: "LTX 2.3", type: .video, parameters: ["duration", "camera", "motion"]),
        ModelProfile(id: "hailuo_minimax", name: "Hailuo / MiniMax", type: .video, parameters: ["duration", "camera", "motion"]),
        ModelProfile(id: "luma_ray", name: "Luma / Ray", type: .video, parameters: ["duration", "camera", "motion"]),
        ModelProfile(id: "pika", name: "Pika", type: .video, parameters: ["duration", "camera", "motion"]),
        ModelProfile(id: "vidu", name: "Vidu", type: .video, parameters: ["duration", "camera", "motion"]),
        ModelProfile(id: "wan_video", name: "Wan / 通义万相视频", type: .video, parameters: ["duration", "camera", "motion"]),
        ModelProfile(id: "chatgpt_gpt", name: "ChatGPT / GPT", type: .text, parameters: ["format", "tone", "length"]),
        ModelProfile(id: "claude", name: "Claude", type: .text, parameters: ["format", "tone", "length"]),
        ModelProfile(id: "gemini", name: "Gemini", type: .text, parameters: ["format", "tone", "length"]),
        ModelProfile(id: "deepseek", name: "DeepSeek", type: .text, parameters: ["format", "tone", "length"]),
        ModelProfile(id: "qwen", name: "Qwen / 通义千问", type: .text, parameters: ["format", "tone", "length"]),
        ModelProfile(id: "doubao", name: "豆包", type: .text, parameters: ["format", "tone", "length"]),
        ModelProfile(id: "kimi", name: "Kimi", type: .text, parameters: ["format", "tone", "length"]),
        ModelProfile(id: "grok", name: "Grok", type: .text, parameters: ["format", "tone", "length"]),
        ModelProfile(id: "glm", name: "GLM / 智谱", type: .text, parameters: ["format", "tone", "length"]),
        ModelProfile(id: "minimax_text", name: "MiniMax", type: .text, parameters: ["format", "tone", "length"]),
        ModelProfile(id: "elevenlabs", name: "ElevenLabs", type: .audio, parameters: ["voice", "mood", "duration"]),
        ModelProfile(id: "openai_audio", name: "OpenAI Audio", type: .audio, parameters: ["voice", "mood", "duration"]),
        ModelProfile(id: "minimax_audio", name: "MiniMax Audio", type: .audio, parameters: ["voice", "mood", "duration"]),
        ModelProfile(id: "suno", name: "Suno", type: .audio, parameters: ["mood", "genre", "duration"]),
        ModelProfile(id: "udio", name: "Udio", type: .audio, parameters: ["mood", "genre", "duration"]),
        ModelProfile(id: "google_lyria", name: "Google Lyria", type: .audio, parameters: ["mood", "genre", "duration"]),
        ModelProfile(id: "cartesia", name: "Cartesia", type: .audio, parameters: ["voice", "mood", "duration"]),
        ModelProfile(id: "fish_audio", name: "Fish Audio", type: .audio, parameters: ["voice", "mood", "duration"]),
        ModelProfile(id: "stable_audio", name: "Stable Audio", type: .audio, parameters: ["mood", "genre", "duration"]),
        ModelProfile(id: "riffusion", name: "Riffusion", type: .audio, parameters: ["mood", "genre", "duration"])
    ]

    static let tags: [Tag] = [
        Tag(name: "风景", count: 128),
        Tag(name: "人物", count: 96),
        Tag(name: "插画", count: 89),
        Tag(name: "写实", count: 73),
        Tag(name: "摄影设计", count: 65)
    ]

    static let folders: [LibraryFolder] = [
        LibraryFolder(id: rootFolderID, name: "项目", sortOrder: 0),
        LibraryFolder(id: "folder-summary", name: "项总", parentId: rootFolderID, sortOrder: 0),
        LibraryFolder(id: "folder-reference", name: "实拍高清图", parentId: "folder-summary", sortOrder: 0),
        LibraryFolder(id: defaultFolderID, name: "PromptStudio", parentId: "folder-reference", sortOrder: 0),
        LibraryFolder(id: "folder-ux-pro", name: "UX Pro Max Skill", parentId: rootFolderID, sortOrder: 1),
        LibraryFolder(id: "folder-g-stack", name: "G-Stack 实战方法", parentId: rootFolderID, sortOrder: 2),
        LibraryFolder(id: "folder-inshennx", name: "Inshennx/优化合集", parentId: rootFolderID, sortOrder: 3),
        LibraryFolder(id: "folder-lab", name: "灵感实验室", parentId: rootFolderID, sortOrder: 4),
        LibraryFolder(id: "folder-project-dev", name: "完整项目框架开发", parentId: rootFolderID, sortOrder: 5),
        LibraryFolder(id: "folder-aigc-follow", name: "讨论跟踪 AIGC 平台", parentId: rootFolderID, sortOrder: 6),
        LibraryFolder(id: "folder-video-lab", name: "视频创作实验室", parentId: rootFolderID, sortOrder: 7),
        LibraryFolder(id: uncategorizedFolderID, name: "未分类", sortOrder: 99)
    ]

    static func orderedModels(_ persisted: [ModelProfile]) -> [ModelProfile] {
        let persistedByID = Dictionary(uniqueKeysWithValues: persisted.map { ($0.id, $0) })
        let knownIDs = Set(models.map(\.id))
        let known = models.map { defaultModel in
            guard let persisted = persistedByID[defaultModel.id] else { return defaultModel }
            return shouldRefreshDefaultModel(persisted) ? defaultModel : persisted
        }
        let custom = persisted
            .filter { !knownIDs.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return known + custom
    }

    private static func shouldRefreshDefaultModel(_ model: ModelProfile) -> Bool {
        let legacyNamesByID: [String: Set<String>] = [
            "image_2": ["Image 2"],
            "nano_banana_2": ["Nano banana 2", "Nano Banana 2"],
            "seedream_7": ["Seedream 7.0"],
            "kling_3": ["可灵 3.0"]
        ]
        return legacyNamesByID[model.id]?.contains(model.name) == true
    }

    static func makePromptItems(resourceBundle: Bundle, libraryURL: URL) throws -> [PromptItem] {
        let imageNames = [
            "asset-face",
            "asset-samurai",
            "asset-fish",
            "asset-caravan",
            "asset-field",
            "asset-girl-deer",
            "asset-moon",
            "asset-leaves",
            "preview-samurai"
        ]

        let destination = libraryURL.appendingPathComponent("assets/images")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let copied = try imageNames.reduce(into: [String: URL]()) { result, name in
            guard let source = resourceBundle.url(forResource: name, withExtension: "png", subdirectory: "SeedImages")
                ?? resourceBundle.url(forResource: name, withExtension: "png") else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "SeedImages/\(name).png"])
            }
            let target = destination.appendingPathComponent(name + ".png")
            if !FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.copyItem(at: source, to: target)
            }
            result[name] = target
        }

        func url(_ name: String) -> String {
            copied[name]?.path ?? ""
        }

        func date(_ day: Int, hour: Int) -> Date {
            DateComponents(calendar: .current, year: 2024, month: 6, day: day, hour: hour, minute: 35).date ?? Date()
        }

        func item(
            title: String,
            type: PromptType = .image,
            modelId: String,
            modelName: String,
            asset: String,
            ratio: String,
            width: Int,
            height: Int,
            tags: [String],
            favorite: Bool = false,
            createdAt: Date,
            prompt: String,
            negative: String = "低分辨率, 模糊, 变形, 多余的手指, 文字, 水印",
            parameters: [String: String]
        ) -> PromptItem {
            let id = UUID().uuidString
            let version = PromptVersion(
                promptItemId: id,
                version: "V1.0",
                prompt: prompt,
                negativePrompt: negative,
                parameters: parameters,
                note: "初始版本",
                createdAt: createdAt
            )
            return PromptItem(
                id: id,
                title: title,
                type: type,
                modelId: modelId,
                modelName: modelName,
                folderId: modelId.contains("seedance") ? "folder-project-dev" : defaultFolderID,
                folderName: modelId.contains("seedance") ? "完整项目框架开发" : "PromptStudio",
                category: type == .video ? "视频 Prompt" : "图片 Prompt",
                assetPath: url(asset),
                aspectRatio: ratio,
                width: width,
                height: height,
                format: "PNG",
                fileSize: Int64((width * height) / 9),
                favorite: favorite,
                createdAt: createdAt,
                updatedAt: createdAt,
                lastUsedAt: Date(timeIntervalSince1970: 0),
                tags: tags,
                referenceAssets: [
                    ReferenceAsset(type: "风格参考", path: url("asset-samurai"), label: "Samurai mood"),
                    ReferenceAsset(type: "色彩参考", path: url("asset-fish"), label: "Warm palette")
                ],
                versions: [version],
                description: "本地演示数据，可用于验证浏览、筛选、编辑和复制 Prompt。"
            )
        }

        return [
            item(
                title: "人群构成的侧脸",
                modelId: "seedream_7",
                modelName: "Seedream 7.0",
                asset: "asset-face",
                ratio: "3:4",
                width: 1344,
                height: 2016,
                tags: ["人物", "写实"],
                createdAt: date(1, hour: 10),
                prompt: "A human profile made of thousands of tiny people, editorial poster composition, white background, detailed documentary realism.",
                parameters: ["比例": "3:4", "风格": "editorial", "质量": "high"]
            ),
            item(
                title: "这里是一个标题",
                modelId: "nano_banana_2",
                modelName: "Nano Banana 2",
                asset: "asset-samurai",
                ratio: "16:9",
                width: 1920,
                height: 1080,
                tags: ["风景", "人物", "写实"],
                favorite: true,
                createdAt: date(1, hour: 14),
                prompt: "A samurai, with purple grasses swaying gently around him in the style of James Gurney and John Bauer. The illustration scene is captured from an overhead perspective, creating a vast landscape that adds to its grandeur.",
                parameters: ["比例": "16:9", "风格": "cinematic", "种子": "3291", "版本": "v6"]
            ),
            item(
                title: "鱼的排列插画",
                modelId: "image_2",
                modelName: "Image 2",
                asset: "asset-fish",
                ratio: "4:5",
                width: 1024,
                height: 1280,
                tags: ["插画"],
                createdAt: date(2, hour: 9),
                prompt: "A minimal illustration of red and blue fish arranged in rows, flat poster texture, playful children's book style.",
                parameters: ["比例": "4:5", "风格": "flat illustration"]
            ),
            item(
                title: "森林露营车场景",
                modelId: "midjourney",
                modelName: "Midjourney",
                asset: "asset-caravan",
                ratio: "3:4",
                width: 1344,
                height: 2016,
                tags: ["风景", "插画"],
                favorite: true,
                createdAt: date(2, hour: 12),
                prompt: "A cozy green camper in a lush forest clearing, small animals, warm lights, highly detailed storybook illustration.",
                parameters: ["比例": "3:4", "风格": "storybook", "chaos": "12"]
            ),
            item(
                title: "草原上的合影",
                modelId: "seedream_7",
                modelName: "Seedream 7.0",
                asset: "asset-field",
                ratio: "3:4",
                width: 1344,
                height: 2016,
                tags: ["人物", "摄影设计"],
                createdAt: date(3, hour: 9),
                prompt: "A group portrait in open grassland, all subjects dressed in white, cinematic editorial photography, soft overcast daylight.",
                parameters: ["比例": "3:4", "镜头": "medium wide"]
            ),
            item(
                title: "女孩与小鹿",
                modelId: "nano_banana_2",
                modelName: "Nano Banana 2",
                asset: "asset-girl-deer",
                ratio: "4:5",
                width: 1024,
                height: 1280,
                tags: ["人物", "写实"],
                createdAt: date(3, hour: 16),
                prompt: "A gentle portrait of a young girl holding a small deer, soft bokeh garden background, nostalgic film colors.",
                parameters: ["比例": "4:5", "色彩": "soft pastel"]
            ),
            item(
                title: "月亮下的女孩",
                modelId: "seedream_7",
                modelName: "Seedream 7.0",
                asset: "asset-moon",
                ratio: "3:4",
                width: 1344,
                height: 2016,
                tags: ["插画", "人物"],
                createdAt: date(4, hour: 11),
                prompt: "A tarot inspired illustration of a girl under the moon, flowers, cats, surreal editorial composition.",
                parameters: ["比例": "3:4", "风格": "tarot"]
            ),
            item(
                title: "雨滴叶子特写",
                modelId: "image_2",
                modelName: "Image 2",
                asset: "asset-leaves",
                ratio: "1:1",
                width: 1024,
                height: 1024,
                tags: ["风景", "摄影设计"],
                createdAt: date(4, hour: 18),
                prompt: "Macro photography of colorful autumn leaves with water drops, crisp texture, natural light.",
                parameters: ["比例": "1:1", "镜头": "macro"]
            )
        ]
    }
}
