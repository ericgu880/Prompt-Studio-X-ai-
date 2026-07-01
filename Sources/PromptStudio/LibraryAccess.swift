import Darwin
import Foundation
import PromptStudioCore
import Security
import SQLite3

enum LibraryAuthorizationReason: Equatable {
    case noBookmarkInSandbox
    case noSavedLibraryAuthorization
    case permissionDenied
    case bookmarkUnavailable

    var title: String {
        switch self {
        case .noBookmarkInSandbox:
            "需要重新连接资料库"
        case .noSavedLibraryAuthorization:
            "需要连接资料库"
        case .permissionDenied:
            "资料库访问被拒绝"
        case .bookmarkUnavailable:
            "资料库授权已失效"
        }
    }

    var message: String {
        switch self {
        case .noBookmarkInSandbox:
            "首次授权被拒绝后，PromptStudio 需要你重新选择已有资料库目录。"
        case .noSavedLibraryAuthorization:
            "请选择已有 PromptStudio 资料库目录，完成一次授权后后续启动会自动加载。"
        case .permissionDenied:
            "当前系统权限无法访问资料库，请重新连接已有资料库。"
        case .bookmarkUnavailable:
            "保存的资料库授权无法解析，请重新连接已有资料库。"
        }
    }
}

struct LibraryDescriptor: Equatable {
    let url: URL
    let isSecurityScoped: Bool
    let isSandboxed: Bool
}

enum LibraryAccessState: Equatable {
    case loading
    case ready(LibraryDescriptor)
    case needsAuthorization(reason: LibraryAuthorizationReason, lastKnownURL: URL?)
    case missing(lastKnownURL: URL?)
    case readOnly(URL)
    case invalidLibrary(URL, message: String)
    case failed(LibraryLoadError)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var lastKnownURL: URL? {
        switch self {
        case .ready(let descriptor):
            descriptor.url
        case .needsAuthorization(_, let url), .missing(let url):
            url
        case .readOnly(let url), .invalidLibrary(let url, _):
            url
        case .loading, .failed:
            nil
        }
    }
}

enum LibraryLoadError: Error, Equatable, LocalizedError {
    case authorizationRequired(reason: LibraryAuthorizationReason, lastKnownURL: URL?)
    case permissionDenied(URL?, String)
    case notFound(URL?, String)
    case readOnly(URL, String)
    case invalidLibrary(URL, String)
    case bookmarkResolutionFailed(String)
    case databaseCorrupted(URL, String)
    case incompatibleSchema(URL, String)
    case ioFailure(URL?, String)
    case databaseBusy(URL, String)
    case diskFull(URL, String)

    var errorDescription: String? {
        switch self {
        case .authorizationRequired(let reason, _):
            reason.message
        case .permissionDenied(_, let message),
             .notFound(_, let message),
             .readOnly(_, let message),
             .invalidLibrary(_, let message),
             .bookmarkResolutionFailed(let message),
             .databaseCorrupted(_, let message),
             .incompatibleSchema(_, let message),
             .ioFailure(_, let message),
             .databaseBusy(_, let message),
             .diskFull(_, let message):
            message
        }
    }
}

final class LibraryBookmarkStore {
    private let defaults: UserDefaults
    private let bookmarkKey = "promptStudio.libraryBookmark.v1"
    private let lastKnownPathKey = "promptStudio.libraryLastKnownPath.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var bookmarkData: Data? {
        defaults.data(forKey: bookmarkKey)
    }

    var lastKnownURL: URL? {
        guard let path = defaults.string(forKey: lastKnownPathKey),
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    func save(bookmarkData: Data, url: URL) {
        defaults.set(bookmarkData, forKey: bookmarkKey)
        defaults.set(url.path, forKey: lastKnownPathKey)
    }

    func saveLastKnownURL(_ url: URL) {
        defaults.set(url.path, forKey: lastKnownPathKey)
    }
}

final class LibraryAccessSession {
    let url: URL
    private let didStartAccessing: Bool

    init(url: URL, requiresSecurityScope: Bool) {
        self.url = url
        self.didStartAccessing = requiresSecurityScope && url.startAccessingSecurityScopedResource()
    }

    var hasAccess: Bool {
        didStartAccessing
    }

    deinit {
        if didStartAccessing {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

final class AuthorizedLibraryContext {
    let url: URL
    let session: LibraryAccessSession?
    let repository: PromptRepository

    init(url: URL, session: LibraryAccessSession?, repository: PromptRepository) {
        self.url = url
        self.session = session
        self.repository = repository
    }
}

final class LibraryAccessCoordinator {
    let isSandboxed: Bool
    private let defaultURL: URL
    private let bookmarkStore: LibraryBookmarkStore
    private let sqliteIOErrorAccess = SQLITE_IOERR | (13 << 8)
    private let sqliteIOErrorLock = SQLITE_IOERR | (15 << 8)

    init(defaultURL: URL, bookmarkStore: LibraryBookmarkStore = LibraryBookmarkStore()) {
        self.defaultURL = defaultURL
        self.bookmarkStore = bookmarkStore
        self.isSandboxed = Self.currentProcessIsSandboxed()
    }

    var preferredPanelURL: URL? {
        bookmarkStore.lastKnownURL ?? defaultURL
    }

    func loadInitialContext() throws -> AuthorizedLibraryContext {
        if let bookmarkData = bookmarkStore.bookmarkData {
            return try loadContext(fromBookmarkData: bookmarkData, saveOnSuccess: true)
        }

        let reason: LibraryAuthorizationReason = isSandboxed
            ? .noBookmarkInSandbox
            : .noSavedLibraryAuthorization
        throw LibraryLoadError.authorizationRequired(
            reason: reason,
            lastKnownURL: bookmarkStore.lastKnownURL ?? defaultURL
        )
    }

    func connectExistingLibrary(fromPanelURL panelURL: URL) throws -> AuthorizedLibraryContext {
        let bookmarkData = try panelURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        return try loadContext(fromBookmarkData: bookmarkData, saveOnSuccess: true)
    }

    private func loadContext(fromBookmarkData bookmarkData: Data, saveOnSuccess: Bool) throws -> AuthorizedLibraryContext {
        var isStale = false
        let resolvedURL: URL
        do {
            resolvedURL = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw LibraryLoadError.bookmarkResolutionFailed(error.localizedDescription)
        }

        let session = LibraryAccessSession(url: resolvedURL, requiresSecurityScope: true)
        guard session.hasAccess else {
            throw LibraryLoadError.permissionDenied(resolvedURL, LibraryAuthorizationReason.permissionDenied.message)
        }

        let context = try classify(defaultURL: resolvedURL) {
            try PromptRepository.validateExistingLibrary(at: resolvedURL)
            let repository = try PromptRepository(libraryURL: resolvedURL)
            return AuthorizedLibraryContext(url: resolvedURL, session: session, repository: repository)
        }

        if saveOnSuccess {
            if isStale {
                refreshBookmarkIfPossible(for: resolvedURL, fallback: bookmarkData)
            } else {
                bookmarkStore.save(bookmarkData: bookmarkData, url: resolvedURL)
            }
        }
        return context
    }

    private func refreshBookmarkIfPossible(for url: URL, fallback: Data) {
        do {
            let refreshed = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            bookmarkStore.save(bookmarkData: refreshed, url: url)
        } catch {
            bookmarkStore.save(bookmarkData: fallback, url: url)
        }
    }

    private func classify<T>(defaultURL: URL?, _ work: () throws -> T) throws -> T {
        do {
            return try work()
        } catch let error as LibraryLoadError {
            throw error
        } catch let error as PromptRepositoryValidationError {
            throw classifyValidationError(error, url: defaultURL)
        } catch let error as SQLiteError {
            throw classifySQLiteError(error, url: defaultURL)
        } catch {
            throw classifyNSError(error, url: defaultURL)
        }
    }

    private func classifyValidationError(_ error: PromptRepositoryValidationError, url: URL?) -> LibraryLoadError {
        switch error {
        case .notDirectory:
            return .invalidLibrary(url ?? defaultURL, error.localizedDescription)
        case .missingDatabase:
            return .notFound(url, error.localizedDescription)
        case .incompatibleSchema:
            return .incompatibleSchema(url ?? defaultURL, error.localizedDescription)
        }
    }

    private func classifySQLiteError(_ error: SQLiteError, url: URL?) -> LibraryLoadError {
        let code = error.extendedCode ?? error.resultCode ?? SQLITE_ERROR
        let baseCode = code & 0xFF
        let message = error.localizedDescription

        if baseCode == SQLITE_BUSY || baseCode == SQLITE_LOCKED {
            return .databaseBusy(url ?? defaultURL, message)
        }
        if baseCode == SQLITE_FULL {
            return .diskFull(url ?? defaultURL, message)
        }
        if baseCode == SQLITE_READONLY {
            return .readOnly(url ?? defaultURL, message)
        }
        if baseCode == SQLITE_CORRUPT || baseCode == SQLITE_NOTADB {
            return .databaseCorrupted(url ?? defaultURL, message)
        }
        if baseCode == SQLITE_CANTOPEN {
            return .ioFailure(url, message)
        }
        if baseCode == SQLITE_IOERR {
            if code == sqliteIOErrorAccess {
                return .permissionDenied(url, message)
            }
            if code == sqliteIOErrorLock {
                return .databaseBusy(url ?? defaultURL, message)
            }
            return .ioFailure(url, message)
        }
        if baseCode == SQLITE_AUTH {
            return .invalidLibrary(url ?? defaultURL, message)
        }
        return .ioFailure(url, message)
    }

    private func classifyNSError(_ error: Error, url: URL?) -> LibraryLoadError {
        for nsError in Self.errorChain(from: error) {
            if nsError.domain == NSPOSIXErrorDomain {
                switch nsError.code {
                case Int(EACCES), Int(EPERM):
                    return .permissionDenied(url, nsError.localizedDescription)
                case Int(ENOENT):
                    return .notFound(url, nsError.localizedDescription)
                case Int(EROFS):
                    return .readOnly(url ?? defaultURL, nsError.localizedDescription)
                case Int(ENOSPC):
                    return .diskFull(url ?? defaultURL, nsError.localizedDescription)
                case Int(EBUSY):
                    return .databaseBusy(url ?? defaultURL, nsError.localizedDescription)
                default:
                    break
                }
            }
            if nsError.domain == NSCocoaErrorDomain {
                switch nsError.code {
                case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                    return .permissionDenied(url, nsError.localizedDescription)
                case NSFileReadNoSuchFileError, NSFileNoSuchFileError:
                    return .notFound(url, nsError.localizedDescription)
                case NSFileWriteVolumeReadOnlyError:
                    return .readOnly(url ?? defaultURL, nsError.localizedDescription)
                default:
                    break
                }
            }
        }
        return .ioFailure(url, error.localizedDescription)
    }

    private static func errorChain(from error: Error) -> [NSError] {
        var result: [NSError] = []
        var current: NSError? = error as NSError
        while let nsError = current {
            result.append(nsError)
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return result
    }

    private static func currentProcessIsSandboxed() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                task,
                "com.apple.security.app-sandbox" as CFString,
                nil
              ) else {
            return false
        }
        return (value as? Bool) == true
    }
}
