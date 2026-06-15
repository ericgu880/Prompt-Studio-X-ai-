import AppKit

@MainActor
enum AppShortcutRouter {
    enum UndoRedoShortcut {
        case undo
        case redo
    }

    static func performUndoOrBack(_ state: AppState) {
        if AppKitBridge.isTextInputActive() {
            NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
        } else {
            state.navigateBack()
        }
    }

    static func performRedoOrForward(_ state: AppState) {
        if AppKitBridge.isTextInputActive() {
            NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
        } else {
            state.navigateForward()
        }
    }

    static func canPerformUndoOrBack(_ state: AppState) -> Bool {
        AppKitBridge.isTextInputActive() || state.canNavigateBack
    }

    static func canPerformRedoOrForward(_ state: AppState) -> Bool {
        AppKitBridge.isTextInputActive() || state.canNavigateForward
    }

    static func shouldUseAppHistoryForUndoRedo() -> Bool {
        !AppKitBridge.isTextInputActive()
    }

    nonisolated static func undoRedoShortcut(for event: NSEvent) -> UndoRedoShortcut? {
        guard event.charactersIgnoringModifiers?.lowercased() == "z" else { return nil }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags.contains(.command),
              !flags.contains(.option),
              !flags.contains(.control) else {
            return nil
        }
        return flags.contains(.shift) ? .redo : .undo
    }
}
