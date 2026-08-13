import Foundation

public struct CaptureOriginAllowlist: Equatable, Sendable {
    // The development ID is deliberately fixed from the checked-in public manifest key. A
    // production/Web Store ID is loaded only from an explicit signed build configuration.
    public static let developmentOrigin = "chrome-extension://ejdemjnekbbpodkgfpngckkhghfeheng/"

    public static func origin(forExtensionID extensionID: String) -> String? {
        guard extensionID.count == 32, extensionID.allSatisfy({ $0 >= "a" && $0 <= "p" }) else { return nil }
        return "chrome-extension://\(extensionID)/"
    }

    public let origins: [String]

    public static let `default` = CaptureOriginAllowlist(origins: [developmentOrigin])

    public init(origins: [String]) {
        self.origins = origins
    }

    public func contains(_ origin: String) -> Bool {
        origins.contains(origin)
    }

    public static func runtime(executablePath: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> CaptureOriginAllowlist {
        var origins = Set(Self.default.origins)
        let configPath = environment["PROMPTSTUDIO_CAPTURE_ALLOWED_ORIGINS_FILE"]
            ?? URL(fileURLWithPath: executablePath).deletingLastPathComponent()
                .appendingPathComponent("PromptStudioCaptureHost.allowed-origins.json").path
        if let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
           let config = try? JSONDecoder().decode(AllowedOriginsConfiguration.self, from: data) {
            origins.formUnion(config.allowedOrigins.filter { isExactOrigin($0) })
        }
        return CaptureOriginAllowlist(origins: origins.sorted())
    }

    private static func isExactOrigin(_ value: String) -> Bool {
        guard value.hasPrefix("chrome-extension://"), value.hasSuffix("/") else { return false }
        let id = value.dropFirst("chrome-extension://".count).dropLast()
        return id.count == 32 && id.allSatisfy { ("a"..."p").contains(String($0)) }
    }

    private struct AllowedOriginsConfiguration: Decodable {
        let allowedOrigins: [String]

        enum CodingKeys: String, CodingKey {
            case allowedOrigins = "allowed_origins"
        }
    }
}

public enum ProcessOrigin: Equatable, Sendable {
    case allowed(String)
    case missing
    case rejected(String)

    public static func parse(arguments: [String], allowlist: CaptureOriginAllowlist = .default) -> ProcessOrigin {
        // Chromium supplies the extension origin as argv[1]. Do not accept a later
        // flag or envelope field as an alternate authentication channel: direct
        // invocations must have the exact browser-provided argument in this slot.
        let rawValue = arguments.count > 1 ? arguments[1] : nil
        guard let rawValue, !rawValue.isEmpty else {
            return .missing
        }
        let origin = rawValue
        return allowlist.contains(origin) ? .allowed(origin) : .rejected(origin)
    }
}

public struct CaptureScreenPoint: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct CaptureScreenRect: Codable, Equatable, Sendable {
    public let left: Double
    public let top: Double
    public let right: Double
    public let bottom: Double

    public init(left: Double, top: Double, right: Double, bottom: Double) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }
}

/// Browser-side and app-side JSON use an ISO-8601 string for capturedAt. The host validates and
/// forwards this value unchanged; the app decoder owns the date strategy.
public struct BrowserCaptureCandidate: Codable, Equatable, Sendable {
    public let captureID: String
    public let selectedText: String
    public let pageTitle: String
    public let pageURL: String
    public let siteName: String
    public let clickScreenPoint: CaptureScreenPoint
    public let capturedAt: String

    public init(
        captureID: String,
        selectedText: String,
        pageTitle: String,
        pageURL: String,
        siteName: String,
        clickScreenPoint: CaptureScreenPoint,
        capturedAt: String
    ) {
        self.captureID = captureID
        self.selectedText = selectedText
        self.pageTitle = pageTitle
        self.pageURL = pageURL
        self.siteName = siteName
        self.clickScreenPoint = clickScreenPoint
        self.capturedAt = capturedAt
    }
}

public struct CaptureEnvelope: Codable, Equatable, Sendable {
    public let type: String
    public let origin: String
    public let candidate: BrowserCaptureCandidate

    public init(type: String = "capture", origin: String, candidate: BrowserCaptureCandidate) {
        self.type = type
        self.origin = origin
        self.candidate = candidate
    }
}

public enum CaptureRequestValidationError: Error, Equatable, CustomStringConvertible, Sendable {
    case originNotAllowed
    case originMismatch

    public var description: String {
        switch self {
        case .originNotAllowed: return "origin is not allowlisted"
        case .originMismatch: return "envelope origin does not match trusted argv origin"
        }
    }
}

public enum CaptureRequestValidator {
    public static func validate(
        _ envelope: CaptureEnvelope,
        trustedOrigin: String,
        allowlist: CaptureOriginAllowlist = .default
    ) throws -> CaptureEnvelope {
        guard allowlist.contains(trustedOrigin) else { throw CaptureRequestValidationError.originNotAllowed }
        guard envelope.origin == trustedOrigin else { throw CaptureRequestValidationError.originMismatch }
        guard allowlist.contains(envelope.origin) else { throw CaptureRequestValidationError.originNotAllowed }
        return envelope
    }
}

/// The wire payload consumed by the app-side WebCapture socket. `capturedAt` stays ISO-8601 text
/// so the host cannot silently change the capture timestamp representation.
struct SocketCaptureEnvelope: Encodable, Equatable, Sendable {
    let type: String
    let candidate: SocketCaptureCandidate

    init(type: String = "capture", candidate: BrowserCaptureCandidate) {
        self.type = type
        self.candidate = SocketCaptureCandidate(candidate)
    }
}

struct SocketCaptureCandidate: Encodable, Equatable, Sendable {
    let captureID: String
    let selectedText: String
    let pageTitle: String
    let pageURL: String
    let siteName: String
    let clickScreenPoint: CaptureScreenPoint
    let capturedAt: String

    init(_ candidate: BrowserCaptureCandidate) {
        captureID = candidate.captureID
        selectedText = candidate.selectedText
        pageTitle = candidate.pageTitle
        pageURL = candidate.pageURL
        siteName = candidate.siteName
        clickScreenPoint = candidate.clickScreenPoint
        capturedAt = candidate.capturedAt
    }
}

public struct CaptureHostResponse: Codable, Equatable, Sendable {
    public let type: String
    public let captureID: String
    public let code: String?
    public let retryable: Bool?
    public let selectedText: String?
    public let message: String?
    public let mouthScreenPoint: CaptureScreenPoint?
    public let clearSource: Bool?
    public let sequence: Int?
    public let insidePet: Bool?

    private enum CodingKeys: String, CodingKey {
        case type
        case status
        case captureID
        case code
        case retryable
        case message
        case selectedText
        case text
        case mouthScreenPoint
        case mouthPoint
        case clearSource
        case sequence
        case insidePet
    }

    public init(
        type: String,
        captureID: String,
        code: String? = nil,
        retryable: Bool? = nil,
        selectedText: String? = nil,
        message: String? = nil,
        mouthScreenPoint: CaptureScreenPoint? = nil,
        clearSource: Bool? = nil,
        sequence: Int? = nil,
        insidePet: Bool? = nil
    ) {
        self.type = type
        self.captureID = captureID
        self.code = code
        self.retryable = retryable
        self.selectedText = selectedText
        self.message = message
        self.mouthScreenPoint = mouthScreenPoint
        self.clearSource = clearSource
        self.sequence = sequence
        self.insidePet = insidePet
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let typeValue = try values.decodeIfPresent(String.self, forKey: .type)
        let statusValue = try values.decodeIfPresent(String.self, forKey: .status)
        let rawType = typeValue ?? statusValue ?? "failed"
        type = rawType == "captureResult" ? "failed" : rawType
        captureID = try values.decodeIfPresent(String.self, forKey: .captureID) ?? ""
        code = try values.decodeIfPresent(String.self, forKey: .code)
        retryable = try values.decodeIfPresent(Bool.self, forKey: .retryable)
        message = try values.decodeIfPresent(String.self, forKey: .message)
            ?? code
        let selectedTextValue = try values.decodeIfPresent(String.self, forKey: .selectedText)
        let textValue = try values.decodeIfPresent(String.self, forKey: .text)
        selectedText = selectedTextValue ?? textValue
        let mouthScreenPointValue = try values.decodeIfPresent(CaptureScreenPoint.self, forKey: .mouthScreenPoint)
        let mouthPointValue = try values.decodeIfPresent(CaptureScreenPoint.self, forKey: .mouthPoint)
        mouthScreenPoint = mouthScreenPointValue ?? mouthPointValue
        clearSource = try values.decodeIfPresent(Bool.self, forKey: .clearSource)
        sequence = try values.decodeIfPresent(Int.self, forKey: .sequence)
        insidePet = try values.decodeIfPresent(Bool.self, forKey: .insidePet)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(type, forKey: .type)
        try values.encode(captureID, forKey: .captureID)
        try values.encodeIfPresent(code, forKey: .code)
        try values.encodeIfPresent(retryable, forKey: .retryable)
        try values.encodeIfPresent(message, forKey: .message)
        try values.encodeIfPresent(selectedText, forKey: .selectedText)
        try values.encodeIfPresent(mouthScreenPoint, forKey: .mouthScreenPoint)
        try values.encodeIfPresent(clearSource, forKey: .clearSource)
        try values.encodeIfPresent(sequence, forKey: .sequence)
        try values.encodeIfPresent(insidePet, forKey: .insidePet)
    }
}

public enum CaptureHostConfigurationError: Error, Equatable, CustomStringConvertible, Sendable {
    case hostPathMustBeAbsolute
    case hostPathMustNotContainNUL

    public var description: String {
        switch self {
        case .hostPathMustBeAbsolute: return "native host path must be absolute"
        case .hostPathMustNotContainNUL: return "native host path contains NUL"
        }
    }
}

public struct BrowserHostManifest: Codable, Equatable, Sendable {
    public let name: String
    public let description: String
    public let path: String
    public let type: String
    public let allowedOrigins: [String]

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case path
        case type
        case allowedOrigins = "allowed_origins"
    }

    public static func make(
        hostPath: String,
        allowlist: CaptureOriginAllowlist = .default,
        name: String = "com.creatigo.promptstudio.capture"
    ) throws -> BrowserHostManifest {
        guard !hostPath.contains("\0") else { throw CaptureHostConfigurationError.hostPathMustNotContainNUL }
        guard hostPath.hasPrefix("/") else { throw CaptureHostConfigurationError.hostPathMustBeAbsolute }
        return BrowserHostManifest(
            name: name,
            description: "PromptStudio local web capture host",
            path: hostPath,
            type: "stdio",
            allowedOrigins: allowlist.origins
        )
    }
}

public enum BrowserHostRegistration {
    public static func userManifestDirectories(homeDirectory: String) -> [String] {
        let base = homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
        return [
            "\(base)/Library/Application Support/Google/Chrome/NativeMessagingHosts",
            "\(base)/Library/Application Support/Microsoft Edge/NativeMessagingHosts",
            "\(base)/Library/Application Support/Arc/User Data/NativeMessagingHosts",
        ]
    }
}
