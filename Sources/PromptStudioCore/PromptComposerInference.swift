import Foundation

/// The source of a Prompt composer's current type selection.
///
/// Manual confirmation is intentionally represented separately from automatic
/// inference so a later clipboard interpretation cannot overwrite the user's
/// choice. Returning to `.automatic` allows inference to resume.
public enum PromptComposerTypeMode: Equatable, Sendable {
    case automatic
    case manual(PromptType)
}

public typealias PromptComposerTypeState = PromptComposerTypeMode

/// The result shown by the composer after applying one clipboard interpretation.
public enum PromptComposerTypeDecision: Equatable, Sendable {
    case automatic(type: PromptType, confidence: PromptClipboardTypeConfidence, reason: String)
    case manual(type: PromptType)
    case unresolved(reason: String)

    public var type: PromptType? {
        switch self {
        case .automatic(let type, _, _), .manual(let type):
            type
        case .unresolved:
            nil
        }
    }

    public var confidence: PromptClipboardTypeConfidence? {
        switch self {
        case .automatic(_, let confidence, _):
            confidence
        case .manual, .unresolved:
            nil
        }
    }

    public var reason: String {
        switch self {
        case .automatic(_, _, let reason), .unresolved(let reason):
            reason
        case .manual:
            "已人工确认 Prompt 类型"
        }
    }

    public var isAutomatic: Bool {
        if case .automatic = self { return true }
        return false
    }

    public var isManual: Bool {
        if case .manual = self { return true }
        return false
    }

    public var isPendingSelection: Bool {
        if case .unresolved = self { return true }
        return false
    }

    /// Resolve an interpretation without allowing low-confidence guesses to
    /// silently switch the composer's type.
    public static func resolve(
        interpretation: PromptClipboardInterpretation,
        mode: PromptComposerTypeMode = .automatic
    ) -> Self {
        switch mode {
        case .manual(let type):
            return .manual(type: type)
        case .automatic:
            guard let suggestedType = interpretation.suggestedType,
                  interpretation.typeConfidence != .low else {
                return .unresolved(reason: unresolvedReason(for: interpretation))
            }
            return .automatic(
                type: suggestedType,
                confidence: interpretation.typeConfidence,
                reason: interpretation.typeReason
            )
        }
    }

    public static func decide(
        interpretation: PromptClipboardInterpretation,
        mode: PromptComposerTypeMode = .automatic
    ) -> Self {
        resolve(interpretation: interpretation, mode: mode)
    }

    /// Interpret plain text through the existing clipboard interpreter before
    /// applying the same state policy. This keeps all keyword semantics in one
    /// place and avoids a second inference rule set.
    public static func resolve(
        text: String,
        mode: PromptComposerTypeMode = .automatic
    ) -> Self {
        resolve(interpretation: PromptClipboardInterpreter.interpret(text), mode: mode)
    }

    public static func decide(
        text: String,
        mode: PromptComposerTypeMode = .automatic
    ) -> Self {
        resolve(text: text, mode: mode)
    }

    private static func unresolvedReason(for interpretation: PromptClipboardInterpretation) -> String {
        if !interpretation.typeReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return interpretation.typeReason
        }
        if let warning = interpretation.warnings.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return warning
        }
        return "需要手动选择 Prompt 类型"
    }
}

/// The metadata selected for a composer draft after type inference.
public struct PromptComposerMetadataDecision: Equatable, Sendable {
    public let model: ModelProfile
    public let promptFormatID: String?
    public let promptFormat: String?
    public let parameters: [String: String]

    public init(
        model: ModelProfile,
        promptFormatID: String? = nil,
        promptFormat: String? = nil,
        parameters: [String: String] = [:]
    ) {
        self.model = model
        self.promptFormatID = promptFormatID
        self.promptFormat = promptFormat
        self.parameters = parameters
    }

    public var modelID: String { model.id }
    public var modelName: String { model.name }
}

/// Applies conservative metadata rules to a clipboard interpretation.
///
/// A model hint is only trusted when it exactly matches a local model's ID or
/// name and that model has the already-determined prompt type. All other hints
/// intentionally collapse to an internal unspecified model, preventing stale
/// or guessed model data from being persisted.
public enum PromptComposerMetadataPolicy {
    public static let unspecifiedModelID = "unspecified"
    public static let unspecifiedModelName = "未指定"

    public static func resolve(
        type: PromptType,
        interpretation: PromptClipboardInterpretation,
        localModels: [ModelProfile]
    ) -> PromptComposerMetadataDecision {
        resolve(
            type: type,
            modelHint: interpretation.modelHint,
            formatHint: interpretation.formatHint,
            parameters: interpretation.parameters,
            localModels: localModels
        )
    }

    public static func decide(
        type: PromptType,
        interpretation: PromptClipboardInterpretation,
        localModels: [ModelProfile]
    ) -> PromptComposerMetadataDecision {
        resolve(type: type, interpretation: interpretation, localModels: localModels)
    }

    public static func resolve(
        type: PromptType,
        modelHint: String?,
        formatHint: String? = nil,
        parameters: [String: String] = [:],
        localModels: [ModelProfile]
    ) -> PromptComposerMetadataDecision {
        let model = resolveModel(type: type, hint: modelHint, localModels: localModels)
        let cleanParameters = parameters.filter { !isPromptFormatMetadataKey($0.key) }

        guard type == .text else {
            return PromptComposerMetadataDecision(model: model, parameters: cleanParameters)
        }

        let format = resolveTextFormat(formatHint)
        var result = cleanParameters
        result["prompt_format_id"] = format.id
        result["prompt_format"] = format.name
        return PromptComposerMetadataDecision(
            model: model,
            promptFormatID: format.id,
            promptFormat: format.name,
            parameters: result
        )
    }

    public static func decide(
        type: PromptType,
        modelHint: String?,
        formatHint: String? = nil,
        parameters: [String: String] = [:],
        localModels: [ModelProfile]
    ) -> PromptComposerMetadataDecision {
        resolve(
            type: type,
            modelHint: modelHint,
            formatHint: formatHint,
            parameters: parameters,
            localModels: localModels
        )
    }

    private struct TextFormat {
        let id: String
        let name: String
    }

    private static func resolveModel(type: PromptType, hint: String?, localModels: [ModelProfile]) -> ModelProfile {
        let normalizedHint = normalize(hint)
        if !normalizedHint.isEmpty,
           let match = localModels.first(where: {
               $0.id != "all" && $0.id != unspecifiedModelID && $0.type == type &&
                   (normalize($0.id) == normalizedHint || normalize($0.name) == normalizedHint)
           }) {
            return match
        }
        return ModelProfile(
            id: unspecifiedModelID,
            name: unspecifiedModelName,
            type: type,
            parameters: []
        )
    }

    private static func resolveTextFormat(_ hint: String?) -> TextFormat {
        switch normalize(hint) {
        case "json", "text_json", "application/json":
            return TextFormat(id: "text_json", name: "JSON")
        case "yaml", "yml", "text_yaml", "application/yaml", "text/yaml":
            return TextFormat(id: "text_yaml", name: "YAML")
        case "txt", "text", "text_txt", "plain", "plaintext", "text/plain":
            return TextFormat(id: "text_txt", name: "TXT")
        case "md", "markdown", "mdown", "text_markdown", "text/markdown":
            return TextFormat(id: "text_markdown", name: "Markdown")
        default:
            return TextFormat(id: "text_markdown", name: "Markdown")
        }
    }

    private static func isPromptFormatMetadataKey(_ key: String) -> Bool {
        let normalizedKey = key
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        return normalizedKey == "prompt_format_id" || normalizedKey == "prompt_format"
    }

    private static func normalize(_ value: String?) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
