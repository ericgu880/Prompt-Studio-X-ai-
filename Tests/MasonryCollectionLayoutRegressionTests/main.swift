import Foundation

private struct DeterministicRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func nextUInt64() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1
        return state
    }

    mutating func nextInt(in range: ClosedRange<Int>) -> Int {
        let width = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(nextUInt64() % width)
    }

    mutating func nextCGFloat(in range: ClosedRange<CGFloat>) -> CGFloat {
        let fraction = CGFloat(nextUInt64() % 1_000_001) / 1_000_000
        return range.lowerBound + (range.upperBound - range.lowerBound) * fraction
    }
}

private struct TestAttribute: Equatable {
    let id: Int
}

private enum RegressionFailure: Error, CustomStringConvertible {
    case mismatch(caseIndex: Int, expected: [Int], actual: [Int])
    case unsortedColumn(column: Int, previousY: CGFloat, currentY: CGFloat)

    var description: String {
        switch self {
        case let .mismatch(caseIndex, expected, actual):
            return "case \(caseIndex) mismatch: expected \(expected), got \(actual)"
        case let .unsortedColumn(column, previousY, currentY):
            return "column \(column) is not Y-sorted: \(previousY) > \(currentY)"
        }
    }
}

@main
private struct MasonryCollectionLayoutRegressionTests {
    static func main() throws {
        var random = DeterministicRandom(seed: 0x4D41534F4E525931)
        let caseCount = 15_000

        for caseIndex in 0..<caseCount {
            let columnCount = random.nextInt(in: 0...8)
            let itemCount = random.nextInt(in: 0...320)
            let itemWidth = random.nextCGFloat(in: 80...360)
            let spacing = random.nextCGFloat(in: 4...24)
            var columnHeights = Array(repeating: CGFloat.zero, count: columnCount)
            var frames: [CGRect] = []
            var values: [TestAttribute] = []
            var index = MasonryVisibleAttributeIndex<TestAttribute>()
            index.reset(columnCount: columnCount)

            for itemIndex in 0..<itemCount {
                guard columnCount > 0 else { break }
                let column = shortestColumnIndex(in: columnHeights)
                let height = random.nextCGFloat(in: 8...320)
                let frame = CGRect(
                    x: CGFloat(column) * (itemWidth + spacing),
                    y: columnHeights[column],
                    width: itemWidth,
                    height: height
                )
                let value = TestAttribute(id: itemIndex)
                index.append(value, frame: frame, order: itemIndex, toColumn: column)
                frames.append(frame)
                values.append(value)
                columnHeights[column] += height + spacing
            }

            for (columnIndex, column) in index.columns.enumerated() {
                for pair in zip(column, column.dropFirst()) where pair.0.minY > pair.1.minY {
                    throw RegressionFailure.unsortedColumn(
                        column: columnIndex,
                        previousY: pair.0.minY,
                        currentY: pair.1.minY
                    )
                }
            }

            let query = CGRect(
                x: random.nextCGFloat(in: -itemWidth...itemWidth * 8),
                y: random.nextCGFloat(in: -500...max(500, columnHeights.max() ?? 0)),
                width: random.nextCGFloat(in: 0...itemWidth * 2.5),
                height: random.nextCGFloat(in: 0...520)
            )
            let expected = zip(values, frames)
                .filter { $0.1.intersects(query) }
                .map(\.0.id)
            let actual = index.entriesIntersecting(query).map(\.value.id)
            guard actual == expected else {
                throw RegressionFailure.mismatch(caseIndex: caseIndex, expected: expected, actual: actual)
            }
        }

        print("MasonryCollectionLayout randomized regression passed (\(caseCount) layouts/rects)")
    }

    private static func shortestColumnIndex(in heights: [CGFloat]) -> Int {
        heights.indices.min { lhs, rhs in
            if heights[lhs] == heights[rhs] {
                return lhs < rhs
            }
            return heights[lhs] < heights[rhs]
        } ?? 0
    }
}
