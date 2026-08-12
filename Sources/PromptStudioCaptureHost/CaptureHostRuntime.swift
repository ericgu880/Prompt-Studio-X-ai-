import Foundation

#if canImport(Darwin)
import Darwin
#endif

public enum CaptureHostRuntimeError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidOrigin
    case originMismatch
    case invalidRequest
    case selectionEmpty
    case selectionTooLarge
    case socketUnavailable
    case connectionTimedOut
    case responseTimedOut
    case responseDisconnected
    case appLaunchFailed
    case imageBusy
    case imageInvalid
    case imagePathRejected
    case imageTooLarge
    case imageChunkInvalid
    case imageOutOfOrder
    case imageDuplicate
    case imageTruncated
    case imageHashMismatch
    case imageTimeout
    case imageStagingUnavailable

    public var description: String {
        switch self {
        case .invalidOrigin: return "origin is not allowlisted"
        case .originMismatch: return "envelope origin does not match trusted argv origin"
        case .invalidRequest: return "request is invalid"
        case .selectionEmpty: return "selection is empty"
        case .selectionTooLarge: return "selection exceeds 50,000 characters"
        case .socketUnavailable: return "capture socket unavailable"
        case .connectionTimedOut: return "capture socket connection timed out"
        case .responseTimedOut: return "capture response timed out"
        case .responseDisconnected: return "capture socket closed before terminal response"
        case .appLaunchFailed: return "unable to launch PromptStudio"
        case .imageBusy: return "image session is busy"
        case .imageInvalid: return "image request is invalid"
        case .imagePathRejected: return "browser paths are not accepted"
        case .imageTooLarge: return "image exceeds 50 MiB"
        case .imageChunkInvalid: return "image chunk is invalid"
        case .imageOutOfOrder: return "image chunks are out of order"
        case .imageDuplicate: return "image chunk was duplicated"
        case .imageTruncated: return "image bytes are truncated"
        case .imageHashMismatch: return "image SHA-256 does not match"
        case .imageTimeout: return "image transfer timed out"
        case .imageStagingUnavailable: return "image staging is unavailable"
        }
    }
}

public enum CaptureHostLogger {
    public static func status(_ value: String, durationMilliseconds: Int? = nil, characterCount: Int? = nil) {
        var fields = ["status=\(value)"]
        if let durationMilliseconds { fields.append("duration_ms=\(durationMilliseconds)") }
        if let characterCount { fields.append("characters=\(characterCount)") }
        FileHandle.standardError.write(Data((fields.joined(separator: " ") + "\n").utf8))
    }
}

public struct UnixCaptureSocket {
    public let path: String

    public init(path: String = UnixCaptureSocket.defaultPath()) {
        self.path = path
    }

    public static func defaultPath(homeDirectory: String? = nil) -> String {
        let applicationSupportPath: String
        if let homeDirectory {
            let home = homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
            applicationSupportPath = "\(home)/Library/Application Support"
        } else if let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            applicationSupportPath = url.path
        } else {
            applicationSupportPath = "\(NSHomeDirectory())/Library/Application Support"
        }
        return URL(fileURLWithPath: applicationSupportPath)
            .appendingPathComponent("PromptStudio", isDirectory: true)
            .appendingPathComponent("web-capture.sock")
            .path
    }
}

public struct PromptStudioLauncher {
    public static let launchArguments = ["-g", "-b", "com.creatigo.promptstudio"]

    public init() {}

    public func launch() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = Self.launchArguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw CaptureHostRuntimeError.appLaunchFailed
        }
    }
}

public final class UnixSocketCaptureForwarder {
    public typealias Exchange = (Data, Date, Date) throws -> Data
    public typealias ResponseSink = (Data) throws -> Void
    public typealias StreamingExchange = (Data, Date, Date, ResponseSink) throws -> Void
    public typealias TerminalStreamingExchange = (Data, Date, Date, Set<String>, ResponseSink) throws -> Void
    private let socketPath: String
    private let launchApp: () throws -> Void
    private let exchange: Exchange?
    private let terminalStreamingExchange: TerminalStreamingExchange
    private let clock: () -> Date
    private let sleep: (UInt32) -> Void

    public init(
        socketPath: String = UnixCaptureSocket.defaultPath(),
        launchApp: @escaping () throws -> Void = { try PromptStudioLauncher().launch() },
        exchange: Exchange? = nil,
        streamingExchange: StreamingExchange? = nil,
        terminalStreamingExchange: TerminalStreamingExchange? = nil,
        clock: @escaping () -> Date = Date.init,
        sleep: @escaping (UInt32) -> Void = { _ = usleep($0) }
    ) {
        self.socketPath = socketPath
        self.launchApp = launchApp
        self.exchange = exchange
        if let terminalStreamingExchange {
            self.terminalStreamingExchange = terminalStreamingExchange
        } else if let streamingExchange {
            self.terminalStreamingExchange = { payload, connectDeadline, responseDeadline, _, sink in
                try streamingExchange(payload, connectDeadline, responseDeadline, sink)
            }
        } else if let exchange {
            // Preserve the single-frame injection seam used by callers/tests while
            // routing production instances through the real socket stream below.
            self.terminalStreamingExchange = { payload, connectDeadline, responseDeadline, _, sink in
                try sink(exchange(payload, connectDeadline, responseDeadline))
            }
        } else {
            self.terminalStreamingExchange = { payload, connectDeadline, responseDeadline, terminalTypes, sink in
                try UnixSocketCaptureForwarder.exchangeStreaming(
                    payload,
                    socketPath: socketPath,
                    connectDeadline: connectDeadline,
                    responseDeadline: responseDeadline,
                    terminalTypes: terminalTypes,
                    responseSink: sink
                )
            }
        }
        self.clock = clock
        self.sleep = sleep
    }

    public func forward(_ payload: Data) throws -> Data {
        if let exchange {
            return try forwardSingle(payload, exchange: exchange)
        }
        var lastResponse: Data?
        try forwardStreaming(payload) { response in
            lastResponse = response
        }
        guard let lastResponse else { throw CaptureHostRuntimeError.responseDisconnected }
        return lastResponse
    }

    public func forwardStreaming(
        _ payload: Data,
        responseSink: @escaping ResponseSink,
        terminalTypes: Set<String> = ["saved", "cancelled", "failed"]
    ) throws {
        let connectionDeadline = clock().addingTimeInterval(5)
        var launched = false
        while clock() < connectionDeadline {
            let currentResponseDeadline = clock().addingTimeInterval(300)
            var sawTerminal = false
            var deliveredResponse = false
            do {
                try terminalStreamingExchange(payload, connectionDeadline, currentResponseDeadline, terminalTypes) { frame in
                    deliveredResponse = true
                    if Self.isTerminalResponse(frame, terminalTypes: terminalTypes) { sawTerminal = true }
                    try responseSink(frame)
                }
                if sawTerminal { return }
                throw CaptureHostRuntimeError.responseDisconnected
            } catch CaptureHostRuntimeError.responseDisconnected {
                // The app accepted this request but closed before a terminal frame. Do
                // not resend it: let the native port disconnect so background pending
                // state can replay by captureID.
                throw CaptureHostRuntimeError.responseDisconnected
            } catch CaptureHostRuntimeError.responseTimedOut {
                throw CaptureHostRuntimeError.responseTimedOut
            } catch let error as CaptureHostRuntimeError {
                switch error {
                case .socketUnavailable, .connectionTimedOut, .appLaunchFailed:
                    if deliveredResponse {
                        throw CaptureHostRuntimeError.responseDisconnected
                    }
                    if !launched {
                        try? launchApp()
                        launched = true
                    }
                default:
                    throw error
                }
            } catch {
                // A response sink failure (for example malformed app JSON) is not a
                // connection retry. The caller emits a terminal failed response.
                throw error
            }
            sleep(100_000)
        }
        throw CaptureHostRuntimeError.connectionTimedOut
    }

    private func forwardSingle(_ payload: Data, exchange: @escaping Exchange) throws -> Data {
        let connectionDeadline = clock().addingTimeInterval(5)
        var launched = false
        while clock() < connectionDeadline {
            do {
                return try exchange(payload, connectionDeadline, clock().addingTimeInterval(300))
            } catch CaptureHostRuntimeError.responseTimedOut {
                throw CaptureHostRuntimeError.responseTimedOut
            } catch {
                if !launched {
                    try? launchApp()
                    launched = true
                }
                sleep(100_000)
            }
        }
        throw CaptureHostRuntimeError.connectionTimedOut
    }

    private static func isTerminalResponse(_ payload: Data, terminalTypes: Set<String> = [
        "saved", "cancelled", "failed", "ack", "imageDragPreviewAck", "imageDragCancelAck"
    ]) -> Bool {
        guard let response = try? JSONDecoder().decode(CaptureHostResponse.self, from: payload) else { return false }
        return terminalTypes.contains(response.type)
    }

    private static func exchangeStreaming(
        _ payload: Data,
        socketPath: String,
        connectDeadline: Date,
        responseDeadline: Date,
        terminalTypes: Set<String>,
        responseSink: ResponseSink
    ) throws {
        #if canImport(Darwin)
        var socketInfo = stat()
        guard lstat(socketPath, &socketInfo) == 0,
              (socketInfo.st_mode & S_IFMT) == S_IFSOCK,
              socketInfo.st_uid == geteuid() else {
            throw CaptureHostRuntimeError.socketUnavailable
        }
        // The app creates a user-only parent directory. Tighten the socket itself as well so a
        // stale or inherited umask cannot expose capture text to another local user.
        _ = chmod(socketPath, mode_t(S_IRUSR | S_IWUSR))
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw CaptureHostRuntimeError.socketUnavailable }
        defer { close(descriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8) + [UInt8(0)]
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= capacity else { throw CaptureHostRuntimeError.socketUnavailable }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: capacity) { rebound in
                for index in 0..<pathBytes.count { rebound[index] = pathBytes[index] }
            }
        }
        let addressLength = socklen_t(MemoryLayout<sockaddr_un>.size)
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.connect(descriptor, rebound, addressLength)
            }
        }
        if connected != 0 {
            guard errno == EINPROGRESS else { throw CaptureHostRuntimeError.socketUnavailable }
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            while true {
                let remaining = connectDeadline.timeIntervalSinceNow
                guard remaining > 0 else { throw CaptureHostRuntimeError.connectionTimedOut }
                let milliseconds = Int32(max(1, min(Double(Int32.max), ceil(remaining * 1_000))))
                let pollResult = Darwin.poll(&pollDescriptor, 1, milliseconds)
                if pollResult == 0 { throw CaptureHostRuntimeError.connectionTimedOut }
                if pollResult < 0 {
                    if errno == EINTR { continue }
                    throw CaptureHostRuntimeError.socketUnavailable
                }
                var socketError: Int32 = 0
                var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &socketErrorLength) == 0 else {
                    throw CaptureHostRuntimeError.socketUnavailable
                }
                guard socketError == 0 else { throw CaptureHostRuntimeError.socketUnavailable }
                break
            }
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        do {
            try NativeMessagingFramer.writeFrame(payload, to: handle, deadline: responseDeadline)
            while true {
                guard let response = try NativeMessagingFramer.readFrame(from: handle, deadline: responseDeadline) else {
                    throw CaptureHostRuntimeError.responseDisconnected
                }
                try responseSink(response)
                if isTerminalResponse(response, terminalTypes: terminalTypes) { return }
            }
        } catch NativeMessagingError.deadlineExceeded {
            throw CaptureHostRuntimeError.responseTimedOut
        } catch CaptureHostRuntimeError.responseDisconnected {
            throw CaptureHostRuntimeError.responseDisconnected
        } catch is NativeMessagingError {
            throw CaptureHostRuntimeError.responseDisconnected
        }
        #else
        throw CaptureHostRuntimeError.socketUnavailable
        #endif
    }
}

public final class PromptStudioCaptureHost {
    private let input: FileHandle
    private let output: FileHandle
    private let forwarder: UnixSocketCaptureForwarder
    private let allowlist: CaptureOriginAllowlist
    private let trustedOrigin: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let stagingStore: ImageStagingStore

    private struct ImageBeginWire: Decodable {
        let type: String
        let origin: String
        let candidate: BrowserImageCaptureCandidate
        let expectedByteCount: Int64
        let sha256: String
    }

    private struct ImageChunkWire: Decodable {
        let type: String
        let origin: String
        let captureID: String
        let index: Int
        let base64Data: String?
        let data: String?
    }

    private struct ImageEndWire: Decodable {
        let type: String
        let origin: String
        let captureID: String
        let byteCount: Int64?
        let sha256: String?
    }

    private struct ImageCancelWire: Decodable {
        let type: String
        let origin: String
        let captureID: String
    }

    private struct ImageDragPreviewWire: Decodable {
        let type: String
        let origin: String
        let captureID: String
        let screenPoint: CaptureScreenPoint?
        let point: CaptureScreenPoint?
        let insidePet: Bool?
        let drop: Bool?
    }

    private struct SocketImageCaptureEnvelope: Encodable {
        let type = "imageCapture"
        let stagingToken: String
        let candidate: BrowserImageCaptureCandidate
    }

    private struct SocketImageControlEnvelope: Encodable {
        let type: String
        let captureID: String
        let screenPoint: CaptureScreenPoint?
        let insidePet: Bool?
        let drop: Bool?
    }

    public init(
        trustedOrigin: String,
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput,
        forwarder: UnixSocketCaptureForwarder = UnixSocketCaptureForwarder(),
        allowlist: CaptureOriginAllowlist = .default,
        stagingStore: ImageStagingStore = ImageStagingStore()
    ) {
        self.input = input
        self.output = output
        self.forwarder = forwarder
        self.allowlist = allowlist
        self.trustedOrigin = trustedOrigin
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.stagingStore = stagingStore
    }

    public func run() throws {
        defer { stagingStore.disconnect() }
        while true {
            let frame: Data?
            do {
                if stagingStore.activeSession != nil {
                    frame = try NativeMessagingFramer.readFrame(
                        from: input,
                        deadline: Date().addingTimeInterval(ImageStagingStore.transferTimeout)
                    )
                } else {
                    frame = try NativeMessagingFramer.readFrame(from: input)
                }
            } catch NativeMessagingError.deadlineExceeded {
                let captureID = stagingStore.activeSession?.captureID ?? "unknown"
                stagingStore.disconnect()
                try? writeResponse(CaptureHostResponse(type: "failed", captureID: captureID, code: "image-timeout", retryable: true, message: "image-timeout"))
                throw CaptureHostRuntimeError.imageTimeout
            }
            guard let frame else { break }
            let started = Date()
            stagingStore.pruneExpired()
            var textCandidate: BrowserCaptureCandidate?
            let requestCaptureID = captureID(from: frame)
            var terminalSent = false
            do {
                switch try messageType(from: frame) {
                case "capture":
                    let request = try decodeAndValidate(frame)
                    textCandidate = request.candidate
                    let socketPayload = try encoder.encode(SocketCaptureEnvelope(candidate: request.candidate))
                    try forwarder.forwardStreaming(socketPayload) { forwarded in
                        let appResponse = try self.decoder.decode(CaptureHostResponse.self, from: forwarded)
                        let response = CaptureHostResponse(
                            type: appResponse.type,
                            captureID: appResponse.captureID.isEmpty ? request.candidate.captureID : appResponse.captureID,
                            code: appResponse.code,
                            retryable: appResponse.retryable,
                            selectedText: appResponse.selectedText ?? request.candidate.selectedText,
                            message: appResponse.message,
                            mouthScreenPoint: appResponse.mouthScreenPoint,
                            clearSource: appResponse.clearSource
                        )
                        terminalSent = Self.isTerminal(response.type)
                        try NativeMessagingFramer.writeFrame(self.encoder.encode(response), to: self.output)
                    }
                    guard terminalSent else { throw CaptureHostRuntimeError.responseDisconnected }
                    CaptureHostLogger.status("forwarded", durationMilliseconds: Int(Date().timeIntervalSince(started) * 1_000), characterCount: request.candidate.selectedText.count)
                case "imageBegin":
                    try handleImageBegin(frame)
                case "imageChunk":
                    try handleImageChunk(frame)
                case "imageEnd":
                    try handleImageEnd(frame)
                case "imageCancel":
                    try handleImageCancel(frame)
                case "imageDragPreview":
                    try handleImageDragPreview(frame)
                case "imageDragCancel":
                    try handleImageDragCancel(frame)
                default:
                    throw CaptureHostRuntimeError.invalidRequest
                }
            } catch let error as CaptureHostRuntimeError {
                if case .responseDisconnected = error, textCandidate != nil {
                    CaptureHostLogger.status("disconnected", durationMilliseconds: Int(Date().timeIntervalSince(started) * 1_000), characterCount: textCandidate?.selectedText.count)
                    throw error
                }
                if !terminalSent {
                    let code = errorCode(error)
                    let response = CaptureHostResponse(type: "failed", captureID: textCandidate?.captureID ?? requestCaptureID, code: code, retryable: isRetryable(error), message: code)
                    try NativeMessagingFramer.writeFrame(encoder.encode(response), to: output)
                    CaptureHostLogger.status("failed", durationMilliseconds: Int(Date().timeIntervalSince(started) * 1_000), characterCount: textCandidate?.selectedText.count)
                }
            } catch {
                if !terminalSent {
                    let response = CaptureHostResponse(type: "failed", captureID: textCandidate?.captureID ?? requestCaptureID, code: "invalid-request", message: "invalid-request")
                    try NativeMessagingFramer.writeFrame(encoder.encode(response), to: output)
                    CaptureHostLogger.status("failed", durationMilliseconds: Int(Date().timeIntervalSince(started) * 1_000), characterCount: textCandidate?.selectedText.count)
                }
            }
        }
    }

    private static func isTerminal(_ type: String) -> Bool {
        ["saved", "cancelled", "failed"].contains(type)
    }

    private func decodeAndValidate(_ frame: Data) throws -> CaptureEnvelope {
        let request = try decoder.decode(CaptureEnvelope.self, from: frame)
        do {
            _ = try CaptureRequestValidator.validate(request, trustedOrigin: trustedOrigin, allowlist: allowlist)
        } catch CaptureRequestValidationError.originMismatch {
            throw CaptureHostRuntimeError.originMismatch
        } catch {
            throw CaptureHostRuntimeError.invalidOrigin
        }
        guard request.type == "capture", !request.candidate.captureID.isEmpty else { throw CaptureHostRuntimeError.invalidRequest }
        guard !request.candidate.selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CaptureHostRuntimeError.selectionEmpty }
        guard request.candidate.selectedText.count <= 50_000 else { throw CaptureHostRuntimeError.selectionTooLarge }
        return request
    }

    private func messageType(from frame: Data) throws -> String {
        guard let object = try JSONSerialization.jsonObject(with: frame) as? [String: Any],
              let type = object["type"] as? String,
              !type.isEmpty else { throw CaptureHostRuntimeError.invalidRequest }
        return type
    }

    private func validateImageEnvelope(_ frame: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: frame) as? [String: Any],
              let origin = object["origin"] as? String else { throw CaptureHostRuntimeError.invalidOrigin }
        guard allowlist.contains(trustedOrigin) else { throw CaptureHostRuntimeError.invalidOrigin }
        guard origin == trustedOrigin else { throw CaptureHostRuntimeError.originMismatch }
        guard allowlist.contains(origin) else { throw CaptureHostRuntimeError.invalidOrigin }
        guard !containsForbiddenPathField(object) else { throw CaptureHostRuntimeError.imagePathRejected }
    }

    private func handleImageBegin(_ frame: Data) throws {
        try validateImageEnvelope(frame)
        let request: ImageBeginWire
        do { request = try decoder.decode(ImageBeginWire.self, from: frame) }
        catch { throw CaptureHostRuntimeError.imageInvalid }
        guard (request.candidate.byteCount == 0 || request.candidate.byteCount == request.expectedByteCount),
              (request.candidate.sha256.isEmpty || request.candidate.sha256.lowercased() == request.sha256.lowercased()) else {
            throw CaptureHostRuntimeError.imageInvalid
        }
        do {
            _ = try stagingStore.begin(candidate: request.candidate, expectedByteCount: request.expectedByteCount, sha256: request.sha256)
            try writeResponse(CaptureHostResponse(type: "ack", captureID: request.candidate.captureID, code: "image-begin-accepted"))
        } catch let error as ImageStagingError {
            throw mapImageError(error)
        }
    }

    private func handleImageChunk(_ frame: Data) throws {
        try validateImageEnvelope(frame)
        let request: ImageChunkWire
        do { request = try decoder.decode(ImageChunkWire.self, from: frame) }
        catch { throw CaptureHostRuntimeError.imageInvalid }
        guard let encoded = request.base64Data ?? request.data else { throw CaptureHostRuntimeError.imageChunkInvalid }
        do {
            try stagingStore.appendChunk(captureID: request.captureID, index: request.index, base64Data: encoded)
            try writeResponse(CaptureHostResponse(type: "ack", captureID: request.captureID, code: "image-chunk-accepted"))
        } catch let error as ImageStagingError {
            throw mapImageError(error)
        }
    }

    private func handleImageEnd(_ frame: Data) throws {
        try validateImageEnvelope(frame)
        let request: ImageEndWire
        do { request = try decoder.decode(ImageEndWire.self, from: frame) }
        catch { throw CaptureHostRuntimeError.imageInvalid }
        let staged: StagedImageCapture
        do {
            staged = try stagingStore.finish(captureID: request.captureID, byteCount: request.byteCount, sha256: request.sha256)
        } catch let error as ImageStagingError {
            throw mapImageError(error)
        }
        let payload = try encoder.encode(SocketImageCaptureEnvelope(
            stagingToken: staged.stagingToken,
            candidate: staged.candidate.withIntegrity(byteCount: staged.byteCount, sha256: staged.sha256)
        ))
        var terminalSent = false
        do {
            try forwarder.forwardStreaming(payload) { forwarded in
                let appResponse = try self.decoder.decode(CaptureHostResponse.self, from: forwarded)
                let response = self.forwardedResponse(appResponse, captureID: request.captureID, selectedText: nil)
                terminalSent = Self.isTerminal(response.type)
                try self.writeResponse(response)
            }
            guard terminalSent else { throw CaptureHostRuntimeError.responseDisconnected }
            stagingStore.release(captureID: request.captureID)
        } catch {
            stagingStore.release(captureID: request.captureID)
            throw error
        }
    }

    private func handleImageCancel(_ frame: Data) throws {
        try handleImageControl(frame, type: "imageCancel", terminalTypes: ["ack", "cancelled", "failed"]) { request in
            stagingStore.cancel(captureID: request.captureID)
        }
    }

    private func handleImageDragPreview(_ frame: Data) throws {
        try validateImageEnvelope(frame)
        let request: ImageDragPreviewWire
        do { request = try decoder.decode(ImageDragPreviewWire.self, from: frame) }
        catch { throw CaptureHostRuntimeError.imageInvalid }
        let payload = try encoder.encode(SocketImageControlEnvelope(
            type: "imageDragPreview",
            captureID: request.captureID,
            screenPoint: request.screenPoint ?? request.point,
            insidePet: request.insidePet,
            drop: request.drop
        ))
        try forwardControl(payload, captureID: request.captureID, terminalTypes: ["ack", "imageDragPreviewAck", "failed"])
    }

    private func handleImageDragCancel(_ frame: Data) throws {
        try handleImageControl(frame, type: "imageDragCancel", terminalTypes: ["ack", "imageDragCancelAck", "cancelled", "failed"]) { request in
            stagingStore.cancel(captureID: request.captureID)
        }
    }

    private func handleImageControl(
        _ frame: Data,
        type: String,
        terminalTypes: Set<String>,
        beforeForward: (ImageCancelWire) -> Void
    ) throws {
        try validateImageEnvelope(frame)
        let request: ImageCancelWire
        do { request = try decoder.decode(ImageCancelWire.self, from: frame) }
        catch { throw CaptureHostRuntimeError.imageInvalid }
        guard request.type == type else { throw CaptureHostRuntimeError.imageInvalid }
        beforeForward(request)
        let payload = try encoder.encode(SocketImageControlEnvelope(type: type, captureID: request.captureID, screenPoint: nil, insidePet: nil, drop: nil))
        try forwardControl(payload, captureID: request.captureID, terminalTypes: terminalTypes)
    }

    private func forwardControl(_ payload: Data, captureID: String, terminalTypes: Set<String>) throws {
        var terminalSent = false
        do {
            try forwarder.forwardStreaming(payload, responseSink: { forwarded in
                let appResponse = try self.decoder.decode(CaptureHostResponse.self, from: forwarded)
                let response = self.forwardedResponse(appResponse, captureID: captureID, selectedText: nil)
                terminalSent = terminalTypes.contains(response.type)
                try self.writeResponse(response)
            }, terminalTypes: terminalTypes)
            guard terminalSent else { throw CaptureHostRuntimeError.responseDisconnected }
        } catch let error as CaptureHostRuntimeError {
            throw error
        } catch {
            throw CaptureHostRuntimeError.invalidRequest
        }
    }

    private func forwardedResponse(_ appResponse: CaptureHostResponse, captureID: String, selectedText: String?) -> CaptureHostResponse {
        CaptureHostResponse(
            type: appResponse.type,
            captureID: appResponse.captureID.isEmpty ? captureID : appResponse.captureID,
            code: appResponse.code,
            retryable: appResponse.retryable,
            selectedText: appResponse.selectedText ?? selectedText,
            message: appResponse.message,
            mouthScreenPoint: appResponse.mouthScreenPoint,
            clearSource: appResponse.clearSource
        )
    }

    private func writeResponse(_ response: CaptureHostResponse) throws {
        try NativeMessagingFramer.writeFrame(encoder.encode(response), to: output)
    }

    private func mapImageError(_ error: ImageStagingError) -> CaptureHostRuntimeError {
        switch error {
        case .imageBusy: return .imageBusy
        case .invalidCaptureID, .invalidDigest, .unknownSession, .invalidBase64, .tokenRejected: return .imageInvalid
        case .clientPathRejected: return .imagePathRejected
        case .imageTooLarge: return .imageTooLarge
        case .chunkTooLarge, .byteCountExceeded: return .imageChunkInvalid
        case .duplicateChunk: return .imageDuplicate
        case .outOfOrderChunk: return .imageOutOfOrder
        case .truncatedImage: return .imageTruncated
        case .hashMismatch: return .imageHashMismatch
        case .transferTimedOut: return .imageTimeout
        case .stagingDirectoryUnavailable, .stagingDirectoryInsecure, .stagingFileUnavailable, .stagingFileInsecure: return .imageStagingUnavailable
        }
    }

    private func containsForbiddenPathField(_ object: Any) -> Bool {
        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary {
                let normalized = key.lowercased()
                if ["path", "filepath", "fileurl", "stagedfilepath", "localpath", "stagingtoken"].contains(normalized) {
                    return true
                }
                if containsForbiddenPathField(value) { return true }
            }
        } else if let array = object as? [Any] {
            return array.contains(where: containsForbiddenPathField)
        }
        return false
    }

    private func captureID(from frame: Data) -> String {
        if let request = try? decoder.decode(CaptureEnvelope.self, from: frame) {
            return request.candidate.captureID
        }
        if let object = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
           let captureID = object["captureID"] as? String { return captureID }
        if let object = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
           let candidate = object["candidate"] as? [String: Any],
           let captureID = candidate["captureID"] as? String { return captureID }
        return "unknown"
    }

    private func isRetryable(_ error: CaptureHostRuntimeError) -> Bool {
        switch error {
        case .imageBusy, .imageTimeout, .connectionTimedOut, .socketUnavailable, .responseTimedOut, .responseDisconnected:
            return true
        default:
            return false
        }
    }

    private func errorCode(_ error: CaptureHostRuntimeError) -> String {
        switch error {
        case .invalidOrigin: return "origin-not-allowed"
        case .originMismatch: return "origin-mismatch"
        case .invalidRequest: return "invalid-request"
        case .selectionEmpty: return "empty-selection"
        case .selectionTooLarge: return "selection-too-large"
        case .socketUnavailable: return "app-unavailable"
        case .connectionTimedOut: return "app-connection-timeout"
        case .responseTimedOut: return "app-response-timeout"
        case .responseDisconnected: return "app-response-disconnected"
        case .appLaunchFailed: return "app-launch-failed"
        case .imageBusy: return "image-busy"
        case .imageInvalid: return "image-invalid"
        case .imagePathRejected: return "image-path-rejected"
        case .imageTooLarge: return "image-too-large"
        case .imageChunkInvalid: return "image-chunk-invalid"
        case .imageOutOfOrder: return "image-out-of-order"
        case .imageDuplicate: return "image-duplicate"
        case .imageTruncated: return "image-truncated"
        case .imageHashMismatch: return "image-sha-mismatch"
        case .imageTimeout: return "image-timeout"
        case .imageStagingUnavailable: return "image-staging-unavailable"
        }
    }
}
