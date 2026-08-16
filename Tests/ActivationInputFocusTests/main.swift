import Foundation

@main
struct ActivationInputFocusTests {
    static func main() {
        precondition(
            !TextInputFocusPolicy.shouldClearFocus(
                isTextInputActive: true,
                eventWindowNumber: 42,
                ownerWindowNumber: 7,
                clickIsInsideEditableInput: false
            ),
            "A main-workspace monitor must not clear focus in a settings sheet."
        )

        precondition(
            TextInputFocusPolicy.shouldClearFocus(
                isTextInputActive: true,
                eventWindowNumber: 7,
                ownerWindowNumber: 7,
                clickIsInsideEditableInput: false
            ),
            "A click outside an editor in the owning workspace should still clear focus."
        )

        precondition(
            !TextInputFocusPolicy.shouldClearFocus(
                isTextInputActive: true,
                eventWindowNumber: 7,
                ownerWindowNumber: 7,
                clickIsInsideEditableInput: true
            ),
            "A click inside an editor must preserve focus."
        )

        print("ActivationInputFocusTests passed")
    }
}
