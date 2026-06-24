import AppKit

final class HoverRevealScrollView: NSScrollView {
    private var revealTrackingArea: NSTrackingArea?
    nonisolated(unsafe) private var revealEventMonitor: Any?
    private var isPointerInside = false
    private var isPointerOverScroller = false
    private var isDraggingScroller = false
    private var revealOnHover = false

    func setRevealScrollerOnHover(_ enabled: Bool) {
        autohidesScrollers = !enabled
        guard revealOnHover != enabled else {
            applyScrollerVisibility()
            return
        }

        revealOnHover = enabled
        if enabled {
            installRevealEventMonitor()
        } else {
            removeRevealEventMonitor()
            isPointerOverScroller = false
            (verticalScroller as? TransparentOverlayScroller)?.setKnobHover(false)
        }
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
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
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
        updateScrollerHover(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard revealOnHover else { return }
        isPointerInside = false
        if containsVisibleScrollerKnob(windowPoint: event.locationInWindow) {
            setScrollerHover(true)
            showScroller()
            return
        }
        setScrollerHover(false)
        hideScrollerIfIdle()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard revealOnHover else { return }
        updateScrollerHover(with: event)
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
        setScrollerHover(true)
        showScroller()
    }

    func endScrollerDrag() {
        guard revealOnHover else { return }
        isDraggingScroller = false
        if !isPointerInside && !isPointerOverScroller {
            hideScrollerIfIdle()
        }
    }

    func updateScrollerHoverFromScroller(_ isHovering: Bool) {
        guard revealOnHover else { return }
        setScrollerHover(isHovering)
    }

    func containsVisibleScrollerKnob(windowPoint: NSPoint) -> Bool {
        guard let scroller = verticalScroller as? TransparentOverlayScroller else { return false }
        let point = convert(windowPoint, from: nil)
        return scrollerHitRect(for: scroller).contains(point)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if revealOnHover,
           let scroller = verticalScroller as? TransparentOverlayScroller,
           scrollerHitRect(for: scroller).contains(point) {
            setScrollerHover(true)
            showScroller()
            return scroller
        }
        return super.hitTest(point)
    }

    private func updateScrollerHover(with event: NSEvent) {
        guard let scroller = verticalScroller as? TransparentOverlayScroller else {
            setScrollerHover(false)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        setScrollerHover(scrollerHitRect(for: scroller).contains(point))
    }

    private func scrollerHitRect(for scroller: TransparentOverlayScroller) -> NSRect {
        convert(scroller.visibleKnobHitRect, from: scroller)
    }

    private func installRevealEventMonitor() {
        guard revealEventMonitor == nil else { return }
        revealEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown]
        ) { [weak self] event in
            self?.handleRevealEvent(event) ?? event
        }
    }

    private func removeRevealEventMonitor() {
        if let revealEventMonitor {
            NSEvent.removeMonitor(revealEventMonitor)
            self.revealEventMonitor = nil
        }
    }

    private func handleRevealEvent(_ event: NSEvent) -> NSEvent? {
        guard revealOnHover, event.window === window else { return event }

        switch event.type {
        case .mouseMoved:
            let point = convert(event.locationInWindow, from: nil)
            if containsVisibleScrollerKnob(windowPoint: event.locationInWindow) {
                setScrollerHover(true)
            } else if !bounds.contains(point) {
                isPointerInside = false
                setScrollerHover(false)
                hideScrollerIfIdle()
            }
            return event

        case .leftMouseDown:
            guard containsVisibleScrollerKnob(windowPoint: event.locationInWindow),
                  let scroller = verticalScroller as? TransparentOverlayScroller else {
                return event
            }
            scroller.handleKnobDrag(with: event, in: self)
            return nil

        default:
            return event
        }
    }

    private func setScrollerHover(_ isHovering: Bool) {
        guard isPointerOverScroller != isHovering else { return }
        isPointerOverScroller = isHovering
        (verticalScroller as? TransparentOverlayScroller)?.setKnobHover(isHovering)
        if isHovering {
            showScroller()
        }
    }

    private func showScroller() {
        verticalScroller?.alphaValue = 1
        verticalScroller?.needsDisplay = true
    }

    private func hideScrollerIfIdle() {
        guard revealOnHover, !isPointerInside, !isPointerOverScroller, !isDraggingScroller else { return }
        verticalScroller?.alphaValue = 0
        verticalScroller?.needsDisplay = true
    }

    private func applyScrollerVisibility() {
        if revealOnHover {
            verticalScroller?.alphaValue = (isPointerInside || isPointerOverScroller || isDraggingScroller) ? 1 : 0
        } else {
            verticalScroller?.alphaValue = 1
        }
        verticalScroller?.needsDisplay = true
    }

    deinit {
        if let revealEventMonitor {
            NSEvent.removeMonitor(revealEventMonitor)
        }
    }
}

final class TransparentOverlayScroller: NSScroller {
    private static let knobWidth: CGFloat = 6
    private static let knobHorizontalHitOutset: CGFloat = 6
    private static let knobVerticalHitOutset: CGFloat = 2

    private var hoverTrackingArea: NSTrackingArea?
    private var isKnobHovered = false

    var visibleKnobHitRect: NSRect {
        let knobRect = rect(for: .knob)
        guard knobRect.height > 0 else { return .zero }

        let hitWidth = Self.knobWidth + Self.knobHorizontalHitOutset * 2
        let hitHeight = knobRect.height + Self.knobVerticalHitOutset * 2
        return NSRect(
            x: knobRect.midX - hitWidth / 2,
            y: knobRect.minY - Self.knobVerticalHitOutset,
            width: hitWidth,
            height: hitHeight
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
            self.hoverTrackingArea = nil
        }

        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHover(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setKnobHover(false)
        enclosingHoverRevealScrollView?.updateScrollerHoverFromScroller(false)
    }

    override func mouseDown(with event: NSEvent) {
        handleKnobDrag(with: event, in: nil)
    }

    func handleKnobDrag(with event: NSEvent, in preferredScrollView: HoverRevealScrollView?) {
        guard let scrollView = preferredScrollView ?? enclosingHoverRevealScrollView,
              visibleKnobHitRect.contains(convert(event.locationInWindow, from: nil)) ||
              scrollView.containsVisibleScrollerKnob(windowPoint: event.locationInWindow),
              let window,
              let documentView = scrollView.documentView else { return }

        let viewportHeight = scrollView.contentView.bounds.height
        let documentHeight = documentView.bounds.height
        let maxOffset = max(0, documentHeight - viewportHeight)
        guard maxOffset > 0 else { return }

        scrollView.beginScrollerDrag()
        defer { scrollView.endScrollerDrag() }

        setKnobHover(true)
        let startPoint = scrollView.convert(event.locationInWindow, from: nil)
        let startOffset = scrollView.contentView.bounds.origin.y
        let knobHeight = max(1, rect(for: .knob).height)
        let trackTravel = max(1, bounds.height - knobHeight)

        while let nextEvent = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            guard nextEvent.type == .leftMouseDragged || nextEvent.type == .leftMouseUp else { continue }
            if nextEvent.type == .leftMouseDragged {
                let currentPoint = scrollView.convert(nextEvent.locationInWindow, from: nil)
                let deltaY = currentPoint.y - startPoint.y
                let nextOffset = min(maxOffset, max(0, startOffset + deltaY / trackTravel * maxOffset))
                scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.origin.x, y: nextOffset))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
            if nextEvent.type == .leftMouseUp {
                break
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        drawKnob()
    }

    override func drawKnob() {
        let knobRect = rect(for: .knob)
        guard knobRect.height > 0 else { return }

        let knobWidth = Self.knobWidth
        let knobX = knobRect.midX - knobWidth / 2
        let visibleKnobRect = NSRect(
            x: knobX,
            y: knobRect.minY,
            width: knobWidth,
            height: knobRect.height
        )

        let color = isKnobHovered
            ? NSColor(calibratedWhite: 0.56, alpha: 0.82)
            : NSColor(calibratedWhite: 0.34, alpha: 0.62)
        color.setFill()
        NSBezierPath(
            roundedRect: visibleKnobRect,
            xRadius: knobWidth / 2,
            yRadius: knobWidth / 2
        ).fill()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    func setKnobHover(_ isHovered: Bool) {
        guard isKnobHovered != isHovered else { return }
        isKnobHovered = isHovered
        needsDisplay = true
    }

    private func updateHover(with event: NSEvent) {
        let isHovering = visibleKnobHitRect.contains(convert(event.locationInWindow, from: nil))
        setKnobHover(isHovering)
        enclosingHoverRevealScrollView?.updateScrollerHoverFromScroller(isHovering)
    }

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
