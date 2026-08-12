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
public enum WebCaptureEvent: String, Codable, CaseIterable, Sendable {
    case presented
    case cancelled
    case animate
    case saved
    case failed
}
