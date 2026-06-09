import Foundation

public enum TextSyntaxMode: String, CaseIterable, Sendable {
    case markdown
    case json
    case yamlToml
    case xml
    case log
    case source
    case plain

    public static func infer(for item: PromptItem) -> TextSyntaxMode {
        infer(assetPath: item.assetPath, format: item.format, assetKind: item.assetKind)
    }

    public static func infer(assetPath: String, format: String = "", assetKind: AssetKind = .unknown) -> TextSyntaxMode {
        if let mode = mode(forExtension: (assetPath as NSString).pathExtension) {
            return mode
        }
        if let mode = mode(forExtension: format) {
            return mode
        }
        switch assetKind {
        case .markdown:
            return .markdown
        case .json:
            return .json
        case .data:
            return .yamlToml
        case .source:
            return .source
        case .text, .document:
            return .plain
        case .image, .video, .audio, .raw, .threeD, .texture, .font, .web, .unknown:
            return .plain
        }
    }

    private static func mode(forExtension value: String) -> TextSyntaxMode? {
        let normalized = value
            .trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines))
            .lowercased()
        guard !normalized.isEmpty else { return nil }

        if ["md", "markdown", "mdown"].contains(normalized) {
            return .markdown
        }
        if normalized == "json" {
            return .json
        }
        if ["yaml", "yml", "toml", "plist"].contains(normalized) {
            return .yamlToml
        }
        if ["xml", "html", "htm"].contains(normalized) {
            return .xml
        }
        if normalized == "log" {
            return .log
        }
        if sourceExtensions.contains(normalized) {
            return .source
        }
        if ["txt", "text", "csv", "tsv", "rtf", "doc", "docx"].contains(normalized) {
            return .plain
        }
        return nil
    }

    private static let sourceExtensions: Set<String> = [
        "c", "cc", "cpp", "cs", "css", "go", "h", "hpp", "java", "js", "jsx",
        "kt", "m", "mm", "php", "py", "rb", "rs", "scss", "sh", "sql", "swift",
        "ts", "tsx", "vue"
    ]
}

public enum TextSyntaxToken: String, CaseIterable, Hashable, Sendable {
    case heading
    case quoteMarker
    case listMarker
    case inlineCode
    case muted
    case negativeConstraint
    case bold
    case jsonKey
    case yamlKey
    case string
    case number
    case literal
    case punctuation
    case comment
    case xmlTag
    case xmlAttribute
    case timestamp
    case errorLevel
    case warningLevel
    case infoLevel
    case sourceKeyword
    case url
    case path
}

public struct TextSyntaxRule: Sendable {
    public let token: TextSyntaxToken
    public let pattern: String
    public let captureGroup: Int
    public let options: NSRegularExpression.Options

    public init(
        token: TextSyntaxToken,
        pattern: String,
        captureGroup: Int = 0,
        options: NSRegularExpression.Options = []
    ) {
        self.token = token
        self.pattern = pattern
        self.captureGroup = captureGroup
        self.options = options
    }
}

public enum TextSyntaxRules {
    public static let largeTextByteLimit = 200_000
    public static let largeTextLineLimit = 3_000

    public static func rules(for mode: TextSyntaxMode, text: String) -> [TextSyntaxRule] {
        if isLargeText(text) {
            if mode == .markdown {
                return markdownLightRules
            }
            return lightRules
        }

        switch mode {
        case .markdown:
            return markdownRules
        case .json:
            return jsonRules
        case .yamlToml:
            return yamlTomlRules
        case .xml:
            return xmlRules
        case .log:
            return logRules
        case .source:
            return sourceRules
        case .plain:
            return plainRules
        }
    }

    public static func tokenKinds(in text: String, mode: TextSyntaxMode) -> Set<TextSyntaxToken> {
        var tokens = Set<TextSyntaxToken>()
        for rule in rules(for: mode, text: text) {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: rule.options) else {
                continue
            }
            let range = NSRange(location: 0, length: (text as NSString).length)
            if regex.firstMatch(in: text, range: range) != nil {
                tokens.insert(rule.token)
            }
        }
        return tokens
    }

    private static func isLargeText(_ text: String) -> Bool {
        text.utf8.count > largeTextByteLimit || lineCount(in: text, limit: largeTextLineLimit + 1) > largeTextLineLimit
    }

    private static func lineCount(in text: String, limit: Int) -> Int {
        guard !text.isEmpty else { return 0 }
        let value = text as NSString
        var count = 1
        for index in 0..<value.length where value.character(at: index) == 10 {
            count += 1
            if count >= limit {
                return count
            }
        }
        return count
    }

    private static let markdownRules: [TextSyntaxRule] = [
        TextSyntaxRule(token: .heading, pattern: #"(?m)^\s{0,6}#{1,6}\s.*$"#),
        TextSyntaxRule(token: .heading, pattern: markdownSetextHeadingPattern),
        TextSyntaxRule(token: .heading, pattern: markdownWrappedHeadingPattern),
        TextSyntaxRule(token: .heading, pattern: markdownNumberedHeadingPattern, options: .caseInsensitive),
        TextSyntaxRule(token: .heading, pattern: markdownColonHeadingPattern),
        TextSyntaxRule(token: .heading, pattern: markdownShortHeadingPattern),
        TextSyntaxRule(token: .quoteMarker, pattern: #"(?m)^\s{0,3}(>)"#, captureGroup: 1),
        TextSyntaxRule(token: .muted, pattern: #"(?m)^\s*[-*_]{3,}\s*$"#),
        TextSyntaxRule(token: .listMarker, pattern: #"(?m)^\s*((?:\d+\.|[-*]))"#, captureGroup: 1),
        TextSyntaxRule(token: .inlineCode, pattern: #"(?<!`)`(?!`)[^`\n]+(?<!`)`(?!`)"#),
        TextSyntaxRule(token: .negativeConstraint, pattern: negativeConstraintPattern),
        TextSyntaxRule(token: .bold, pattern: #"\*\*[^*\n]+?\*\*"#)
    ]

    private static let markdownLightRules: [TextSyntaxRule] = [
        TextSyntaxRule(token: .heading, pattern: #"(?m)^\s{0,6}#{1,6}\s.*$"#),
        TextSyntaxRule(token: .heading, pattern: markdownSetextHeadingPattern),
        TextSyntaxRule(token: .heading, pattern: markdownWrappedHeadingPattern),
        TextSyntaxRule(token: .heading, pattern: markdownNumberedHeadingPattern, options: .caseInsensitive),
        TextSyntaxRule(token: .heading, pattern: markdownColonHeadingPattern),
        TextSyntaxRule(token: .heading, pattern: markdownShortHeadingPattern),
        TextSyntaxRule(token: .negativeConstraint, pattern: negativeConstraintPattern)
    ]

    private static let markdownSetextHeadingPattern = #"(?m)^\s{0,6}(?!\s*(?:[-*+]\s|>\s?|\||`{3,}|~{3,}))(?![^\n]*[。！？；，,!?;])[^\n]{1,40}(?=\n\s*[=-]{3,}\s*$)"#
    private static let markdownWrappedHeadingPattern = #"(?m)^\s{0,6}(?:【[^】\n]{1,40}】|《[^》\n]{1,40}》|「[^」\n]{1,40}」|『[^』\n]{1,40}』|\[[^\]\n]{1,40}\]|\([^)\n]{1,40}\)|（[^）\n]{1,40}）)\s*$"#
    private static let markdownNumberedHeadingPattern = #"(?m)^\s{0,6}(?:[一二三四五六七八九十百千万]+[、.．]\s*|\d{1,2}[.、．]\s+|step\s+\d+\s*[:：]\s*)[^\n。！？；，,!?;]{1,60}$"#
    private static let markdownColonHeadingPattern = #"(?m)^\s{0,6}(?!\s*(?:[-*+]\s|>\s?|\||`{3,}|~{3,}))[^。\n！？；，,!?;:：|]{1,40}[:：]\s*$"#
    private static let markdownShortHeadingPattern = #"(?m)^\s{0,6}(?!\s*(?:[-*+]\s|>\s?|\||`{3,}|~{3,}))(?![^\n]*[。！？；，,!?;])(?=[^\n]{1,40}\s*$)(?=(?:[^\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}\n]*[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]){0,16}[^\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}\n]*$)[\p{L}\p{N}][\p{L}\p{N}\s·・／/()（）-]*$"#

    private static let jsonRules: [TextSyntaxRule] = [
        TextSyntaxRule(token: .punctuation, pattern: #"[{}\[\],:]"#),
        TextSyntaxRule(token: .number, pattern: numberPattern),
        TextSyntaxRule(token: .literal, pattern: #"\b(?:true|false|null)\b"#),
        TextSyntaxRule(token: .jsonKey, pattern: #""(?:\\.|[^"\\])*"(?=\s*:)"#)
    ]

    private static let yamlTomlRules: [TextSyntaxRule] = [
        TextSyntaxRule(token: .comment, pattern: #"(?m)#.*$"#),
        TextSyntaxRule(token: .number, pattern: numberPattern),
        TextSyntaxRule(token: .literal, pattern: #"\b(?:true|false|null|yes|no|on|off)\b"#, options: .caseInsensitive),
        TextSyntaxRule(token: .string, pattern: #""(?:\\.|[^"\\])*"|'[^'\n]*'"#),
        TextSyntaxRule(token: .yamlKey, pattern: #"(?m)^\s*([A-Za-z_][\w.-]*)(?=\s*[:=])"#, captureGroup: 1)
    ]

    private static let xmlRules: [TextSyntaxRule] = [
        TextSyntaxRule(token: .xmlTag, pattern: #"</?\s*[A-Za-z][A-Za-z0-9:_-]*|/?>"#),
        TextSyntaxRule(token: .string, pattern: #""[^"]*"|'[^']*'"#),
        TextSyntaxRule(token: .xmlAttribute, pattern: #"\s([A-Za-z_:][-A-Za-z0-9_:.]*)(?=\s*=)"#, captureGroup: 1),
        TextSyntaxRule(token: .comment, pattern: #"<!--[\s\S]*?-->"#)
    ]

    private static let logRules: [TextSyntaxRule] = [
        TextSyntaxRule(token: .timestamp, pattern: #"\b\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?\b"#),
        TextSyntaxRule(token: .errorLevel, pattern: #"\b(?:ERROR|ERR|FATAL)\b"#, options: .caseInsensitive),
        TextSyntaxRule(token: .warningLevel, pattern: #"\b(?:WARN|WARNING)\b"#, options: .caseInsensitive),
        TextSyntaxRule(token: .infoLevel, pattern: #"\b(?:INFO|DEBUG|TRACE)\b"#, options: .caseInsensitive),
        TextSyntaxRule(token: .url, pattern: urlPattern),
        TextSyntaxRule(token: .path, pattern: pathPattern, captureGroup: 2)
    ]

    private static let sourceRules: [TextSyntaxRule] = [
        TextSyntaxRule(token: .comment, pattern: #"(?m)(//|#|--).*$"#),
        TextSyntaxRule(token: .comment, pattern: #"/\*[\s\S]*?\*/"#),
        TextSyntaxRule(token: .number, pattern: numberPattern),
        TextSyntaxRule(token: .string, pattern: #""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#),
        TextSyntaxRule(token: .sourceKeyword, pattern: #"\b(?:async|await|break|case|catch|class|const|continue|def|else|enum|for|from|func|function|guard|if|import|in|interface|let|private|public|return|struct|switch|throws|try|type|var|while|where)\b"#)
    ]

    private static let plainRules: [TextSyntaxRule] = [
        TextSyntaxRule(token: .url, pattern: urlPattern),
        TextSyntaxRule(token: .path, pattern: pathPattern, captureGroup: 2),
        TextSyntaxRule(token: .number, pattern: numberPattern),
        TextSyntaxRule(token: .negativeConstraint, pattern: negativeConstraintPattern)
    ]

    private static let lightRules: [TextSyntaxRule] = [
        TextSyntaxRule(token: .errorLevel, pattern: #"\b(?:ERROR|ERR|FATAL)\b"#, options: .caseInsensitive),
        TextSyntaxRule(token: .warningLevel, pattern: #"\b(?:WARN|WARNING)\b"#, options: .caseInsensitive),
        TextSyntaxRule(token: .infoLevel, pattern: #"\b(?:INFO|DEBUG|TRACE)\b"#, options: .caseInsensitive),
        TextSyntaxRule(token: .url, pattern: urlPattern),
        TextSyntaxRule(token: .path, pattern: pathPattern, captureGroup: 2)
    ]

    private static let numberPattern = #"(?<![\w.])-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?(?![\w.])"#
    private static let urlPattern = #"https?://[^\s<>)"]+"#
    private static let pathPattern = #"(?m)(^|\s)((?:~|/)[^\s,;:]+)"#
    private static let negativeConstraintPattern = #"(?im)^\s{0,6}(?:(?:#{1,6}\s*.*(?:负面提示(?:词)?|反向提示(?:词)?|负面约束|反向约束|Negative Prompt).*)|(?:(?:负面提示(?:词)?|反向提示(?:词)?|负面约束|反向约束|Negative Prompt)(?:\s*(?:规则|内容|列表|清单|要求|Constraints?))?\s*[:：]?))\s*$"#
}
