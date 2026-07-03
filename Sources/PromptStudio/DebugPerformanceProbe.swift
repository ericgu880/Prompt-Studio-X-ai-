import Foundation

final class DebugPerformanceProbe: @unchecked Sendable {
    static let shared = DebugPerformanceProbe()

    private struct Bucket {
        var samples = 0
        var total = 0.0
        var maxValue = 0.0
        var recent: [Double] = []
    }

    private let lock = NSLock()
    private var buckets: [String: Bucket] = [:]
    private let reportInterval = 50

    static var isEnabled: Bool {
        _isDebugAssertConfiguration()
    }

    static func now() -> Double {
        ProcessInfo.processInfo.systemUptime
    }

    static func record(_ name: String, value: Double = 1) {
        shared.record(name, value: value)
    }

    static func recordDuration(_ name: String, startedAt start: Double) {
        record(name, value: max(0, (now() - start) * 1_000))
    }

    private func record(_ name: String, value: Double) {
        guard Self.isEnabled else { return }

        lock.lock()
        var bucket = buckets[name] ?? Bucket()
        bucket.samples += 1
        bucket.total += value
        bucket.maxValue = max(bucket.maxValue, value)
        bucket.recent.append(value)
        if bucket.recent.count > reportInterval {
            bucket.recent.removeFirst(bucket.recent.count - reportInterval)
        }
        buckets[name] = bucket
        let shouldReport = bucket.samples % reportInterval == 0
        let reportBucket = bucket
        lock.unlock()

        guard shouldReport else { return }
        let average = reportBucket.total / Double(reportBucket.samples)
        let sorted = reportBucket.recent.sorted()
        let p95Index = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * 0.95)))
        let p95 = sorted.isEmpty ? 0 : sorted[p95Index]
        print("[PromptStudioPerf] \(name) samples=\(reportBucket.samples) avg=\(format(average)) p95=\(format(p95)) max=\(format(reportBucket.maxValue))")
    }

    private func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
