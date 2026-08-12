import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A durable, library-local thumbnail for one reference asset.
///
/// The service owns no database state. It only reads the source file and writes
/// `thumbnails/references/<reference-id>-v1.jpg` in the selected library.
@MainActor
public final class ReferenceThumbnailService {
    public enum ProbeEvent: Sendable {
        case hit
        case miss
        /// Generation duration in milliseconds.
        case generation(Double)
        case failure
    }

    public typealias Probe = @Sendable (ProbeEvent) -> Void
    public typealias Generator = @Sendable (_ sourceURL: URL, _ destinationURL: URL) throws -> Void

    private struct RequestKey: Hashable, Sendable {
        let referenceID: String
        let sourcePath: String
        let sourceVersion: String
        let destinationPath: String
    }

    private struct PendingGeneration {
        let key: RequestKey
        let sourceURL: URL
        let destinationURL: URL
        var priority: TaskPriority
        let generator: Generator
        let probe: Probe?
        let cancellationToken: CancellationToken
        let continuation: CheckedContinuation<URL?, Never>
    }

    private final class CancellationToken: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
    }

    private static var services: [String: ReferenceThumbnailService] = [:]
    private static var generationQueue: [PendingGeneration] = []
    private static var generationInProgress = false

    private let configuredLibraryURL: URL?
    private let generator: Generator
    private let probe: Probe?
    private let cancellationToken = CancellationToken()
    private var inFlight: [RequestKey: Task<URL?, Never>] = [:]

    public init(
        libraryURL: URL? = nil,
        generator: Generator? = nil,
        probe: Probe? = nil
    ) {
        configuredLibraryURL = libraryURL?.standardizedFileURL
        self.generator = generator ?? { sourceURL, destinationURL in
            try Self.generateJPEGThumbnail(sourceURL: sourceURL, destinationURL: destinationURL)
        }
        self.probe = probe
    }

    /// Returns the shared service for a normalized library path.
    ///
    /// A single service instance is important: SwiftUI cells, inspector
    /// previews, and background prewarming then share the same in-flight work.
    public static func shared(libraryURL: URL, probe: Probe? = nil) -> ReferenceThumbnailService {
        let key = libraryURL.standardizedFileURL.path
        if let service = services[key] {
            return service
        }
        let service = ReferenceThumbnailService(libraryURL: libraryURL, probe: probe)
        services[key] = service
        return service
    }

    public nonisolated static func thumbnailURL(referenceID: String, libraryURL: URL) -> URL {
        let fileID = safeFileID(for: referenceID)
        return libraryURL
            .standardizedFileURL
            .appendingPathComponent("thumbnails", isDirectory: true)
            .appendingPathComponent("references", isDirectory: true)
            .appendingPathComponent("\(fileID)-v1.jpg")
    }

    /// Requests a thumbnail using the library supplied at initialization.
    public func request(
        _ reference: ReferenceAsset,
        priority: TaskPriority = .utility
    ) async -> URL? {
        guard let libraryURL = configuredLibraryURL else {
            probe?(.failure)
            return nil
        }
        return await request(reference, libraryURL: libraryURL, priority: priority)
    }

    /// Compatibility entry point for callers that keep the active library URL
    /// outside the service. The shared service API uses `request(_:priority:)`.
    public func thumbnail(
        for reference: ReferenceAsset,
        libraryURL: URL,
        priority: TaskPriority = .utility
    ) async -> URL? {
        await request(reference, libraryURL: libraryURL, priority: priority)
    }

    public func request(
        _ reference: ReferenceAsset,
        libraryURL: URL,
        priority: TaskPriority = .utility
    ) async -> URL? {
        let sourceURL = URL(fileURLWithPath: reference.path).standardizedFileURL
        let destinationURL = Self.thumbnailURL(referenceID: reference.id, libraryURL: libraryURL)
        let preparation = await Task.detached(priority: priority) {
            (
                sourceVersion: Self.sourceVersion(for: sourceURL),
                hasValidThumbnail: Self.isValidThumbnail(at: destinationURL, sourceURL: sourceURL)
            )
        }.value
        let key = RequestKey(
            referenceID: reference.id,
            sourcePath: sourceURL.path,
            sourceVersion: preparation.sourceVersion,
            destinationPath: destinationURL.path
        )

        if preparation.hasValidThumbnail {
            probe?(.hit)
            return destinationURL
        }

        probe?(.miss)
        if let task = inFlight[key] {
            Self.promotePendingGeneration(for: key, to: priority)
            return await task.value
        }

        let task = Task<URL?, Never> { [weak self] in
            guard let self else { return nil }
            return await withCheckedContinuation { continuation in
                self.enqueue(
                    PendingGeneration(
                        key: key,
                        sourceURL: sourceURL,
                        destinationURL: destinationURL,
                        priority: priority,
                        generator: self.generator,
                        probe: self.probe,
                        cancellationToken: self.cancellationToken,
                        continuation: continuation
                    )
                )
            }
        }
        inFlight[key] = task
        Self.startNextGenerationIfNeeded()
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    /// Cancels queued work owned by this service. A generation already decoding
    /// may finish its temporary file, but it will not replace the destination.
    public func cancelPendingRequests() {
        cancellationToken.cancel()
        for task in inFlight.values {
            task.cancel()
        }
        inFlight.removeAll()

        let cancelled = Self.generationQueue.filter { $0.cancellationToken === cancellationToken }
        Self.generationQueue.removeAll { $0.cancellationToken === cancellationToken }
        for pending in cancelled {
            pending.continuation.resume(returning: nil)
        }

        if let configuredLibraryURL {
            let key = configuredLibraryURL.standardizedFileURL.path
            if Self.services[key] === self {
                Self.services[key] = nil
            }
        }
    }

    /// Schedules utility work for all references. Requests already cached on
    /// disk are cheap hits; uncached requests enter the shared priority queue.
    public func prewarm(
        _ references: [ReferenceAsset],
        priority: TaskPriority = .utility
    ) async {
        await withTaskGroup(of: URL?.self) { group in
            for reference in references {
                group.addTask { [weak self] in
                    guard let self else { return nil }
                    return await self.request(reference, priority: priority)
                }
            }
        }
    }

    /// Removes only files matching the service's `<id>-v1.jpg` naming scheme.
    /// Other files in the directory are intentionally left untouched.
    public func cleanupOrphans(keeping validReferenceIDs: Set<String>) async throws -> [URL] {
        guard let libraryURL = configuredLibraryURL else { return [] }
        return try await cleanupOrphans(validReferenceIDs: validReferenceIDs, libraryURL: libraryURL)
    }

    public func cleanupOrphans(
        validReferenceIDs: Set<String>,
        libraryURL: URL
    ) async throws -> [URL] {
        try await Task.detached(priority: .utility) {
            try Self.removeOrphans(validReferenceIDs: validReferenceIDs, libraryURL: libraryURL)
        }.value
    }

    private nonisolated static func removeOrphans(
        validReferenceIDs: Set<String>,
        libraryURL: URL
    ) throws -> [URL] {
        let directory = libraryURL
            .standardizedFileURL
            .appendingPathComponent("thumbnails", isDirectory: true)
            .appendingPathComponent("references", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }

        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        let validFileIDs = Set(validReferenceIDs.map(Self.safeFileID))
        let orphanURLs = files
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .filter { $0.pathExtension.caseInsensitiveCompare("jpg") == .orderedSame }
            .filter { $0.lastPathComponent.hasSuffix("-v1.jpg") }
            .filter { url in
                let id = String(url.deletingPathExtension().lastPathComponent.dropLast(3))
                return !validFileIDs.contains(id)
            }
            .sorted { $0.path < $1.path }

        for url in orphanURLs {
            try FileManager.default.removeItem(at: url)
        }
        return orphanURLs
    }

    private func enqueue(_ pending: PendingGeneration) {
        Self.generationQueue.append(pending)
        Self.generationQueue.sort { lhs, rhs in
            lhs.priority.rawValue > rhs.priority.rawValue
        }
        Self.startNextGenerationIfNeeded()
    }

    private static func promotePendingGeneration(for key: RequestKey, to priority: TaskPriority) {
        guard let index = generationQueue.firstIndex(where: { $0.key == key }),
              priority.rawValue > generationQueue[index].priority.rawValue else { return }
        generationQueue[index].priority = priority
        generationQueue.sort { lhs, rhs in
            lhs.priority.rawValue > rhs.priority.rawValue
        }
    }

    private static func startNextGenerationIfNeeded() {
        guard !generationInProgress, !generationQueue.isEmpty else { return }
        generationInProgress = true
        let pending = generationQueue.removeFirst()
        let startedAt = ProcessInfo.processInfo.systemUptime

        Task.detached(priority: pending.priority) {
            let result: URL?
            do {
                guard !pending.cancellationToken.isCancelled else {
                    await Self.finishGeneration(pending, result: nil, startedAt: startedAt)
                    return
                }
                guard FileManager.default.fileExists(atPath: pending.sourceURL.path) else {
                    result = nil
                    await Self.finishGeneration(pending, result: result, startedAt: startedAt)
                    return
                }
                try FileManager.default.createDirectory(
                    at: pending.destinationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let temporaryURL = pending.destinationURL
                    .deletingPathExtension()
                    .appendingPathExtension("tmp-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: temporaryURL) }
                try pending.generator(pending.sourceURL, temporaryURL)
                guard !pending.cancellationToken.isCancelled else {
                    await Self.finishGeneration(pending, result: nil, startedAt: startedAt)
                    return
                }
                try Self.atomicReplace(temporaryURL, destinationURL: pending.destinationURL)
                try Self.alignThumbnailModificationDate(
                    at: pending.destinationURL,
                    with: pending.sourceURL
                )
                result = Self.isValidThumbnail(at: pending.destinationURL, sourceURL: pending.sourceURL) ? pending.destinationURL : nil
            } catch {
                result = nil
            }
            await Self.finishGeneration(pending, result: result, startedAt: startedAt)
        }
    }

    private static func finishGeneration(
        _ pending: PendingGeneration,
        result: URL?,
        startedAt: Double
    ) async {
        await MainActor.run {
            pending.continuation.resume(returning: result)
            generationInProgress = false
            if result != nil {
                pending.probe?(.generation((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000))
            } else {
                pending.probe?(.failure)
            }
            startNextGenerationIfNeeded()
        }
    }

    private nonisolated static func atomicReplace(_ temporaryURL: URL, destinationURL: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(
                destinationURL,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: .usingNewMetadataOnly
            )
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        }
    }

    private nonisolated static func sourceVersion(for sourceURL: URL) -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: sourceURL.path) else {
            return "missing"
        }
        let modification = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        return "\(modification)-\(size)"
    }

    private nonisolated static func alignThumbnailModificationDate(
        at thumbnailURL: URL,
        with sourceURL: URL
    ) throws {
        guard let sourceDate = try FileManager.default
            .attributesOfItem(atPath: sourceURL.path)[.modificationDate] as? Date else { return }
        try FileManager.default.setAttributes(
            [.modificationDate: max(sourceDate, Date())],
            ofItemAtPath: thumbnailURL.path
        )
    }

    private nonisolated static func safeFileID(for referenceID: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_") )
        if !referenceID.isEmpty,
           referenceID.unicodeScalars.allSatisfy(allowed.contains) {
            return referenceID
        }
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in referenceID.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "encoded-\(String(hash, radix: 16))"
    }

    private nonisolated static func isValidThumbnail(at url: URL, sourceURL: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            return false
        }
        guard let sourceDate = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)[.modificationDate] as? Date,
              let thumbnailDate = try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date else {
            return false
        }
        return thumbnailDate >= sourceDate
    }

    private nonisolated static func generateJPEGThumbnail(sourceURL: URL, destinationURL: URL) throws {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: 512
                ] as CFDictionary
              ),
              let destination = CGImageDestinationCreateWithURL(
                destinationURL as CFURL,
                UTType.jpeg.identifier as CFString,
                1,
                nil
              ) else {
            throw ReferenceThumbnailError.unreadableSource
        }

        CGImageDestinationAddImage(
            destination,
            thumbnail,
            [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw ReferenceThumbnailError.unreadableSource
        }
    }
}

private enum ReferenceThumbnailError: Error {
    case unreadableSource
}
