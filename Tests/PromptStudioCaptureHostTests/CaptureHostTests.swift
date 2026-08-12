import Foundation
import Testing
@testable import PromptStudioCaptureHost

#if canImport(CryptoKit)
import CryptoKit
#endif

@Test("image staging accepts ordered chunks and returns only a generated token")
func imageStagingAcceptsOrderedChunksAndGeneratedToken() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("promptstudio-image-stage-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let bytes = Data("hello image".utf8)
    let digest = sha256Hex(bytes)
    let candidate = BrowserImageCaptureCandidate(captureID: "image-1", capturedAt: "2026-08-13T00:00:00.000Z")
    let store = ImageStagingStore(rootDirectory: root)

    let session = try store.begin(candidate: candidate, expectedByteCount: Int64(bytes.count), sha256: digest)
    #expect(!session.stagingToken.isEmpty)
    #expect(!session.stagingToken.contains("/"))
    #expect(session.stagingToken != root.path)
    try store.appendChunk(captureID: candidate.captureID, index: 0, base64Data: bytes.base64EncodedString())
    let staged = try store.finish(captureID: candidate.captureID, byteCount: Int64(bytes.count), sha256: digest)
    #expect(staged.stagingToken == session.stagingToken)
    #expect(try Data(contentsOf: staged.fileURL) == bytes)
}

@Test("image staging rejects duplicate and out-of-order chunks")
func imageStagingRejectsDuplicateAndOutOfOrderChunks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("promptstudio-image-stage-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ImageStagingStore(rootDirectory: root)
    let candidate = BrowserImageCaptureCandidate(captureID: "image-order", capturedAt: "2026-08-13T00:00:00.000Z")
    let bytes = Data("chunk".utf8)
    let digest = sha256Hex(bytes)
    _ = try store.begin(candidate: candidate, expectedByteCount: Int64(bytes.count), sha256: digest)
    #expect(throws: ImageStagingError.outOfOrderChunk) {
        try store.appendChunk(captureID: candidate.captureID, index: 1, base64Data: bytes.base64EncodedString())
    }
    #expect(store.activeSession == nil)

    _ = try store.begin(candidate: candidate, expectedByteCount: Int64(bytes.count * 2), sha256: sha256Hex(bytes + bytes))
    try store.appendChunk(captureID: candidate.captureID, index: 0, base64Data: bytes.base64EncodedString())
    #expect(throws: ImageStagingError.duplicateChunk) {
        try store.appendChunk(captureID: candidate.captureID, index: 0, base64Data: bytes.base64EncodedString())
    }
    #expect(store.activeSession == nil)
}

@Test("image staging enforces raw chunk, 50 MiB, hash, and truncation limits")
func imageStagingEnforcesLimitsHashAndTruncation() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("promptstudio-image-stage-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ImageStagingStore(rootDirectory: root)
    let candidate = BrowserImageCaptureCandidate(captureID: "image-limits", capturedAt: "2026-08-13T00:00:00.000Z")
    let oversizedChunk = Data(repeating: 0x61, count: ImageStagingStore.maxRawChunkBytes + 1).base64EncodedString()
    #expect(throws: ImageStagingError.chunkTooLarge) {
        _ = try store.begin(candidate: candidate, expectedByteCount: Int64(ImageStagingStore.maxRawChunkBytes + 1), sha256: String(repeating: "0", count: 64))
        try store.appendChunk(captureID: candidate.captureID, index: 0, base64Data: oversizedChunk)
    }
    #expect(store.activeSession == nil)

    #expect(throws: ImageStagingError.imageTooLarge) {
        _ = try store.begin(candidate: candidate, expectedByteCount: ImageStagingStore.maxImageBytes + 1, sha256: String(repeating: "0", count: 64))
    }

    let bytes = Data("truncated".utf8)
    _ = try store.begin(candidate: candidate, expectedByteCount: Int64(bytes.count + 1), sha256: sha256Hex(bytes))
    try store.appendChunk(captureID: candidate.captureID, index: 0, base64Data: bytes.base64EncodedString())
    #expect(throws: ImageStagingError.truncatedImage) {
        try store.finish(captureID: candidate.captureID, byteCount: Int64(bytes.count), sha256: sha256Hex(bytes))
    }
    #expect(store.activeSession == nil)

    _ = try store.begin(candidate: candidate, expectedByteCount: Int64(bytes.count), sha256: String(repeating: "0", count: 64))
    try store.appendChunk(captureID: candidate.captureID, index: 0, base64Data: bytes.base64EncodedString())
    #expect(throws: ImageStagingError.hashMismatch) {
        try store.finish(captureID: candidate.captureID, byteCount: Int64(bytes.count), sha256: String(repeating: "0", count: 64))
    }
    #expect(store.activeSession == nil)
}

@Test("image staging cleans up on cancel, disconnect, timeout, TTL, and forged paths")
func imageStagingCleansUpAndRejectsForgedPaths() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("promptstudio-image-stage-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var now = Date(timeIntervalSince1970: 100)
    let store = ImageStagingStore(rootDirectory: root, clock: { now }, tokenGenerator: { "generated-token" })
    let candidate = BrowserImageCaptureCandidate(captureID: "image-cleanup", capturedAt: "2026-08-13T00:00:00.000Z")
    #expect(throws: ImageStagingError.clientPathRejected) {
        try store.begin(candidate: candidate, expectedByteCount: 0, sha256: "", clientPath: "/tmp/forged")
    }
    _ = try store.begin(candidate: candidate, expectedByteCount: 0, sha256: sha256Hex(Data()))
    let token = try #require(store.activeSession?.stagingToken)
    let stagedURL = try #require(store.resolve(token: token))
    #expect(stagedURL.path.hasSuffix(token))
    let rootAttributes = try FileManager.default.attributesOfItem(atPath: root.path)
    let fileAttributes = try FileManager.default.attributesOfItem(atPath: stagedURL.path)
    #expect((rootAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect(store.resolve(token: "../forged") == nil)
    #expect(store.resolve(token: "/tmp/forged") == nil)
    store.cancel(captureID: candidate.captureID)
    #expect(store.activeSession == nil)

    _ = try store.begin(candidate: candidate, expectedByteCount: 0, sha256: sha256Hex(Data()))
    now = now.addingTimeInterval(ImageStagingStore.transferTimeout + 1)
    store.pruneExpired(now: now)
    #expect(store.activeSession == nil)

    _ = try store.begin(candidate: candidate, expectedByteCount: 0, sha256: sha256Hex(Data()))
    let completed = try store.finish(captureID: candidate.captureID, byteCount: 0, sha256: sha256Hex(Data()))
    #expect(FileManager.default.fileExists(atPath: completed.fileURL.path))
    now = now.addingTimeInterval(ImageStagingStore.completedTTL + 1)
    store.pruneExpired(now: now)
    #expect(!FileManager.default.fileExists(atPath: completed.fileURL.path))

    _ = try store.begin(candidate: candidate, expectedByteCount: 0, sha256: sha256Hex(Data()))
    store.disconnect()
    #expect(store.activeSession == nil)

    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let orphan = root.appendingPathComponent("orphan-token")
    try Data("orphan".utf8).write(to: orphan)
    try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-(ImageStagingStore.completedTTL + 1))], ofItemAtPath: orphan.path)
    store.pruneExpired(now: now)
    #expect(!FileManager.default.fileExists(atPath: orphan.path))
}

@Test("capture host response carries optional retryability without changing text fields")
func captureHostResponseCarriesRetryability() throws {
    let encoded = try JSONEncoder().encode(CaptureHostResponse(type: "failed", captureID: "busy", code: "image-busy", retryable: true))
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(object["retryable"] as? Bool == true)
    let decoded = try JSONDecoder().decode(CaptureHostResponse.self, from: encoded)
    #expect(decoded.retryable == true)
}

@Test("host stages image frames and forwards a tokenized candidate without a path")
func hostStagesImageFramesAndForwardsTokenizedCandidate() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("promptstudio-host-image-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let origin = CaptureOriginAllowlist.developmentOrigin
    let bytes = Data("image bytes".utf8)
    let digest = sha256Hex(bytes)
    let candidate = BrowserImageCaptureCandidate(
        captureID: "image-host-1",
        pageTitle: "Page",
        pageURL: "https://example.test/private?token=redact",
        siteName: "example.test",
        altText: "A picture",
        originalFileName: "picture.png",
        mimeType: "image/png",
        capturedAt: "2026-08-13T00:00:00.000Z"
    )
    let begin = try imageRequestJSON([
        "type": "imageBegin",
        "origin": origin,
        "candidate": try jsonObject(candidate),
        "expectedByteCount": bytes.count,
        "sha256": digest
    ])
    let chunk = try imageRequestJSON([
        "type": "imageChunk",
        "origin": origin,
        "captureID": candidate.captureID,
        "index": 0,
        "base64Data": bytes.base64EncodedString()
    ])
    let end = try imageRequestJSON([
        "type": "imageEnd",
        "origin": origin,
        "captureID": candidate.captureID,
        "byteCount": bytes.count,
        "sha256": digest
    ])
    let inputURL = try temporaryFile(begin + chunk + end)
    let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("promptstudio-host-image-output-\(UUID().uuidString)")
    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
    defer {
        try? FileManager.default.removeItem(at: inputURL)
        try? FileManager.default.removeItem(at: outputURL)
    }
    let appResponses = [
        CaptureHostResponse(type: "presented", captureID: candidate.captureID),
        CaptureHostResponse(type: "animate", captureID: candidate.captureID, mouthScreenPoint: CaptureScreenPoint(x: 2, y: 3)),
        CaptureHostResponse(type: "saved", captureID: candidate.captureID)
    ]
    let appPayloads = try appResponses.map { try JSONEncoder().encode($0) }
    var forwardedPayload: Data?
    let forwarder = UnixSocketCaptureForwarder(streamingExchange: { payload, _, _, sink in
        forwardedPayload = payload
        for response in appPayloads { try sink(response) }
    })
    let host = PromptStudioCaptureHost(
        trustedOrigin: origin,
        input: try FileHandle(forReadingFrom: inputURL),
        output: try FileHandle(forWritingTo: outputURL),
        forwarder: forwarder,
        stagingStore: ImageStagingStore(rootDirectory: root)
    )
    try host.run()

    let payload = try #require(forwardedPayload)
    let appObject = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
    #expect(appObject["type"] as? String == "imageCapture")
    #expect(appObject["stagingToken"] as? String != nil)
    #expect(appObject["stagedFilePath"] == nil)
    #expect(appObject["fileURL"] == nil)
    #expect(appObject["path"] == nil)
    #expect(String(decoding: payload, as: UTF8.self).contains("private?token=redact"))

    let outputHandle = try FileHandle(forReadingFrom: outputURL)
    var responses: [CaptureHostResponse] = []
    while let frame = try NativeMessagingFramer.readFrame(from: outputHandle) {
        responses.append(try JSONDecoder().decode(CaptureHostResponse.self, from: frame))
    }
    #expect(responses.map(\.type) == ["ack", "ack", "presented", "animate", "saved"])
    #expect(responses.last?.captureID == candidate.captureID)
}

@Test("host reports image busy, rejects forged paths, and enforces image origin")
func hostReportsImageBusyAndRejectsForgeryAndOrigin() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("promptstudio-host-image-busy-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let origin = CaptureOriginAllowlist.developmentOrigin
    let digest = String(repeating: "0", count: 64)
    let candidate = BrowserImageCaptureCandidate(captureID: "busy-image", capturedAt: "2026-08-13T00:00:00.000Z")
    let candidateObject = try jsonObject(candidate)
    let firstBegin = try imageRequestJSON(["type": "imageBegin", "origin": origin, "candidate": candidateObject, "expectedByteCount": 0, "sha256": sha256Hex(Data())])
    let secondBegin = try imageRequestJSON(["type": "imageBegin", "origin": origin, "candidate": ["captureID": "busy-image-2", "capturedAt": "2026-08-13T00:00:00.000Z"], "expectedByteCount": 0, "sha256": sha256Hex(Data())])
    let forged = try imageRequestJSON(["type": "imageBegin", "origin": origin, "candidate": candidateObject, "expectedByteCount": 0, "sha256": digest, "path": "/tmp/forged-local-path"])
    let wrongOrigin = try imageRequestJSON(["type": "imageBegin", "origin": "chrome-extension://abcdefghijklmnopabcdefghijklmnop/", "candidate": candidateObject, "expectedByteCount": 0, "sha256": sha256Hex(Data())])
    let inputURL = try temporaryFile(firstBegin + secondBegin + forged + wrongOrigin)
    let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("promptstudio-host-image-busy-output-\(UUID().uuidString)")
    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
    defer {
        try? FileManager.default.removeItem(at: inputURL)
        try? FileManager.default.removeItem(at: outputURL)
    }
    let host = PromptStudioCaptureHost(
        trustedOrigin: origin,
        input: try FileHandle(forReadingFrom: inputURL),
        output: try FileHandle(forWritingTo: outputURL),
        forwarder: UnixSocketCaptureForwarder(streamingExchange: { _, _, _, _ in fatalError("no app request expected") }),
        stagingStore: ImageStagingStore(rootDirectory: root)
    )
    try host.run()
    let outputHandle = try FileHandle(forReadingFrom: outputURL)
    var responses: [CaptureHostResponse] = []
    while let frame = try NativeMessagingFramer.readFrame(from: outputHandle) {
        responses.append(try JSONDecoder().decode(CaptureHostResponse.self, from: frame))
    }
    #expect(responses.map(\.type) == ["ack", "failed", "failed", "failed"])
    #expect(responses[1].code == "image-busy")
    #expect(responses[1].retryable == true)
    #expect(responses[2].code == "image-path-rejected")
    #expect(responses[3].code == "origin-mismatch" || responses[3].code == "origin-not-allowed")
}

@Test("host forwards bounded drag preview acknowledgements through the app socket")
func hostForwardsDragPreviewAcknowledgement() throws {
    let origin = CaptureOriginAllowlist.developmentOrigin
    let preview = try imageRequestJSON([
        "type": "imageDragPreview",
        "origin": origin,
        "captureID": "drag-1",
        "screenPoint": ["x": 12, "y": 24],
        "insidePet": true,
        "drop": false
    ])
    let inputURL = try temporaryFile(preview)
    let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("promptstudio-host-preview-output-\(UUID().uuidString)")
    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
    defer {
        try? FileManager.default.removeItem(at: inputURL)
        try? FileManager.default.removeItem(at: outputURL)
    }
    var forwarded: Data?
    let appAck = try JSONEncoder().encode(CaptureHostResponse(type: "ack", captureID: "drag-1", code: "preview-accepted"))
    let host = PromptStudioCaptureHost(
        trustedOrigin: origin,
        input: try FileHandle(forReadingFrom: inputURL),
        output: try FileHandle(forWritingTo: outputURL),
        forwarder: UnixSocketCaptureForwarder(streamingExchange: { payload, _, _, sink in
            forwarded = payload
            try sink(appAck)
        }),
        stagingStore: ImageStagingStore(rootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("promptstudio-preview-stage-\(UUID().uuidString)"))
    )
    try host.run()
    let forwardedObject = try #require(forwarded.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
    #expect(forwardedObject["type"] as? String == "imageDragPreview")
    #expect(forwardedObject["captureID"] as? String == "drag-1")
    let outputHandle = try FileHandle(forReadingFrom: outputURL)
    let responseFrame = try #require(try NativeMessagingFramer.readFrame(from: outputHandle))
    let response = try #require(try? JSONDecoder().decode(CaptureHostResponse.self, from: responseFrame))
    #expect(response.type == "ack")
    #expect(response.code == "preview-accepted")
}

private func imageRequestJSON(_ object: [String: Any]) throws -> Data {
    try NativeMessagingFramer.encode(JSONSerialization.data(withJSONObject: object))
}

private func jsonObject<T: Encodable>(_ value: T) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
}

private func sha256Hex(_ data: Data) -> String {
#if canImport(CryptoKit)
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
#else
    ""
#endif
}

@Test("native messaging framing round trips little-endian JSON")
func nativeMessagingFramingRoundTrips() throws {
    let payload = Data(#"{"type":"capture","text":"hello"}"#.utf8)
    let frame = try NativeMessagingFramer.encode(payload)
    #expect(frame.prefix(4) == Data([UInt8(payload.count), 0, 0, 0]))
    #expect(try NativeMessagingFramer.decode(frame) == payload)
}

@Test("native messaging rejects frames over one megabyte")
func nativeMessagingRejectsOversizedFrames() {
    #expect(throws: NativeMessagingError.frameTooLarge) {
        try NativeMessagingFramer.encode(Data(repeating: 0x61, count: NativeMessagingFramer.maxFrameBytes + 1))
    }
}

@Test("stdout responses are framed JSON envelopes with no body leakage")
func stdoutResponseUsesFramedProtocol() throws {
    let response = CaptureHostResponse(
        type: "saved",
        captureID: "capture-1",
        selectedText: "hello",
        mouthScreenPoint: CaptureScreenPoint(x: 12, y: -4)
    )
    let payload = try JSONEncoder().encode(response)
    let frame = try NativeMessagingFramer.encode(payload)
    let decodedPayload = try NativeMessagingFramer.decode(frame)
    let object = try #require(JSONSerialization.jsonObject(with: decodedPayload) as? [String: Any])
    #expect(object["type"] as? String == "saved")
    #expect(object["captureID"] as? String == "capture-1")
    #expect(object["selectedText"] as? String == "hello")
    #expect(object["pageURL"] == nil)
}

@Test("host validates argv origin and emits a framed terminal response")
func hostRunUsesTrustedOriginAndStdoutFraming() throws {
    let candidate = BrowserCaptureCandidate(
        captureID: "capture-run",
        selectedText: "hello",
        pageTitle: "Page",
        pageURL: "https://example.test/private?q=secret",
        siteName: "example.test",
        clickScreenPoint: CaptureScreenPoint(x: 4, y: 8),
        capturedAt: "2026-08-12T00:00:00.000Z"
    )
    let request = CaptureEnvelope(origin: CaptureOriginAllowlist.developmentOrigin, candidate: candidate)
    let inputURL = try temporaryFile(try NativeMessagingFramer.encode(JSONEncoder().encode(request)))
    let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("promptstudio-host-output-(UUID().uuidString)")
    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
    defer {
        try? FileManager.default.removeItem(at: inputURL)
        try? FileManager.default.removeItem(at: outputURL)
    }
    let appResponse = CaptureHostResponse(type: "saved", captureID: candidate.captureID, selectedText: candidate.selectedText)
    let appPayload = try JSONEncoder().encode(appResponse)
    let forwarder = UnixSocketCaptureForwarder(streamingExchange: { _, _, _, sink in
        try sink(appPayload)
    })
    let host = PromptStudioCaptureHost(
        trustedOrigin: CaptureOriginAllowlist.developmentOrigin,
        input: try FileHandle(forReadingFrom: inputURL),
        output: try FileHandle(forWritingTo: outputURL),
        forwarder: forwarder
    )
    try host.run()
    let stdoutFrame = try NativeMessagingFramer.decode(Data(contentsOf: outputURL))
    let response = try JSONDecoder().decode(CaptureHostResponse.self, from: stdoutFrame)
    #expect(response.type == "saved")
    #expect(response.captureID == candidate.captureID)
    #expect(response.selectedText == candidate.selectedText)
}

@Test("origin validation is exact and rejects wildcard origins")
func originAllowlistIsExact() {
    let allowlist = CaptureOriginAllowlist.default
    #expect(allowlist.contains(CaptureOriginAllowlist.developmentOrigin))
    // Deliberately unconfigured fixture; this is not a claimed Web Store ID.
    let unconfiguredProductionOrigin = "chrome-extension://abcdefghijklmnopabcdefghijklmnop/"
    #expect(!allowlist.contains(unconfiguredProductionOrigin))
    #expect(!allowlist.contains("chrome-extension://*"))
    #expect(!allowlist.contains("chrome-extension://another-extension-id/"))
    #expect(CaptureOriginAllowlist.origin(forExtensionID: "abcdefghijklmnopabcdefghijklmnop") == unconfiguredProductionOrigin)
    #expect(CaptureOriginAllowlist.origin(forExtensionID: "abcdefghijklmnopabcdefghijklmnop!") == nil)
    #expect(ProcessOrigin.parse(arguments: ["host", unconfiguredProductionOrigin]) == .rejected(unconfiguredProductionOrigin))
    #expect(ProcessOrigin.parse(arguments: ["host"]) == .missing)
    #expect(ProcessOrigin.parse(arguments: ["host", "chrome-extension://wrong/"]) == .rejected("chrome-extension://wrong/"))
    #expect(ProcessOrigin.parse(arguments: ["host", CaptureOriginAllowlist.developmentOrigin, "--origin=chrome-extension://wrong/"]) == .allowed(CaptureOriginAllowlist.developmentOrigin))
}

@Test("direct execution spoof and argv/envelope mismatch are rejected")
func trustedArgvOriginIsRequired() throws {
    // Deliberately unconfigured fixture; this is not a claimed Web Store ID.
    let unconfiguredProductionOrigin = "chrome-extension://abcdefghijklmnopabcdefghijklmnop/"
    let candidate = BrowserCaptureCandidate(
        captureID: "capture-1", selectedText: "hello", pageTitle: "", pageURL: "", siteName: "",
        clickScreenPoint: CaptureScreenPoint(x: 0, y: 0), capturedAt: "2026-08-12T00:00:00.000Z"
    )
    let envelope = CaptureEnvelope(origin: CaptureOriginAllowlist.developmentOrigin, candidate: candidate)
    #expect(throws: CaptureRequestValidationError.originNotAllowed) {
        try CaptureRequestValidator.validate(envelope, trustedOrigin: unconfiguredProductionOrigin)
    }
    let runtimeAllowlist = CaptureOriginAllowlist(origins: [CaptureOriginAllowlist.developmentOrigin, unconfiguredProductionOrigin])
    #expect(throws: CaptureRequestValidationError.originMismatch) {
        try CaptureRequestValidator.validate(envelope, trustedOrigin: unconfiguredProductionOrigin, allowlist: runtimeAllowlist)
    }
    #expect(ProcessOrigin.parse(arguments: ["PromptStudioCaptureHost"]) == .missing)
    #expect(ProcessOrigin.parse(arguments: ["PromptStudioCaptureHost", "chrome-extension://abcdefghijklmnopabcdefghijklmnop/"]) == .rejected("chrome-extension://abcdefghijklmnopabcdefghijklmnop/"))
}

@Test("runtime allowlist loads a release origin from the helper-side signed config")
func runtimeAllowlistLoadsExplicitProductionID() throws {
    // Deliberately unconfigured fixture; this is not a claimed Web Store ID.
    let unconfiguredProductionOrigin = "chrome-extension://abcdefghijklmnopabcdefghijklmnop/"
    let config = FileManager.default.temporaryDirectory.appendingPathComponent("PromptStudioCaptureHost.allowed-origins-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: config) }
    try Data("{\"allowed_origins\":[\"\(unconfiguredProductionOrigin)\"]}".utf8).write(to: config)
    let allowlist = CaptureOriginAllowlist.runtime(executablePath: "/tmp/PromptStudioCaptureHost", environment: ["PROMPTSTUDIO_CAPTURE_ALLOWED_ORIGINS_FILE": config.path])
    #expect(allowlist.contains(CaptureOriginAllowlist.developmentOrigin))
    #expect(allowlist.contains(unconfiguredProductionOrigin))
}

@Test("socket envelope keeps ISO-8601 capturedAt and core field names")
func socketEnvelopeUsesCanonicalCaptureSchema() throws {
    let browserCandidate = BrowserCaptureCandidate(
        captureID: "capture-1",
        selectedText: "hello",
        pageTitle: "Page",
        pageURL: "https://example.test/path",
        siteName: "example.test",
        clickScreenPoint: CaptureScreenPoint(x: 12, y: 34),
        capturedAt: "2026-08-12T00:00:00.000Z"
    )
    let socketJSON = String(decoding: try JSONEncoder().encode(SocketCaptureEnvelope(candidate: browserCandidate)), as: UTF8.self)
    #expect(socketJSON.contains("\"type\":\"capture\""))
    #expect(socketJSON.contains("\"selectedText\":\"hello\""))
    #expect(socketJSON.contains("2026-08-12T00:00:00.000Z"))
    #expect(!socketJSON.contains("\"origin\""))
}

@Test("host manifest requires an absolute executable and exact origins")
func hostManifestUsesSafeAbsolutePath() throws {
    let manifest = try BrowserHostManifest.make(hostPath: "/Applications/PromptStudio.app/Contents/Helpers/PromptStudioCaptureHost")
    #expect(manifest.path.hasPrefix("/"))
    #expect(manifest.type == "stdio")
    #expect(manifest.allowedOrigins == CaptureOriginAllowlist.default.origins)
    #expect(!manifest.allowedOrigins.contains(where: { $0.contains("*") }))
    #expect(throws: CaptureHostConfigurationError.hostPathMustBeAbsolute) {
        try BrowserHostManifest.make(hostPath: "relative/host")
    }
}

@Test("user browser registration directories cover Chrome Edge and Arc")
func browserRegistrationPathsCoverSupportedBrowsers() {
    let directories = BrowserHostRegistration.userManifestDirectories(homeDirectory: "/Users/tester")
    #expect(directories.contains("/Users/tester/Library/Application Support/Google/Chrome/NativeMessagingHosts"))
    #expect(directories.contains("/Users/tester/Library/Application Support/Microsoft Edge/NativeMessagingHosts"))
    #expect(directories.contains("/Users/tester/Library/Application Support/Arc/User Data/NativeMessagingHosts"))
    #expect(UnixCaptureSocket.defaultPath(homeDirectory: "/Users/tester").hasSuffix("/PromptStudio/web-capture.sock"))
}

@Test("cold launch keeps PromptStudio in the background")
func coldLaunchDoesNotActivateMainApp() {
    #expect(PromptStudioLauncher.launchArguments == ["-g", "-b", "com.creatigo.promptstudio"])
}

@Test("framer rejects partial headers, truncated payloads, and invalid length")
func nativeMessagingFramerRejectsMalformedFrames() throws {
    #expect(throws: NativeMessagingError.truncatedFrame) {
        try NativeMessagingFramer.decode(Data([1, 0, 0]))
    }
    #expect(throws: NativeMessagingError.invalidFrame) {
        try NativeMessagingFramer.decode(Data([4, 0, 0, 0, 0]))
    }
    let partialURL = try temporaryFile(Data([4, 0, 0, 0, 0, 0]))
    defer { try? FileManager.default.removeItem(at: partialURL) }
    let partial = try FileHandle(forReadingFrom: partialURL)
    #expect(throws: NativeMessagingError.truncatedFrame) {
        try NativeMessagingFramer.readFrame(from: partial)
    }
    let partialDeadlineURL = try temporaryFile(Data([4, 0, 0, 0, 0, 0]))
    defer { try? FileManager.default.removeItem(at: partialDeadlineURL) }
    let partialWithDeadline = try FileHandle(forReadingFrom: partialDeadlineURL)
    #expect(throws: NativeMessagingError.truncatedFrame) {
        try NativeMessagingFramer.readFrame(from: partialWithDeadline, deadline: Date().addingTimeInterval(1))
    }
}

@Test("forwarder separates five second cold connection from five minute confirmation")
func forwarderUsesBoundedDeadlines() throws {
    let start = Date(timeIntervalSince1970: 10)
    var observedConnectDeadline: Date?
    var observedResponseDeadline: Date?
    var launchCount = 0
    let forwarder = UnixSocketCaptureForwarder(
        socketPath: "/does/not/matter",
        launchApp: { launchCount += 1 },
        exchange: { payload, connectDeadline, responseDeadline in
            observedConnectDeadline = connectDeadline
            observedResponseDeadline = responseDeadline
            return payload
        },
        clock: { start },
        sleep: { _ in }
    )
    _ = try forwarder.forward(Data("ok".utf8))
    #expect(launchCount == 0)
    #expect(observedConnectDeadline == start.addingTimeInterval(5))
    #expect(observedResponseDeadline == start.addingTimeInterval(300))
}

@Test("host forwards every presented animate and terminal frame on one request")
func hostForwardsCompleteResponseSequence() throws {
    let candidate = BrowserCaptureCandidate(
        captureID: "capture-sequence",
        selectedText: "hello",
        pageTitle: "Page",
        pageURL: "https://example.test",
        siteName: "example.test",
        clickScreenPoint: CaptureScreenPoint(x: 4, y: 8),
        capturedAt: "2026-08-12T00:00:00.000Z"
    )
    let request = CaptureEnvelope(origin: CaptureOriginAllowlist.developmentOrigin, candidate: candidate)
    let inputURL = try temporaryFile(try NativeMessagingFramer.encode(JSONEncoder().encode(request)))
    let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("promptstudio-sequence-output-\(UUID().uuidString)")
    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
    defer {
        try? FileManager.default.removeItem(at: inputURL)
        try? FileManager.default.removeItem(at: outputURL)
    }
    let appResponses = [
        CaptureHostResponse(type: "presented", captureID: candidate.captureID, selectedText: candidate.selectedText),
        CaptureHostResponse(type: "animate", captureID: candidate.captureID, selectedText: candidate.selectedText, mouthScreenPoint: CaptureScreenPoint(x: 20, y: 30)),
        CaptureHostResponse(type: "saved", captureID: candidate.captureID, selectedText: candidate.selectedText, clearSource: true),
    ]
    let appPayloads = try appResponses.map { try JSONEncoder().encode($0) }
    let forwarder = UnixSocketCaptureForwarder(streamingExchange: { _, _, _, sink in
        for payload in appPayloads { try sink(payload) }
    })
    let host = PromptStudioCaptureHost(
        trustedOrigin: CaptureOriginAllowlist.developmentOrigin,
        input: try FileHandle(forReadingFrom: inputURL),
        output: try FileHandle(forWritingTo: outputURL),
        forwarder: forwarder
    )
    try host.run()
    let outputHandle = try FileHandle(forReadingFrom: outputURL)
    var types: [String] = []
    var savedClearSource: Bool?
    while let frame = try NativeMessagingFramer.readFrame(from: outputHandle) {
        let response = try JSONDecoder().decode(CaptureHostResponse.self, from: frame)
        types.append(response.type)
        if response.type == "saved" { savedClearSource = response.clearSource }
    }
    #expect(types == ["presented", "animate", "saved"])
    #expect(savedClearSource == true)
}

@Test("EOF before a terminal response is a retryable stream failure")
func forwarderTreatsEOFWithoutTerminalAsRetryable() throws {
    var clockCalls = 0
    var responseDeadlines: [Date] = []
    let forwarder = UnixSocketCaptureForwarder(streamingExchange: { _, _, responseDeadline, sink in
        responseDeadlines.append(responseDeadline)
        let presented = try JSONEncoder().encode(CaptureHostResponse(type: "presented", captureID: "capture-eof"))
        try sink(presented)
        throw CaptureHostRuntimeError.responseDisconnected
    }, clock: {
        clockCalls += 1
        let time: TimeInterval = clockCalls < 3 ? 10 : (clockCalls < 8 ? 100 : 200)
        return Date(timeIntervalSince1970: time)
    }, sleep: { _ in })
    #expect(throws: CaptureHostRuntimeError.responseDisconnected) {
        try forwarder.forwardStreaming(Data("payload".utf8), responseSink: { _ in })
    }
    #expect(responseDeadlines.count == 1)
}

private func temporaryFile(_ data: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("promptstudio-framer-\(UUID().uuidString)")
    try data.write(to: url)
    return url
}
