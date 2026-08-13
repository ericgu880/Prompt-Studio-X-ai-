import Foundation

/// The small, app-local envelope passed between the browser capture coordinator
/// and the PromptStudioCore adapter. Core owns its production capture model;
/// this type deliberately stays internal to the app target.
struct PetCaptureRequest: Codable, Equatable, Identifiable, Sendable {
    struct ScreenPoint: Codable, Equatable, Sendable {
        let x: Double
        let y: Double

        init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }

        init(_ point: CGPoint) {
            x = Double(point.x)
            y = Double(point.y)
        }

        var cgPoint: CGPoint { CGPoint(x: x, y: y) }
    }

    let id: String
    let selectedText: String
    let pageTitle: String
    let pageURL: String
    let siteName: String
    let clickPoint: ScreenPoint?
    let capturedAt: Date
    let defaultFolderID: String?
    let clearSourceAfterCapture: Bool
    let soundEnabled: Bool

    init(
        id: String = UUID().uuidString,
        selectedText: String,
        pageTitle: String = "",
        pageURL: String = "",
        siteName: String = "",
        clickPoint: ScreenPoint? = nil,
        capturedAt: Date = Date(),
        defaultFolderID: String? = nil,
        clearSourceAfterCapture: Bool = false,
        soundEnabled: Bool = false
    ) {
        self.id = id
        self.selectedText = selectedText
        self.pageTitle = pageTitle
        self.pageURL = pageURL
        self.siteName = siteName
        self.clickPoint = clickPoint
        self.capturedAt = capturedAt
        self.defaultFolderID = defaultFolderID
        self.clearSourceAfterCapture = clearSourceAfterCapture
        self.soundEnabled = soundEnabled
    }

    var captureID: String { id }
}

enum PetCaptureOutcome: Codable, Equatable, Sendable {
    case presented(captureID: String)
    case saved(captureID: String, mouthPoint: PetCaptureRequest.ScreenPoint?)
    case alreadySaved(captureID: String, mouthPoint: PetCaptureRequest.ScreenPoint?)
    case animate(captureID: String, mouthPoint: PetCaptureRequest.ScreenPoint?)
    case cancelled(captureID: String)
    case failed(
        captureID: String,
        message: String,
        code: String? = nil,
        retryable: Bool = false
    )

    private enum CodingKeys: String, CodingKey {
        case kind
        case captureID
        case mouthPoint
        case message
        case code
        case retryable
    }

    private enum Kind: String, Codable {
        case saved
        case alreadySaved
        case animate
        case presented
        case cancelled
        case failed
    }

    var captureID: String {
        switch self {
        case .presented(let id), .saved(let id, _), .alreadySaved(let id, _), .animate(let id, _), .cancelled(let id), .failed(let id, _, _, _):
            return id
        }
    }

    var isSuccess: Bool {
        switch self {
        case .saved, .alreadySaved: true
        case .presented, .animate, .cancelled, .failed: false
        }
    }

    var mouthPoint: PetCaptureRequest.ScreenPoint? {
        switch self {
        case .saved(_, let point), .alreadySaved(_, let point), .animate(_, let point): point
        case .presented, .cancelled, .failed: nil
        }
    }

    var failureMessage: String? {
        if case .failed(_, let message, _, _) = self { return message }
        return nil
    }

    var failureCode: String? {
        if case .failed(_, _, let code, _) = self { return code }
        return nil
    }

    var isRetryable: Bool {
        if case .failed(_, _, _, let retryable) = self { return retryable }
        return false
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try values.decode(Kind.self, forKey: .kind)
        let captureID = try values.decode(String.self, forKey: .captureID)
        switch kind {
        case .presented:
            self = .presented(captureID: captureID)
        case .saved:
            self = .saved(captureID: captureID, mouthPoint: try values.decodeIfPresent(PetCaptureRequest.ScreenPoint.self, forKey: .mouthPoint))
        case .alreadySaved:
            self = .alreadySaved(captureID: captureID, mouthPoint: try values.decodeIfPresent(PetCaptureRequest.ScreenPoint.self, forKey: .mouthPoint))
        case .animate:
            self = .animate(captureID: captureID, mouthPoint: try values.decodeIfPresent(PetCaptureRequest.ScreenPoint.self, forKey: .mouthPoint))
        case .cancelled:
            self = .cancelled(captureID: captureID)
        case .failed:
            self = .failed(
                captureID: captureID,
                message: try values.decode(String.self, forKey: .message),
                code: try values.decodeIfPresent(String.self, forKey: .code),
                retryable: try values.decodeIfPresent(Bool.self, forKey: .retryable) ?? false
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .presented(let captureID):
            try values.encode(Kind.presented, forKey: .kind)
            try values.encode(captureID, forKey: .captureID)
        case .saved(let captureID, let mouthPoint):
            try values.encode(Kind.saved, forKey: .kind)
            try values.encode(captureID, forKey: .captureID)
            try values.encodeIfPresent(mouthPoint, forKey: .mouthPoint)
        case .alreadySaved(let captureID, let mouthPoint):
            try values.encode(Kind.alreadySaved, forKey: .kind)
            try values.encode(captureID, forKey: .captureID)
            try values.encodeIfPresent(mouthPoint, forKey: .mouthPoint)
        case .animate(let captureID, let mouthPoint):
            try values.encode(Kind.animate, forKey: .kind)
            try values.encode(captureID, forKey: .captureID)
            try values.encodeIfPresent(mouthPoint, forKey: .mouthPoint)
        case .cancelled(let captureID):
            try values.encode(Kind.cancelled, forKey: .kind)
            try values.encode(captureID, forKey: .captureID)
        case .failed(let captureID, let message, let code, let retryable):
            try values.encode(Kind.failed, forKey: .kind)
            try values.encode(captureID, forKey: .captureID)
            try values.encode(message, forKey: .message)
            try values.encodeIfPresent(code, forKey: .code)
            if retryable {
                try values.encode(retryable, forKey: .retryable)
            }
        }
    }
}

enum PetCaptureError: LocalizedError, Equatable {
    case unavailable
    case busy
    case disabled
    case paused(until: Date)
    case invalidSelection

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "网页采集服务暂不可用"
        case .busy:
            "桌宠正在处理上一条采集"
        case .disabled:
            "网页采集已关闭"
        case .paused(let until):
            "网页采集暂停至 \(until.formatted(date: .omitted, time: .shortened))"
        case .invalidSelection:
            "没有可采集的文本"
        }
    }
}

typealias PetCaptureHandler = (PetCaptureRequest) async throws -> PetCaptureOutcome

/// App-local image metadata.  The host sends this envelope only after it has
/// staged bytes under its user-only CaptureStaging directory; the socket server
/// resolves the token before this value reaches the coordinator.
struct PetImageCaptureCandidate: Codable, Equatable, Sendable {
    let captureID: String
    let pageTitle: String
    let pageURL: String
    let siteName: String
    let resourceURL: String?
    let altText: String
    let originalFileName: String
    let domSourceKind: String
    let acquisitionMethod: String
    let isScreenshot: Bool
    let mimeType: String?
    let byteCount: Int64
    let sha256: String
    let pixelWidth: Int?
    let pixelHeight: Int?
    let clickScreenPoint: PetCaptureRequest.ScreenPoint?
    let capturedAt: Date

    enum CodingKeys: String, CodingKey {
        case captureID, pageTitle, pageURL, siteName, resourceURL, altText
        case originalFileName, domSourceKind, acquisitionMethod, isScreenshot
        case mimeType, byteCount, sha256, pixelWidth, pixelHeight
        case clickScreenPoint, capturedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        captureID = try values.decode(String.self, forKey: .captureID)
        pageTitle = try values.decodeIfPresent(String.self, forKey: .pageTitle) ?? ""
        pageURL = try values.decodeIfPresent(String.self, forKey: .pageURL) ?? ""
        siteName = try values.decodeIfPresent(String.self, forKey: .siteName) ?? ""
        resourceURL = try values.decodeIfPresent(String.self, forKey: .resourceURL)
        altText = try values.decodeIfPresent(String.self, forKey: .altText) ?? ""
        originalFileName = try values.decodeIfPresent(String.self, forKey: .originalFileName) ?? ""
        domSourceKind = try values.decodeIfPresent(String.self, forKey: .domSourceKind) ?? "image"
        acquisitionMethod = try values.decodeIfPresent(String.self, forKey: .acquisitionMethod) ?? "pageContext"
        isScreenshot = try values.decodeIfPresent(Bool.self, forKey: .isScreenshot) ?? false
        mimeType = try values.decodeIfPresent(String.self, forKey: .mimeType)
        byteCount = try values.decodeIfPresent(Int64.self, forKey: .byteCount) ?? 0
        sha256 = try values.decodeIfPresent(String.self, forKey: .sha256) ?? ""
        pixelWidth = try values.decodeIfPresent(Int.self, forKey: .pixelWidth)
        pixelHeight = try values.decodeIfPresent(Int.self, forKey: .pixelHeight)
        clickScreenPoint = try values.decodeIfPresent(PetCaptureRequest.ScreenPoint.self, forKey: .clickScreenPoint)
        if let string = try? values.decode(String.self, forKey: .capturedAt),
           let date = ISO8601DateFormatter().date(from: string) {
            capturedAt = date
        } else if let seconds = try? values.decode(Double.self, forKey: .capturedAt) {
            capturedAt = Date(timeIntervalSince1970: seconds)
        } else {
            capturedAt = Date()
        }
    }

    init(
        captureID: String,
        pageTitle: String = "",
        pageURL: String = "",
        siteName: String = "",
        resourceURL: String? = nil,
        altText: String = "",
        originalFileName: String = "",
        domSourceKind: String = "image",
        acquisitionMethod: String = "pageContext",
        isScreenshot: Bool = false,
        mimeType: String? = nil,
        byteCount: Int64 = 0,
        sha256: String = "",
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        clickScreenPoint: PetCaptureRequest.ScreenPoint? = nil,
        capturedAt: Date = Date()
    ) {
        self.captureID = captureID
        self.pageTitle = pageTitle
        self.pageURL = pageURL
        self.siteName = siteName
        self.resourceURL = resourceURL
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
}

struct PetImageCaptureRequest: Codable, Equatable, Sendable {
    let stagingToken: String
    let candidate: PetImageCaptureCandidate

    var captureID: String { candidate.captureID }
    var clickPoint: PetCaptureRequest.ScreenPoint? { candidate.clickScreenPoint }
}

typealias PetImageCaptureHandler = (PetImageCaptureRequest, URL) async throws -> PetCaptureOutcome
typealias PetImageDragHandler = (PetImageDragPreview) -> PetImageDragFeedback
typealias PetImageDragCancelHandler = (String) -> Void

struct PetImageDragPreview: Codable, Equatable, Sendable {
    let captureID: String
    let sequence: Int
    let screenPoint: PetCaptureRequest.ScreenPoint?
    let drop: Bool
}

struct PetImageDragFeedback: Codable, Equatable, Sendable {
    let captureID: String
    let sequence: Int
    let insidePet: Bool
    let mouthScreenPoint: PetCaptureRequest.ScreenPoint?
    let terminal: Bool
}

enum ImageDropDecision: String, Equatable, Sendable {
    case waiting
    case drop
    case cancel
}

/// Independent image drag state.  Text capture continues to use
/// `PetStateMachine`; this type only accepts the exact sequence that was sent
/// to native hit-testing, preventing stale ACKs from saving an image.
struct ImageDropPhase: Equatable, Sendable {
    private(set) var captureID: String?
    private(set) var sequence = 0
    private(set) var insidePet = false
    private(set) var mouthScreenPoint: PetCaptureRequest.ScreenPoint?
    private(set) var isActive = false
    private(set) var isDropped = false
    private(set) var shouldRestoreHiddenPet = false

    @discardableResult
    mutating func begin(captureID: String, temporarilyShown: Bool = false) -> Bool {
        guard !captureID.isEmpty, !isActive else { return false }
        self.captureID = captureID
        sequence = 0
        insidePet = false
        mouthScreenPoint = nil
        isActive = true
        isDropped = false
        shouldRestoreHiddenPet = temporarilyShown
        return true
    }

    mutating func preview(point: PetCaptureRequest.ScreenPoint?) -> Int {
        guard isActive else { return 0 }
        sequence += 1
        return sequence
    }

    /// Records a sequence allocated by the browser. Native ACKs must echo this
    /// exact value; the app never substitutes the latest point for a stale ACK.
    @discardableResult
    mutating func receivePreview(sequence: Int) -> Bool {
        guard isActive, sequence > 0, sequence > self.sequence else { return false }
        self.sequence = sequence
        return true
    }

    @discardableResult
    mutating func receiveFinal(sequence: Int) -> Bool {
        guard isActive, sequence > 0, sequence > self.sequence else { return false }
        self.sequence = sequence
        return true
    }

    @discardableResult
    mutating func consumePreviewAck(
        sequence: Int,
        insidePet: Bool,
        mouthPoint: PetCaptureRequest.ScreenPoint?
    ) -> Bool {
        guard isActive, sequence == self.sequence else { return false }
        self.insidePet = insidePet
        mouthScreenPoint = mouthPoint
        return true
    }

    mutating func requestFinal(point: PetCaptureRequest.ScreenPoint?) -> Int {
        guard isActive else { return 0 }
        sequence += 1
        return sequence
    }

    mutating func consumeFinalAck(
        sequence: Int,
        insidePet: Bool,
        mouthPoint: PetCaptureRequest.ScreenPoint?
    ) -> ImageDropDecision {
        guard isActive, sequence == self.sequence else { return .waiting }
        self.insidePet = insidePet
        mouthScreenPoint = mouthPoint
        if insidePet {
            isDropped = true
            return .drop
        }
        isActive = false
        return .cancel
    }

    mutating func cancel() {
        isActive = false
        isDropped = false
        insidePet = false
        mouthScreenPoint = nil
    }

    mutating func complete() {
        isActive = false
        isDropped = false
    }

    mutating func reset() {
        captureID = nil
        sequence = 0
        insidePet = false
        mouthScreenPoint = nil
        isActive = false
        isDropped = false
        shouldRestoreHiddenPet = false
    }
}

enum PetCaptureAdmission {
    static func isBusy(state: PetState, hasPendingRequest: Bool, hidden: Bool) -> Bool {
        guard !hidden else { return false }
        return state != .idle || hasPendingRequest
    }

    static func busyOutcome(captureID: String) -> PetCaptureOutcome {
        .failed(
            captureID: captureID,
            message: PetCaptureError.busy.localizedDescription,
            code: "pet-busy",
            retryable: true
        )
    }
}

enum PetImageCaptureAdmission {
    static func canBeginDrag(
        state: PetState,
        hasPendingText: Bool,
        hasPendingImage: Bool
    ) -> Bool {
        guard !hasPendingText, !hasPendingImage else { return false }
        return state == .idle || state == .hidden
    }

    static func shouldReleaseActiveImage(
        activeCaptureID: String?,
        outcomeCaptureID: String
    ) -> Bool {
        activeCaptureID != nil && activeCaptureID == outcomeCaptureID
    }
}

enum PetCaptureNotifications {
    static func postHiddenCompletion(_ outcome: PetCaptureOutcome) {
        NotificationCenter.default.post(name: .petHiddenCaptureCompleted, object: outcome)
    }
}

extension Notification.Name {
    static let petCapturePresented = Notification.Name("PromptStudio.petCapturePresented")
    static let petCaptureCancelled = Notification.Name("PromptStudio.petCaptureCancelled")
    static let petCaptureSaved = Notification.Name("PromptStudio.petCaptureSaved")
    static let petCaptureFailed = Notification.Name("PromptStudio.petCaptureFailed")
    static let petHiddenCaptureCompleted = Notification.Name("PromptStudio.petHiddenCaptureCompleted")
    static let petCaptureSourceShouldClear = Notification.Name("PromptStudio.petCaptureSourceShouldClear")
    static let petCaptureClientDisconnected = Notification.Name("PromptStudio.petCaptureClientDisconnected")
    static let petPreferencesDidChange = Notification.Name("PromptStudio.petPreferencesDidChange")
}
