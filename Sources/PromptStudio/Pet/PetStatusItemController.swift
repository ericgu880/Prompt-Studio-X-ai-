import AppKit

@MainActor
final class PetStatusItemController: NSObject {
    private weak var coordinator: PetCoordinator?
    private let statusItem: NSStatusItem

    init(coordinator: PetCoordinator) {
        self.coordinator = coordinator
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        statusItem.button?.image = NSImage(systemSymbolName: "mouth", accessibilityDescription: "PromptStudio 桌宠")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.toolTip = "恢复 PromptStudio 桌宠"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(restorePet)
    }

    @objc private func restorePet() {
        coordinator?.show()
    }

    deinit {
        NSStatusBar.system.removeStatusItem(statusItem)
    }
}
