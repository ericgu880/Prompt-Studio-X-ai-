import Foundation
import PromptStudioCore

@discardableResult
func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws -> Bool {
    if try condition() {
        return true
    }
    throw CoreUnitTestError.failure(message)
}

enum CoreUnitTestError: Error, LocalizedError {
    case failure(String)

    var errorDescription: String? {
        switch self {
        case .failure(let message): message
        }
    }
}

func sampleItem(
    title: String,
    modelId: String = "nano_banana_2",
    assetKind: AssetKind = .image,
    tags: [String] = ["风景"],
    prompt: String,
    aspectRatio: String = "16:9",
    width: Int = 1920,
    height: Int = 1080,
    assetPath: String = "/tmp/mock.png",
    format: String = "PNG"
) -> PromptItem {
    let id = UUID().uuidString
    return PromptItem(
        id: id,
        title: title,
        type: assetKind.promptType,
        assetKind: assetKind,
        modelId: modelId,
        modelName: modelId,
        folderId: "folder-promptstudio",
        folderName: "PromptStudio",
        category: assetKind.displayName,
        assetPath: assetPath,
        aspectRatio: aspectRatio,
        width: width,
        height: height,
        format: format,
        fileSize: 1024,
        tags: tags,
        versions: [
            PromptVersion(promptItemId: id, version: "V1.0", prompt: prompt, parameters: ["比例": "16:9"])
        ]
    )
}

func temporaryLibraryURL() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("PromptStudioCoreUnitTests")
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func testLibraryURLResolution() throws {
    let defaultURL = PromptRepository.defaultLibraryURL()
    let spacedPath = "/tmp/promptstudio qa library"
    let equalsPath = "/tmp/promptstudio-equals-library"
    let envPath = "/tmp/promptstudio-env-library"
    let argPath = "/tmp/promptstudio-arg-wins"

    try expect(
        PromptRepository.resolvedLibraryURL(arguments: ["--library", spacedPath], environment: [:]).path == spacedPath,
        "--library PATH should resolve the following token as the library URL"
    )
    try expect(
        PromptRepository.resolvedLibraryURL(arguments: ["--library=\(equalsPath)"], environment: [:]).path == equalsPath,
        "--library=PATH should resolve the inline value as the library URL"
    )
    try expect(
        PromptRepository.resolvedLibraryURL(arguments: [], environment: ["PROMPTSTUDIO_LIBRARY_PATH": envPath]).path == envPath,
        "PROMPTSTUDIO_LIBRARY_PATH should resolve when no --library argument is present"
    )
    try expect(
        PromptRepository.resolvedLibraryURL(arguments: ["--library", argPath], environment: ["PROMPTSTUDIO_LIBRARY_PATH": envPath]).path == argPath,
        "--library should take priority over PROMPTSTUDIO_LIBRARY_PATH"
    )
    try expect(
        PromptRepository.resolvedLibraryURL(arguments: [], environment: [:]) == defaultURL,
        "missing overrides should fall back to the default library URL"
    )
}

func testExistingLibraryValidationDoesNotCreateDatabase() throws {
    let emptyDirectory = try temporaryLibraryURL()
    do {
        try PromptRepository.validateExistingLibrary(at: emptyDirectory)
        throw CoreUnitTestError.failure("existing library validation should reject an empty directory")
    } catch PromptRepositoryValidationError.missingDatabase {
        let databaseURL = emptyDirectory.appendingPathComponent("database/promptstudio.sqlite")
        try expect(
            !FileManager.default.fileExists(atPath: databaseURL.path),
            "existing library validation must not create database files"
        )
    }
}

@discardableResult
func measurePerformance(_ label: String, threshold: TimeInterval, operation: () throws -> Void) throws -> TimeInterval {
    let start = Date()
    try operation()
    let duration = Date().timeIntervalSince(start)
    try expect(duration < threshold, "\(label) should finish under \(threshold)s, got \(String(format: "%.3f", duration))s")
    return duration
}

func performanceItem(index: Int) -> PromptItem {
    let targetMarker = index == 760 ? " needle-forest-target" : ""
    var item = sampleItem(
        title: index == 760 ? "Forest Product Shot" : "Prompt \(index)",
        modelId: "model-\(index % 8)",
        assetKind: index.isMultiple(of: 3) ? .markdown : .image,
        tags: ["tag-\(index % 10)", index.isMultiple(of: 2) ? "even" : "odd"],
        prompt: "Prompt body \(index) for campaign\(targetMarker)",
        assetPath: "/tmp/promptstudio-performance-\(index).md",
        format: index.isMultiple(of: 3) ? "MD" : "PNG"
    )
    item.folderId = "folder-\(index % 20)"
    item.folderName = "Folder \(index % 20)"
    item.favorite = index.isMultiple(of: 5)
    item.lastUsedAt = Date(timeIntervalSince1970: TimeInterval(index))
    item.sortOrder = index
    item.description = "metadata bucket \(index % 13)"
    if index.isMultiple(of: 17) {
        item.deletedAt = Date()
    }
    if index.isMultiple(of: 11) {
        item.referenceAssets = [
            ReferenceAsset(type: "image", path: "/tmp/reference-\(index).png", label: "reference \(index)")
        ]
    }
    item.versions.append(
        PromptVersion(
            promptItemId: item.id,
            version: "V1.1",
            prompt: "Prompt body \(index) updated\(targetMarker)",
            negativePrompt: "watermark",
            parameters: ["ar": "16:9", "seed": "\(index)"],
            note: "performance fixture"
        )
    )
    return item
}

func makeDocxFixture(text: String) throws -> URL {
    let directory = try temporaryLibraryURL()
    let textURL = directory.appendingPathComponent("fixture.txt")
    let docxURL = directory.appendingPathComponent("fixture.docx")
    try text.write(to: textURL, atomically: true, encoding: .utf8)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
    process.arguments = ["-convert", "docx", "-output", docxURL.path, textURL.path]
    let errorPipe = Pipe()
    process.standardError = errorPipe
    try process.run()
    process.waitUntilExit()
    let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    try expect(process.terminationStatus == 0, "textutil should create docx fixture: \(stderr)")
    return docxURL
}

func testSearchFiltering() throws {
    let item = sampleItem(title: "森林露营车", modelId: "midjourney", tags: ["风景", "插画"], prompt: "green camper in a lush forest")
    let other = sampleItem(title: "人物肖像", modelId: "seedream_7", tags: ["人物"], prompt: "editorial portrait")

    try expect(PromptFiltering.apply([item, other], filter: PromptFilter(query: "camper")).map(\.id) == [item.id], "query should match prompt body")
    try expect(PromptFiltering.apply([item, other], filter: PromptFilter(modelId: "seedream_7")).map(\.id) == [other.id], "model filter should isolate Seedream item")
    try expect(PromptFiltering.apply([item, other], filter: PromptFilter(collection: .tag("插画"))).map(\.id) == [item.id], "tag collection should isolate illustration item")
}

func testFilteringPerformanceWith1000Items() throws {
    let items = (0..<1_000).map(performanceItem(index:))
    let target = try expect(items.first { $0.title == "Forest Product Shot" } != nil, "performance fixture should include target")

    var queryResults: [PromptItem] = []
    var tagResults: [PromptItem] = []
    var folderResults: [PromptItem] = []
    var modelResults: [PromptItem] = []
    var favoriteResults: [PromptItem] = []
    var combinedResults: [PromptItem] = []

    try measurePerformance("1000-item filtering smoke", threshold: 0.5) {
        queryResults = PromptFiltering.apply(items, filter: PromptFilter(query: "needle-forest-target"))
        tagResults = PromptFiltering.apply(items, filter: PromptFilter(collection: .tag("tag-7")))
        folderResults = PromptFiltering.apply(items, filter: PromptFilter(collection: .folder("folder-0")))
        modelResults = PromptFiltering.apply(items, filter: PromptFilter(modelId: "model-3"))
        favoriteResults = PromptFiltering.apply(items, filter: PromptFilter(favoriteOnly: true))
        combinedResults = PromptFiltering.apply(
            items,
            filter: PromptFilter(
                query: "needle-forest-target",
                modelId: "model-0",
                collection: .folder("folder-0"),
                requiredTag: "tag-0",
                favoriteOnly: true,
                hasPromptOnly: true
            )
        )
    }

    _ = target
    try expect(queryResults.map(\.title) == ["Forest Product Shot"], "query should find the unique target prompt")
    try expect(tagResults.allSatisfy { $0.tags.contains("tag-7") && !$0.isDeleted }, "tag filter should return live tag matches")
    try expect(folderResults.allSatisfy { $0.folderId == "folder-0" && !$0.isDeleted }, "folder filter should return live folder matches")
    try expect(modelResults.allSatisfy { $0.modelId == "model-3" && !$0.isDeleted }, "model filter should return live model matches")
    try expect(favoriteResults.allSatisfy { $0.favorite && !$0.isDeleted }, "favorite filter should return live favorites")
    try expect(combinedResults.map(\.title) == ["Forest Product Shot"], "combined filters should keep the target prompt")
}

func testTextFormatFiltering() throws {
    let markdown = sampleItem(title: "Markdown", assetKind: .markdown, prompt: "# doc", assetPath: "/tmp/mock.md", format: "MD")
    let json = sampleItem(title: "Json", assetKind: .json, prompt: "{}", assetPath: "/tmp/mock.json", format: "JSON")
    let text = sampleItem(title: "Text", assetKind: .text, prompt: "notes", assetPath: "/tmp/mock.txt", format: "TXT")
    let word = sampleItem(title: "Word", assetKind: .document, prompt: "doc", assetPath: "/tmp/mock.docx", format: "DOCX")
    let staleWord = sampleItem(title: "Old Word", assetKind: .unknown, prompt: "doc", assetPath: "/tmp/old.docx", format: "FILE")
    let pdf = sampleItem(title: "PDF", assetKind: .document, prompt: "pdf", assetPath: "/tmp/mock.pdf", format: "PDF")

    try expect(PromptFiltering.apply([markdown, json, text, word], filter: PromptFilter(type: .text, textFormat: .markdown)).map(\.id) == [markdown.id], "MD filter should isolate markdown assets")
    try expect(PromptFiltering.apply([markdown, json, text, word], filter: PromptFilter(type: .text, textFormat: .json)).map(\.id) == [json.id], "Json filter should isolate JSON assets")
    try expect(PromptFiltering.apply([markdown, json, text, word], filter: PromptFilter(type: .text, textFormat: .text)).map(\.id) == [text.id], "txt filter should isolate text assets")
    let wordMatches = Set(PromptFiltering.apply([markdown, json, text, word, staleWord], filter: PromptFilter(type: .text, textFormat: .word)).map(\.id))
    try expect(wordMatches == Set([word.id, staleWord.id]), "Word filter should isolate doc/docx assets")
    try expect(word.isTextDocumentLike, "Word documents should use text document presentation")
    try expect(staleWord.isTextDocumentLike, "Old docx items should use text document presentation by file extension")
    try expect(!pdf.isTextDocumentLike, "PDF documents should stay generic document assets")
}

func testPrimaryPromptAssetsAndAttachments() throws {
    let image = sampleItem(title: "Image", assetKind: .image, prompt: "image", assetPath: "/tmp/mock.png", format: "PNG")
    let video = sampleItem(title: "Video", assetKind: .video, prompt: "video", assetPath: "/tmp/mock.mp4", format: "MP4")
    let audio = sampleItem(title: "Audio", assetKind: .audio, prompt: "audio", assetPath: "/tmp/mock.mp3", format: "MP3")
    let markdown = sampleItem(title: "Markdown", assetKind: .markdown, prompt: "# doc", assetPath: "/tmp/mock.md", format: "MD")
    let word = sampleItem(title: "Word", assetKind: .document, prompt: "doc", assetPath: "/tmp/mock.docx", format: "DOCX")
    let source = sampleItem(title: "PSD", assetKind: .source, prompt: "", assetPath: "/tmp/mock.psd", format: "PSD")
    let web = sampleItem(title: "HTML", assetKind: .web, prompt: "", assetPath: "/tmp/mock.html", format: "HTML")
    let pdf = sampleItem(title: "PDF", assetKind: .document, prompt: "", assetPath: "/tmp/mock.pdf", format: "PDF")
    let raw = sampleItem(title: "RAW", assetKind: .raw, prompt: "", assetPath: "/tmp/mock.dng", format: "DNG")
    let font = sampleItem(title: "Font", assetKind: .font, prompt: "", assetPath: "/tmp/mock.otf", format: "OTF")
    let unknown = sampleItem(title: "Unknown", assetKind: .unknown, prompt: "", assetPath: "/tmp/mock.custom", format: "CUSTOM")

    try expect([image, video, audio, markdown, word].allSatisfy(\.isPromptPrimaryAsset), "image, video, audio, and text documents should be primary prompt assets")
    try expect([source, web, pdf, raw, font, unknown].allSatisfy(\.isAttachmentAsset), "non-primary formats should be attachments")

    let items = [image, video, audio, markdown, word, source, web, pdf, raw, font, unknown]
    let audioMatches = PromptFiltering.apply(items, filter: PromptFilter(assetKindFilter: .audio)).map(\.id)
    try expect(audioMatches == [audio.id], "audio filter should isolate audio prompt assets")
    let audioTypeMatches = PromptFiltering.apply(items, filter: PromptFilter(type: .audio)).map(\.id)
    try expect(audioTypeMatches == [audio.id], "audio prompt type should isolate imported audio assets")
    let documentMatches = Set(PromptFiltering.apply(items, filter: PromptFilter(assetKindFilter: .promptDocument)).map(\.id))
    try expect(documentMatches == Set([markdown.id, word.id]), "text filter should isolate text prompt documents")
    let attachmentMatches = Set(PromptFiltering.apply(items, filter: PromptFilter(assetKindFilter: .other)).map(\.id))
    try expect(attachmentMatches == Set([source.id, web.id, pdf.id, raw.id, font.id, unknown.id]), "attachment filter should include non-primary formats")
}

func testTextSyntaxModeInference() throws {
    let staleJson = sampleItem(title: "Old JSON", assetKind: .unknown, prompt: "{}", assetPath: "/tmp/handoff.json", format: "FILE")
    try expect(staleJson.isTextDocumentLike, "Old JSON items should use text document presentation by file extension")
    try expect(TextSyntaxMode.infer(for: staleJson) == .json, "JSON path should infer JSON syntax even when assetKind is stale")

    let expectations: [(String, TextSyntaxMode)] = [
        ("/tmp/mock.md", .markdown),
        ("/tmp/mock.yaml", .yamlToml),
        ("/tmp/mock.toml", .yamlToml),
        ("/tmp/mock.xml", .xml),
        ("/tmp/mock.log", .log),
        ("/tmp/mock.txt", .plain),
        ("/tmp/mock.swift", .source)
    ]
    for (path, mode) in expectations {
        try expect(TextSyntaxMode.infer(assetPath: path, format: "", assetKind: .unknown) == mode, "\(path) should infer \(mode.rawValue) syntax")
    }
}

func testTextSyntaxRulesDetectJSONTokens() throws {
    let json = #"{"name":"Ada","count":3,"enabled":true,"missing":null}"#
    let tokens = TextSyntaxRules.tokenKinds(in: json, mode: .json)
    try expect(tokens.contains(.jsonKey), "JSON highlighter should detect object keys")
    try expect(tokens.contains(.number), "JSON highlighter should detect numbers")
    try expect(tokens.contains(.literal), "JSON highlighter should detect booleans and null")
    try expect(tokens.contains(.punctuation), "JSON highlighter should detect punctuation")
    try expect(!tokens.contains(.string), "JSON highlighter should keep string values as base text to avoid large color blocks")
}

func testMarkdownHeadingRulesDetectCommonTitleShapes() throws {
    let headingSamples = [
        "# 标题",
        "## 标题",
        "Setext 标题\n---",
        "【基础设定】",
        "《角色设定》",
        "「镜头规则」",
        "一、测试目标",
        "1. 测试目标",
        "01. 开场成品",
        "Step 1: 准备",
        "测试目标：",
        "角色设定:",
        "质量检查",
        "成品主参照帧说明"
    ]

    for sample in headingSamples {
        let tokens = TextSyntaxRules.tokenKinds(in: sample, mode: .markdown)
        try expect(tokens.contains(.heading), "\(sample) should be highlighted as a markdown heading")
    }
}

func testMarkdownHeadingRulesAvoidBodyLikeLines() throws {
    let bodySamples = [
        "- 质量检查",
        "* 质量检查",
        "+ 质量检查",
        "> 质量检查",
        "| 项目 | 内容 |",
        "我希望画面不要出现水印。"
    ]

    for sample in bodySamples {
        let tokens = TextSyntaxRules.tokenKinds(in: sample, mode: .markdown)
        try expect(!tokens.contains(.heading), "\(sample) should not be highlighted as a markdown heading")
    }
}

func testLargeMarkdownKeepsHeadingHighlightRules() throws {
    let largeMarkdown = "【基础设定】\n" + String(repeating: "正文内容\n", count: TextSyntaxRules.largeTextLineLimit + 5)
    let tokens = TextSyntaxRules.tokenKinds(in: largeMarkdown, mode: .markdown)
    try expect(tokens.contains(.heading), "large markdown should still highlight headings")
}

func testMarkdownNegativeHighlightRequiresTitle() throws {
    let titleTokens = TextSyntaxRules.tokenKinds(in: "## 负面提示\n不要出现水印", mode: .markdown)
    try expect(titleTokens.contains(.negativeConstraint), "negative heading should be highlighted")
    try expect(titleTokens.contains(.heading), "negative markdown title can still match heading before red override")

    let suffixedTitleTokens = TextSyntaxRules.tokenKinds(in: "## 负面约束规则\n无字幕、无水印", mode: .markdown)
    try expect(suffixedTitleTokens.contains(.negativeConstraint), "negative heading with title suffix should be highlighted")

    let bodyTokens = TextSyntaxRules.tokenKinds(in: "画面不要出现水印，保持干净。", mode: .markdown)
    try expect(!bodyTokens.contains(.negativeConstraint), "body text containing 不要 should not be highlighted as negative")

    let bodyLabelTokens = TextSyntaxRules.tokenKinds(in: "这里是负面提示内容，不要大面积标红。", mode: .markdown)
    try expect(!bodyLabelTokens.contains(.negativeConstraint), "body text mentioning negative prompt should not be highlighted as a heading")

    let reverseTitleTokens = TextSyntaxRules.tokenKinds(in: "反向约束：", mode: .markdown)
    try expect(reverseTitleTokens.contains(.negativeConstraint), "reverse constraint title should be highlighted")
}

func testFolderFilteringUsesStableFolderID() throws {
    var first = sampleItem(title: "同名文件夹 A", prompt: "first")
    var second = sampleItem(title: "同名文件夹 B", prompt: "second")
    first.folderId = "folder-a"
    first.folderName = "同名文件夹"
    second.folderId = "folder-b"
    second.folderName = "同名文件夹"

    let filtered = PromptFiltering.apply([first, second], filter: PromptFilter(collection: .folder("folder-b")))
    try expect(filtered.map(\.id) == [second.id], "folder filtering should use folderId rather than folderName")
}

func testSQLiteRoundTrip() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let item = sampleItem(title: "版本测试", assetKind: .markdown, prompt: "initial prompt", width: 0, height: 0, assetPath: "/tmp/mock.md")

    try repository.saveItem(item)
    var loaded = try repository.loadItems()
    try expect(loaded.count == 1, "repository should load one saved item")
    try expect(loaded[0].versions.first?.prompt == "initial prompt", "initial version should persist")
    try expect(loaded[0].assetKind == .markdown, "assetKind should persist")
    try expect(loaded[0].folderId == "folder-promptstudio", "folderId should persist")

    loaded[0].versions.append(PromptVersion(promptItemId: loaded[0].id, version: "V1.1", prompt: "updated prompt", note: "edit"))
    try repository.saveItem(loaded[0])

    let reloaded = try repository.loadItems()
    try expect(reloaded[0].versions.count == 2, "new version should persist")
    try expect(reloaded[0].currentVersion?.prompt == "updated prompt", "current version should be latest")
}

func testRepositoryBulkSaveLoadPerformanceWith1000Items() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let items = (0..<1_000).map(performanceItem(index:))
    var loaded: [PromptItem] = []

    try measurePerformance("1000-item repository bulk save and load smoke", threshold: 5.0) {
        try repository.saveItems(items)
        loaded = try repository.loadItems()
    }

    try expect(loaded.count == 1_000, "repository should load every saved performance item")
    let target = try expect(loaded.first { $0.title == "Forest Product Shot" } != nil, "loaded repository should include target")
    _ = target
    let sample = try expect(loaded.first { $0.modelId == "model-3" && $0.tags.contains("tag-3") } != nil, "loaded repository should include sample metadata")
    _ = sample
    try expect(loaded.first { $0.title == "Forest Product Shot" }?.currentVersion?.prompt.contains("needle-forest-target") == true, "loaded target should keep prompt versions")
}

func testAssetKindInferenceAndPromptParsing() throws {
    try expect(AssetKind.infer(fileExtension: "mp3") == .audio, "mp3 should import as audio")
    try expect(AssetKind.infer(fileExtension: "mp3").promptType == .audio, "mp3 should import as audio prompt type")
    try expect(AssetKind.infer(fileExtension: "pdf") == .document, "pdf should import as document")
    let parsed = PromptImportParser.parse(
        text: "Prompt: forest portrait --no watermark --ar 3:4\nTags: 风景, 人物\n#写实",
        assetKind: .text
    )
    try expect(parsed.prompt == "forest portrait", "parser should remove Midjourney parameters from prompt")
    try expect(parsed.negativePrompt == "watermark", "parser should read --no as negative prompt")
    try expect(parsed.parameters["ar"] == "3:4", "parser should extract ar parameter")
    try expect(parsed.tags.contains("风景") && parsed.tags.contains("人物") && parsed.tags.contains("写实"), "parser should extract tags")
}

func testAssetFormatCatalogCoversEagleMacOSFormats() throws {
    for ext in AssetFormatCatalog.eagleMacOSExtensions {
        let support = AssetFormatCatalog.support(forFileExtension: ext)
        try expect(support.assetKind != .unknown, "Eagle macOS extension \(ext) should have asset kind support")
        try expect(support.previewMode != .generic, "Eagle macOS extension \(ext) should have a specific preview mode")
    }
}

func testAssetFormatCatalogRepresentativeMappings() throws {
    let expectations: [(String, AssetKind, AssetSupportTier, AssetPreviewMode)] = [
        ("png", .image, .p0Native, .image),
        ("mov", .video, .p0Native, .video),
        ("mp3", .audio, .p1System, .audio),
        ("md", .markdown, .p0Native, .textDocument),
        ("json", .json, .p0Native, .textDocument),
        ("yaml", .data, .p0Native, .textDocument),
        ("docx", .document, .p0Native, .textDocument),
        ("pdf", .document, .p0Native, .document),
        ("key", .document, .p1System, .document),
        ("html", .web, .p1System, .document),
        ("psd", .source, .p2Reference, .reference),
        ("raw", .raw, .p2Reference, .reference),
        ("glb", .threeD, .p2Reference, .reference),
        ("dds", .texture, .p2Reference, .reference),
        ("ttf", .font, .p2Reference, .reference)
    ]

    for (ext, kind, tier, previewMode) in expectations {
        let support = AssetFormatCatalog.support(forFileExtension: ext)
        try expect(support.assetKind == kind, "\(ext) should map to \(kind.rawValue)")
        try expect(support.supportTier == tier, "\(ext) should map to \(tier.rawValue)")
        try expect(support.previewMode == previewMode, "\(ext) should map to \(previewMode.rawValue)")
    }

    let unknown = AssetFormatCatalog.support(forFileExtension: "madeup")
    try expect(unknown.assetKind == .unknown, "unknown extension should keep unknown kind")
    try expect(unknown.previewMode == .generic, "unknown extension should use generic preview")
}

func testPromptDocumentFormatsExtractMetadata() throws {
    for ext in AssetFormatCatalog.promptDocumentExtensions {
        let support = AssetFormatCatalog.support(forFileExtension: ext)
        try expect(support.canExtractPrompt, "\(ext) should be marked for prompt extraction")
        let parsed = PromptImportParser.parse(
            text: "Prompt: product photo --no watermark --ar 1:1\nTags: 产品, 写实",
            assetKind: support.assetKind
        )
        try expect(parsed.prompt == "product photo", "\(ext) should parse prompt")
        try expect(parsed.negativePrompt == "watermark", "\(ext) should parse negative prompt")
        try expect(parsed.parameters["ar"] == "1:1", "\(ext) should parse parameters")
        try expect(parsed.tags.contains("产品") && parsed.tags.contains("写实"), "\(ext) should parse tags")
    }
}

func testAutomationServiceImportsAllKnownFormatFixtures() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let service = PromptStudioAutomationService(repository: repository)
    let fixtureRoot = try temporaryLibraryURL().appendingPathComponent("fixtures")
    try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)

    var paths: [String] = []
    for ext in AssetFormatCatalog.allKnownExtensions {
        let url = fixtureRoot.appendingPathComponent(UUID().uuidString + ".\(ext)")
        let support = AssetFormatCatalog.support(forFileExtension: ext)
        let text = support.canExtractPrompt
            ? "Prompt: fixture prompt --no bad\nTags: 测试\n"
            : "fixture"
        try Data(text.utf8).write(to: url)
        paths.append(url.path)
    }

    let imported = try service.importFiles(paths: paths)
    try expect(imported.count == paths.count, "all known fixture extensions should import")
    for item in imported {
        let support = AssetFormatCatalog.support(forFileExtension: (item.assetPath as NSString).pathExtension)
        try expect(item.assetKind == support.assetKind, "\(item.format) should persist catalog asset kind")
        if support.canExtractPrompt {
            try expect(item.currentVersion?.prompt == "fixture prompt", "\(item.format) should parse fixture prompt")
        }
    }

    let source = imported.first { $0.assetKind == .source }
    let raw = imported.first { $0.assetKind == .raw }
    let threeD = imported.first { $0.assetKind == .threeD }
    let texture = imported.first { $0.assetKind == .texture }
    let font = imported.first { $0.assetKind == .font }
    let web = imported.first { $0.assetKind == .web }
    try expect(source?.assetPath.contains("/assets/sources/") == true, "source files should archive under assets/sources")
    try expect(raw?.assetPath.contains("/assets/raw/") == true, "RAW files should archive under assets/raw")
    try expect(threeD?.assetPath.contains("/assets/three_d/") == true, "3D files should archive under assets/three_d")
    try expect(texture?.assetPath.contains("/assets/textures/") == true, "texture files should archive under assets/textures")
    try expect(font?.assetPath.contains("/assets/fonts/") == true, "font files should archive under assets/fonts")
    try expect(web?.assetPath.contains("/assets/web/") == true, "web files should archive under assets/web")
}

func testUnknownFormatImportsAsGenericFile() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let service = PromptStudioAutomationService(repository: repository)
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".madeup")
    try Data("fixture".utf8).write(to: file)

    let imported = try service.importFiles(paths: [file.path])
    try expect(imported.count == 1, "unknown extension should still import")
    try expect(imported[0].assetKind == .unknown, "unknown extension should keep unknown asset kind")
    try expect(imported[0].previewMode == .generic, "unknown extension should use generic preview mode")
}

func testTagRefreshDeletesUnusedTags() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    var item = sampleItem(title: "标签同步", tags: ["旧标签"], prompt: "tag")
    try repository.saveItem(item)
    try expect(try repository.loadTags().map(\.name) == ["旧标签"], "initial tag should persist")
    item.tags = ["新标签"]
    try repository.saveItem(item)
    try expect(try repository.loadTags().map(\.name) == ["新标签"], "unused tag should be removed")
}

func testTrashAndRestore() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let item = sampleItem(title: "待删除", prompt: "delete me")
    try repository.saveItem(item)

    try repository.markDeleted(itemID: item.id, deletedAt: Date())
    try expect(try repository.loadItems()[0].isDeleted, "deleted item should enter trash")

    try repository.markDeleted(itemID: item.id, deletedAt: nil)
    try expect(try repository.loadItems()[0].isDeleted == false, "restored item should leave trash")
}

func testAspectRatioDisplayNormalizesImportedSizes() throws {
    let item = sampleItem(title: "方图", prompt: "square", aspectRatio: "2048:2048", width: 2048, height: 2048)
    try expect(item.displayAspectRatio == "1:1", "square imported dimensions should display as 1:1")
}

func testSeedAssetRepairKeepsExistingUserData() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let seedAsset = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
    try Data([1, 2, 3]).write(to: seedAsset)

    let broken = sampleItem(title: "内置示例", modelId: "seedream_7", prompt: "broken", assetPath: "/missing/asset.png")
    let seed = sampleItem(title: "内置示例", modelId: "seedream_7", prompt: "seed", width: 1024, height: 1024, assetPath: seedAsset.path)
    let userItem = sampleItem(title: "用户导入", modelId: "seedream_7", prompt: "user", assetPath: "/missing/user.png")

    try repository.saveItem(broken)
    try repository.saveItem(userItem)
    try repository.repairSeedAssetPaths(from: [seed])

    let loaded = try repository.loadItems()
    try expect(loaded.first { $0.id == broken.id }?.assetPath == seedAsset.path, "seed item should be repaired")
    try expect(loaded.first { $0.id == userItem.id }?.assetPath == "/missing/user.png", "non-seed user item should not be rewritten")
}

func testThumbnailPathUpdatePersistsWithoutChangingOriginalAsset() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let item = sampleItem(title: "缩略图测试", prompt: "thumbnail", assetPath: "/tmp/original.png")
    let thumbnailPath = repository.libraryURL.appendingPathComponent("thumbnails").appendingPathComponent(item.id + ".jpg").path

    try repository.saveItem(item)
    try repository.updateThumbnailPath(itemID: item.id, thumbnailPath: thumbnailPath)

    let loaded = try repository.loadItems()[0]
    try expect(loaded.assetPath == "/tmp/original.png", "thumbnail update should not alter original asset path")
    try expect(loaded.thumbnailPath == thumbnailPath, "thumbnail path should persist")
}

func testLastUsedUpdatePersistsForRecentSorting() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let older = sampleItem(title: "较早", prompt: "older")
    let newer = sampleItem(title: "较新", prompt: "newer")
    try repository.saveItem(older)
    try repository.saveItem(newer)

    let date = Date().addingTimeInterval(3_600)
    try repository.updateLastUsed(itemID: older.id, at: date)

    let recent = PromptFiltering.apply(try repository.loadItems(), filter: PromptFilter(collection: .recent))
    try expect(recent.first?.id == older.id, "updated lastUsedAt should drive recent sorting")
}

func testPinnedAtDoesNotAffectNormalCollectionSorting() throws {
    var first = sampleItem(title: "普通靠前", assetKind: .markdown, tags: ["置顶测试"], prompt: "first")
    var pinned = sampleItem(title: "置顶靠后", assetKind: .markdown, tags: ["置顶测试"], prompt: "pinned")
    first.sortOrder = 0
    pinned.sortOrder = 20
    pinned.pinnedAt = Date()

    let all = PromptFiltering.apply([first, pinned], filter: PromptFilter())
    try expect(all.map(\.id) == [first.id, pinned.id], "pinnedAt should not affect all item sorting while pinning is disabled")

    let text = PromptFiltering.apply([first, pinned], filter: PromptFilter(assetKindFilter: .promptDocument))
    try expect(text.map(\.id) == [first.id, pinned.id], "pinnedAt should not affect text filter sorting while pinning is disabled")

    let tag = PromptFiltering.apply([first, pinned], filter: PromptFilter(collection: .tag("置顶测试")))
    try expect(tag.map(\.id) == [first.id, pinned.id], "pinnedAt should not affect tag sorting while pinning is disabled")
}

func testPinnedAtDoesNotAffectRecentOrTrashSorting() throws {
    var pinnedOlder = sampleItem(title: "置顶较早", prompt: "pinned")
    var normalNewer = sampleItem(title: "普通较新", prompt: "newer")
    pinnedOlder.pinnedAt = Date()
    pinnedOlder.lastUsedAt = Date(timeIntervalSince1970: 100)
    normalNewer.lastUsedAt = Date(timeIntervalSince1970: 200)

    let recent = PromptFiltering.apply([normalNewer, pinnedOlder], filter: PromptFilter(collection: .recent))
    try expect(recent.map(\.id) == [normalNewer.id, pinnedOlder.id], "pinnedAt should not override recent sorting while pinning is disabled")

    pinnedOlder.deletedAt = Date()
    normalNewer.deletedAt = Date()
    pinnedOlder.sortOrder = 20
    normalNewer.sortOrder = 0
    let trash = PromptFiltering.apply([pinnedOlder, normalNewer], filter: PromptFilter(collection: .trash))
    try expect(trash.map(\.id) == [normalNewer.id, pinnedOlder.id], "trash sorting should ignore pinned state")
}

func testPinnedAtPersistsAndMigratesFromOldSchema() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    var item = sampleItem(title: "置顶持久化", prompt: "pin")
    let pinnedAt = Date(timeIntervalSince1970: 1_700_000_000)
    item.pinnedAt = pinnedAt
    try repository.saveItem(item)
    try expect(try repository.loadItems()[0].pinnedAt != nil, "pinnedAt should persist through repository save/load")

    let oldLibraryURL = try temporaryLibraryURL()
    try PromptRepository.createLibraryDirectories(at: oldLibraryURL)
    let databaseURL = oldLibraryURL.appendingPathComponent("database/promptstudio.sqlite")
    let database = try SQLiteDatabase(path: databaseURL.path)
    try database.execute(
        """
        CREATE TABLE prompt_items (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            type TEXT NOT NULL,
            assetKind TEXT NOT NULL DEFAULT 'image',
            modelId TEXT NOT NULL,
            modelName TEXT NOT NULL,
            folderId TEXT NOT NULL DEFAULT '',
            folderName TEXT NOT NULL,
            category TEXT NOT NULL,
            assetPath TEXT NOT NULL,
            thumbnailPath TEXT NOT NULL,
            aspectRatio TEXT NOT NULL,
            width INTEGER NOT NULL,
            height INTEGER NOT NULL,
            format TEXT NOT NULL,
            fileSize INTEGER NOT NULL,
            favorite INTEGER NOT NULL,
            deletedAt TEXT,
            createdAt TEXT NOT NULL,
            updatedAt TEXT NOT NULL,
            lastUsedAt TEXT NOT NULL,
            sortOrder INTEGER NOT NULL DEFAULT 0,
            tagsJSON TEXT NOT NULL,
            referencesJSON TEXT NOT NULL,
            description TEXT NOT NULL
        );
        CREATE TABLE prompt_versions (
            id TEXT PRIMARY KEY,
            promptItemId TEXT NOT NULL,
            version TEXT NOT NULL,
            prompt TEXT NOT NULL,
            negativePrompt TEXT NOT NULL,
            parametersJSON TEXT NOT NULL,
            note TEXT NOT NULL,
            createdAt TEXT NOT NULL
        );
        """
    )

    let migratedRepository = try PromptRepository(libraryURL: oldLibraryURL)
    let columns = try SQLiteDatabase(path: databaseURL.path).query("PRAGMA table_info(prompt_items);")
    let columnNames = Set(columns.compactMap { $0["name"] ?? nil })
    try expect(columnNames.contains("pinnedAt"), "migration should add pinnedAt column to old prompt_items table")
    try expect(try migratedRepository.loadItems().isEmpty, "old empty database should still load after pinnedAt migration")
}

func testFolderSeedIsIdempotent() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let folders = [
        LibraryFolder(id: "image-a", name: "图片 A", type: .image, sortOrder: 0),
        LibraryFolder(id: "video-a", name: "视频 A", type: .video, sortOrder: 0)
    ]

    try repository.seedFoldersIfNeeded(folders)
    try repository.seedFoldersIfNeeded(folders)

    let loaded = try repository.loadFolders()
    try expect(loaded.count == 2, "folder seed should not duplicate rows")
    try expect(loaded.map(\.name).contains("图片 A"), "seeded image folder should load")
    try expect(loaded.map(\.name).contains("视频 A"), "seeded video folder should load")
}

func testFolderCRUDRoundTrip() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let parent = LibraryFolder(id: "folder-parent", name: "父文件夹", sortOrder: 1)
    let folder = LibraryFolder(id: "folder-1", name: "旧文件夹", parentId: parent.id, type: .image, sortOrder: 3)

    try repository.saveFolder(parent)
    try repository.saveFolder(folder)
    try expect(try repository.loadFolders().contains { $0.parentId == parent.id && $0.name == "旧文件夹" }, "saved child folder should load with parent")

    try repository.renameFolder(id: folder.id, name: "新文件夹")
    try expect(try repository.loadFolders().first { $0.id == folder.id }?.name == "新文件夹", "renamed folder should persist")

    try repository.deleteFolder(id: folder.id)
    try expect(try repository.loadFolders().contains { $0.id == folder.id } == false, "deleted folder should be removed")
}

func testAutomationServiceCreatesAndUpdatesPrompts() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let service = PromptStudioAutomationService(repository: repository)
    let folder = try service.createFolder(name: "Agent Folder")
    let created = try service.createPrompt(
        AutomationCreatePromptInput(
            title: "Agent Prompt",
            prompt: "cinematic product photo",
            negativePrompt: "watermark",
            tags: ["产品", "写实"],
            model: "Image 2",
            folderID: folder.id
        )
    )

    try expect(created.folderId == folder.id, "agent-created prompt should attach to folder")
    try expect(created.currentVersion?.prompt == "cinematic product photo", "agent-created prompt should persist prompt")

    let updated = try service.updatePrompt(id: created.id, input: AutomationUpdatePromptInput(prompt: "updated prompt", tags: ["更新"]))
    try expect(updated.versions.count == 2, "agent prompt update should append a version")
    try expect(updated.currentVersion?.prompt == "updated prompt", "agent prompt update should become current version")
    try expect(updated.tags == ["更新"], "agent prompt update should replace tags")
}

func testAutomationServiceImportsTextMetadata() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let service = PromptStudioAutomationService(repository: repository)
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
    try "Prompt: forest fashion portrait --no logo\nTags: 风景, 人物".write(to: file, atomically: true, encoding: .utf8)

    let imported = try service.importFiles(paths: [file.path])
    try expect(imported.count == 1, "agent import should create one item")
    try expect(imported[0].assetKind == .markdown, "markdown import should keep asset kind")
    try expect(imported[0].currentVersion?.prompt == "forest fashion portrait", "markdown import should parse prompt")
    try expect(imported[0].currentVersion?.negativePrompt == "logo", "markdown import should parse negative prompt")
    try expect(imported[0].tags.contains("风景") && imported[0].tags.contains("人物"), "markdown import should parse tags")
}

func testDocumentTextExtractorReadsRealDocx() throws {
    let docx = try makeDocxFixture(text: "Prompt: real docx forest --no logo\nTags: 文档, 测试\n")
    guard let text = DocumentTextExtractor.readText(from: docx) else {
        throw CoreUnitTestError.failure("docx text should be readable")
    }
    try expect(text.contains("real docx forest"), "real docx text should include source prompt")
    let parsed = PromptImportParser.parse(text: text, assetKind: .document)
    try expect(parsed.prompt == "real docx forest", "real docx text should parse prompt")
    try expect(parsed.negativePrompt == "logo", "real docx text should parse negative prompt")
    try expect(parsed.tags.contains("文档") && parsed.tags.contains("测试"), "real docx text should parse tags")
}

func testAutomationServiceImportsRealDocxMetadata() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let service = PromptStudioAutomationService(repository: repository)
    let docx = try makeDocxFixture(text: "Prompt: agent docx prompt --no watermark\nTags: Agent, DOCX\n")

    let imported = try service.importFiles(paths: [docx.path])
    try expect(imported.count == 1, "agent docx import should create one item")
    try expect(imported[0].assetKind == .document, "agent docx import should keep document asset kind")
    try expect(imported[0].type == .text, "agent docx import should stay in text prompt flow")
    try expect(imported[0].currentVersion?.prompt == "agent docx prompt", "agent docx import should parse prompt")
    try expect(imported[0].currentVersion?.negativePrompt == "watermark", "agent docx import should parse negative prompt")
    try expect(imported[0].tags.contains("Agent") && imported[0].tags.contains("DOCX"), "agent docx import should parse tags")
}

func testAutomationServiceImportsImageMetadata() throws {
    let repository = try PromptRepository(libraryURL: temporaryLibraryURL())
    let service = PromptStudioAutomationService(repository: repository)
    let png = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
    let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=")!
    try bytes.write(to: png)

    let imported = try service.importFiles(paths: [png.path])
    try expect(imported[0].assetKind == .image, "png import should keep image asset kind")
    try expect(imported[0].width == 1 && imported[0].height == 1, "png import should read pixel dimensions")
    try expect(imported[0].aspectRatio == "1:1", "png import should normalize aspect ratio")
    try expect(imported[0].fileSize > 0, "png import should store file size")
}

do {
    try testLibraryURLResolution()
    try testExistingLibraryValidationDoesNotCreateDatabase()
    try testSearchFiltering()
    try testFilteringPerformanceWith1000Items()
    try testTextFormatFiltering()
    try testPrimaryPromptAssetsAndAttachments()
    try testTextSyntaxModeInference()
    try testTextSyntaxRulesDetectJSONTokens()
    try testMarkdownHeadingRulesDetectCommonTitleShapes()
    try testMarkdownHeadingRulesAvoidBodyLikeLines()
    try testLargeMarkdownKeepsHeadingHighlightRules()
    try testMarkdownNegativeHighlightRequiresTitle()
    try testFolderFilteringUsesStableFolderID()
    try testSQLiteRoundTrip()
    try testRepositoryBulkSaveLoadPerformanceWith1000Items()
    try testAssetKindInferenceAndPromptParsing()
    try testAssetFormatCatalogCoversEagleMacOSFormats()
    try testAssetFormatCatalogRepresentativeMappings()
    try testPromptDocumentFormatsExtractMetadata()
    try testAutomationServiceImportsAllKnownFormatFixtures()
    try testUnknownFormatImportsAsGenericFile()
    try testTagRefreshDeletesUnusedTags()
    try testTrashAndRestore()
    try testAspectRatioDisplayNormalizesImportedSizes()
    try testSeedAssetRepairKeepsExistingUserData()
    try testThumbnailPathUpdatePersistsWithoutChangingOriginalAsset()
    try testLastUsedUpdatePersistsForRecentSorting()
    try testPinnedAtDoesNotAffectNormalCollectionSorting()
    try testPinnedAtDoesNotAffectRecentOrTrashSorting()
    try testPinnedAtPersistsAndMigratesFromOldSchema()
    try testFolderSeedIsIdempotent()
    try testFolderCRUDRoundTrip()
    try testAutomationServiceCreatesAndUpdatesPrompts()
    try testAutomationServiceImportsTextMetadata()
    try testDocumentTextExtractorReadsRealDocx()
    try testAutomationServiceImportsRealDocxMetadata()
    try testAutomationServiceImportsImageMetadata()
    print("PromptStudioCoreUnitTests passed")
} catch {
    fputs("PromptStudioCoreUnitTests failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
