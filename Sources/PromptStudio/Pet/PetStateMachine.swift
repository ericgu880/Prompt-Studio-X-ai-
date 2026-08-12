import Foundation

enum PetState: String, Codable, CaseIterable, Equatable, Sendable {
    case idle
    case asking
    case eating
    case success
    case cancelled
    case error
    case hidden
}

enum PetEvent: Equatable, Sendable {
    case captureRequested
    case confirm
    case cancel
    case saved
    case failed
    case hide
    case show
    case reset
}

/// Pure state transition logic. Side effects (persistence, animation and
/// notifications) belong to PetCoordinator, which keeps this type easy to test.
struct PetStateMachine: Equatable, Sendable {
    private(set) var state: PetState

    init(state: PetState = .idle) {
        self.state = state
    }

    @discardableResult
    mutating func transition(_ event: PetEvent) -> PetState {
        switch event {
        case .captureRequested where state == .idle:
            state = .asking
        case .confirm where state == .asking:
            state = .eating
        case .cancel where state == .asking:
            state = .cancelled
        case .saved where state == .eating:
            state = .success
        case .failed where state == .eating:
            state = .error
        case .hide where state != .hidden:
            state = .hidden
        case .show where state == .hidden:
            state = .idle
        case .reset where state == .success || state == .cancelled || state == .error:
            state = .idle
        default:
            // Hidden capture is saved silently by the coordinator; invalid
            // events leave the current state unchanged.
            break
        }
        return state
    }
}
