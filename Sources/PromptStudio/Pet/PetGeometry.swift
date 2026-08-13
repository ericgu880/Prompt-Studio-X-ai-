import AppKit

enum PetScreenEdge: String, Codable, Equatable, Sendable {
    case left
    case right
    case top
    case bottom
}

enum PetGeometry {
    /// Chromium exposes global screen coordinates from the primary display's
    /// top-left, while AppKit uses the primary display's bottom-left. Keeping
    /// the conversion in one place also makes displays above/below the primary
    /// screen work because their coordinates may be negative in either space.
    static func appKitPoint(
        fromBrowserScreenPoint point: PetCaptureRequest.ScreenPoint,
        primaryScreenMaxY: CGFloat
    ) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenMaxY - point.y)
    }

    static func browserScreenPoint(
        fromAppKitPoint point: CGPoint,
        primaryScreenMaxY: CGFloat
    ) -> PetCaptureRequest.ScreenPoint {
        .init(x: point.x, y: primaryScreenMaxY - point.y)
    }

    /// Places the compact pet directly beneath the browser drag origin. The
    /// pet is moved once when a drag begins, then stays put as a stable drop
    /// target rather than chasing the pointer.
    static func originBelowBrowserPoint(
        _ browserPoint: PetCaptureRequest.ScreenPoint,
        panelSize: CGSize,
        visibleFrame: CGRect,
        primaryScreenMaxY: CGFloat,
        gap: CGFloat = 14,
        inset: CGFloat = 8
    ) -> CGPoint {
        let point = appKitPoint(
            fromBrowserScreenPoint: browserPoint,
            primaryScreenMaxY: primaryScreenMaxY
        )
        return clampedOrigin(
            proposed: CGPoint(
                x: point.x - panelSize.width / 2,
                y: point.y - panelSize.height - gap
            ),
            panelSize: panelSize,
            visibleFrame: visibleFrame,
            inset: inset
        )
    }

    /// Browser drag events stop receiving reliable screen coordinates once
    /// the pointer leaves the browser window. Preview motion can use the
    /// reported browser point, but the terminal drop must use AppKit's current
    /// global mouse location so dropping on the floating pet remains reliable.
    static func dragHitPoint(
        browserPoint: PetCaptureRequest.ScreenPoint?,
        currentMouseLocation: CGPoint,
        isFinalDrop: Bool,
        primaryScreenMaxY: CGFloat
    ) -> CGPoint? {
        if isFinalDrop {
            return currentMouseLocation
        }
        guard let browserPoint else { return nil }
        return appKitPoint(
            fromBrowserScreenPoint: browserPoint,
            primaryScreenMaxY: primaryScreenMaxY
        )
    }

    static func clampedOrigin(
        proposed: CGPoint,
        panelSize: CGSize,
        visibleFrame: CGRect,
        inset: CGFloat = 0
    ) -> CGPoint {
        let minX = visibleFrame.minX + inset
        let maxX = max(minX, visibleFrame.maxX - panelSize.width - inset)
        let minY = visibleFrame.minY + inset
        let maxY = max(minY, visibleFrame.maxY - panelSize.height - inset)
        return CGPoint(
            x: min(max(proposed.x, minX), maxX),
            y: min(max(proposed.y, minY), maxY)
        )
    }

    static func nearestEdge(
        origin: CGPoint,
        panelSize: CGSize,
        visibleFrame: CGRect,
        inset: CGFloat = 16
    ) -> PetScreenEdge {
        let clamped = clampedOrigin(proposed: origin, panelSize: panelSize, visibleFrame: visibleFrame)
        let distances = [
            (PetScreenEdge.left, abs(clamped.x - (visibleFrame.minX + inset))),
            (PetScreenEdge.right, abs(clamped.x - (visibleFrame.maxX - panelSize.width - inset))),
            (PetScreenEdge.bottom, abs(clamped.y - (visibleFrame.minY + inset))),
            (PetScreenEdge.top, abs(clamped.y - (visibleFrame.maxY - panelSize.height - inset)))
        ]
        return distances.min { lhs, rhs in lhs.1 < rhs.1 }?.0 ?? .right
    }

    static func snappedOrigin(
        proposed: CGPoint,
        panelSize: CGSize,
        visibleFrame: CGRect,
        inset: CGFloat = 16,
        snapDistance: CGFloat = 72
    ) -> CGPoint {
        let clamped = clampedOrigin(
            proposed: proposed,
            panelSize: panelSize,
            visibleFrame: visibleFrame,
            inset: inset
        )
        let leftX = visibleFrame.minX + inset
        let rightX = visibleFrame.maxX - panelSize.width - inset
        let bottomY = visibleFrame.minY + inset
        let topY = visibleFrame.maxY - panelSize.height - inset

        let candidates: [(PetScreenEdge, CGFloat, CGPoint)] = [
            (.left, abs(clamped.x - leftX), CGPoint(x: leftX, y: clamped.y)),
            (.right, abs(clamped.x - rightX), CGPoint(x: rightX, y: clamped.y)),
            (.bottom, abs(clamped.y - bottomY), CGPoint(x: clamped.x, y: bottomY)),
            (.top, abs(clamped.y - topY), CGPoint(x: clamped.x, y: topY))
        ]

        guard let nearest = candidates.min(by: { $0.1 < $1.1 }), nearest.1 <= snapDistance else {
            return clamped
        }
        return nearest.2
    }

    static func screenContaining(origin: CGPoint, panelSize: CGSize, screens: [CGRect]) -> CGRect? {
        let center = CGPoint(x: origin.x + panelSize.width / 2, y: origin.y + panelSize.height / 2)
        if let containing = screens.first(where: { $0.contains(center) }) {
            return containing
        }
        return screens.min { lhs, rhs in
            lhs.distance(to: center) < rhs.distance(to: center)
        }
    }
}

private extension CGRect {
    func distance(to point: CGPoint) -> CGFloat {
        let dx = max(minX - point.x, 0, point.x - maxX)
        let dy = max(minY - point.y, 0, point.y - maxY)
        return hypot(dx, dy)
    }
}
