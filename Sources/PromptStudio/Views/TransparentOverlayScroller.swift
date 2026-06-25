import AppKit

@MainActor
private final class ScrollRevealRegistry {
    static let shared = ScrollRevealRegistry()

    private let scrollViews = NSHashTable<HoverRevealScrollView>.weakObjects()
    private var eventMonitor: Any?
    private var syncTimer: Timer?
    private weak var activeScrollView: HoverRevealScrollView?
    private weak var draggingScrollView: HoverRevealScrollView?

    func register(_ scrollView: HoverRevealScrollView) {
        scrollViews.add(scrollView)
        scrollView.window?.acceptsMouseMovedEvents = true
        installEventMonitorIfNeeded()
        installSyncTimerIfNeeded()
    }

    func unregister(_ scrollView: HoverRevealScrollView) {
        scrollViews.remove(scrollView)
        if isActive(scrollView) {
            activeScrollView = nil
        }
        if isDragging(scrollView) {
            draggingScrollView = nil
        }
        guard scrollViews.allObjects.isEmpty else { return }
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
        syncTimer?.invalidate()
        syncTimer = nil
    }

    func syncRegisteredWindows() {
        let windows = Set(scrollViews.allObjects.compactMap(\.window))
        for window in windows {
            syncWithCurrentMouseLocation(in: window)
        }
    }

    func hideOthers(than activeScrollView: HoverRevealScrollView) {
        for scrollView in scrollViews.allObjects where scrollView !== activeScrollView {
            scrollView.forceHideScroller()
        }
    }

    func syncAfterDrag(window: NSWindow?, windowPoint: NSPoint) {
        guard let window else { return }
        if let draggingScrollView, draggingScrollView.window === window {
            self.draggingScrollView = nil
        }
        syncWithCurrentMouseLocation(in: window)
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            ScrollRevealRegistry.shared.syncWithCurrentMouseLocation(in: window)
        }
    }

    private func installSyncTimerIfNeeded() {
        guard syncTimer == nil else { return }
        let timer = Timer(timeInterval: 0.08, repeats: true) { _ in
            MainActor.assumeIsolated {
                ScrollRevealRegistry.shared.syncRegisteredWindows()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        syncTimer = timer
    }

    func sync(window: NSWindow?, windowPoint: NSPoint) {
        guard let window else { return }
        clearStaleDragLockIfNeeded()

        let visibleScrollViews = scrollViews(in: window)
        let nextActive = draggingScrollView ?? resolveActiveScrollView(
            in: window,
            windowPoint: windowPoint,
            candidates: visibleScrollViews
        )
        activeScrollView = nextActive

        for scrollView in visibleScrollViews {
            scrollView.syncPointerState(
                windowPoint: windowPoint,
                isActive: scrollView === nextActive
            )
        }
    }

    func isActive(_ scrollView: HoverRevealScrollView) -> Bool {
        activeScrollView === scrollView
    }

    private func isDragging(_ scrollView: HoverRevealScrollView) -> Bool {
        draggingScrollView === scrollView
    }

    private func clearStaleDragLockIfNeeded() {
        guard let draggingScrollView,
              (NSEvent.pressedMouseButtons & 1) == 0 else { return }
        draggingScrollView.clearScrollerDragState()
        self.draggingScrollView = nil
    }

    func beginDrag(_ scrollView: HoverRevealScrollView) {
        activeScrollView = scrollView
        draggingScrollView = scrollView
        hideOthers(than: scrollView)
    }

    func endDrag(_ scrollView: HoverRevealScrollView, window: NSWindow?, windowPoint: NSPoint) {
        if draggingScrollView === scrollView {
            draggingScrollView = nil
        }
        syncAfterDrag(window: window, windowPoint: windowPoint)
    }

    private func installEventMonitorIfNeeded() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .leftMouseUp, .leftMouseDown, .scrollWheel]
        ) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window = event.window else { return event }
        switch event.type {
        case .mouseMoved, .leftMouseDragged, .leftMouseUp, .scrollWheel:
            sync(window: window, windowPoint: event.locationInWindow)
            return event
        case .leftMouseDown:
            sync(window: window, windowPoint: event.locationInWindow)
            guard let targetScrollView = scrollerDragTarget(
                in: window,
                windowPoint: event.locationInWindow
            ) else {
                return event
            }
            if targetScrollView.handleScrollerMouseDown(with: event) {
                return nil
            }
            return event
        default:
            return event
        }
    }

    func scrollerDragTarget(in window: NSWindow, windowPoint: NSPoint) -> HoverRevealScrollView? {
        clearStaleDragLockIfNeeded()
        let candidates = scrollViews(in: window).filter { scrollView in
            scrollView.isRevealScrollerVisible && scrollView.containsScrollerHitArea(windowPoint: windowPoint)
        }

        if let activeScrollView,
           candidates.contains(where: { $0 === activeScrollView }) {
            return activeScrollView
        }

        return bestScrollView(from: candidates, rect: { $0.knobHitRectInWindow })
    }

    private func scrollViews(in window: NSWindow) -> [HoverRevealScrollView] {
        scrollViews.allObjects.filter { scrollView in
            scrollView.window === window && scrollView.canRevealScroller
        }
    }

    private func resolveActiveScrollView(
        in window: NSWindow,
        windowPoint: NSPoint,
        candidates: [HoverRevealScrollView]
    ) -> HoverRevealScrollView? {
        if let visibleOwner = bestScrollView(
            from: candidates.filter { $0.containsVisibleArea(windowPoint: windowPoint) },
            rect: { $0.visibleAreaInWindow }
        ) {
            return visibleOwner
        }

        return bestScrollView(
            from: candidates.filter { $0.containsScrollerHitArea(windowPoint: windowPoint) },
            rect: { $0.knobHitRectInWindow }
        )
    }

    private func bestScrollView(
        from candidates: [HoverRevealScrollView],
        rect: (HoverRevealScrollView) -> NSRect
    ) -> HoverRevealScrollView? {
        candidates.sorted { lhs, rhs in
            let lhsRect = rect(lhs)
            let rhsRect = rect(rhs)
            let lhsArea = lhsRect.width * lhsRect.height
            let rhsArea = rhsRect.width * rhsRect.height
            if lhsArea != rhsArea {
                return lhsArea < rhsArea
            }
            if lhsRect.minX != rhsRect.minX {
                return lhsRect.minX < rhsRect.minX
            }
            return lhsRect.minY < rhsRect.minY
        }.first
    }

    private func syncWithCurrentMouseLocation(in window: NSWindow) {
        let screenPoint = NSEvent.mouseLocation
        guard window.frame.contains(screenPoint) else {
            let outsidePoint = NSPoint(
                x: CGFloat.greatestFiniteMagnitude,
                y: CGFloat.greatestFiniteMagnitude
            )
            sync(window: window, windowPoint: outsidePoint)
            return
        }
        sync(window: window, windowPoint: window.convertPoint(fromScreen: screenPoint))
    }
}

final class HoverRevealScrollView: NSScrollView {
    private var revealTrackingArea: NSTrackingArea?
    private var isPointerInside = false
    private var isPointerOverScroller = false
    private var isDraggingScroller = false
    private var suppressKnobHoverUntilPointerLeaves = false
    private var revealOnHover = false

    var canRevealScroller: Bool {
        revealOnHover && window != nil && !isHiddenOrHasHiddenAncestor
    }

    var visibleAreaInWindow: NSRect {
        guard canRevealScroller else { return .zero }
        return contentView.convert(contentView.bounds, to: nil)
    }

    var knobHitRectInWindow: NSRect {
        guard canRevealScroller,
              let scroller = verticalScroller as? TransparentOverlayScroller else { return .zero }
        return convert(scrollerHitRect(for: scroller), to: nil)
    }

    var isRevealScrollerVisible: Bool {
        guard canRevealScroller else { return false }
        return (verticalScroller?.alphaValue ?? 0) > 0.01
    }

    func setRevealScrollerOnHover(_ enabled: Bool) {
        autohidesScrollers = !enabled
        guard revealOnHover != enabled else {
            applyScrollerVisibility()
            return
        }

        revealOnHover = enabled
        if enabled {
            ScrollRevealRegistry.shared.register(self)
        } else {
            ScrollRevealRegistry.shared.unregister(self)
            isPointerOverScroller = false
            (verticalScroller as? TransparentOverlayScroller)?.setKnobHover(false)
        }
        applyScrollerVisibility()
        updateTrackingAreas()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard revealOnHover else { return }
        if window == nil {
            ScrollRevealRegistry.shared.unregister(self)
        } else {
            ScrollRevealRegistry.shared.register(self)
            window?.acceptsMouseMovedEvents = true
        }
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
        ScrollRevealRegistry.shared.sync(window: window, windowPoint: event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard revealOnHover else { return }
        ScrollRevealRegistry.shared.sync(window: window, windowPoint: event.locationInWindow)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard revealOnHover else { return }
        ScrollRevealRegistry.shared.sync(window: window, windowPoint: event.locationInWindow)
    }

    override func scrollWheel(with event: NSEvent) {
        if revealOnHover {
            ScrollRevealRegistry.shared.sync(window: window, windowPoint: event.locationInWindow)
        }
        super.scrollWheel(with: event)
    }

    func beginScrollerDrag() {
        guard revealOnHover else { return }
        isDraggingScroller = true
        ScrollRevealRegistry.shared.beginDrag(self)
        setScrollerHover(true)
        showScroller()
    }

    func endScrollerDrag(window: NSWindow?, windowPoint: NSPoint) {
        guard revealOnHover else { return }
        clearScrollerDragState()
        ScrollRevealRegistry.shared.endDrag(self, window: window, windowPoint: windowPoint)
    }

    func clearScrollerDragState() {
        isDraggingScroller = false
        isPointerOverScroller = false
        suppressKnobHoverUntilPointerLeaves = true
        (verticalScroller as? TransparentOverlayScroller)?.setKnobHover(false)
        verticalScroller?.needsDisplay = true
    }

    func updateScrollerHoverFromScroller(_ isHovering: Bool) {
        guard revealOnHover else { return }
        setScrollerHover(isHovering)
    }

    func handleScrollerMouseDown(with event: NSEvent) -> Bool {
        guard revealOnHover,
              ScrollRevealRegistry.shared.isActive(self),
              containsScrollerHitArea(windowPoint: event.locationInWindow),
              let scroller = verticalScroller as? TransparentOverlayScroller,
              scroller.alphaValue > 0.01 else {
            return false
        }
        scroller.handleKnobDrag(with: event, in: self)
        return true
    }

    func containsVisibleArea(windowPoint: NSPoint) -> Bool {
        visibleAreaInWindow.contains(windowPoint)
    }

    func containsInteractionArea(windowPoint: NSPoint) -> Bool {
        containsVisibleArea(windowPoint: windowPoint) || containsScrollerHitArea(windowPoint: windowPoint)
    }

    func containsVisibleScrollerKnob(windowPoint: NSPoint) -> Bool {
        guard let scroller = verticalScroller as? TransparentOverlayScroller,
              scroller.alphaValue > 0.01 else { return false }
        let point = convert(windowPoint, from: nil)
        return scrollerHitRect(for: scroller).contains(point)
    }

    func containsScrollerHitArea(windowPoint: NSPoint) -> Bool {
        knobHitRectInWindow.contains(windowPoint)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if revealOnHover,
           let scroller = verticalScroller as? TransparentOverlayScroller,
           scroller.alphaValue > 0.01,
           ScrollRevealRegistry.shared.isActive(self),
           containsScrollerHitArea(windowPoint: convert(point, to: nil)) {
            return scroller
        }
        return super.hitTest(point)
    }

    func syncPointerState(windowPoint: NSPoint, isActive: Bool) {
        guard revealOnHover else { return }
        let isPointerInKnob = containsScrollerHitArea(windowPoint: windowPoint)
        if suppressKnobHoverUntilPointerLeaves && !isPointerInKnob {
            suppressKnobHoverUntilPointerLeaves = false
        }
        isPointerInside = isActive && containsVisibleArea(windowPoint: windowPoint)
        isPointerOverScroller = isActive && isPointerInKnob && !suppressKnobHoverUntilPointerLeaves
        (verticalScroller as? TransparentOverlayScroller)?.setKnobHover(isPointerOverScroller)
        if isPointerInside || isPointerOverScroller || isDraggingScroller {
            showScroller()
        } else {
            forceHideScroller()
        }
    }

    func forceHideScroller() {
        guard revealOnHover else { return }
        isPointerInside = false
        isPointerOverScroller = false
        isDraggingScroller = false
        suppressKnobHoverUntilPointerLeaves = false
        verticalScroller?.alphaValue = 0
        (verticalScroller as? TransparentOverlayScroller)?.setKnobHover(false)
        verticalScroller?.needsDisplay = true
    }

    private func scrollerHitRect(for scroller: TransparentOverlayScroller) -> NSRect {
        convert(scroller.visibleKnobHitRect, from: scroller)
    }

    private func scrollerHitRect() -> NSRect {
        guard let scroller = verticalScroller as? TransparentOverlayScroller else { return .zero }
        return scrollerHitRect(for: scroller)
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

    private func applyScrollerVisibility() {
        if revealOnHover {
            verticalScroller?.alphaValue = (isPointerInside || isPointerOverScroller || isDraggingScroller) ? 1 : 0
        } else {
            verticalScroller?.alphaValue = 1
        }
        verticalScroller?.needsDisplay = true
    }

    deinit {}
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
        if let window {
            ScrollRevealRegistry.shared.sync(window: window, windowPoint: event.locationInWindow)
        } else {
            setKnobHover(false)
            enclosingHoverRevealScrollView?.updateScrollerHoverFromScroller(false)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let window,
              let scrollView = ScrollRevealRegistry.shared.scrollerDragTarget(
                in: window,
                windowPoint: event.locationInWindow
              ),
              scrollView.verticalScroller === self else { return }
        handleKnobDrag(with: event, in: scrollView)
    }

    func handleKnobDrag(with event: NSEvent, in preferredScrollView: HoverRevealScrollView?) {
        guard let scrollView = preferredScrollView ?? enclosingHoverRevealScrollView,
              scrollView.verticalScroller === self,
              visibleKnobHitRect.contains(convert(event.locationInWindow, from: nil)),
              let window,
              let documentView = scrollView.documentView else { return }

        let viewportHeight = scrollView.contentView.bounds.height
        let documentHeight = documentView.bounds.height
        let maxOffset = max(0, documentHeight - viewportHeight)
        guard maxOffset > 0 else { return }

        scrollView.beginScrollerDrag()
        var lastWindowPoint = event.locationInWindow
        defer { scrollView.endScrollerDrag(window: window, windowPoint: lastWindowPoint) }

        setKnobHover(true)
        let startPoint = scrollView.convert(event.locationInWindow, from: nil)
        let startOffset = scrollView.contentView.bounds.origin.y
        let knobHeight = max(1, rect(for: .knob).height)
        let trackTravel = max(1, bounds.height - knobHeight)

        while let nextEvent = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            guard nextEvent.type == .leftMouseDragged || nextEvent.type == .leftMouseUp else { continue }
            lastWindowPoint = nextEvent.locationInWindow
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
        if let window {
            ScrollRevealRegistry.shared.sync(window: window, windowPoint: event.locationInWindow)
        } else {
            let isHovering = visibleKnobHitRect.contains(convert(event.locationInWindow, from: nil))
            setKnobHover(isHovering)
            enclosingHoverRevealScrollView?.updateScrollerHoverFromScroller(isHovering)
        }
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
