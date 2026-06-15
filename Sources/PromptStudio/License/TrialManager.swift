import Foundation

struct TrialState: Equatable {
    let startedAt: Date
    let daysRemaining: Int
    var isActive: Bool { daysRemaining > 0 }
}

final class TrialManager {
    private let store: KeychainLicenseStore
    private let durationDays: Int
    private let formatter = ISO8601DateFormatter()

    init(store: KeychainLicenseStore, durationDays: Int = 30) {
        self.store = store
        self.durationDays = durationDays
    }

    func currentState(now: Date = Date()) -> TrialState {
        let startedAt = (try? startedAt()) ?? now
        if (try? store.string(.trialStartedAt)) == nil {
            try? store.save(formatter.string(from: startedAt), for: .trialStartedAt)
        }
        let elapsedDays = Calendar.current.dateComponents([.day], from: startedAt, to: now).day ?? 0
        return TrialState(startedAt: startedAt, daysRemaining: max(0, durationDays - elapsedDays))
    }

    private func startedAt() throws -> Date {
        if let raw = try store.string(.trialStartedAt), let date = formatter.date(from: raw) {
            return date
        }
        let now = Date()
        try store.save(formatter.string(from: now), for: .trialStartedAt)
        return now
    }
}
