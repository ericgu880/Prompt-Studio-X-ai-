import Foundation
import CoreGraphics

/// Stores layout attributes in Y-sorted per-column buckets for viewport queries.
///
/// The layout assigns entries in placement order, so each column is already sorted
/// by `frame.minY`. A query binary-searches the first entry whose bottom edge is
/// below the query's top edge, then scans only the possible vertical overlap.
/// Results are restored to placement order so callers retain the collection view's
/// existing drag and prefetch ordering semantics.
struct MasonryVisibleAttributeIndex<Value> {
    struct Entry {
        let value: Value
        let frame: CGRect
        let order: Int

        var minY: CGFloat { frame.minY }
        var maxY: CGFloat { frame.maxY }
    }

    private(set) var columns: [[Entry]] = []

    mutating func reset(columnCount: Int) {
        columns = Array(repeating: [], count: max(0, columnCount))
    }

    mutating func append(
        _ value: Value,
        frame: CGRect,
        order: Int,
        toColumn column: Int
    ) {
        guard columns.indices.contains(column) else { return }
        let entry = Entry(value: value, frame: frame, order: order)
        // Masonry placement appends monotonically increasing Y values per column.
        // Keep this assertion local so an accidental future placement regression is
        // caught during development without changing release behavior.
        assert(columns[column].last.map { $0.minY <= entry.minY } ?? true)
        columns[column].append(entry)
    }

    func entriesIntersecting(_ rect: CGRect) -> [Entry] {
        guard !rect.isNull, !rect.isEmpty else { return [] }

        var matches: [Entry] = []
        for column in columns {
            let firstPossibleIndex = firstIndex(withMaxYAbove: rect.minY, in: column)
            var index = firstPossibleIndex
            while index < column.count {
                let entry = column[index]
                // Since entries are sorted by minY, no later item can intersect.
                if entry.minY >= rect.maxY {
                    break
                }
                if entry.frame.intersects(rect) {
                    matches.append(entry)
                }
                index += 1
            }
        }

        // Per-column scanning is the fast path, while this stable merge preserves
        // the prior placement-order result expected by selection and prefetch code.
        matches.sort { lhs, rhs in
            lhs.order < rhs.order
        }
        return matches
    }

    private func firstIndex(withMaxYAbove minimumY: CGFloat, in column: [Entry]) -> Int {
        var lowerBound = 0
        var upperBound = column.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if column[middle].maxY > minimumY {
                upperBound = middle
            } else {
                lowerBound = middle + 1
            }
        }
        return lowerBound
    }
}
