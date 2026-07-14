import Foundation

public enum PromptSelectionResolver {
    public static func selectedID(
        preserving currentID: String?,
        in items: [PromptItem],
        allowEmptySelection: Bool
    ) -> String? {
        if let currentID, items.contains(where: { $0.id == currentID }) {
            return currentID
        }
        return allowEmptySelection ? nil : items.first?.id
    }
}
