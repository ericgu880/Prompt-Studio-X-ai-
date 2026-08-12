import Foundation

public enum PromptClipboardTypeConfidence: String, Codable, CaseIterable, Identifiable, Sendable {
    case high
    case medium
    case low

    public var id: String { rawValue }
}

public typealias PromptClipboardConfidence = PromptClipboardTypeConfidence

public struct PromptClipboardInterpretation: Equatable, Sendable {
    public var originalText: String
    public var title: String
    public var prompt: String
    public var negativePrompt: String
    public var tags: [String]
    public var parameters: [String: String]
    public var suggestedType: PromptType?
    public var typeConfidence: PromptClipboardTypeConfidence
    public var typeReason: String
    public var warnings: [String]
    public var modelHint: String?
    public var formatHint: String?

    public init(
        originalText: String = "",
        title: String = "",
        prompt: String = "",
        negativePrompt: String = "",
        tags: [String] = [],
        parameters: [String: String] = [:],
        suggestedType: PromptType? = nil,
        typeConfidence: PromptClipboardTypeConfidence = .low,
        typeReason: String = "",
        warnings: [String] = [],
        modelHint: String? = nil,
        formatHint: String? = nil
    ) {
        self.originalText = originalText
        self.title = title
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.tags = tags
        self.parameters = parameters
        self.suggestedType = suggestedType
        self.typeConfidence = typeConfidence
        self.typeReason = typeReason
        self.warnings = warnings
        self.modelHint = modelHint
        self.formatHint = formatHint
    }
}

public enum PromptClipboardInterpreter {
    public static func interpret(_ text: String) -> PromptClipboardInterpretation {
        let originalText = normalizeInput(text)
        guard !originalText.isEmpty else {
            return PromptClipboardInterpretation(
                originalText: "",
                typeReason: "输入为空",
                warnings: ["输入为空"]
            )
        }

        let hints = extractHints(from: originalText)
        let isJSON = jsonDictionary(from: originalText) != nil
        let parsingText = isJSON ? originalText : removingMetadataLines(from: originalText)
        let structured = isJSON || containsStructuredSyntax(in: parsingText) || parsingText != originalText

        let metadata: ParsedPromptMetadata
        let prompt: String
        if structured {
            metadata = PromptImportParser.parse(text: parsingText, assetKind: isJSON ? .json : .text)
            prompt = metadata.prompt
        } else {
            metadata = ParsedPromptMetadata(prompt: originalText)
            prompt = originalText
        }

        let typeResult = inferType(
            from: [prompt, metadata.negativePrompt].filter { !$0.isEmpty }.joined(separator: "\n"),
            modelHint: hints.model,
            formatHint: hints.format
        )

        return PromptClipboardInterpretation(
            originalText: originalText,
            title: makeTitle(from: prompt),
            prompt: prompt,
            negativePrompt: metadata.negativePrompt,
            tags: metadata.tags,
            parameters: metadata.parameters,
            suggestedType: typeResult.type,
            typeConfidence: typeResult.confidence,
            typeReason: typeResult.reason,
            warnings: typeResult.warnings,
            modelHint: hints.model,
            formatHint: hints.format
        )
    }

    public static func interpret(text: String) -> PromptClipboardInterpretation {
        interpret(text)
    }

    private struct Hints {
        var model: String?
        var format: String?
    }

    private struct TypeResult {
        var type: PromptType?
        var confidence: PromptClipboardTypeConfidence
        var reason: String
        var warnings: [String]
    }

    private static let headingKeys: Set<String> = [
        "prompt", "positiveprompt", "正向提示词", "提示词", "主提示词",
        "negativeprompt", "negative", "no", "负面提示词", "反向提示词", "负提示词",
        "tags", "tag", "标签", "分类", "parameters", "parameter", "params", "参数"
    ]

    private static let modelKeys: Set<String> = ["model", "modelid", "modelname", "模型", "模型名", "模型名称"]
    private static let formatKeys: Set<String> = ["format", "outputformat", "格式", "输出格式"]

    private static let chineseOutputIntentTerms = [
        "生成", "输出", "制作", "创建", "撰写", "修改", "改写", "设计", "总结", "翻译", "整理", "提取", "分析", "产出"
    ]

    private static let englishOutputIntentTerms = [
        "generate", "output", "create", "make", "write", "edit", "rewrite", "design", "produce", "render", "compose", "summarize", "translate", "extract", "analyze"
    ]

    private static let imageSignals: [(String, Int)] = [
        ("静态画面", 3), ("静态", 2), ("构图", 2), ("人物", 1), ("人像", 2), ("肖像", 2), ("服装", 2), ("穿着", 2),
        ("光线", 2), ("光影", 2), ("色调", 2), ("焦段", 2), ("画幅", 2), ("摄影", 2), ("照片", 3), ("图片", 3),
        ("插画", 3), ("画面", 2), ("高清图", 4), ("图像", 3), ("image", 3), ("photo", 3), ("portrait", 2), ("illustration", 3), ("static", 2),
        ("composition", 2), ("clothing", 2), ("outfit", 2), ("lighting", 2), ("color tone", 2), ("focal length", 2), ("aspect ratio", 1)
    ]

    private static let videoSignals: [(String, Int)] = [
        ("视频", 4), ("影片", 4), ("短片", 3), ("动画", 3), ("时长", 3), ("分镜", 3), ("运镜", 3), ("连续动作", 3),
        ("转场", 3), ("首尾帧", 3), ("首帧", 2), ("尾帧", 2), ("镜头", 2), ("video", 4), ("film", 3),
        ("animation", 3), ("storyboard", 3), ("camera movement", 3), ("transition", 3), ("first frame", 2), ("last frame", 2),
        ("duration", 3), ("continuous action", 3)
    ]

    private static let audioSignals: [(String, Int)] = [
        ("音频", 4), ("声音", 2), ("音色", 3), ("声线", 3), ("语速", 3), ("旁白", 4), ("配音", 4), ("音乐", 3),
        ("bgm", 3), ("音效", 3), ("audio", 4), ("voice", 3), ("narration", 4), ("dubbing", 4), ("music", 3),
        ("sound effect", 3), ("timbre", 3), ("tempo", 2), ("speech rate", 3)
    ]

    private static let textSignals: [(String, Int)] = [
        ("文本", 3), ("文章", 3), ("文案", 3), ("报告", 3), ("写作", 3), ("整理", 2), ("提取", 2),
        ("分析", 2), ("翻译", 3), ("总结", 3), ("markdown", 3), ("结构化数据", 3), ("json", 2), ("数据", 2),
        ("text", 3), ("document", 3), ("article", 3), ("report", 3), ("writing", 3), ("summarize", 3), ("translate", 3), ("extract", 2),
        ("analyze", 2), ("structured data", 3)
    ]

    private static func normalizeInput(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedKey(_ key: String) -> String {
        key.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
    }

    private static func lineKeyAndValue(_ line: String) -> (String, String)? {
        guard let separator = line.firstIndex(where: { $0 == ":" || $0 == "：" || $0 == "=" }) else { return nil }
        let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
        let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        return (normalizedKey(key), value)
    }

    private static func extractHints(from text: String) -> Hints {
        var hints = Hints()
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let (key, value) = lineKeyAndValue(line), !value.isEmpty else { continue }
            if hints.model == nil, modelKeys.contains(key) {
                hints.model = value
            } else if hints.format == nil, formatKeys.contains(key) {
                hints.format = value
            }
        }

        if let object = jsonDictionary(from: text) {
            if hints.model == nil {
                hints.model = jsonString(object, keys: modelKeys)
            }
            if hints.format == nil {
                hints.format = jsonString(object, keys: formatKeys)
            }
        }
        return hints
    }

    private static func jsonDictionary(from text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return nil }
        return dictionary
    }

    private static func jsonString(_ dictionary: [String: Any], keys: Set<String>) -> String? {
        for (key, value) in dictionary {
            guard keys.contains(normalizedKey(key)), let string = value as? String else { continue }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func removingMetadataLines(from text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { rawLine in
                let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let (key, value) = lineKeyAndValue(line), !value.isEmpty else { return true }
                return !modelKeys.contains(key) && !formatKeys.contains(key)
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func containsStructuredSyntax(in text: String) -> Bool {
        if text.range(of: #"--[A-Za-z][A-Za-z0-9_-]*\s+"#, options: .regularExpression) != nil { return true }
        if text.range(of: #"(?<!\w)#[\p{Han}A-Za-z0-9_-]+"#, options: .regularExpression) != nil { return true }
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if let (key, _) = lineKeyAndValue(line), headingKeys.contains(key) { return true }
            if headingKeys.contains(normalizedKey(line)) { return true }
        }
        return false
    }

    private static func makeTitle(from prompt: String) -> String {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        let firstLine = prompt
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? prompt
        let compact = firstLine
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !compact.isEmpty else { return "" }

        var title = compact
        if let end = compact.firstIndex(where: { ".。!?！？".contains($0) }) {
            title = String(compact[...end])
        }
        return String(title.prefix(40))
    }

    private static func inferType(from text: String, modelHint: String?, formatHint: String?) -> TypeResult {
        let lower = text.lowercased()
        let explicitTypes = explicitOutputTypes(in: lower)
        if explicitTypes.count > 1 {
            let labels = explicitTypes.sorted { typeOrder($0) < typeOrder($1) }.map(\.displayName).joined(separator: "、")
            return TypeResult(type: nil, confidence: .low, reason: "检测到\(labels)等多种输出类型，无法确定", warnings: ["输出类型冲突：\(labels)"])
        }
        if let explicit = explicitTypes.first {
            return TypeResult(type: explicit, confidence: .high, reason: "根据明确的\(explicit.displayName)输出意图判断", warnings: [])
        }

        var scores: [PromptType: Int] = [.image: score(lower, using: imageSignals), .video: score(lower, using: videoSignals), .audio: score(lower, using: audioSignals), .text: score(lower, using: textSignals)]
        if hasDuration(in: lower) { scores[.video, default: 0] += 3 }
        addWeakHintScore(modelHint, formatHint, to: &scores)

        let ordered = PromptType.allCases.sorted { lhs, rhs in
            let left = scores[lhs, default: 0]
            let right = scores[rhs, default: 0]
            return left == right ? typeOrder(lhs) < typeOrder(rhs) : left > right
        }
        guard let best = ordered.first else {
            return TypeResult(type: nil, confidence: .low, reason: "缺少明确的类型语义", warnings: [])
        }
        let bestScore = scores[best, default: 0]
        let secondScore = ordered.dropFirst().first.map { scores[$0, default: 0] } ?? 0
        guard bestScore >= 3, bestScore - secondScore >= 2 else {
            let warning = bestScore > 0 ? ["类型语义不足或存在冲突"] : []
            return TypeResult(type: nil, confidence: .low, reason: bestScore > 0 ? "类型语义不足或存在冲突" : "缺少明确的类型语义", warnings: warning)
        }

        let confidence: PromptClipboardTypeConfidence = bestScore >= 6 && bestScore - secondScore >= 3 ? .high : .medium
        return TypeResult(type: best, confidence: confidence, reason: semanticReason(for: best), warnings: [])
    }

    private static func explicitOutputTypes(in lower: String) -> Set<PromptType> {
        let clauses = lower.components(separatedBy: CharacterSet(charactersIn: "，,。.!！？?；;\n"))
        var result: Set<PromptType> = []
        for clause in clauses where hasOutputIntent(in: clause) {
            let imageScore = score(clause, using: imageSignals)
            let videoScore = score(clause, using: videoSignals) + (hasDuration(in: clause) ? 3 : 0)
            let audioScore = score(clause, using: audioSignals)
            let textScore = score(clause, using: textSignals)
            if imageScore >= 3 { result.insert(.image) }
            if videoScore >= 3 { result.insert(.video) }
            if audioScore >= 3 { result.insert(.audio) }
            if textScore >= 2 { result.insert(.text) }
        }
        return result
    }

    private static func hasOutputIntent(in clause: String) -> Bool {
        if containsAny(clause, chineseOutputIntentTerms) {
            return true
        }
        let writeIntent = clause == "写"
            || clause.contains("写一")
            || clause.contains("写个")
            || clause.contains("写篇")
            || clause.contains("写文章")
            || clause.contains("写文案")
            || clause.contains("写报告")
            || clause.contains("写出")
            || clause.contains("写成")
            || clause.contains("写作")
        if writeIntent {
            return true
        }
        let tokens = clause.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return tokens.contains { englishOutputIntentTerms.contains($0) }
    }

    private static func addWeakHintScore(_ modelHint: String?, _ formatHint: String?, to scores: inout [PromptType: Int]) {
        let model = modelHint?.lowercased() ?? ""
        let format = formatHint?.lowercased() ?? ""
        if containsAny(model, ["nano banana", "midjourney", "seedream", "stable diffusion", "dall-e", "flux"]) {
            scores[.image, default: 0] += 1
        } else if containsAny(model, ["seedance", "sora", "runway", "kling"]) {
            scores[.video, default: 0] += 1
        } else if containsAny(model, ["suno", "udio"]) {
            scores[.audio, default: 0] += 1
        }
        if containsAny(format, ["json", "markdown", "md", "txt", "text"]) {
            scores[.text, default: 0] += 1
        } else if containsAny(format, ["png", "jpg", "jpeg", "webp"]) {
            scores[.image, default: 0] += 1
        } else if containsAny(format, ["mp4", "mov", "webm"]) {
            scores[.video, default: 0] += 1
        } else if containsAny(format, ["mp3", "wav", "m4a", "flac"]) {
            scores[.audio, default: 0] += 1
        }
    }

    private static func score(_ text: String, using signals: [(String, Int)]) -> Int {
        signals.reduce(0) { result, signal in result + (text.contains(signal.0) ? signal.1 : 0) }
    }

    private static func hasDuration(in text: String) -> Bool {
        text.range(of: #"\d+(?:\.\d+)?\s*(?:秒|分钟|分|s|sec|secs|second|seconds|min|mins|minute|minutes)"#, options: .regularExpression) != nil
    }

    private static func containsAny(_ text: String, _ values: [String]) -> Bool {
        values.contains { text.contains($0.lowercased()) }
    }

    private static func typeOrder(_ type: PromptType) -> Int {
        switch type {
        case .image: 0
        case .video: 1
        case .audio: 2
        case .text: 3
        }
    }

    private static func semanticReason(for type: PromptType) -> String {
        switch type {
        case .image: "根据画面、构图、人物或光线等静态图像语义判断"
        case .video: "根据时长、分镜、运镜或连续动作等视频语义判断"
        case .audio: "根据音色、旁白、音乐或音效等音频语义判断"
        case .text: "根据写作、整理、分析、翻译或结构化数据等文本语义判断"
        }
    }
}
