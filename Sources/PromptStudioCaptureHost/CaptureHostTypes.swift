import Foundation

public struct CaptureOriginAllowlist: Equatable, Sendable {
    // These IDs are deliberately fixed. A release extension must retain its ID; a development
    // build uses the second ID. Neither value is a wildcard or a prefix match.
    public static let productionOrigin = "chrome-extension://cnafjhfhjdmkknjgojhnkglgllliimjo/"
    public static let developmentOrigin = "chrome-extension://pnafjhfhjdmkknjgojhnkglgllliimjo/"

    public let origins: [String]

    public static let `default` = CaptureOriginAllowlist(origins: [productionOrigin, developmentOrigin])

    public init(origins: [String]) {
        self.origins = origins
    }

    public func contains(_ origin: String) -> Bool {
        origins.contains(origin)
    }
}

public enum ProcessOrigin: Equatable, Sendable {
    case allowed(String)
    case missing
    case rejected(String)

    public static func parse(arguments: [String], allowlist: CaptureOriginAllowlist = .default) -> ProcessOrigin {
        let rawValue = arguments.first(where: { $0.hasPrefix("--origin=") }).map {
            String($0.dropFirst("--origin=".count))
        } ?? arguments.dropFirst().first
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
    public let selectedText: String?
    public let message: String?
    public let mouthScreenPoint: CaptureScreenPoint?

    private enum CodingKeys: String, CodingKey {
        case type
        case status
        case captureID
        case code
        case message
        case selectedText
        case text
        case mouthScreenPoint
        case mouthPoint
    }

    public init(
        type: String,
        captureID: String,
        code: String? = nil,
        selectedText: String? = nil,
        message: String? = nil,
        mouthScreenPoint: CaptureScreenPoint? = nil
    ) {
        self.type = type
        self.captureID = captureID
        self.code = code
        self.selectedText = selectedText
        self.message = message
        self.mouthScreenPoint = mouthScreenPoint
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let typeValue = try values.decodeIfPresent(String.self, forKey: .type)
        let statusValue = try values.decodeIfPresent(String.self, forKey: .status)
        let rawType = typeValue ?? statusValue ?? "failed"
        type = rawType == "captureResult" ? "failed" : rawType
        captureID = try values.decodeIfPresent(String.self, forKey: .captureID) ?? ""
        code = try values.decodeIfPresent(String.self, forKey: .code)
        message = try values.decodeIfPresent(String.self, forKey: .message)
            ?? code
        let selectedTextValue = try values.decodeIfPresent(String.self, forKey: .selectedText)
        let textValue = try values.decodeIfPresent(String.self, forKey: .text)
        selectedText = selectedTextValue ?? textValue
        let mouthScreenPointValue = try values.decodeIfPresent(CaptureScreenPoint.self, forKey: .mouthScreenPoint)
        let mouthPointValue = try values.decodeIfPresent(CaptureScreenPoint.self, forKey: .mouthPoint)
        mouthScreenPoint = mouthScreenPointValue ?? mouthPointValue
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(type, forKey: .type)
        try values.encode(captureID, forKey: .captureID)
        try values.encodeIfPresent(code, forKey: .code)
        try values.encodeIfPresent(message, forKey: .message)
        try values.encodeIfPresent(selectedText, forKey: .selectedText)
        try values.encodeIfPresent(mouthScreenPoint, forKey: .mouthScreenPoint)
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
