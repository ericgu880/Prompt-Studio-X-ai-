import AppKit

final class TransparentOverlayScroller: NSScroller {
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
}
