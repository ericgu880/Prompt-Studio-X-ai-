import Foundation
import PromptStudioCore

private enum SummaryStartupMigrationError: LocalizedError {
    case tagRelationsNotReady
    case versionSequenceNotReady
    case itemSequenceNotReady

    var errorDescription: String? {
        switch self {
        case .tagRelationsNotReady:
            "资料库标签关系迁移未能完成。"
        case .versionSequenceNotReady:
            "资料库版本顺序迁移未能完成。"
        case .itemSequenceNotReady:
            "资料库项目顺序迁移未能完成。"
        }
    }
}

/// Keeps the complete startup migration sequence single-flight per Library.
/// Individual repository migration methods already serialize their own SQLite
/// steps; this wider gate also prevents two startup requests from interleaving
/// readiness checks across different repository instances for the same file.
actor SummaryStartupMigrationCoordinator {
    static let shared = SummaryStartupMigrationCoordinator()

    private var inFlightByLibraryPath: [String: Task<Void, Error>] = [:]

    func prepare(repository: PromptRepository) async throws {
        let key = repository.libraryURL.standardizedFileURL.path
        if let inFlight = inFlightByLibraryPath[key] {
            try await inFlight.value
            return
        }

        let migration = Task.detached(priority: .utility) {
            try Self.prepareSynchronously(repository: repository)
        }
        inFlightByLibraryPath[key] = migration
        do {
            try await migration.value
            inFlightByLibraryPath[key] = nil
        } catch {
            inFlightByLibraryPath[key] = nil
            throw error
        }
    }

    /// Summary SQL intentionally has no legacy ordering fallback. Complete or
    /// resume the existing durable migrations before a paginator can query.
    private nonisolated static func prepareSynchronously(repository: PromptRepository) throws {
        // Preserve the durable rollback chain: tag relations are the oldest
        // Summary migration, followed by version ordering, then item ordering.
        if !repository.tagRelationsReady {
            _ = try repository.prepareTagRelationMigration()
            _ = try repository.runTagRelationBackfill()
            let report = try repository.validateTagRelationConsistency()
            guard report.isConsistent else {
                throw SummaryStartupMigrationError.tagRelationsNotReady
            }
        }
        guard repository.tagRelationsReady else {
            throw SummaryStartupMigrationError.tagRelationsNotReady
        }

        if !repository.versionSequenceMigrationReady {
            _ = try repository.prepareVersionSequenceMigration()
            _ = try repository.runVersionSequenceMigration()
        }
        guard repository.versionSequenceMigrationReady else {
            throw SummaryStartupMigrationError.versionSequenceNotReady
        }

        if !repository.itemSequenceMigrationReady {
            _ = try repository.prepareItemSequenceMigration()
            _ = try repository.runItemSequenceMigration()
        }
        guard repository.itemSequenceMigrationReady else {
            throw SummaryStartupMigrationError.itemSequenceNotReady
        }
    }
}
