import Foundation

#if canImport(Darwin)
import Darwin
#endif

public enum CaptureHostRuntimeError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidOrigin
    case invalidRequest
    case selectionEmpty
    case selectionTooLarge
    case socketUnavailable
    case appLaunchFailed

    public var description: String {
        switch self {
        case .invalidOrigin: return "origin is not allowlisted"
        case .invalidRequest: return "request is invalid"
        case .selectionEmpty: return "selection is empty"
        case .selectionTooLarge: return "selection exceeds 50,000 characters"
        case .socketUnavailable: return "capture socket unavailable"
        case .appLaunchFailed: return "unable to launch PromptStudio"
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

    public static func defaultPath(homeDirectory: String = NSHomeDirectory()) -> String {
        let home = homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
        return "\(home)/Library/Application Support/PromptStudio/web-capture.sock"
    }
}

public struct PromptStudioLauncher {
    public init() {}

    public func launch() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-b", "com.creatigo.promptstudio"]
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
    public typealias Exchange = (Data) throws -> Data
    private let socketPath: String
    private let launchApp: () throws -> Void
    private let exchange: Exchange
    private let clock: () -> Date
    private let sleep: (UInt32) -> Void

    public init(
        socketPath: String = UnixCaptureSocket.defaultPath(),
        launchApp: @escaping () throws -> Void = { try PromptStudioLauncher().launch() },
        exchange: Exchange? = nil,
        clock: @escaping () -> Date = Date.init,
        sleep: @escaping (UInt32) -> Void = { _ = usleep($0) }
    ) {
        self.socketPath = socketPath
        self.launchApp = launchApp
        self.exchange = exchange ?? { payload in try UnixSocketCaptureForwarder.exchange(payload, socketPath: socketPath) }
        self.clock = clock
        self.sleep = sleep
    }

    public func forward(_ payload: Data) throws -> Data {
        let deadline = clock().addingTimeInterval(5)
        var launched = false
        var lastError: Error = CaptureHostRuntimeError.socketUnavailable
        while clock() < deadline {
            do {
                return try exchange(payload)
            } catch {
                lastError = error
                if !launched {
                    do {
                        try launchApp()
                        launched = true
                    } catch {
                        lastError = error
                        launched = true
                    }
                }
                sleep(100_000)
            }
        }
        if lastError is CaptureHostRuntimeError { throw lastError }
        throw CaptureHostRuntimeError.socketUnavailable
    }

    private static func exchange(_ payload: Data, socketPath: String) throws -> Data {
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
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.connect(descriptor, rebound, addressLength)
            }
        }
        guard connected == 0 else { throw CaptureHostRuntimeError.socketUnavailable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try NativeMessagingFramer.writeFrame(payload, to: handle)
        guard let response = try NativeMessagingFramer.readFrame(from: handle) else {
            throw CaptureHostRuntimeError.socketUnavailable
        }
        return response
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
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput,
        forwarder: UnixSocketCaptureForwarder = UnixSocketCaptureForwarder(),
        allowlist: CaptureOriginAllowlist = .default
    ) {
        self.input = input
        self.output = output
        self.forwarder = forwarder
        self.allowlist = allowlist
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    public func run() throws {
        while let frame = try NativeMessagingFramer.readFrame(from: input) {
            let started = Date()
            let response: CaptureHostResponse
            do {
                let request = try decodeAndValidate(frame)
                let socketPayload = try encoder.encode(SocketCaptureEnvelope(candidate: request.candidate))
                let forwarded = try forwarder.forward(socketPayload)
                let appResponse = try decoder.decode(CaptureHostResponse.self, from: forwarded)
                response = CaptureHostResponse(
                    type: appResponse.type,
                    captureID: appResponse.captureID.isEmpty ? request.candidate.captureID : appResponse.captureID,
                    code: appResponse.code,
                    selectedText: appResponse.selectedText ?? request.candidate.selectedText,
                    message: appResponse.message,
                    mouthScreenPoint: appResponse.mouthScreenPoint
                )
                CaptureHostLogger.status("forwarded", durationMilliseconds: Int(Date().timeIntervalSince(started) * 1_000), characterCount: request.candidate.selectedText.count)
            } catch let error as CaptureHostRuntimeError {
                response = CaptureHostResponse(type: "failed", captureID: captureID(from: frame), code: errorCode(error), message: errorCode(error))
                CaptureHostLogger.status("failed", durationMilliseconds: Int(Date().timeIntervalSince(started) * 1_000))
            } catch {
                response = CaptureHostResponse(type: "failed", captureID: captureID(from: frame), code: "invalid-request", message: "invalid-request")
                CaptureHostLogger.status("failed", durationMilliseconds: Int(Date().timeIntervalSince(started) * 1_000))
            }
            try NativeMessagingFramer.writeFrame(encoder.encode(response), to: output)
        }
    }

    private func decodeAndValidate(_ frame: Data) throws -> CaptureEnvelope {
        let request = try decoder.decode(CaptureEnvelope.self, from: frame)
        guard allowlist.contains(request.origin) else { throw CaptureHostRuntimeError.invalidOrigin }
        guard request.type == "capture", !request.candidate.captureID.isEmpty else { throw CaptureHostRuntimeError.invalidRequest }
        guard !request.candidate.selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CaptureHostRuntimeError.selectionEmpty }
        guard request.candidate.selectedText.count <= 50_000 else { throw CaptureHostRuntimeError.selectionTooLarge }
        return request
    }

    private func captureID(from frame: Data) -> String {
        guard let request = try? decoder.decode(CaptureEnvelope.self, from: frame) else { return "unknown" }
        return request.candidate.captureID
    }

    private func errorCode(_ error: CaptureHostRuntimeError) -> String {
        switch error {
        case .invalidOrigin: return "origin-not-allowed"
        case .invalidRequest: return "invalid-request"
        case .selectionEmpty: return "empty-selection"
        case .selectionTooLarge: return "selection-too-large"
        case .socketUnavailable: return "app-unavailable"
        case .appLaunchFailed: return "app-launch-failed"
        }
    }
}
