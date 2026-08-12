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
