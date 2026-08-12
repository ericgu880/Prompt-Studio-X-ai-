import Foundation
import CryptoKit

#if canImport(Darwin)
import Darwin
#endif

/// The image metadata carried by the browser's `imageBegin` envelope.  The host treats every
/// field other than the integrity information as opaque and never dereferences a resource URL.
public struct BrowserImageCaptureCandidate: Codable, Equatable, Sendable {
    public let captureID: String
    public let pageTitle: String
    public let pageURL: String
    public let siteName: String
    public let resourceURL: String?
    public let altText: String
    public let originalFileName: String
    public let domSourceKind: ImageDOMSourceKind
    public let acquisitionMethod: ImageAcquisitionMethod
    public let isScreenshot: Bool
    public let mimeType: String?
    public let byteCount: Int64
    public let sha256: String
    public let pixelWidth: Int?
    public let pixelHeight: Int?
    public let clickScreenPoint: CaptureScreenPoint
    public let capturedAt: String

    public init(
        captureID: String,
        pageTitle: String = "",
        pageURL: String = "",
        siteName: String = "",
        resourceURL: String? = nil,
        altText: String = "",
        originalFileName: String = "",
        domSourceKind: ImageDOMSourceKind = .image,
        acquisitionMethod: ImageAcquisitionMethod = .pageContext,
        isScreenshot: Bool = false,
        mimeType: String? = nil,
        byteCount: Int64 = 0,
        sha256: String = "",
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        clickScreenPoint: CaptureScreenPoint = CaptureScreenPoint(x: 0, y: 0),
        capturedAt: String = ""
    ) {
        self.captureID = captureID
        self.pageTitle = pageTitle
        self.pageURL = pageURL
        self.siteName = siteName
        self.resourceURL = resourceURL
        self.altText = altText
        self.originalFileName = originalFileName
        self.domSourceKind = domSourceKind
        self.acquisitionMethod = acquisitionMethod
        self.isScreenshot = isScreenshot
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.sha256 = sha256
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.clickScreenPoint = clickScreenPoint
        self.capturedAt = capturedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        captureID = try values.decode(String.self, forKey: .captureID)
        pageTitle = try values.decodeIfPresent(String.self, forKey: .pageTitle) ?? ""
        pageURL = try values.decodeIfPresent(String.self, forKey: .pageURL) ?? ""
        siteName = try values.decodeIfPresent(String.self, forKey: .siteName) ?? ""
        resourceURL = try values.decodeIfPresent(String.self, forKey: .resourceURL)
        altText = try values.decodeIfPresent(String.self, forKey: .altText) ?? ""
        originalFileName = try values.decodeIfPresent(String.self, forKey: .originalFileName) ?? ""
        domSourceKind = try values.decodeIfPresent(ImageDOMSourceKind.self, forKey: .domSourceKind) ?? .image
        acquisitionMethod = try values.decodeIfPresent(ImageAcquisitionMethod.self, forKey: .acquisitionMethod) ?? .pageContext
        isScreenshot = try values.decodeIfPresent(Bool.self, forKey: .isScreenshot) ?? false
        mimeType = try values.decodeIfPresent(String.self, forKey: .mimeType)
        byteCount = try values.decodeIfPresent(Int64.self, forKey: .byteCount) ?? 0
        sha256 = try values.decodeIfPresent(String.self, forKey: .sha256) ?? ""
        pixelWidth = try values.decodeIfPresent(Int.self, forKey: .pixelWidth)
        pixelHeight = try values.decodeIfPresent(Int.self, forKey: .pixelHeight)
        clickScreenPoint = try values.decodeIfPresent(CaptureScreenPoint.self, forKey: .clickScreenPoint)
            ?? CaptureScreenPoint(x: 0, y: 0)
        capturedAt = try values.decodeIfPresent(String.self, forKey: .capturedAt) ?? ""
    }

    public func withIntegrity(byteCount: Int64, sha256: String) -> BrowserImageCaptureCandidate {
        BrowserImageCaptureCandidate(
            captureID: captureID,
            pageTitle: pageTitle,
            pageURL: pageURL,
            siteName: siteName,
            resourceURL: resourceURL,
            altText: altText,
            originalFileName: originalFileName,
            domSourceKind: domSourceKind,
            acquisitionMethod: acquisitionMethod,
            isScreenshot: isScreenshot,
            mimeType: mimeType,
            byteCount: byteCount,
            sha256: sha256,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            clickScreenPoint: clickScreenPoint,
            capturedAt: capturedAt
        )
    }

    private enum CodingKeys: String, CodingKey {
        case captureID
        case pageTitle
        case pageURL
        case siteName
        case resourceURL
        case altText
        case originalFileName
        case domSourceKind
        case acquisitionMethod
        case isScreenshot
        case mimeType
        case byteCount
        case sha256
        case pixelWidth
        case pixelHeight
        case clickScreenPoint
        case capturedAt
    }
}

public enum ImageDOMSourceKind: String, Codable, CaseIterable, Sendable {
    case image
    case picture
    case srcset
    case dataURL
    case blob
    case canvas
    case inlineSVG
    case cssBackground
}

public enum ImageAcquisitionMethod: String, Codable, CaseIterable, Sendable {
    case pageContext
    case extensionFetch
    case loadedBytes
    case screenshot
}

public enum ImageStagingError: Error, Equatable, CustomStringConvertible, Sendable {
    case imageBusy
    case invalidCaptureID
    case invalidDigest
    case imageTooLarge
    case clientPathRejected
    case stagingDirectoryUnavailable
    case stagingDirectoryInsecure
    case stagingFileUnavailable
    case stagingFileInsecure
    case unknownSession
    case transferTimedOut
    case invalidBase64
    case chunkTooLarge
    case byteCountExceeded
    case duplicateChunk
    case outOfOrderChunk
    case truncatedImage
    case hashMismatch
    case tokenRejected

    public var description: String {
        switch self {
        case .imageBusy: return "image session is busy"
        case .invalidCaptureID: return "captureID is invalid"
        case .invalidDigest: return "SHA-256 digest is invalid"
        case .imageTooLarge: return "image exceeds 50 MiB"
        case .clientPathRejected: return "browser paths are not accepted"
        case .stagingDirectoryUnavailable: return "staging directory is unavailable"
        case .stagingDirectoryInsecure: return "staging directory is insecure"
        case .stagingFileUnavailable: return "staging file is unavailable"
        case .stagingFileInsecure: return "staging file is insecure"
        case .unknownSession: return "image session is unknown"
        case .transferTimedOut: return "image transfer timed out"
        case .invalidBase64: return "image chunk is not valid base64"
        case .chunkTooLarge: return "image chunk exceeds 512 KiB"
        case .byteCountExceeded: return "image bytes exceed the declared size"
        case .duplicateChunk: return "image chunk was duplicated"
        case .outOfOrderChunk: return "image chunks are out of order"
        case .truncatedImage: return "image bytes are truncated"
        case .hashMismatch: return "image SHA-256 does not match"
        case .tokenRejected: return "staging token is invalid"
        }
    }
}

public struct ImageStagingSession: Equatable, Sendable {
    public let captureID: String
    public let stagingToken: String
    public let expectedByteCount: Int64
    public let expectedSHA256: String
    public let candidate: BrowserImageCaptureCandidate
    /// This URL is only exposed to trusted Host/App code. It is never encoded in a browser
    /// response; browser messages can carry a token only after Host generated it.
    public let fileURL: URL

    public init(
        captureID: String,
        stagingToken: String,
        expectedByteCount: Int64,
        expectedSHA256: String,
        candidate: BrowserImageCaptureCandidate,
        fileURL: URL
    ) {
        self.captureID = captureID
        self.stagingToken = stagingToken
        self.expectedByteCount = expectedByteCount
        self.expectedSHA256 = expectedSHA256
        self.candidate = candidate
        self.fileURL = fileURL
    }
}

public struct StagedImageCapture: Equatable, Sendable {
    public let captureID: String
    public let stagingToken: String
    public let candidate: BrowserImageCaptureCandidate
    public let fileURL: URL
    public let byteCount: Int64
    public let sha256: String

    public init(
        captureID: String,
        stagingToken: String,
        candidate: BrowserImageCaptureCandidate,
        fileURL: URL,
        byteCount: Int64,
        sha256: String
    ) {
        self.captureID = captureID
        self.stagingToken = stagingToken
        self.candidate = candidate
        self.fileURL = fileURL
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

/// A single-session, user-only image byte staging store. The synchronous API keeps runtime
/// routing deterministic while the lock makes disconnect/timeout cleanup safe if a future Host
/// reader moves to a background task.
public final class ImageStagingStore: @unchecked Sendable {
    public static let maxRawChunkBytes = 512 * 1024
    public static let maxImageBytes: Int64 = 50 * 1024 * 1024
    public static let transferTimeout: TimeInterval = 120
    public static let completedTTL: TimeInterval = 10 * 60

    public let rootDirectory: URL

    private final class Session {
        let publicSession: ImageStagingSession
        let handle: FileHandle
        var hasher = SHA256()
        var receivedByteCount: Int64 = 0
        var nextChunkIndex = 0
        var lastActivity: Date
        var completedAt: Date?

        init(publicSession: ImageStagingSession, handle: FileHandle, now: Date) {
            self.publicSession = publicSession
            self.handle = handle
            self.lastActivity = now
        }
    }

    private let lock = NSLock()
    private let clock: () -> Date
    private let tokenGenerator: () -> String
    private var session: Session?

    public init(
        rootDirectory: URL = ImageStagingStore.defaultRootDirectory(),
        clock: @escaping () -> Date = Date.init,
        tokenGenerator: @escaping () -> String = { UUID().uuidString }
    ) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.clock = clock
        self.tokenGenerator = tokenGenerator
    }

    public static func defaultRootDirectory(homeDirectory: String? = nil) -> URL {
        let home = homeDirectory ?? NSHomeDirectory()
        return URL(fileURLWithPath: home)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("PromptStudio", isDirectory: true)
            .appendingPathComponent("CaptureStaging", isDirectory: true)
    }

    public var activeSession: ImageStagingSession? {
        lock.lock()
        defer { lock.unlock() }
        return session?.publicSession
    }

    public func begin(
        candidate: BrowserImageCaptureCandidate,
        expectedByteCount: Int64,
        sha256: String,
        clientPath: String? = nil
    ) throws -> ImageStagingSession {
        lock.lock()
        defer { lock.unlock() }
        return try beginLocked(candidate: candidate, expectedByteCount: expectedByteCount, sha256: sha256, clientPath: clientPath)
    }

    public func appendChunk(captureID: String, index: Int, base64Data: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let session else { throw ImageStagingError.unknownSession }
        guard session.publicSession.captureID == captureID else { throw ImageStagingError.unknownSession }
        if clock().timeIntervalSince(session.lastActivity) > Self.transferTimeout {
            removeLocked()
            throw ImageStagingError.transferTimedOut
        }
        if index < session.nextChunkIndex {
            removeLocked()
            throw ImageStagingError.duplicateChunk
        }
        guard index == session.nextChunkIndex else {
            removeLocked()
            throw ImageStagingError.outOfOrderChunk
        }
        guard let bytes = Data(base64Encoded: base64Data), !bytes.isEmpty else {
            removeLocked()
            throw ImageStagingError.invalidBase64
        }
        guard bytes.count <= Self.maxRawChunkBytes else {
            removeLocked()
            throw ImageStagingError.chunkTooLarge
        }
        guard session.receivedByteCount + Int64(bytes.count) <= session.publicSession.expectedByteCount else {
            removeLocked()
            throw ImageStagingError.byteCountExceeded
        }
        do {
            try session.handle.write(contentsOf: bytes)
            session.hasher.update(data: bytes)
        } catch {
            removeLocked()
            throw ImageStagingError.stagingFileUnavailable
        }
        session.receivedByteCount += Int64(bytes.count)
        session.nextChunkIndex += 1
        session.lastActivity = clock()
    }

    public func finish(captureID: String, byteCount: Int64? = nil, sha256: String? = nil) throws -> StagedImageCapture {
        lock.lock()
        defer { lock.unlock() }
        guard let session else { throw ImageStagingError.unknownSession }
        guard session.publicSession.captureID == captureID else { throw ImageStagingError.unknownSession }
        if clock().timeIntervalSince(session.lastActivity) > Self.transferTimeout {
            removeLocked()
            throw ImageStagingError.transferTimedOut
        }
        guard session.receivedByteCount == session.publicSession.expectedByteCount,
              byteCount == nil || byteCount == session.publicSession.expectedByteCount else {
            removeLocked()
            throw ImageStagingError.truncatedImage
        }
        let actualDigest = session.hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actualDigest == session.publicSession.expectedSHA256,
              sha256 == nil || sha256?.lowercased() == actualDigest else {
            removeLocked()
            throw ImageStagingError.hashMismatch
        }
        do {
            try session.handle.synchronize()
            try session.handle.close()
        } catch {
            removeLocked()
            throw ImageStagingError.stagingFileUnavailable
        }
        let now = clock()
        session.completedAt = now
        session.lastActivity = now
        return StagedImageCapture(
            captureID: captureID,
            stagingToken: session.publicSession.stagingToken,
            candidate: session.publicSession.candidate,
            fileURL: session.publicSession.fileURL,
            byteCount: session.receivedByteCount,
            sha256: actualDigest
        )
    }

    public func resolve(token: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard let session,
              token == session.publicSession.stagingToken,
              Self.isSafeToken(token),
              FileManager.default.fileExists(atPath: session.publicSession.fileURL.path) else { return nil }
        return session.publicSession.fileURL
    }

    public func release(captureID: String, removeFile: Bool = true) {
        lock.lock()
        defer { lock.unlock() }
        guard let session, session.publicSession.captureID == captureID else { return }
        removeLocked(removeFile: removeFile)
    }

    public func cancel(captureID: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard let session, captureID == nil || session.publicSession.captureID == captureID else { return }
        removeLocked()
    }

    public func disconnect() {
        lock.lock()
        defer { lock.unlock() }
        removeLocked()
    }

    public func pruneExpired(now: Date? = nil) {
        lock.lock()
        defer { lock.unlock() }
        let current = now ?? clock()
        if let session {
            let expiration = session.completedAt.map { current.timeIntervalSince($0) > Self.completedTTL } ?? false
                || current.timeIntervalSince(session.lastActivity) > Self.transferTimeout
            if expiration { removeLocked() }
        }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for file in files {
            if let activeURL = self.session?.publicSession.fileURL.standardizedFileURL,
               file.standardizedFileURL == activeURL { continue }
            guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  current.timeIntervalSince(modified) > Self.completedTTL else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func beginLocked(
        candidate: BrowserImageCaptureCandidate,
        expectedByteCount: Int64,
        sha256: String,
        clientPath: String?
    ) throws -> ImageStagingSession {
        guard session == nil else { throw ImageStagingError.imageBusy }
        guard !candidate.captureID.isEmpty, !candidate.captureID.contains("\0") else {
            throw ImageStagingError.invalidCaptureID
        }
        if let clientPath, !clientPath.isEmpty { throw ImageStagingError.clientPathRejected }
        guard (0...Self.maxImageBytes).contains(expectedByteCount) else { throw ImageStagingError.imageTooLarge }
        let normalizedDigest = sha256.lowercased()
        guard normalizedDigest.count == 64,
              normalizedDigest.allSatisfy({ $0.isHexDigit }) else { throw ImageStagingError.invalidDigest }
        try ensureSecureRootLocked()
        let (token, fileURL, handle) = try createSecureFileLocked()
        let publicSession = ImageStagingSession(
            captureID: candidate.captureID,
            stagingToken: token,
            expectedByteCount: expectedByteCount,
            expectedSHA256: normalizedDigest,
            candidate: candidate,
            fileURL: fileURL
        )
        session = Session(publicSession: publicSession, handle: handle, now: clock())
        return publicSession
    }

    private func ensureSecureRootLocked() throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if !fileManager.fileExists(atPath: rootDirectory.path, isDirectory: &isDirectory) {
            do {
                try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
            } catch {
                throw ImageStagingError.stagingDirectoryUnavailable
            }
        }
        guard isDirectory.boolValue || (fileManager.fileExists(atPath: rootDirectory.path, isDirectory: &isDirectory) && isDirectory.boolValue) else {
            throw ImageStagingError.stagingDirectoryInsecure
        }
        #if canImport(Darwin)
        var info = stat()
        guard lstat(rootDirectory.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid() else { throw ImageStagingError.stagingDirectoryInsecure }
        #endif
        do {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootDirectory.path)
        } catch {
            throw ImageStagingError.stagingDirectoryUnavailable
        }
    }

    private func createSecureFileLocked() throws -> (token: String, fileURL: URL, handle: FileHandle) {
        for _ in 0..<8 {
            let token = tokenGenerator()
            guard Self.isSafeToken(token) else { continue }
            let fileURL = rootDirectory.appendingPathComponent(token, isDirectory: false)
            #if canImport(Darwin)
            let descriptor = fileURL.path.withCString {
                Darwin.open(
                    $0,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    mode_t(S_IRUSR | S_IWUSR)
                )
            }
            if descriptor < 0 {
                if errno == EEXIST { continue }
                throw ImageStagingError.stagingFileUnavailable
            }
            var identity = stat()
            var isValid = fstat(descriptor, &identity) == 0
            if isValid {
                isValid = fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0
            }
            if isValid {
                var verified = stat()
                isValid = fstat(descriptor, &verified) == 0
                if isValid { identity = verified }
            }
            let mode = identity.st_mode & mode_t(0o777)
            isValid = isValid
                && (identity.st_mode & S_IFMT) == S_IFREG
                && identity.st_uid == geteuid()
                && (mode & mode_t(0o077)) == 0
                && (mode & mode_t(0o600)) == mode_t(0o600)
            if !isValid {
                closeCreatedFile(descriptor: descriptor, path: fileURL.path, identity: identity)
                throw ImageStagingError.stagingFileInsecure
            }
            return (token, fileURL, FileHandle(fileDescriptor: descriptor, closeOnDealloc: true))
            #else
            guard FileManager.default.createFile(atPath: fileURL.path, contents: Data()) else {
                if FileManager.default.fileExists(atPath: fileURL.path) { continue }
                throw ImageStagingError.stagingFileUnavailable
            }
            do {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
                return (token, fileURL, try FileHandle(forWritingTo: fileURL))
            } catch {
                try? FileManager.default.removeItem(at: fileURL)
                throw ImageStagingError.stagingFileUnavailable
            }
            #endif
        }
        throw ImageStagingError.stagingFileUnavailable
    }

    #if canImport(Darwin)
    private func closeCreatedFile(descriptor: Int32, path: String, identity: stat) {
        var current = stat()
        if lstat(path, &current) == 0,
           current.st_dev == identity.st_dev,
           current.st_ino == identity.st_ino {
            _ = unlink(path)
        }
        close(descriptor)
    }
    #endif

    private func removeLocked(removeFile: Bool = true) {
        guard let session else { return }
        try? session.handle.close()
        if removeFile { try? FileManager.default.removeItem(at: session.publicSession.fileURL) }
        self.session = nil
    }

    private static func isSafeToken(_ token: String) -> Bool {
        guard !token.isEmpty, token.count <= 128 else { return false }
        return token.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    private static func isOwnedRegularFile(_ path: String) throws -> Bool {
        #if canImport(Darwin)
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFREG && info.st_uid == geteuid()
        #else
        let values = try FileManager.default.attributesOfItem(atPath: path)
        let type = values[.type] as? FileAttributeType
        return type == .typeRegular
        #endif
    }
}
