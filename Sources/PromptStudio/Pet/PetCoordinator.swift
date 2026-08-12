import AppKit
import Combine
import Foundation

@MainActor
final class PetCoordinator: ObservableObject {
    @Published private(set) var machine = PetStateMachine()
    @Published private(set) var pendingRequest: PetCaptureRequest?
    @Published private(set) var pendingImageRequest: PetImageCaptureRequest?
    @Published private(set) var imagePhase = ImageDropPhase()
    @Published private(set) var preferences: PetPreferences
    @Published private(set) var pausedUntil: Date?
    @Published private(set) var isSessionHidden = false

    var captureHandler: PetCaptureHandler?
    var imageCaptureHandler: PetImageCaptureHandler?
    let hostRegistrationService: PetHostRegistrationService

    private let preferencesStore: PetPreferencesStore
    private var preferenceObserver: NSObjectProtocol?
    private var captureDisconnectObserver: NSObjectProtocol?
    private var didStart = false
    private var resetTask: Task<Void, Never>?
    private var pendingImageStagedURL: URL?

    private lazy var panelController = PetPanelController(coordinator: self)
    private lazy var statusItemController = PetStatusItemController(coordinator: self)
    private lazy var socketCoordinatorServer = PetCaptureSocketServer { [weak self] request in
        guard let self else {
            return .failed(captureID: request.id, message: PetCaptureError.unavailable.localizedDescription)
        }
        return await self.capture(request)
    } imageHandler: { [weak self] request, stagedURL in
        guard let self else { throw PetCaptureError.unavailable }
        return await self.receiveImageCapture(request, stagedFileURL: stagedURL)
    } imageDragHandler: { [weak self] preview in
        guard let self else {
            return PetImageDragFeedback(captureID: preview.captureID, sequence: preview.sequence, insidePet: false, mouthScreenPoint: nil, terminal: preview.drop)
        }
        return self.receiveImageDragPreview(preview)
    } imageDragCancelHandler: { [weak self] captureID in
        self?.cancelImageDrag(captureID: captureID)
    }

    init(
        preferencesStore: PetPreferencesStore? = nil,
        hostRegistrationService: PetHostRegistrationService? = nil,
        captureHandler: PetCaptureHandler? = nil
    ) {
        let store = preferencesStore ?? PetPreferencesStore.shared
        self.preferencesStore = store
        preferences = store.value
        self.hostRegistrationService = hostRegistrationService ?? .live()
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
            enableBrowserConnection()
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
                    enableBrowserConnection()
                } else {
                    socketCoordinatorServer.stop()
                    _ = try? hostRegistrationService.removeHost()
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
        captureDisconnectObserver = NotificationCenter.default.addObserver(
            forName: .petCaptureClientDisconnected,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let captureID = notification.object as? String else { return }
            Task { @MainActor [weak self] in
                self?.abandonPendingCapture(captureID: captureID)
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
        if let captureDisconnectObserver {
            NotificationCenter.default.removeObserver(captureDisconnectObserver)
            self.captureDisconnectObserver = nil
        }
        panelController.hide()
    }

    private func abandonPendingCapture(captureID: String) {
        if pendingImageRequest?.captureID == captureID {
            cancelPendingImageCapture()
            return
        }
        guard pendingRequest?.captureID == captureID else { return }
        pendingRequest = nil
        panelController.setAsking(false)
        resetTask?.cancel()
        _ = machine.transition(.cancel)
        _ = machine.transition(.reset)
    }

    private func enableBrowserConnection() {
        do {
            try hostRegistrationService.installHost()
            socketCoordinatorServer.start()
        } catch {
            socketCoordinatorServer.stop()
        }
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
        if pendingImageRequest != nil {
            cancelPendingImageCapture()
        }
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

    private func cleanupStagedImage() {
        if let url = pendingImageStagedURL {
            try? FileManager.default.removeItem(at: url)
        }
        pendingImageStagedURL = nil
        pendingImageRequest = nil
    }

    private func restoreHiddenAfterImageIfNeeded() {
        let restore = imagePhase.shouldRestoreHiddenPet
        imagePhase.reset()
        guard restore else { return }
        isSessionHidden = true
        panelController.setAsking(false)
        _ = machine.transition(.hide)
        panelController.hide()
    }

    private func imageBusyOutcome(captureID: String) -> PetCaptureOutcome {
        .failed(captureID: captureID, message: "桌宠正在处理上一张图片", code: "image-busy", retryable: true)
    }

    func receiveImageCapture(_ request: PetImageCaptureRequest, stagedFileURL: URL) async -> PetCaptureOutcome {
        guard preferences.captureEnabled else {
            try? FileManager.default.removeItem(at: stagedFileURL)
            return .failed(captureID: request.captureID, message: PetCaptureError.disabled.localizedDescription, code: "capture-disabled")
        }
        let isDrop = imagePhase.isDropped && imagePhase.captureID == request.captureID
        let machineIsAvailable = machine.state == .idle || machine.state == .hidden
        if !isDrop && (imagePhase.isActive || pendingImageRequest != nil || pendingRequest != nil || !machineIsAvailable) {
            try? FileManager.default.removeItem(at: stagedFileURL)
            return imageBusyOutcome(captureID: request.captureID)
        }
        if isDrop {
            pendingImageStagedURL = stagedFileURL
            _ = machine.transition(.captureRequested)
            _ = machine.transition(.confirm)
            return await performImageCapture(request, stagedFileURL: stagedFileURL, silently: false, restoreDrop: true)
        }

        pendingImageRequest = request
        pendingImageStagedURL = stagedFileURL
        pendingImageThumbnail = NSImage(contentsOf: stagedFileURL)
        let wasHidden = isSessionHidden || machine.state == .hidden
        imagePhase.begin(captureID: request.captureID, temporarilyShown: wasHidden)
        if wasHidden { show() }
        _ = machine.transition(.captureRequested)
        panelController.setAsking(true)
        panelController.moveNearBrowserPoint(request.clickPoint)
        NotificationCenter.default.post(name: .petCapturePresented, object: request)
        return .presented(captureID: request.captureID)
    }

    @Published private(set) var pendingImageThumbnail: NSImage?

    func confirmPendingImageCapture() {
        guard let request = pendingImageRequest, let stagedURL = pendingImageStagedURL else { return }
        pendingImageRequest = nil
        panelController.setAsking(false)
        _ = machine.transition(.confirm)
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.performImageCapture(request, stagedFileURL: stagedURL, silently: false, restoreDrop: false)
        }
    }

    func cancelPendingImageCapture() {
        guard let request = pendingImageRequest else { return }
        let restore = imagePhase.shouldRestoreHiddenPet
        cleanupStagedImage()
        pendingImageThumbnail = nil
        panelController.setAsking(false)
        _ = machine.transition(.cancel)
        NotificationCenter.default.post(name: .petCaptureCancelled, object: PetCaptureOutcome.cancelled(captureID: request.captureID))
        if restore {
            isSessionHidden = true
            _ = machine.transition(.hide)
            panelController.hide()
        }
        imagePhase.reset()
        scheduleReset()
    }

    private func performImageCapture(
        _ request: PetImageCaptureRequest,
        stagedFileURL: URL,
        silently: Bool,
        restoreDrop: Bool
    ) async -> PetCaptureOutcome {
        guard let imageCaptureHandler else {
            try? FileManager.default.removeItem(at: stagedFileURL)
            let outcome = PetCaptureOutcome.failed(captureID: request.captureID, message: PetCaptureError.unavailable.localizedDescription, code: "image-unavailable", retryable: true)
            if !silently { _ = machine.transition(.failed); NotificationCenter.default.post(name: .petCaptureFailed, object: outcome) }
            if imagePhase.shouldRestoreHiddenPet { restoreHiddenAfterImageIfNeeded() }
            else { imagePhase.reset() }
            return outcome
        }
        do {
            let saved = try await imageCaptureHandler(request, stagedFileURL)
            try? FileManager.default.removeItem(at: stagedFileURL)
            pendingImageStagedURL = nil
            pendingImageThumbnail = nil
            let outcome = outcomeWithPetMouth(saved)
            if outcome.isSuccess {
                _ = machine.transition(.saved)
                NotificationCenter.default.post(name: .petCaptureSaved, object: outcome)
            } else {
                _ = machine.transition(.failed)
                NotificationCenter.default.post(name: .petCaptureFailed, object: outcome)
            }
            if imagePhase.shouldRestoreHiddenPet { restoreHiddenAfterImageIfNeeded() }
            else { imagePhase.reset() }
            scheduleReset()
            return outcome
        } catch {
            try? FileManager.default.removeItem(at: stagedFileURL)
            let outcome = PetCaptureOutcome.failed(captureID: request.captureID, message: error.localizedDescription, code: "capture-save-failed", retryable: true)
            _ = machine.transition(.failed)
            NotificationCenter.default.post(name: .petCaptureFailed, object: outcome)
            if imagePhase.shouldRestoreHiddenPet { restoreHiddenAfterImageIfNeeded() }
            else { imagePhase.reset() }
            scheduleReset()
            return outcome
        }
    }

    func receiveImageDragPreview(_ preview: PetImageDragPreview) -> PetImageDragFeedback {
        if !imagePhase.isActive {
            guard PetImageCaptureAdmission.canBeginDrag(
                state: machine.state,
                hasPendingText: pendingRequest != nil,
                hasPendingImage: pendingImageRequest != nil
            ) else {
                return PetImageDragFeedback(captureID: preview.captureID, sequence: 0, insidePet: false, mouthScreenPoint: nil, terminal: preview.drop)
            }
            let hidden = isSessionHidden || machine.state == .hidden
            guard imagePhase.begin(captureID: preview.captureID, temporarilyShown: hidden) else {
                return PetImageDragFeedback(captureID: preview.captureID, sequence: 0, insidePet: false, mouthScreenPoint: nil, terminal: preview.drop)
            }
            if hidden { show() }
        }
        guard imagePhase.captureID == preview.captureID else {
            return PetImageDragFeedback(captureID: preview.captureID, sequence: 0, insidePet: false, mouthScreenPoint: nil, terminal: preview.drop)
        }
        let accepted = preview.drop
            ? imagePhase.receiveFinal(sequence: preview.sequence)
            : imagePhase.receivePreview(sequence: preview.sequence)
        guard accepted else {
            return PetImageDragFeedback(captureID: preview.captureID, sequence: preview.sequence, insidePet: false, mouthScreenPoint: nil, terminal: preview.drop)
        }
        let hit = panelController.hitTest(browserPoint: preview.screenPoint)
        if preview.drop {
            _ = imagePhase.consumeFinalAck(sequence: preview.sequence, insidePet: hit.insidePet, mouthPoint: hit.mouthPoint)
        } else {
            _ = imagePhase.consumePreviewAck(sequence: preview.sequence, insidePet: hit.insidePet, mouthPoint: hit.mouthPoint)
        }
        return PetImageDragFeedback(captureID: preview.captureID, sequence: preview.sequence, insidePet: hit.insidePet, mouthScreenPoint: hit.mouthPoint, terminal: preview.drop)
    }

    func cancelImageDrag(captureID: String) {
        guard imagePhase.captureID == captureID else { return }
        imagePhase.cancel()
        restoreHiddenAfterImageIfNeeded()
    }

    /// Entry point for the native messaging/socket layer. A visible pet asks
    /// first; hidden mode bypasses the confirmation UI and saves immediately.
    @discardableResult
    func requestCapture(_ request: PetCaptureRequest) -> PetCaptureOutcome? {
        let request = requestWithCurrentPreferences(request)
        let hidden = isSessionHidden || machine.state == .hidden
        // Hidden mode intentionally bypasses the visible state machine and
        // saves directly; visible requests must be the sole owner of idle →
        // asking so a second browser request cannot replace the first card.
        if imagePhase.isActive || pendingImageRequest != nil || PetCaptureAdmission.isBusy(
            state: machine.state,
            hasPendingRequest: pendingRequest != nil,
            hidden: hidden
        ) {
            let outcome = PetCaptureAdmission.busyOutcome(captureID: request.id)
            postFailure(outcome)
            return outcome
        }
        let text = request.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            postFailure(for: request, message: PetCaptureError.invalidSelection.localizedDescription)
            return .failed(captureID: request.id, message: PetCaptureError.invalidSelection.localizedDescription)
        }
        guard preferences.captureEnabled else {
            postFailure(for: request, message: PetCaptureError.disabled.localizedDescription)
            return .failed(captureID: request.id, message: PetCaptureError.disabled.localizedDescription)
        }
        if let pausedUntil, pausedUntil > Date() {
            postFailure(for: request, message: PetCaptureError.paused(until: pausedUntil).localizedDescription)
            return .failed(captureID: request.id, message: PetCaptureError.paused(until: pausedUntil).localizedDescription)
        }
        if self.pausedUntil != nil {
            self.pausedUntil = nil
        }

        if hidden {
            Task { @MainActor [weak self] in
                _ = await self?.performCapture(request, silently: true)
            }
            return nil
        }

        pendingRequest = request
        _ = machine.transition(.captureRequested)
        panelController.setAsking(true)
        panelController.moveNearBrowserPoint(request.clickPoint)
        NotificationCenter.default.post(name: .petCapturePresented, object: request)
        return .presented(captureID: request.id)
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
        if PetCaptureAdmission.isBusy(
            state: machine.state,
            hasPendingRequest: pendingRequest != nil,
            hidden: isHidden
        ) {
            let outcome = PetCaptureAdmission.busyOutcome(captureID: request.id)
            postFailure(outcome)
            return outcome
        }
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
            return requestCapture(request) ?? .failed(
                captureID: request.id,
                message: PetCaptureError.unavailable.localizedDescription
            )
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
            let savedOutcome = try await captureHandler(request)
            let outcome = silently ? savedOutcome : outcomeWithPetMouth(savedOutcome)
            if silently {
                sendHiddenNotification(outcome: outcome)
                if outcome.isSuccess {
                    postSourceClearIfNeeded(request: request, outcome: outcome)
                }
                return outcome
            }
            if outcome.isSuccess {
                _ = machine.transition(.saved)
                postSourceClearIfNeeded(request: request, outcome: outcome)
                NotificationCenter.default.post(name: .petCaptureSaved, object: outcome)
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

    private func outcomeWithPetMouth(_ outcome: PetCaptureOutcome) -> PetCaptureOutcome {
        switch outcome {
        case .saved(let captureID, _):
            return .saved(captureID: captureID, mouthPoint: panelController.mouthBrowserScreenPoint)
        case .alreadySaved(let captureID, _):
            return .alreadySaved(captureID: captureID, mouthPoint: panelController.mouthBrowserScreenPoint)
        case .presented, .animate, .cancelled, .failed:
            return outcome
        }
    }

    private func sendHiddenNotification(outcome: PetCaptureOutcome) {
        PetCaptureNotifications.postHiddenCompletion(outcome)
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

    private func postFailure(_ outcome: PetCaptureOutcome) {
        NotificationCenter.default.post(name: .petCaptureFailed, object: outcome)
    }

    private func postFailure(for request: PetCaptureRequest, message: String) {
        postFailure(.failed(captureID: request.id, message: message))
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
