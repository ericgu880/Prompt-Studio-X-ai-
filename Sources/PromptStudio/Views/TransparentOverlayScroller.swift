import AppKit

final class HoverRevealScrollView: NSScrollView {
    private var revealTrackingArea: NSTrackingArea?
    private var isPointerInside = false
    private var isDraggingScroller = false
    private var revealOnHover = false

    func setRevealScrollerOnHover(_ enabled: Bool) {
        autohidesScrollers = !enabled
        guard revealOnHover != enabled else {
            applyScrollerVisibility()
            return
        }

        revealOnHover = enabled
        applyScrollerVisibility()
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let revealTrackingArea {
            removeTrackingArea(revealTrackingArea)
            self.revealTrackingArea = nil
        }
        guard revealOnHover else { return }

        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        revealTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard revealOnHover else { return }
        isPointerInside = true
        showScroller()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard revealOnHover else { return }
        isPointerInside = false
        hideScrollerIfIdle()
    }

    override func scrollWheel(with event: NSEvent) {
        if revealOnHover && isPointerInside {
            showScroller()
        }
        super.scrollWheel(with: event)
        if revealOnHover && !isPointerInside {
            hideScrollerIfIdle()
        }
    }

    func beginScrollerDrag() {
        guard revealOnHover else { return }
        isDraggingScroller = true
        showScroller()
    }

    func endScrollerDrag() {
        guard revealOnHover else { return }
        isDraggingScroller = false
        if !isPointerInside {
            hideScrollerIfIdle()
        }
    }

    private func showScroller() {
        verticalScroller?.alphaValue = 1
        verticalScroller?.needsDisplay = true
    }

    private func hideScrollerIfIdle() {
        guard revealOnHover, !isPointerInside, !isDraggingScroller else { return }
        verticalScroller?.alphaValue = 0
        verticalScroller?.needsDisplay = true
    }

    private func applyScrollerVisibility() {
        if revealOnHover {
            verticalScroller?.alphaValue = (isPointerInside || isDraggingScroller) ? 1 : 0
        } else {
            verticalScroller?.alphaValue = 1
        }
        verticalScroller?.needsDisplay = true
    }
}

final class TransparentOverlayScroller: NSScroller {
    override func mouseDown(with event: NSEvent) {
        let scrollView = enclosingHoverRevealScrollView
        scrollView?.beginScrollerDrag()
        defer { scrollView?.endScrollerDrag() }
        super.mouseDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawKnob()
    }

    override func drawKnob() {
        let knobRect = rect(for: .knob)
        guard knobRect.height > 0 else { return }

        let knobWidth: CGFloat = 6
        let knobX = knobRect.midX - knobWidth / 2
        let visibleKnobRect = NSRect(
            x: knobX,
            y: knobRect.minY,
            width: knobWidth,
            height: knobRect.height
        )

        NSColor(calibratedWhite: 0.34, alpha: 0.62).setFill()
        NSBezierPath(
            roundedRect: visibleKnobRect,
            xRadius: knobWidth / 2,
            yRadius: knobWidth / 2
        ).fill()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    private var enclosingHoverRevealScrollView: HoverRevealScrollView? {
        var current = superview
        while let view = current {
            if let scrollView = view as? HoverRevealScrollView {
                return scrollView
            }
            current = view.superview
        }
        return nil
    }
}
