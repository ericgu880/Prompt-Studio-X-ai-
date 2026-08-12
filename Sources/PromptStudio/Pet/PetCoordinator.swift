import AppKit
import Combine
import Foundation

@MainActor
final class PetCoordinator: ObservableObject {
    @Published private(set) var machine = PetStateMachine()
    @Published private(set) var pendingRequest: PetCaptureRequest?
    @Published private(set) var preferences: PetPreferences
    @Published private(set) var pausedUntil: Date?
    @Published private(set) var isSessionHidden = false

    var captureHandler: PetCaptureHandler?

    private let preferencesStore: PetPreferencesStore
    private var preferenceObserver: NSObjectProtocol?
    private var didStart = false
    private var resetTask: Task<Void, Never>?

    private lazy var panelController = PetPanelController(coordinator: self)
    private lazy var statusItemController = PetStatusItemController(coordinator: self)
    private lazy var socketCoordinatorServer = PetCaptureSocketServer { [weak self] request in
        guard let self else {
            return .failed(captureID: request.id, message: PetCaptureError.unavailable.localizedDescription)
        }
        return await self.capture(request)
    }

    init(
        preferencesStore: PetPreferencesStore? = nil,
        captureHandler: PetCaptureHandler? = nil
    ) {
        let store = preferencesStore ?? PetPreferencesStore.shared
        self.preferencesStore = store
        preferences = store.value
        self.captureHandler = captureHandler
    }

    var captureSocketServer: PetCaptureSocketServer {
        socketCoordinatorServer
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        _ = statusItemController
        if preferences.hostRegistrationEnabled {
            socketCoordinatorServer.start()
        }
        preferenceObserver = NotificationCenter.default.addObserver(
            forName: .petPreferencesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let value = notification.object as? PetPreferences
            Task { @MainActor [weak self] in
                guard let self, let value else { return }
                preferences = value
                if value.hostRegistrationEnabled {
                    socketCoordinatorServer.start()
                } else {
                    socketCoordinatorServer.stop()
                }
                if value.showOnLaunch {
                    if isSessionHidden {
                        show()
                    }
                } else if !isSessionHidden {
                    hideForSession()
                }
            }
        }

        if preferences.showOnLaunch {
            show()
        } else {
            hideForSession()
        }
    }

    func stop() {
        guard didStart else { return }
        didStart = false
        resetTask?.cancel()
        resetTask = nil
        socketCoordinatorServer.stop()
        if let preferenceObserver {
            NotificationCenter.default.removeObserver(preferenceObserver)
            self.preferenceObserver = nil
        }
        panelController.hide()
    }

    func show() {
        isSessionHidden = false
        _ = machine.transition(.show)
        panelController.show()
    }

    func hideForSession() {
        isSessionHidden = true
        if let pendingRequest {
            NotificationCenter.default.post(
                name: .petCaptureCancelled,
                object: PetCaptureOutcome.cancelled(captureID: pendingRequest.id)
            )
        }
        pendingRequest = nil
        panelController.setAsking(false)
        _ = machine.transition(.hide)
        panelController.hide()
    }

    func pauseCapture(for seconds: TimeInterval = 3_600) {
        pausedUntil = Date().addingTimeInterval(seconds)
        if let pendingRequest {
            NotificationCenter.default.post(
                name: .petCaptureCancelled,
                object: PetCaptureOutcome.cancelled(captureID: pendingRequest.id)
            )
        }
        pendingRequest = nil
        if machine.state == .asking {
            _ = machine.transition(.cancel)
            scheduleReset()
        }
    }

    func resumeCapture() {
        pausedUntil = nil
    }

    func openPromptStudio() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.styleMask.contains(.resizable) && $0.contentView != nil }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// Entry point for the native messaging/socket layer. A visible pet asks
    /// first; hidden mode bypasses the confirmation UI and saves immediately.
    func requestCapture(_ request: PetCaptureRequest) {
        let request = requestWithCurrentPreferences(request)
        let text = request.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            postFailure(for: request, message: PetCaptureError.invalidSelection.localizedDescription)
            return
        }
        guard preferences.captureEnabled else {
            postFailure(for: request, message: PetCaptureError.disabled.localizedDescription)
            return
        }
        if let pausedUntil, pausedUntil > Date() {
            postFailure(for: request, message: PetCaptureError.paused(until: pausedUntil).localizedDescription)
            return
        }
        if self.pausedUntil != nil {
            self.pausedUntil = nil
        }

        if isSessionHidden || machine.state == .hidden {
            Task { @MainActor [weak self] in
                _ = await self?.performCapture(request, silently: true)
            }
            return
        }

        pendingRequest = request
        _ = machine.transition(.captureRequested)
        panelController.setAsking(true)
        NotificationCenter.default.post(name: .petCapturePresented, object: request)
    }

    func confirmPendingCapture() {
        guard let request = pendingRequest else { return }
        pendingRequest = nil
        panelController.setAsking(false)
        _ = machine.transition(.confirm)
        Task { @MainActor [weak self] in
            _ = await self?.performCapture(request, silently: false)
        }
    }

    func cancelPendingCapture() {
        guard let request = pendingRequest else { return }
        pendingRequest = nil
        panelController.setAsking(false)
        _ = machine.transition(.cancel)
        NotificationCenter.default.post(name: .petCaptureCancelled, object: PetCaptureOutcome.cancelled(captureID: request.id))
        scheduleReset()
    }

    /// A testable async boundary for callers that need the result directly.
    /// Visible requests still require explicit confirmation through
    /// `confirmPendingCapture()` and therefore return a `presented` outcome.
    func capture(_ request: PetCaptureRequest) async -> PetCaptureOutcome {
        let request = requestWithCurrentPreferences(request)
        let isHidden = isSessionHidden || machine.state == .hidden
        let text = request.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return rejectedCapture(request, message: PetCaptureError.invalidSelection.localizedDescription, silently: isHidden)
        }
        guard preferences.captureEnabled else {
            return rejectedCapture(request, message: PetCaptureError.disabled.localizedDescription, silently: isHidden)
        }
        if let pausedUntil, pausedUntil > Date() {
            return rejectedCapture(request, message: PetCaptureError.paused(until: pausedUntil).localizedDescription, silently: isHidden)
        }
        guard isHidden else {
            requestCapture(request)
            return .presented(captureID: request.id)
        }
        return await performCapture(request, silently: true)
    }

    func panelDidMove(to origin: CGPoint) {
        // Kept as an integration hook for diagnostics and multi-display tests.
        _ = origin
    }

    private func performCapture(_ request: PetCaptureRequest, silently: Bool) async -> PetCaptureOutcome {
        guard let captureHandler else {
            let outcome = PetCaptureOutcome.failed(captureID: request.id, message: PetCaptureError.unavailable.localizedDescription)
            if !silently {
                _ = machine.transition(.failed)
                NotificationCenter.default.post(name: .petCaptureFailed, object: outcome)
                scheduleReset()
            } else {
                sendHiddenNotification(outcome: outcome)
            }
            return outcome
        }

        do {
            let outcome = try await captureHandler(request)
            if silently {
                sendHiddenNotification(outcome: outcome)
                if outcome.isSuccess {
                    postSourceClearIfNeeded(request: request, outcome: outcome)
                }
                return outcome
            }
            if outcome.isSuccess {
                _ = machine.transition(.saved)
                NotificationCenter.default.post(name: .petCaptureSaved, object: outcome)
                postSourceClearIfNeeded(request: request, outcome: outcome)
            } else {
                _ = machine.transition(.failed)
                NotificationCenter.default.post(name: .petCaptureFailed, object: outcome)
            }
            scheduleReset()
            return outcome
        } catch {
            let outcome = PetCaptureOutcome.failed(captureID: request.id, message: error.localizedDescription)
            if silently {
                sendHiddenNotification(outcome: outcome)
            } else {
                _ = machine.transition(.failed)
                NotificationCenter.default.post(name: .petCaptureFailed, object: outcome)
                scheduleReset()
            }
            return outcome
        }
    }

    private func sendHiddenNotification(outcome: PetCaptureOutcome) {
        NotificationCenter.default.post(name: .petHiddenCaptureSaved, object: outcome)
        let notification = NSUserNotification()
        let didSave: Bool
        switch outcome {
        case .saved, .alreadySaved:
            didSave = true
        case .presented, .animate, .cancelled, .failed:
            didSave = false
        }
        notification.title = didSave ? "PromptStudio" : "网页采集失败"
        notification.informativeText = didSave ? "网页文字已保存到采集收件箱" : (outcome.failureMessage ?? "无法保存网页文字")
        notification.soundName = preferences.soundEnabled ? NSUserNotificationDefaultSoundName : nil
        NSUserNotificationCenter.default.deliver(notification)
    }

    private func postSourceClearIfNeeded(request: PetCaptureRequest, outcome: PetCaptureOutcome) {
        guard request.clearSourceAfterCapture else { return }
        switch outcome {
        case .saved, .alreadySaved:
            NotificationCenter.default.post(name: .petCaptureSourceShouldClear, object: outcome)
        case .presented, .animate, .cancelled, .failed:
            break
        }
    }

    private func requestWithCurrentPreferences(_ request: PetCaptureRequest) -> PetCaptureRequest {
        PetCaptureRequest(
            id: request.id,
            selectedText: request.selectedText,
            pageTitle: request.pageTitle,
            pageURL: request.pageURL,
            siteName: request.siteName,
            clickPoint: request.clickPoint,
            capturedAt: request.capturedAt,
            defaultFolderID: preferences.defaultFolderID,
            clearSourceAfterCapture: preferences.clearSourceAfterCapture,
            soundEnabled: preferences.soundEnabled
        )
    }

    private func postFailure(for request: PetCaptureRequest, message: String) {
        let outcome = PetCaptureOutcome.failed(captureID: request.id, message: message)
        NotificationCenter.default.post(name: .petCaptureFailed, object: outcome)
    }

    private func rejectedCapture(_ request: PetCaptureRequest, message: String, silently: Bool) -> PetCaptureOutcome {
        let outcome = PetCaptureOutcome.failed(captureID: request.id, message: message)
        if silently {
            sendHiddenNotification(outcome: outcome)
        }
        return outcome
    }

    private func scheduleReset() {
        resetTask?.cancel()
        resetTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            _ = machine.transition(.reset)
        }
    }
}
