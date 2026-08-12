import Foundation
#if canImport(Darwin)
import Darwin
#endif

private func defaultPetCaptureSocketURL() -> URL {
    let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    return applicationSupport
        .appendingPathComponent("PromptStudio", isDirectory: true)
        .appendingPathComponent("web-capture.sock")
}

/// App-side transport boundary for the native-messaging host. It validates the
/// JSON envelope, owns the user-only Unix socket and routes requests into the
/// coordinator.
@MainActor
final class PetCaptureSocketServer {
    private struct SocketIdentity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let owner: UInt32
    }

    let socketURL: URL
    let pendingTimeout: TimeInterval
    private(set) var isRunning = false
    private(set) var lastStartError: String?
    private let handler: PetCaptureHandler
    private var listenerDescriptor: Int32 = -1
    private var acceptTask: Task<Void, Never>?
    private var createdSocketIdentity: SocketIdentity?
    private var pendingIDs = Set<String>()
    private var terminalOutcomes: [String: PetCaptureOutcome] = [:]
    private var pendingWaiters: [String: [UUID: CheckedContinuation<PetCaptureOutcome?, Never>]] = [:]
    private var outcomeObservers: [NSObjectProtocol] = []

    private enum TerminalWaitResult: Sendable {
        case terminal(PetCaptureOutcome)
        case disconnected
        case timedOut
    }

    private struct CaptureEnvelope: Decodable {
        let type: String
        let candidate: Candidate

        struct Candidate: Decodable {
            let captureID: String
            let selectedText: String
            let pageTitle: String
            let pageURL: String
            let siteName: String
            let clickScreenPoint: PetCaptureRequest.ScreenPoint?
            let capturedAt: Date

            enum CodingKeys: String, CodingKey {
                case captureID
                case selectedText
                case pageTitle
                case pageURL
                case siteName
                case clickScreenPoint
                case capturedAt
            }

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                captureID = try values.decode(String.self, forKey: .captureID)
                selectedText = try values.decode(String.self, forKey: .selectedText)
                pageTitle = try values.decodeIfPresent(String.self, forKey: .pageTitle) ?? ""
                pageURL = try values.decodeIfPresent(String.self, forKey: .pageURL) ?? ""
                siteName = try values.decodeIfPresent(String.self, forKey: .siteName) ?? ""
                clickScreenPoint = try values.decodeIfPresent(PetCaptureRequest.ScreenPoint.self, forKey: .clickScreenPoint)

                if let isoString = try? values.decode(String.self, forKey: .capturedAt),
                   let isoDate = ISO8601DateFormatter().date(from: isoString) {
                    capturedAt = isoDate
                } else if let seconds = try? values.decode(Double.self, forKey: .capturedAt) {
                    capturedAt = Date(timeIntervalSince1970: seconds)
                } else {
                    capturedAt = Date()
                }
            }
        }
    }

    private struct WireResponse: Codable {
        let type: String
        let captureID: String
        let mouthScreenPoint: PetCaptureRequest.ScreenPoint?
        let message: String?
        let code: String?
        let retryable: Bool?

        init(
            type: String,
            captureID: String,
            mouthScreenPoint: PetCaptureRequest.ScreenPoint? = nil,
            message: String? = nil,
            code: String? = nil,
            retryable: Bool? = nil
        ) {
            self.type = type
            self.captureID = captureID
            self.mouthScreenPoint = mouthScreenPoint
            self.message = message
            self.code = code
            self.retryable = retryable
        }
    }

    init(
        socketURL: URL? = nil,
        pendingTimeout: TimeInterval = 300,
        handler: @escaping PetCaptureHandler
    ) {
        self.socketURL = socketURL ?? defaultPetCaptureSocketURL()
        self.pendingTimeout = pendingTimeout
        self.handler = handler
        outcomeObservers = [
            NotificationCenter.default.addObserver(forName: .petCaptureSaved, object: nil, queue: .main) { [weak self] notification in
                Task { @MainActor [weak self] in self?.receiveOutcome(notification.object) }
            },
            NotificationCenter.default.addObserver(forName: .petCaptureCancelled, object: nil, queue: .main) { [weak self] notification in
                Task { @MainActor [weak self] in self?.receiveOutcome(notification.object) }
            },
            NotificationCenter.default.addObserver(forName: .petCaptureFailed, object: nil, queue: .main) { [weak self] notification in
                Task { @MainActor [weak self] in self?.receiveOutcome(notification.object) }
            }
        ]
    }

    var pendingCaptureIDs: Set<String> { pendingIDs }

    func start() {
        guard !isRunning else { return }
        lastStartError = nil
        do {
            try FileManager.default.createDirectory(
                at: socketURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: socketURL.deletingLastPathComponent().path
            )
            #if canImport(Darwin)
            listenerDescriptor = try Self.makeListener(at: socketURL.path)
            createdSocketIdentity = try Self.socketIdentity(at: socketURL.path)
            isRunning = true
            let descriptor = listenerDescriptor
            acceptTask = Task.detached(priority: .utility) { [weak self] in
                await self?.acceptConnections(on: descriptor)
            }
            #else
            isRunning = false
            #endif
        } catch {
            isRunning = false
            lastStartError = error.localizedDescription
        }
    }

    func stop() {
        acceptTask?.cancel()
        acceptTask = nil
        #if canImport(Darwin)
        if listenerDescriptor >= 0 {
            Darwin.close(listenerDescriptor)
            listenerDescriptor = -1
        }
        if let createdSocketIdentity,
           let current = try? Self.socketIdentity(at: socketURL.path),
           current == createdSocketIdentity {
            _ = Darwin.unlink(socketURL.path)
        }
        createdSocketIdentity = nil
        #endif
        let continuations = pendingWaiters.values.flatMap(\.values)
        pendingWaiters.removeAll()
        pendingIDs.removeAll()
        terminalOutcomes.removeAll()
        continuations.forEach { $0.resume(returning: nil) }
        isRunning = false
    }

    deinit {
        outcomeObservers.forEach(NotificationCenter.default.removeObserver)
    }

    func handleMessage(_ data: Data) async -> Data {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        decoder.dateDecodingStrategy = .iso8601
        encoder.dateEncodingStrategy = .iso8601
        guard let envelope = try? decoder.decode(CaptureEnvelope.self, from: data),
              envelope.type == "capture" else {
            return encoded(WireResponse(type: "failed", captureID: "", message: "无效的采集请求"), encoder: encoder)
        }
        let candidate = envelope.candidate
        let request = PetCaptureRequest(
            id: candidate.captureID,
            selectedText: candidate.selectedText,
            pageTitle: candidate.pageTitle,
            pageURL: candidate.pageURL,
            siteName: candidate.siteName,
            clickPoint: candidate.clickScreenPoint,
            capturedAt: candidate.capturedAt
        )
        // Register before invoking the coordinator so a very fast confirm or
        // cancel notification cannot race the response that marks the request
        // as `presented`.
        pendingIDs.insert(request.id)
        do {
            let outcome = try await handler(request)
            switch outcome {
            case .presented(let captureID):
                if terminalOutcomes[captureID] == nil {
                    pendingIDs.insert(captureID)
                } else {
                    pendingIDs.remove(captureID)
                }
            default:
                pendingIDs.remove(request.id)
            }
            return encoded(response(for: outcome), encoder: encoder)
        } catch {
            pendingIDs.remove(request.id)
            return encoded(
                WireResponse(type: "failed", captureID: request.id, message: error.localizedDescription),
                encoder: encoder
            )
        }
    }

    func handleLine(_ line: String) async -> String {
        let data = await handleMessage(Data(line.utf8))
        return String(decoding: data, as: UTF8.self)
    }

    private func receiveOutcome(_ object: Any?) {
        guard let outcome = object as? PetCaptureOutcome,
              pendingIDs.contains(outcome.captureID) else { return }
        terminalOutcomes[outcome.captureID] = outcome
        pendingIDs.remove(outcome.captureID)
        let waiterDictionary = pendingWaiters.removeValue(forKey: outcome.captureID)
            ?? [UUID: CheckedContinuation<PetCaptureOutcome?, Never>]()
        let waiters = waiterDictionary.values
        waiters.forEach { $0.resume(returning: outcome) }
    }

    private func awaitTerminalOutcome(for captureID: String, descriptor: Int32) async -> PetCaptureOutcome? {
        if let terminal = terminalOutcomes.removeValue(forKey: captureID) {
            return terminal
        }
        let token = UUID()
        return await withTaskGroup(of: TerminalWaitResult.self) { group in
            group.addTask { [weak self] in
                guard let self,
                      let outcome = await self.waitForTerminalContinuation(captureID: captureID, token: token) else {
                    return .disconnected
                }
                return .terminal(outcome)
            }
            group.addTask {
                #if canImport(Darwin)
                if await Self.waitForPeerDisconnect(descriptor) {
                    return .disconnected
                }
                #endif
                return .timedOut
            }
            group.addTask { [pendingTimeout] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, pendingTimeout) * 1_000_000_000))
                return .timedOut
            }
            let result = await group.next() ?? .timedOut
            group.cancelAll()
            cancelWaiter(captureID: captureID, token: token)
            switch result {
            case .terminal(let outcome):
                return outcome
            case .disconnected, .timedOut:
                pendingIDs.remove(captureID)
                return nil
            }
        }
    }

    private func cancelWaiter(captureID: String, token: UUID) {
        let continuation = pendingWaiters[captureID]?.removeValue(forKey: token)
        if pendingWaiters[captureID]?.isEmpty == true {
            pendingWaiters.removeValue(forKey: captureID)
        }
        continuation?.resume(returning: nil)
    }

    private func waitForTerminalContinuation(captureID: String, token: UUID) async -> PetCaptureOutcome? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                registerWaiter(captureID: captureID, token: token, continuation: continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(captureID: captureID, token: token)
            }
        }
    }

    private func registerWaiter(
        captureID: String,
        token: UUID,
        continuation: CheckedContinuation<PetCaptureOutcome?, Never>
    ) {
        if let terminal = terminalOutcomes.removeValue(forKey: captureID) {
            pendingIDs.remove(captureID)
            continuation.resume(returning: terminal)
            return
        }
        pendingWaiters[captureID, default: [:]][token] = continuation
    }

    private func response(for outcome: PetCaptureOutcome) -> WireResponse {
        switch outcome {
        case .presented(let captureID):
            return WireResponse(type: "presented", captureID: captureID)
        case .saved(let captureID, let mouthPoint):
            return WireResponse(type: "saved", captureID: captureID, mouthScreenPoint: mouthPoint)
        case .alreadySaved(let captureID, let mouthPoint):
            return WireResponse(type: "saved", captureID: captureID, mouthScreenPoint: mouthPoint)
        case .animate(let captureID, let mouthPoint):
            return WireResponse(type: "animate", captureID: captureID, mouthScreenPoint: mouthPoint)
        case .cancelled(let captureID):
            return WireResponse(type: "cancelled", captureID: captureID)
        case .failed(let captureID, let message, let code, let retryable):
            return WireResponse(
                type: "failed",
                captureID: captureID,
                message: message,
                code: code,
                retryable: retryable ? true : nil
            )
        }
    }

    private func encoded(_ response: WireResponse, encoder: JSONEncoder) -> Data {
        (try? encoder.encode(response)) ?? Data()
    }

    #if canImport(Darwin)
    private static func makeListener(at path: String) throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw socketError("socket", errno) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8) + [UInt8(0)]
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= capacity else {
            Darwin.close(descriptor)
            throw socketError("path", ENAMETOOLONG)
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: capacity) { rebound in
                for index in 0..<pathBytes.count { rebound[index] = pathBytes[index] }
            }
        }

        try removeExistingSocketIfOwned(at: path)
        let addressLength = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.bind(descriptor, rebound, addressLength)
            }
        }
        guard bound == 0 else {
            Darwin.close(descriptor)
            throw socketError("bind", errno)
        }
        let boundIdentity: SocketIdentity
        do {
            boundIdentity = try socketIdentity(at: path)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        guard Darwin.listen(descriptor, 8) == 0 else {
            Darwin.close(descriptor)
            removeSocketIfMatches(path: path, identity: boundIdentity)
            throw socketError("listen", errno)
        }
        guard Darwin.chmod(path, mode_t(0o600)) == 0 else {
            Darwin.close(descriptor)
            removeSocketIfMatches(path: path, identity: boundIdentity)
            throw socketError("chmod", errno)
        }
        return descriptor
    }

    private static func removeExistingSocketIfOwned(at path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            guard errno == ENOENT else { throw socketError("lstat", errno) }
            return
        }
        let fileType = info.st_mode & S_IFMT
        guard fileType == S_IFSOCK, info.st_uid == getuid() else {
            throw socketError("ownership", EPERM)
        }
        guard unlink(path) == 0 else { throw socketError("unlink", errno) }
    }

    private static func socketIdentity(at path: String) throws -> SocketIdentity {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw socketError("identity", errno) }
        let fileType = info.st_mode & S_IFMT
        guard fileType == S_IFSOCK, info.st_uid == getuid() else { throw socketError("identity", EPERM) }
        return SocketIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino), owner: UInt32(info.st_uid))
    }

    private static func removeSocketIfMatches(path: String, identity: SocketIdentity) {
        guard let current = try? socketIdentity(at: path), current == identity else { return }
        _ = unlink(path)
    }

    private static func socketError(_ operation: String, _ code: Int32) -> NSError {
        NSError(domain: "PromptStudio.PetSocket", code: Int(code), userInfo: [NSLocalizedDescriptionKey: "\(operation) failed (errno \(code))"])
    }

    private nonisolated func acceptConnections(on descriptor: Int32) async {
        while !Task.isCancelled {
            let client = Darwin.accept(descriptor, nil, nil)
            guard client >= 0 else {
                if Task.isCancelled { return }
                continue
            }
            var noSigPipe: Int32 = 1
            _ = withUnsafePointer(to: &noSigPipe) { pointer in
                Darwin.setsockopt(
                    client,
                    SOL_SOCKET,
                    SO_NOSIGPIPE,
                    pointer,
                    socklen_t(MemoryLayout<Int32>.size)
                )
            }
            Task.detached(priority: .utility) { [weak self] in
                await self?.serve(clientDescriptor: client)
            }
        }
    }

    private nonisolated func serve(clientDescriptor: Int32) async {
        let handle = FileHandle(fileDescriptor: clientDescriptor, closeOnDealloc: true)
        var pendingCaptureID: String?
        do {
            while let payload = try Self.readFrame(from: handle) {
                let response = await handleMessage(payload)
                let decoder = JSONDecoder()
                let envelope = try? decoder.decode(WireResponse.self, from: response)
                if envelope?.type == "presented" {
                    // Mark this before the first write. If the peer closes or
                    // the write fails, the catch path can release the pending
                    // ID and its terminal waiter deterministically.
                    pendingCaptureID = envelope?.captureID
                }
                try Self.writeFrame(response, to: handle)
                guard let envelope, envelope.type == "presented" else { continue }
                guard let terminal = await awaitTerminalOutcome(for: envelope.captureID, descriptor: clientDescriptor) else {
                    pendingCaptureID = nil
                    continue
                }
                pendingCaptureID = nil
                for followUp in await followUpResponses(for: terminal) {
                    try Self.writeFrame(followUp, to: handle)
                }
            }
        } catch {
            // The host may disconnect while the app is hidden or shutting down.
            if let pendingCaptureID {
                await disconnect(captureID: pendingCaptureID)
            }
        }
    }

    private func disconnect(captureID: String) {
        pendingIDs.remove(captureID)
        terminalOutcomes.removeValue(forKey: captureID)
        if let waiterDictionary = pendingWaiters.removeValue(forKey: captureID) {
            waiterDictionary.values.forEach { $0.resume(returning: nil) }
        }
        NotificationCenter.default.post(name: .petCaptureClientDisconnected, object: captureID)
    }

    private nonisolated func followUpResponses(for outcome: PetCaptureOutcome) async -> [Data] {
        await MainActor.run {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            switch outcome {
            case .saved(let captureID, let mouthPoint), .alreadySaved(let captureID, let mouthPoint):
                return [
                    encoded(response(for: .animate(captureID: captureID, mouthPoint: mouthPoint)), encoder: encoder),
                    encoded(response(for: outcome), encoder: encoder)
                ]
            default:
                return [encoded(response(for: outcome), encoder: encoder)]
            }
        }
    }

    #if canImport(Darwin)
    /// Polls the connected descriptor without consuming protocol bytes.  This
    /// lets a browser host that closes after `presented` release its pending
    /// capture immediately instead of waiting for the terminal timeout.
    private nonisolated static func waitForPeerDisconnect(_ descriptor: Int32) async -> Bool {
        while !Task.isCancelled {
            var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let result = Darwin.poll(&event, 1, 100)
            if result < 0 {
                if errno == EINTR { continue }
                return true
            }
            if result == 0 { continue }

            let terminalEvents = Int16(POLLHUP | POLLERR | POLLNVAL)
            if event.revents & terminalEvents != 0 { return true }
            guard event.revents & Int16(POLLIN) != 0 else { continue }

            var byte: UInt8 = 0
            let received = withUnsafeMutablePointer(to: &byte) { pointer in
                Darwin.recv(descriptor, pointer, 1, MSG_PEEK | MSG_DONTWAIT)
            }
            if received == 0 { return true }
            if received < 0, errno != EAGAIN, errno != EWOULDBLOCK { return true }
            if received > 0 {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        return false
    }
    #endif

    private nonisolated static func readFrame(from handle: FileHandle) throws -> Data? {
        let header = try readExactly(4, from: handle)
        guard !header.isEmpty else { return nil }
        guard header.count == 4 else { throw PetCaptureError.unavailable }
        let length = UInt32(header[0])
            | (UInt32(header[1]) << 8)
            | (UInt32(header[2]) << 16)
            | (UInt32(header[3]) << 24)
        guard length <= 1_048_576 else { throw PetCaptureError.unavailable }
        return try readExactly(Int(length), from: handle)
    }

    private nonisolated static func writeFrame(_ payload: Data, to handle: FileHandle) throws {
        guard payload.count <= 1_048_576 else { throw PetCaptureError.unavailable }
        let length = UInt32(payload.count)
        var frame = Data([
            UInt8(length & 0xff),
            UInt8((length >> 8) & 0xff),
            UInt8((length >> 16) & 0xff),
            UInt8((length >> 24) & 0xff)
        ])
        frame.append(payload)
        try handle.write(contentsOf: frame)
    }

    private nonisolated static func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            guard let chunk = try handle.read(upToCount: count - data.count), !chunk.isEmpty else {
                throw PetCaptureError.unavailable
            }
            data.append(chunk)
        }
        return data
    }
    #endif
}
