import Foundation

/// Owns the active interactive library query.
///
/// Starting a newer request cancels the older Task so generation checks remain
/// a stale-result safety net rather than the only cancellation mechanism.
public actor LibraryQuerySession {
    private struct ActiveRequest {
        let id: UUID
        let task: Task<LibraryItemPage, Error>
    }

    private let service: LibraryQueryService
    private var activeRequest: ActiveRequest?

    public init(service: LibraryQueryService) {
        self.service = service
    }

    public func query(_ query: LibraryQuery) async throws -> LibraryItemPage {
        // A cancelled caller may be delayed at this actor boundary. Check
        // before touching the active slot so that a stale invocation cannot
        // cancel a newer request or start an unstructured child.
        try Task.checkCancellation()
        activeRequest?.task.cancel()
        let requestID = UUID()
        let generation = service.beginGeneration()
        let task = Task {
            try Task.checkCancellation()
            return try await service.query(query, generation: generation)
        }
        activeRequest = ActiveRequest(id: requestID, task: task)

        defer {
            if activeRequest?.id == requestID {
                activeRequest = nil
            }
        }
        // `task` is intentionally unstructured so the session actor can
        // replace it without retaining the caller's task. Link cancellation
        // back to this exact child, otherwise cancelling the browser state's
        // request only marks the outer waiter cancelled while the SQLite read
        // continues in the background.
        return try await withTaskCancellationHandler(operation: {
            try await task.value
        }, onCancel: {
            task.cancel()
        })
    }

    public func cancel() {
        activeRequest?.task.cancel()
        activeRequest = nil
    }
}
