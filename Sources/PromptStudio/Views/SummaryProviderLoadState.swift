import Foundation
import AppKit

/// Explicit lifecycle for an NSItemProvider request.  NSItemProvider is
/// callback-based and a provider is allowed to never call its completion
/// handler, so the Summary drop path cannot use an unchecked continuation.
enum ProviderLoadState: Equatable, Sendable {
    case idle
    case preCancelled
    case inFlight(UInt64)
    case completed
    case timedOut
    case failed
}

enum SummaryProviderLoadError: Error, Equatable, Sendable {
    case preCancelled
    case cancelled
    case timeout
    case failed
}

/// Thread-safe state machine shared by the callback and timeout tasks.
/// Repeated completion, a late callback, and a cancelled request are all
/// fail-closed and never resume a continuation twice.
final class ProviderLoadController: @unchecked Sendable {
    private let lock = NSLock()
    private var nextToken: UInt64 = 0
    private var currentState: ProviderLoadState = .idle

    var state: ProviderLoadState {
        lock.lock()
        defer { lock.unlock() }
        return currentState
    }

    func begin() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        if case .inFlight = currentState { return nil }
        if currentState == .preCancelled { return nil }
        nextToken &+= 1
        currentState = .inFlight(nextToken)
        return nextToken
    }

    func preCancel(token: UInt64? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if token == nil, currentState == .idle {
            currentState = .preCancelled
            return true
        }
        guard tokenMatches(token) else { return false }
        currentState = .preCancelled
        return true
    }

    func complete(token: UInt64) -> Bool {
        transition(token: token, to: .completed)
    }

    func timeout(token: UInt64) -> Bool {
        transition(token: token, to: .timedOut)
    }

    func fail(token: UInt64) -> Bool {
        transition(token: token, to: .failed)
    }

    private func transition(token: UInt64, to state: ProviderLoadState) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .inFlight(token) = currentState else { return false }
        currentState = state
        return true
    }

    private func tokenMatches(_ token: UInt64?) -> Bool {
        guard case .inFlight(let active) = currentState else { return false }
        return token == nil || token == active
    }
}

private final class ProviderLoadContinuation: @unchecked Sendable {
    typealias ResultValue = Result<Data, SummaryProviderLoadError>

    private let lock = NSLock()
    private let controller: ProviderLoadController
    private let token: UInt64
    private let onPublication: (@Sendable (ResultValue) -> Void)?
    private var continuation: CheckedContinuation<ResultValue, Never>?
    private var finished = false
    private var timeoutTask: Task<Void, Never>?

    init(
        controller: ProviderLoadController,
        token: UInt64,
        onPublication: (@Sendable (ResultValue) -> Void)?
    ) {
        self.controller = controller
        self.token = token
        self.onPublication = onPublication
    }

    func install(_ continuation: CheckedContinuation<ResultValue, Never>) {
        lock.lock()
        self.continuation = continuation
        let shouldResume = finished
        if shouldResume {
            self.continuation = nil
        }
        lock.unlock()
        if shouldResume {
            continuation.resume(returning: .failure(.cancelled))
        }
    }

    func startTimeout(nanoseconds: UInt64) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        let task = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            self?.finish(.failure(.timeout), transition: .timeout)
        }
        timeoutTask = task
        lock.unlock()
    }

    func callback(data: Data?, error: Error?) {
        if let data {
            finish(.success(data), transition: .complete)
        } else if error != nil {
            finish(.failure(.failed), transition: .fail)
        } else {
            finish(.failure(.failed), transition: .fail)
        }
    }

    func cancel() {
        _ = controller.preCancel(token: token)
        finish(.failure(.cancelled), transition: .cancelled)
    }

    private enum Transition {
        case complete
        case timeout
        case fail
        case cancelled
    }

    private func finish(_ result: ResultValue, transition: Transition) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        timeoutTask?.cancel()
        self.continuation = nil
        lock.unlock()

        let accepted: Bool
        switch transition {
        case .complete: accepted = controller.complete(token: token)
        case .timeout: accepted = controller.timeout(token: token)
        case .fail: accepted = controller.fail(token: token)
        case .cancelled:
            _ = controller.preCancel(token: token)
            accepted = true
        }
        let publishedResult = accepted ? result : .failure(.cancelled)
        continuation?.resume(returning: publishedResult)
        onPublication?(publishedResult)
    }
}

private final class ItemProviderBox: @unchecked Sendable {
    let provider: NSItemProvider

    init(_ provider: NSItemProvider) {
        self.provider = provider
    }
}

/// Bounded callback adapter used by both SwiftUI drops and deterministic UI
/// tests.  The start closure may complete synchronously, asynchronously, or
/// never; every path settles within the supplied deadline.
enum SummaryProviderLoader {
    typealias Start = @Sendable (@escaping @Sendable (Data?, Error?) -> Void) -> Void

    static func load(
        timeoutNanoseconds: UInt64 = 500_000_000,
        controller: ProviderLoadController = ProviderLoadController(),
        onPublication: (@Sendable (Result<Data, SummaryProviderLoadError>) -> Void)? = nil,
        start: @escaping Start
    ) async -> Result<Data, SummaryProviderLoadError> {
        guard let token = controller.begin() else {
            return .failure(.preCancelled)
        }
        let gate = ProviderLoadContinuation(
            controller: controller,
            token: token,
            onPublication: onPublication
        )
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.install(continuation)
                gate.startTimeout(nanoseconds: timeoutNanoseconds)
                start { data, error in gate.callback(data: data, error: error) }
            }
        } onCancel: {
            gate.cancel()
        }
    }

    static func loadData(
        from provider: NSItemProvider,
        typeIdentifier: String,
        timeoutNanoseconds: UInt64 = 500_000_000
    ) async -> Result<Data, SummaryProviderLoadError> {
        let box = ItemProviderBox(provider)
        return await load(timeoutNanoseconds: timeoutNanoseconds) { completion in
            box.provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                completion(data, error)
            }
        }
    }
}
