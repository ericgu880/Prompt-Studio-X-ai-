import AppKit
import PromptStudioCore
import SwiftUI

@MainActor
final class NativeMarqueeCollectionView: NSCollectionView {
    var onBlankClick: (() -> Void)?
    var onMarqueeBegin: ((CGPoint, Bool) -> Void)?
    var onMarqueeChange: ((CGRect) -> Void)?
    var onMarqueeEnd: (() -> Void)?
    var onMarqueeCancel: (() -> Void)?

    private let marqueeOverlay = MarqueeOverlayView(frame: .zero)
    private var startPoint: CGPoint?
    private var isMarqueeActive = false
    private var ignoreUntilMouseUp = false
    private let threshold: CGFloat = 4

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// NSCollectionView can keep returning itself for a point inside an item
    /// when its marquee overlay is installed above the item views. Summary
    /// cards own a sibling native event view, so route attached hit-tests to
    /// that overlay before falling back to collection-level blank selection.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let eventView = summaryEventView(at: point) {
            return eventView
        }
        return super.hitTest(point)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if marqueeOverlay.superview == nil {
            addSubview(marqueeOverlay, positioned: .above, relativeTo: nil)
        }
        if window == nil { finish(cancelled: false) }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard event.buttonNumber == 0, !hasItem(at: point) else {
            super.mouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        startPoint = point
        ignoreUntilMouseUp = false
        isMarqueeActive = false
        onMarqueeBegin?(point, event.modifierFlags.contains(.command))
    }

    override func mouseDragged(with event: NSEvent) {
        guard !ignoreUntilMouseUp, let startPoint else {
            if !ignoreUntilMouseUp { super.mouseDragged(with: event) }
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if !isMarqueeActive, hypot(point.x - startPoint.x, point.y - startPoint.y) >= threshold {
            isMarqueeActive = true
        }
        guard isMarqueeActive else { return }
        let rect = MarqueeSelectionResolver.normalizedRect(from: startPoint, to: point)
        marqueeOverlay.frame = rect
        marqueeOverlay.isHidden = false
        onMarqueeChange?(rect)
    }

    override func mouseUp(with event: NSEvent) {
        defer { clearGesture() }
        guard startPoint != nil else {
            super.mouseUp(with: event)
            return
        }
        if isMarqueeActive { onMarqueeEnd?() }
        else if !ignoreUntilMouseUp { onBlankClick?() }
    }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 53, startPoint != nil else {
            super.keyDown(with: event)
            return
        }
        ignoreUntilMouseUp = true
        finish(cancelled: true)
    }

    func finishMarqueeForDatasetChange() { finish(cancelled: false) }

    private func finish(cancelled: Bool) {
        guard startPoint != nil else { return }
        if isMarqueeActive {
            if cancelled { onMarqueeCancel?() } else { onMarqueeEnd?() }
        }
        clearGesture()
    }

    private func clearGesture() {
        marqueeOverlay.isHidden = true
        marqueeOverlay.frame = .zero
        startPoint = nil
        isMarqueeActive = false
    }

    private func hasItem(at point: CGPoint) -> Bool {
        collectionViewLayout?.layoutAttributesForElements(
            in: CGRect(origin: point, size: CGSize(width: 1, height: 1))
        ).contains(where: { $0.representedElementCategory == .item }) == true
    }

    private func summaryEventView(at point: NSPoint) -> SummaryCardEventView? {
        for itemView in subviews.reversed() {
            guard itemView !== marqueeOverlay,
                  !itemView.isHidden,
                  itemView.alphaValue > 0,
                  itemView.frame.contains(point) else { continue }
            let itemPoint = itemView.convert(point, from: self)
            if let eventView = descendantSummaryEventView(in: itemView, point: itemPoint) {
                return eventView
            }
        }
        return nil
    }

    private func descendantSummaryEventView(in view: NSView, point: NSPoint) -> SummaryCardEventView? {
        if let eventView = view as? SummaryCardEventView, eventView.bounds.contains(point) {
            return eventView
        }
        for child in view.subviews.reversed() {
            guard !child.isHidden,
                  child.alphaValue > 0,
                  child.frame.contains(point) else { continue }
            let childPoint = child.convert(point, from: view)
            if let eventView = descendantSummaryEventView(in: child, point: childPoint) {
                return eventView
            }
        }
        return nil
    }
}

private final class MarqueeOverlayView: NSView {
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let accent = NSColor(StudioColor.primaryAction)
        layer?.backgroundColor = accent.withAlphaComponent(0.16).cgColor
        layer?.borderColor = accent.withAlphaComponent(0.72).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 8
        layer?.zPosition = 10_000
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
