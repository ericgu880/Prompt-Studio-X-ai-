import Foundation

public enum MarqueeSelectionResolver {
    public static func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    public static func hitIDs(in selection: CGRect, itemFrames: [String: CGRect]) -> Set<String> {
        Set(itemFrames.compactMap { id, frame in
            selection.intersects(frame) ? id : nil
        })
    }

    public static func selection(base: Set<String>, hits: Set<String>, additive: Bool) -> Set<String> {
        additive ? base.union(hits) : hits
    }
}
