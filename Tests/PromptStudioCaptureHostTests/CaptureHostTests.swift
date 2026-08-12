import Foundation
import Testing
@testable import PromptStudioCaptureHost

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

@Test("forwarder separates five second cold connection from sixty second confirmation")
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
    #expect(observedResponseDeadline == start.addingTimeInterval(60))
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
