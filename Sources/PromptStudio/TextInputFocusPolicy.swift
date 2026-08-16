import Foundation

enum TextInputFocusPolicy {
    static func shouldClearFocus(
        isTextInputActive: Bool,
        eventWindowNumber: Int,
        ownerWindowNumber: Int?,
        clickIsInsideEditableInput: Bool
    ) -> Bool {
        guard isTextInputActive,
              let ownerWindowNumber,
              eventWindowNumber == ownerWindowNumber else {
            return false
        }
        return !clickIsInsideEditableInput
    }
}
