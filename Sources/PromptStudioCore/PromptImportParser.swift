import Foundation

public struct ParsedPromptMetadata: Equatable, Sendable {
    public var prompt: String
    public var negativePrompt: String
    public var tags: [String]
    public var parameters: [String: String]

    public init(
        prompt: String = "",
        negativePrompt: String = "",
        tags: [String] = [],
        parameters: [String: String] = [:]
    ) {
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.tags = tags
        self.parameters = parameters
    }
}

public enum PromptImportParser {
    public static func parse(text: String, assetKind: AssetKind = .text) -> ParsedPromptMetadata {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ParsedPromptMetadata() }
        if assetKind == .json, let jsonResult = parseJSON(trimmed) {
            return jsonResult
        }

        var result = parseSections(trimmed)
        extractInlineSyntax(from: trimmed, into: &result)
        result.prompt = cleanPrompt(result.prompt)
        result.negativePrompt = result.negativePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        result.tags = normalizedTags(result.tags)
        if result.prompt.isEmpty {
            result.prompt = cleanPrompt(trimmed)
        }
        return result
    }

    private enum Section {
        case prompt
        case negative
        case tags
        case parameters
        case none
    }

    private static func parseSections(_ text: String) -> ParsedPromptMetadata {
        var result = ParsedPromptMetadata()
        var section: Section = .none
        var promptLines: [String] = []
        var negativeLines: [String] = []

        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if let parsed = parseHeadingLine(line) {
                section = parsed.section
                if !parsed.value.isEmpty {
                    append(parsed.value, to: section, result: &result, promptLines: &promptLines, negativeLines: &negativeLines)
                }
                continue
            }
            append(line, to: section == .none ? .prompt : section, result: &result, promptLines: &promptLines, negativeLines: &negativeLines)
        }

        result.prompt = promptLines.joined(separator: "\n")
        result.negativePrompt = negativeLines.joined(separator: "\n")
        return result
    }

    private static func parseHeadingLine(_ line: String) -> (section: Section, value: String)? {
        let separators = [":", "："]
        for separator in separators where line.contains(separator) {
            let parts = line.split(separator: Character(separator), maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = parts.first else { continue }
            let value = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
            if let section = section(for: String(key)) {
                return (section, value)
            }
        }
        return section(for: line).map { ($0, "") }
    }

    private static func section(for key: String) -> Section? {
        let normalized = key.lowercased()
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
        if ["prompt", "positiveprompt", "正向提示词", "提示词", "主提示词"].contains(normalized) {
            return .prompt
        }
        if ["negativeprompt", "negative", "no", "负面提示词", "反向提示词", "负提示词"].contains(normalized) {
            return .negative
        }
        if ["tags", "tag", "标签", "分类"].contains(normalized) {
            return .tags
        }
        if ["parameters", "parameter", "params", "参数"].contains(normalized) {
            return .parameters
        }
        return nil
    }

    private static func append(
        _ value: String,
        to section: Section,
        result: inout ParsedPromptMetadata,
        promptLines: inout [String],
        negativeLines: inout [String]
    ) {
        switch section {
        case .prompt:
            promptLines.append(value)
        case .negative:
            negativeLines.append(value)
        case .tags:
            result.tags.append(contentsOf: splitTags(value))
        case .parameters:
            let pair = value.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 {
                result.parameters[pair[0].trimmingCharacters(in: .whitespaces)] = pair[1].trimmingCharacters(in: .whitespaces)
            } else {
                extractParameters(from: value, into: &result.parameters)
            }
        case .none:
            promptLines.append(value)
        }
    }

    private static func parseJSON(_ text: String) -> ParsedPromptMetadata? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        var result = ParsedPromptMetadata()
        result.prompt = stringValue(dictionary, keys: ["prompt", "positive_prompt", "positivePrompt", "提示词", "正向提示词"])
        result.negativePrompt = stringValue(dictionary, keys: ["negative_prompt", "negativePrompt", "negative", "no", "负面提示词", "反向提示词"])
        if let tags = dictionary["tags"] as? [String] {
            result.tags.append(contentsOf: tags)
        } else if let tags = dictionary["标签"] as? [String] {
            result.tags.append(contentsOf: tags)
        } else {
            result.tags.append(contentsOf: splitTags(stringValue(dictionary, keys: ["tags", "标签"])))
        }
        if let parameters = dictionary["parameters"] as? [String: Any] {
            for (key, value) in parameters {
                result.parameters[key] = "\(value)"
            }
        }
        extractInlineSyntax(from: [result.prompt, result.negativePrompt, text].joined(separator: "\n"), into: &result)
        result.prompt = cleanPrompt(result.prompt)
        result.tags = normalizedTags(result.tags)
        return result
    }

    private static func stringValue(_ dictionary: [String: Any], keys: [String]) -> String {
        for key in keys {
            if let value = dictionary[key] as? String {
                return value
            }
        }
        return ""
    }

    private static func extractInlineSyntax(from text: String, into result: inout ParsedPromptMetadata) {
        extractNoFlag(from: text, into: &result.negativePrompt)
        extractParameters(from: text, into: &result.parameters)
        result.tags.append(contentsOf: hashTags(in: text))
        result.tags.append(contentsOf: keywordTags(in: text))
    }

    private static func extractNoFlag(from text: String, into negativePrompt: inout String) {
        let pattern = #"--no\s+(.+?)(?=\s--[a-zA-Z]+|\n|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        let values = matches.compactMap { match -> String? in
            guard match.numberOfRanges > 1 else { return nil }
            return nsText.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !values.isEmpty else { return }
        negativePrompt = normalizedJoined([negativePrompt] + values)
    }

    private static func extractParameters(from text: String, into parameters: inout [String: String]) {
        let pattern = #"--([a-zA-Z][a-zA-Z0-9_-]*)\s+([^-\n]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let nsText = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) where match.numberOfRanges > 2 {
            let key = nsText.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard key.lowercased() != "no" else { continue }
            let value = nsText.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty, !value.isEmpty {
                parameters[key] = value
            }
        }
    }

    private static func cleanPrompt(_ text: String) -> String {
        let withoutNo = text.replacingOccurrences(of: #"--no\s+(.+?)(?=\s--[a-zA-Z]+|\n|$)"#, with: "", options: [.regularExpression])
        let withoutParameters = withoutNo.replacingOccurrences(of: #"--[a-zA-Z][a-zA-Z0-9_-]*\s+[^-\n]+"#, with: "", options: [.regularExpression])
        return withoutParameters.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func hashTags(in text: String) -> [String] {
        let pattern = #"(?<!\w)#([\p{Han}A-Za-z0-9_\-]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsText = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            return nsText.substring(with: match.range(at: 1))
        }
    }

    private static func keywordTags(in text: String) -> [String] {
        let lower = text.lowercased()
        var tags: [String] = []
        if lower.contains("person") || lower.contains("portrait") || text.contains("人物") || text.contains("人像") {
            tags.append("人物")
        }
        if lower.contains("landscape") || text.contains("风景") || text.contains("自然") {
            tags.append("风景")
        }
        if lower.contains("illustration") || text.contains("插画") {
            tags.append("插画")
        }
        if lower.contains("realistic") || lower.contains("photo") || text.contains("写实") || text.contains("摄影") {
            tags.append("写实")
        }
        if lower.contains("editorial") || text.contains("设计") {
            tags.append("摄影设计")
        }
        return tags
    }

    private static func splitTags(_ value: String) -> [String] {
        value
            .replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: "、", with: ",")
            .split { [",", " ", "\n", "\t"].contains(String($0)) }
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func normalizedTags(_ tags: [String]) -> [String] {
        var seen: Set<String> = []
        return tags.compactMap { tag in
            let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, !seen.contains(normalized) else { return nil }
            seen.insert(normalized)
            return normalized
        }
    }

    private static func normalizedJoined(_ values: [String]) -> String {
        values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}
