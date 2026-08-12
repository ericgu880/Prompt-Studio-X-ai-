import AppKit
import SwiftUI

@MainActor
final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PetPanelController: NSObject, NSWindowDelegate {
    weak var coordinator: PetCoordinator?
    let panel: PetPanel

    private let compactSize = CGSize(width: 102, height: 102)
    private let askingSize = CGSize(width: 320, height: 150)
    private var isAsking = false
    private var snapWorkItem: DispatchWorkItem?

    init(coordinator: PetCoordinator) {
        self.coordinator = coordinator
        panel = PetPanel(
            contentRect: NSRect(origin: .zero, size: CGSize(width: 102, height: 102)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.delegate = self
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: PetView(coordinator: coordinator))
    }

    func show() {
        guard let screen = targetScreen() else { return }
        if panel.screen == nil {
            panel.setFrameOrigin(restoredOrigin(on: screen.visibleFrame))
        } else {
            panel.setFrameOrigin(PetGeometry.clampedOrigin(
                proposed: panel.frame.origin,
                panelSize: panel.frame.size,
                visibleFrame: screen.visibleFrame,
                inset: 8
            ))
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func setAsking(_ asking: Bool) {
        guard asking != isAsking else { return }
        isAsking = asking
        let oldFrame = panel.frame
        let newSize = asking ? askingSize : compactSize
        var origin = oldFrame.origin
        if asking, let visibleFrame = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            origin.x = min(origin.x, visibleFrame.maxX - newSize.width - 8)
            origin.y = min(origin.y, visibleFrame.maxY - newSize.height - 8)
            origin.x = max(origin.x, visibleFrame.minX + 8)
            origin.y = max(origin.y, visibleFrame.minY + 8)
        } else if !asking, oldFrame.maxX > (panel.screen?.visibleFrame.maxX ?? oldFrame.maxX) {
            origin.x = max(origin.x, oldFrame.maxX - newSize.width)
        }
        panel.setFrame(NSRect(origin: origin, size: newSize), display: true, animate: false)
        panel.orderFrontRegardless()
    }

    func snapNow() {
        guard let screen = targetScreen() else { return }
        let origin = PetGeometry.snappedOrigin(
            proposed: panel.frame.origin,
            panelSize: panel.frame.size,
            visibleFrame: screen.visibleFrame,
            inset: 8,
            snapDistance: 96
        )
        panel.setFrameOrigin(origin)
        savePosition(origin)
    }

    func windowDidMove(_ notification: Notification) {
        snapWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.snapNow()
        }
        snapWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: workItem)
    }

    private func targetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        let frames = screens.map(\.visibleFrame)
        guard let frame = PetGeometry.screenContaining(origin: panel.frame.origin, panelSize: panel.frame.size, screens: frames) else {
            return NSScreen.main ?? screens.first
        }
        return screens.first(where: { $0.visibleFrame == frame }) ?? NSScreen.main ?? screens.first
    }

    private func restoredOrigin(on visibleFrame: CGRect) -> CGPoint {
        if let stored = PetPositionStore.load(),
           let screen = PetGeometry.screenContaining(origin: stored, panelSize: compactSize, screens: NSScreen.screens.map(\.visibleFrame)) {
            return PetGeometry.clampedOrigin(proposed: stored, panelSize: compactSize, visibleFrame: screen, inset: 8)
        }
        return CGPoint(
            x: visibleFrame.maxX - compactSize.width - 24,
            y: visibleFrame.minY + 34
        )
    }

    private func savePosition(_ origin: CGPoint) {
        PetPositionStore.save(origin)
        coordinator?.panelDidMove(to: origin)
    }
}

private enum PetPositionStore {
    private static let key = "PromptStudio.petPosition"

    static func load(userDefaults: UserDefaults = .standard) -> CGPoint? {
        guard let data = userDefaults.data(forKey: key),
              let value = try? JSONDecoder().decode(PetCaptureRequest.ScreenPoint.self, from: data) else {
            return nil
        }
        return value.cgPoint
    }

    static func save(_ point: CGPoint, userDefaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(PetCaptureRequest.ScreenPoint(point)) else { return }
        userDefaults.set(data, forKey: key)
    }
}
