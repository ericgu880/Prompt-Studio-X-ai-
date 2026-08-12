import Foundation

/// A screen-space point supplied by a browser capture overlay.
public struct WebCapturePoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public static let zero = WebCapturePoint(x: 0, y: 0)

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Compatibility spelling for consumers that use the generic screen-coordinate name.
public typealias ScreenPoint = WebCapturePoint

/// Web-page metadata retained alongside a captured prompt.
public struct CapturedSource: Codable, Equatable, Sendable {
    public var pageTitle: String
    public var pageURL: String
    public var siteName: String
    public var capturedAt: Date

    public init(
        pageTitle: String = "",
        pageURL: String = "",
        siteName: String = "",
        capturedAt: Date = Date()
    ) {
        self.pageTitle = pageTitle
        self.pageURL = pageURL
        self.siteName = siteName
        self.capturedAt = capturedAt
    }
}

/// A browser selection awaiting confirmation or persistence.
public struct WebCaptureCandidate: Codable, Equatable, Sendable {
    public var captureID: String
    public var selectedText: String
    public var pageTitle: String
    public var pageURL: String
    public var siteName: String
    public var clickScreenPoint: WebCapturePoint
    public var capturedAt: Date

    public init(
        captureID: String,
        selectedText: String,
        pageTitle: String = "",
        pageURL: String = "",
        siteName: String = "",
        clickScreenPoint: WebCapturePoint = .zero,
        capturedAt: Date = Date()
    ) {
        self.captureID = captureID
        self.selectedText = selectedText
        self.pageTitle = pageTitle
        self.pageURL = pageURL
        self.siteName = siteName
        self.clickScreenPoint = clickScreenPoint
        self.capturedAt = capturedAt
    }

    public var capturedSource: CapturedSource {
        CapturedSource(
            pageTitle: pageTitle,
            pageURL: pageURL,
            siteName: siteName,
            capturedAt: capturedAt
        )
    }
}

/// Lifecycle events emitted by the local web-capture coordinator.
///
/// The explicit `type` discriminator keeps the payload stable for the browser wire protocol.
public enum WebCaptureEvent: Codable, Equatable, Sendable {
    case presented(captureID: String)
    case cancelled(captureID: String)
    case animate(captureID: String, mouthScreenPoint: WebCapturePoint)
    case saved(captureID: String, itemID: String)
    case failed(captureID: String, code: String, retryable: Bool)

    private enum CodingKeys: String, CodingKey {
        case type
        case captureID
        case mouthScreenPoint
        case itemID
        case code
        case retryable
    }

    private enum EventType: String, Codable {
        case presented
        case cancelled
        case animate
        case saved
        case failed
    }

    public var captureID: String {
        switch self {
        case .presented(let captureID),
             .cancelled(let captureID),
             .animate(let captureID, _),
             .saved(let captureID, _),
             .failed(let captureID, _, _):
            return captureID
        }
    }

    public var type: String {
        switch self {
        case .presented: return EventType.presented.rawValue
        case .cancelled: return EventType.cancelled.rawValue
        case .animate: return EventType.animate.rawValue
        case .saved: return EventType.saved.rawValue
        case .failed: return EventType.failed.rawValue
        }
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let type = try values.decode(EventType.self, forKey: .type)
        let captureID = try values.decode(String.self, forKey: .captureID)
        switch type {
        case .presented:
            self = .presented(captureID: captureID)
        case .cancelled:
            self = .cancelled(captureID: captureID)
        case .animate:
            self = .animate(
                captureID: captureID,
                mouthScreenPoint: try values.decode(WebCapturePoint.self, forKey: .mouthScreenPoint)
            )
        case .saved:
            self = .saved(
                captureID: captureID,
                itemID: try values.decode(String.self, forKey: .itemID)
            )
        case .failed:
            self = .failed(
                captureID: captureID,
                code: try values.decode(String.self, forKey: .code),
                retryable: try values.decode(Bool.self, forKey: .retryable)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .presented(let captureID):
            try values.encode(EventType.presented, forKey: .type)
            try values.encode(captureID, forKey: .captureID)
        case .cancelled(let captureID):
            try values.encode(EventType.cancelled, forKey: .type)
            try values.encode(captureID, forKey: .captureID)
        case .animate(let captureID, let mouthScreenPoint):
            try values.encode(EventType.animate, forKey: .type)
            try values.encode(captureID, forKey: .captureID)
            try values.encode(mouthScreenPoint, forKey: .mouthScreenPoint)
        case .saved(let captureID, let itemID):
            try values.encode(EventType.saved, forKey: .type)
            try values.encode(captureID, forKey: .captureID)
            try values.encode(itemID, forKey: .itemID)
        case .failed(let captureID, let code, let retryable):
            try values.encode(EventType.failed, forKey: .type)
            try values.encode(captureID, forKey: .captureID)
            try values.encode(code, forKey: .code)
            try values.encode(retryable, forKey: .retryable)
        }
    }
}
