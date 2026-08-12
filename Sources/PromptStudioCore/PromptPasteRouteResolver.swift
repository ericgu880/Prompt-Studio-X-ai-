import Foundation

public enum PromptPasteRoute: Equatable, Sendable {
    case nativeTextPaste
    case importFiles
    case smartPaste(String)
    case unavailable
}

public enum PromptPasteRouteResolver {
    public static func resolve(
        isTextInputActive: Bool,
        hasFileURLs: Bool,
        plainText: String?
    ) -> PromptPasteRoute {
        if isTextInputActive {
            return .nativeTextPaste
        }
        if hasFileURLs {
            return .importFiles
        }
        guard let plainText, !plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unavailable
        }
        return .smartPaste(plainText)
    }
}
