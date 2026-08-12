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
    let socketURL: URL
    private(set) var isRunning = false
    private let handler: PetCaptureHandler
    private var listenerDescriptor: Int32 = -1
    private var acceptTask: Task<Void, Never>?

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

    private struct WireResponse: Encodable {
        let type: String
        let captureID: String
        let mouthScreenPoint: PetCaptureRequest.ScreenPoint?
        let message: String?

        init(type: String, captureID: String, mouthScreenPoint: PetCaptureRequest.ScreenPoint? = nil, message: String? = nil) {
            self.type = type
            self.captureID = captureID
            self.mouthScreenPoint = mouthScreenPoint
            self.message = message
        }
    }

    init(
        socketURL: URL? = nil,
        handler: @escaping PetCaptureHandler
    ) {
        self.socketURL = socketURL ?? defaultPetCaptureSocketURL()
        self.handler = handler
    }

    func start() {
        guard !isRunning else { return }
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
        if FileManager.default.fileExists(atPath: socketURL.path) {
            try? FileManager.default.removeItem(at: socketURL)
        }
        #endif
        isRunning = false
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
        do {
            return encoded(response(for: try await handler(request)), encoder: encoder)
        } catch {
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
        case .failed(let captureID, let message):
            return WireResponse(type: "failed", captureID: captureID, message: message)
        }
    }

    private func encoded(_ response: WireResponse, encoder: JSONEncoder) -> Data {
        (try? encoder.encode(response)) ?? Data()
    }

    #if canImport(Darwin)
    private static func makeListener(at path: String) throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw PetCaptureError.unavailable }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8) + [UInt8(0)]
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= capacity else {
            Darwin.close(descriptor)
            throw PetCaptureError.unavailable
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: capacity) { rebound in
                for index in 0..<pathBytes.count { rebound[index] = pathBytes[index] }
            }
        }

        if FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(atPath: path)
        }
        let addressLength = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.bind(descriptor, rebound, addressLength)
            }
        }
        guard bound == 0, Darwin.listen(descriptor, 8) == 0 else {
            Darwin.close(descriptor)
            try? FileManager.default.removeItem(atPath: path)
            throw PetCaptureError.unavailable
        }
        _ = Darwin.chmod(path, mode_t(0o600))
        return descriptor
    }

    private nonisolated func acceptConnections(on descriptor: Int32) async {
        while !Task.isCancelled {
            let client = Darwin.accept(descriptor, nil, nil)
            guard client >= 0 else {
                if Task.isCancelled { return }
                continue
            }
            Task.detached(priority: .utility) { [weak self] in
                await self?.serve(clientDescriptor: client)
            }
        }
    }

    private nonisolated func serve(clientDescriptor: Int32) async {
        let handle = FileHandle(fileDescriptor: clientDescriptor, closeOnDealloc: true)
        do {
            while let payload = try Self.readFrame(from: handle) {
                let response = await handleMessage(payload)
                try Self.writeFrame(response, to: handle)
            }
        } catch {
            // The host may disconnect while the app is hidden or shutting down.
        }
    }

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
