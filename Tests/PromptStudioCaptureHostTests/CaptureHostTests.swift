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

@Test("origin validation is exact and rejects wildcard origins")
func originAllowlistIsExact() {
    let allowlist = CaptureOriginAllowlist.default
    #expect(allowlist.contains(CaptureOriginAllowlist.productionOrigin))
    #expect(allowlist.contains(CaptureOriginAllowlist.developmentOrigin))
    #expect(!allowlist.contains("chrome-extension://*"))
    #expect(!allowlist.contains("chrome-extension://another-extension-id/"))
    #expect(ProcessOrigin.parse(arguments: ["host", CaptureOriginAllowlist.productionOrigin]) == .allowed(CaptureOriginAllowlist.productionOrigin))
    #expect(ProcessOrigin.parse(arguments: ["host"]) == .missing)
    #expect(ProcessOrigin.parse(arguments: ["host", "chrome-extension://wrong/"]) == .rejected("chrome-extension://wrong/"))
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
