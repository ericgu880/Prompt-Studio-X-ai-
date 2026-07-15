import Foundation

struct TrialState: Equatable {
    let startedAt: Date
    let daysRemaining: Int
    var isActive: Bool { daysRemaining > 0 }
}

final class TrialManager {
    private let store: any LicenseValueStore
    private let durationDays: Int
    private let formatter = ISO8601DateFormatter()

    init(store: any LicenseValueStore, durationDays: Int = 30) {
        self.store = store
        self.durationDays = durationDays
    }

    func currentState(now: Date = Date()) throws -> TrialState {
        let startedAt: Date
        if let raw = try store.string(.trialStartedAt), let existing = formatter.date(from: raw) {
            startedAt = existing
        } else {
            startedAt = now
            try store.save(formatter.string(from: startedAt), for: .trialStartedAt)
        }
        let elapsedDays = Calendar.current.dateComponents([.day], from: startedAt, to: now).day ?? 0
        return TrialState(startedAt: startedAt, daysRemaining: max(0, durationDays - elapsedDays))
    }
}
