import Foundation

public struct PromptEditorMatchedFieldsSummary: Equatable, Sendable {
    public var hasPrompt: Bool
    public var hasNegativePrompt: Bool
    public var tagCount: Int
    public var parameterCount: Int
    public var hasExplicitModel: Bool
    public var hasExplicitFormat: Bool

    public init(
        hasPrompt: Bool,
        hasNegativePrompt: Bool,
        tagCount: Int,
        parameterCount: Int,
        hasExplicitModel: Bool,
        hasExplicitFormat: Bool
    ) {
        self.hasPrompt = hasPrompt
        self.hasNegativePrompt = hasNegativePrompt
        self.tagCount = tagCount
        self.parameterCount = parameterCount
        self.hasExplicitModel = hasExplicitModel
        self.hasExplicitFormat = hasExplicitFormat
    }
}

public enum PromptEditorPasteDecision: Equatable, Sendable {
    case nativeText
    case structured(PromptEditorMatchedFieldsSummary)
}

public enum PromptEditorPasteResolver {
    public static func resolve(_ interpretation: PromptClipboardInterpretation) -> PromptEditorPasteDecision {
        let fields = interpretation.explicitFields
        let summary = PromptEditorMatchedFieldsSummary(
            hasPrompt: fields.hasPrompt,
            hasNegativePrompt: fields.hasNegativePrompt,
            tagCount: fields.tags.count,
            parameterCount: fields.parameters.count,
            hasExplicitModel: fields.hasModel,
            hasExplicitFormat: fields.hasFormat
        )
        let hasMatchedFields = summary.hasPrompt || summary.hasNegativePrompt ||
            summary.tagCount > 0 ||
            summary.parameterCount > 0 ||
            summary.hasExplicitModel ||
            summary.hasExplicitFormat
        return hasMatchedFields ? .structured(summary) : .nativeText
    }
}
