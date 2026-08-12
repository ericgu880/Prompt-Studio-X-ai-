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

/// The DOM representation that produced a browser image capture.
public enum ImageDOMSourceKind: String, Codable, CaseIterable, Sendable {
    case image
    case picture
    case srcset
    case dataURL
    case blob
    case canvas
    case inlineSVG
    case cssBackground
}

/// The trusted browser-side acquisition path for an image's bytes.
public enum ImageAcquisitionMethod: String, Codable, CaseIterable, Sendable {
    case pageContext
    case extensionFetch
    case loadedBytes
    case screenshot
}

/// Web-page metadata retained alongside a captured prompt.
public struct CapturedSource: Codable, Equatable, Sendable {
    public var pageTitle: String
    public var pageURL: String
    public var siteName: String
    public var capturedAt: Date
    public var resourceURL: String?
    public var imageDOMSourceKind: ImageDOMSourceKind?
    public var imageAcquisitionMethod: ImageAcquisitionMethod?
    public var isScreenshotCapture: Bool?

    private enum CodingKeys: String, CodingKey {
        case pageTitle
        case pageURL
        case siteName
        case capturedAt
        case resourceURL
        case imageDOMSourceKind
        case imageAcquisitionMethod
        case isScreenshotCapture
    }

    public init(
        pageTitle: String = "",
        pageURL: String = "",
        siteName: String = "",
        capturedAt: Date = Date(),
        resourceURL: String? = nil,
        imageDOMSourceKind: ImageDOMSourceKind? = nil,
        imageAcquisitionMethod: ImageAcquisitionMethod? = nil,
        isScreenshotCapture: Bool? = nil
    ) {
        self.pageTitle = pageTitle
        self.pageURL = pageURL
        self.siteName = siteName
        self.capturedAt = capturedAt
        self.resourceURL = sanitizedWebResourceURL(resourceURL)
        self.imageDOMSourceKind = imageDOMSourceKind
        self.imageAcquisitionMethod = imageAcquisitionMethod
        self.isScreenshotCapture = isScreenshotCapture
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.pageTitle = try values.decodeIfPresent(String.self, forKey: .pageTitle) ?? ""
        self.pageURL = try values.decodeIfPresent(String.self, forKey: .pageURL) ?? ""
        self.siteName = try values.decodeIfPresent(String.self, forKey: .siteName) ?? ""
        self.capturedAt = try values.decodeIfPresent(Date.self, forKey: .capturedAt) ?? Date()
        self.resourceURL = sanitizedWebResourceURL(try values.decodeIfPresent(String.self, forKey: .resourceURL))
        self.imageDOMSourceKind = try values.decodeIfPresent(ImageDOMSourceKind.self, forKey: .imageDOMSourceKind)
        self.imageAcquisitionMethod = try values.decodeIfPresent(ImageAcquisitionMethod.self, forKey: .imageAcquisitionMethod)
        self.isScreenshotCapture = try values.decodeIfPresent(Bool.self, forKey: .isScreenshotCapture)
    }
}

/// Metadata and integrity information for an image staged by the browser host.
public struct WebImageCaptureCandidate: Codable, Equatable, Sendable {
    public var captureID: String
    public var pageTitle: String
    public var pageURL: String
    public var siteName: String
    public var resourceURL: String?
    public var altText: String
    public var originalFileName: String
    public var domSourceKind: ImageDOMSourceKind
    public var acquisitionMethod: ImageAcquisitionMethod
    public var isScreenshot: Bool
    public var mimeType: String?
    public var byteCount: Int64
    public var sha256: String
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var clickScreenPoint: WebCapturePoint
    public var capturedAt: Date

    public init(
        captureID: String,
        domSourceKind: ImageDOMSourceKind,
        acquisitionMethod: ImageAcquisitionMethod,
        sha256: String,
        pageTitle: String = "",
        pageURL: String = "",
        siteName: String = "",
        resourceURL: String? = nil,
        altText: String = "",
        originalFileName: String = "",
        isScreenshot: Bool = false,
        mimeType: String? = nil,
        byteCount: Int64 = 0,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        clickScreenPoint: WebCapturePoint = .zero,
        capturedAt: Date = Date()
    ) {
        self.captureID = captureID
        self.pageTitle = pageTitle
        self.pageURL = pageURL
        self.siteName = siteName
        self.resourceURL = sanitizedWebResourceURL(resourceURL)
        self.altText = altText
        self.originalFileName = originalFileName
        self.domSourceKind = domSourceKind
        self.acquisitionMethod = acquisitionMethod
        self.isScreenshot = isScreenshot
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.sha256 = sha256
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.clickScreenPoint = clickScreenPoint
        self.capturedAt = capturedAt
    }

    public var capturedSource: CapturedSource {
        CapturedSource(
            pageTitle: pageTitle,
            pageURL: pageURL,
            siteName: siteName,
            capturedAt: capturedAt,
            resourceURL: sanitizedWebResourceURL(resourceURL),
            imageDOMSourceKind: domSourceKind,
            imageAcquisitionMethod: acquisitionMethod,
            isScreenshotCapture: isScreenshot || acquisitionMethod == .screenshot
        )
    }
}

/// Removes credentials and fragments while retaining the resource URL query.
internal func sanitizedWebResourceURL(_ rawValue: String?) -> String? {
    guard let rawValue,
          !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          var components = URLComponents(string: rawValue) else {
        return nil
    }
    components.user = nil
    components.password = nil
    components.fragment = nil
    return components.string
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
