import Foundation
import Darwin

@main
struct PromptStudioPetTests {
    static func main() async {
        var failures: [String] = []
        var machine = PetStateMachine()
        _ = machine.transition(.captureRequested)
        check(machine.state == .asking, "visible capture asks", failures: &failures)
        _ = machine.transition(.confirm)
        check(machine.state == .eating, "confirmation starts saving", failures: &failures)
        _ = machine.transition(.saved)
        check(machine.state == .success, "save reaches success", failures: &failures)
        _ = machine.transition(.reset)
        _ = machine.transition(.captureRequested)
        _ = machine.transition(.cancel)
        check(machine.state == .cancelled, "cancel reaches cancelled", failures: &failures)
        _ = machine.transition(.reset)
        _ = machine.transition(.hide)
        check(machine.state == .hidden, "hide reaches hidden", failures: &failures)
        _ = machine.transition(.show)
        check(machine.state == .idle, "show restores idle", failures: &failures)
        check(PetPreferences.defaults.showOnLaunch, "launch visibility default", failures: &failures)
        check(PetPreferences.defaults.captureEnabled, "capture default is enabled", failures: &failures)
        check(!PetPreferences.defaults.soundEnabled, "sound default is off", failures: &failures)
        check(PetPreferences.defaults.defaultFolderID == "folder-capture-inbox", "capture folder default", failures: &failures)
        check(!PetPreferences.defaults.hostRegistrationEnabled, "browser registration requires explicit opt-in", failures: &failures)

        check(!PetCaptureAdmission.isBusy(state: .idle, hasPendingRequest: false, hidden: false), "first visible capture is admitted", failures: &failures)
        check(PetCaptureAdmission.isBusy(state: .asking, hasPendingRequest: true, hidden: false), "second visible capture is busy", failures: &failures)
        var admittedCaptureID = "first"
        let secondAdmissionIsBusy = PetCaptureAdmission.isBusy(state: .asking, hasPendingRequest: true, hidden: false)
        if secondAdmissionIsBusy {
            let secondOutcome = PetCaptureAdmission.busyOutcome(captureID: "second")
            check(secondOutcome.captureID == "second", "concurrent second request receives its own terminal ID", failures: &failures)
        } else {
            admittedCaptureID = "second"
        }
        check(admittedCaptureID == "first", "concurrent request cannot overwrite first pending ID", failures: &failures)
        let busy = PetCaptureAdmission.busyOutcome(captureID: "second")
        check(busy.failureCode == "pet-busy" && busy.isRetryable, "busy failure is retryable and coded", failures: &failures)
        check(!PetCaptureAdmission.isBusy(state: .hidden, hasPendingRequest: false, hidden: true), "hidden capture remains admitted", failures: &failures)
        let encodedBusy = try? JSONEncoder().encode(busy)
        let decodedBusy = encodedBusy.flatMap { try? JSONDecoder().decode(PetCaptureOutcome.self, from: $0) }
        check(decodedBusy == busy, "busy failure preserves wire metadata", failures: &failures)

        var hiddenCompletion: PetCaptureOutcome?
        let hiddenObserver = NotificationCenter.default.addObserver(
            forName: .petHiddenCaptureCompleted,
            object: nil,
            queue: nil
        ) { notification in
            hiddenCompletion = notification.object as? PetCaptureOutcome
        }
        let hiddenFailure = PetCaptureOutcome.failed(
            captureID: "hidden-failure",
            message: "保存失败",
            code: "save-failed"
        )
        PetCaptureNotifications.postHiddenCompletion(hiddenFailure)
        NotificationCenter.default.removeObserver(hiddenObserver)
        check(hiddenCompletion == hiddenFailure, "hidden failure posts completion event", failures: &failures)
        let hostInstallRejected = await MainActor.run { () -> Bool in
            do {
                _ = try PetHostRegistrationService().installHost()
                return false
            } catch {
                return (error as? PetHostRegistrationError) == .unavailable
            }
        }
        let hostRemoveRejected = await MainActor.run { () -> Bool in
            do {
                _ = try PetHostRegistrationService().removeHost()
                return false
            } catch {
                return (error as? PetHostRegistrationError) == .unavailable
            }
        }
        check(hostInstallRejected && hostRemoveRejected, "nil host actions fail closed", failures: &failures)

        let registrationRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pspet-registration-\(UUID().uuidString)", isDirectory: true)
        let homeURL = registrationRoot.appendingPathComponent("home", isDirectory: true)
        let applicationsURL = registrationRoot.appendingPathComponent("Applications", isDirectory: true)
        let appURL = registrationRoot.appendingPathComponent("PromptStudio.app", isDirectory: true)
        let helperURL = appURL.appendingPathComponent("Contents/Helpers/PromptStudioCaptureHost")
        try? FileManager.default.createDirectory(
            at: applicationsURL.appendingPathComponent("Google Chrome.app"),
            withIntermediateDirectories: true
        )
        try? FileManager.default.createDirectory(at: helperURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: helperURL.path, contents: Data("host".utf8))
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helperURL.path)
        let installer = PetBrowserHostInstaller(
            homeURL: homeURL,
            applicationRoots: [applicationsURL],
            appBundleURL: appURL
        )
        do {
            let installed = try installer.install()
            let manifestURL = homeURL.appendingPathComponent(
                "Library/Application Support/Google/Chrome/NativeMessagingHosts/com.creatigo.promptstudio.capture.json"
            )
            let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
            let origins = manifest?["allowed_origins"] as? [String]
            check(installed.isInstalled && installed.configuredBrowserCount == 1, "registration detects installed browsers", failures: &failures)
            check(manifest?["path"] as? String == helperURL.path, "registration stores the bundled helper path", failures: &failures)
            check(origins == [PetBrowserHostInstaller.developmentOrigin], "registration uses one exact development origin", failures: &failures)
            _ = try installer.remove()
            check(!FileManager.default.fileExists(atPath: manifestURL.path), "registration removal deletes only the owned manifest", failures: &failures)
        } catch {
            failures.append("browser registration failed: \(error.localizedDescription)")
        }
        try? FileManager.default.removeItem(at: registrationRoot)

        let screen = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let clamped = PetGeometry.clampedOrigin(
            proposed: CGPoint(x: 990, y: 790),
            panelSize: CGSize(width: 100, height: 100),
            visibleFrame: screen,
            inset: 8
        )
        check(clamped == CGPoint(x: 892, y: 692), "panel origin clamps inside display", failures: &failures)
        let snapped = PetGeometry.snappedOrigin(
            proposed: CGPoint(x: 35, y: 420),
            panelSize: CGSize(width: 100, height: 100),
            visibleFrame: screen,
            inset: 8,
            snapDistance: 48
        )
        check(snapped.x == 8 && snapped.y == 420, "panel origin snaps to nearest edge", failures: &failures)
        let appKitPoint = PetGeometry.appKitPoint(
            fromBrowserScreenPoint: .init(x: 160, y: 220),
            primaryScreenMaxY: 900
        )
        check(appKitPoint == CGPoint(x: 160, y: 680), "browser point converts to AppKit screen coordinates", failures: &failures)
        let browserPoint = PetGeometry.browserScreenPoint(
            fromAppKitPoint: appKitPoint,
            primaryScreenMaxY: 900
        )
        check(browserPoint == .init(x: 160, y: 220), "screen coordinate conversion round trips", failures: &failures)

        let temporaryDirectory = URL(fileURLWithPath: "/tmp/pspet-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let socketURL = temporaryDirectory.appendingPathComponent("web-capture.sock")
        let server = PetCaptureSocketServer(socketURL: socketURL) { request in
            .presented(captureID: request.id)
        }
        server.start()
        check(server.isRunning, "socket starts: \(server.lastStartError ?? "unknown")", failures: &failures)
        check(server.pendingCaptureIDs.isEmpty, "socket starts without pending clients", failures: &failures)

        let candidate = """
        {"type":"capture","candidate":{"captureID":"red-1","selectedText":"hello","pageTitle":"Page","pageURL":"https://example.test","siteName":"example.test","clickScreenPoint":{"x":12,"y":34},"capturedAt":"2026-08-12T00:00:00.000Z"}}
        """
        let response = await server.handleMessage(Data(candidate.utf8))
        let responseObject = (try? JSONSerialization.jsonObject(with: response)) as? [String: Any]
        check(responseObject?["type"] as? String == "presented", "socket presents visible capture", failures: &failures)
        check(server.pendingCaptureIDs.contains("red-1"), "presented capture remains pending", failures: &failures)
        NotificationCenter.default.post(
            name: .petCaptureSaved,
            object: PetCaptureOutcome.saved(captureID: "red-1", mouthPoint: .init(x: 12, y: 34))
        )
        try? await Task.sleep(nanoseconds: 20_000_000)
        check(!server.pendingCaptureIDs.contains("red-1"), "terminal event clears pending capture", failures: &failures)
        server.stop()
        check(server.pendingCaptureIDs.isEmpty, "stop clears pending clients", failures: &failures)

        // RED: Task 4 image envelopes must use the trusted staging token boundary,
        // while retaining an independent image session from text capture.
        let imageStageRoot = temporaryDirectory.appendingPathComponent("CaptureStaging", isDirectory: true)
        try? FileManager.default.createDirectory(at: imageStageRoot, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: imageStageRoot.path)
        let imageToken = UUID().uuidString
        FileManager.default.createFile(atPath: imageStageRoot.appendingPathComponent(imageToken).path, contents: Data("staged".utf8))
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: imageStageRoot.appendingPathComponent(imageToken).path)
        let imageServer = PetCaptureSocketServer(
            socketURL: temporaryDirectory.appendingPathComponent("image.sock"),
            stagingRootURL: imageStageRoot
        ) { request in
            .presented(captureID: request.id)
        } imageHandler: { request, _ in
            .presented(captureID: request.captureID)
        }
        imageServer.start()
        let imageEnvelope = """
        {"type":"imageCapture","stagingToken":"\(imageToken)","candidate":{"captureID":"image-red-1","pageTitle":"Page","pageURL":"https://example.test/image?q=1","siteName":"example.test","resourceURL":"https://example.test/assets/a.png","altText":"A","originalFileName":"a.png","domSourceKind":"image","acquisitionMethod":"pageContext","isScreenshot":false,"mimeType":"image/png","byteCount":0,"sha256":"\(String(repeating: "0", count: 64))","clickScreenPoint":{"x":12,"y":34},"capturedAt":"2026-08-13T00:00:00.000Z"}}
        """
        let imageResponse = await imageServer.handleMessage(Data(imageEnvelope.utf8))
        let imageObject = (try? JSONSerialization.jsonObject(with: imageResponse)) as? [String: Any]
        check(imageObject?["type"] as? String == "presented", "image socket presents tokenized image capture: \(String(decoding: imageResponse, as: UTF8.self))", failures: &failures)
        let busyImageEnvelope = imageEnvelope.replacingOccurrences(of: "image-red-1", with: "image-red-2")
        let busyImageResponse = await imageServer.handleMessage(Data(busyImageEnvelope.utf8))
        let busyImageObject = (try? JSONSerialization.jsonObject(with: busyImageResponse)) as? [String: Any]
        check(busyImageObject?["code"] as? String == "image-busy" && busyImageObject?["retryable"] as? Bool == true, "image socket rejects concurrent image session as retryable busy", failures: &failures)
        let forgedImageEnvelope = imageEnvelope.replacingOccurrences(
            of: #"stagingToken":"[^"]+"#,
            with: #"stagingToken":"/tmp/forged-image"#,
            options: .regularExpression
        )
        let forgedResponse = await imageServer.handleMessage(Data(forgedImageEnvelope.utf8))
        let forgedObject = (try? JSONSerialization.jsonObject(with: forgedResponse)) as? [String: Any]
        check(forgedObject?["code"] as? String == "staging-token-rejected", "image socket rejects forged staging paths", failures: &failures)
        imageServer.stop()

        // RED: image drag feedback must preserve exact sequence and perform native
        // hit-testing rather than trusting browser-provided insidePet values.
        var imageDrop = ImageDropPhase()
        check(imageDrop.begin(captureID: "drag-red-1", temporarilyShown: true), "image drag begins independently", failures: &failures)
        let previewSequence = imageDrop.preview(point: .init(x: 12, y: 34))
        check(previewSequence == 1, "image drag preview starts at sequence one", failures: &failures)
        check(imageDrop.consumePreviewAck(sequence: previewSequence, insidePet: true, mouthPoint: .init(x: 5, y: 6)), "image drag accepts matching preview ACK", failures: &failures)
        let finalSequence = imageDrop.requestFinal(point: .init(x: 15, y: 36))
        check(finalSequence == 2, "image drag final sequence increments exactly", failures: &failures)
        check(imageDrop.consumeFinalAck(sequence: finalSequence - 1, insidePet: true, mouthPoint: .init(x: 5, y: 6)) == .waiting, "image drag rejects stale final ACK", failures: &failures)
        check(imageDrop.consumeFinalAck(sequence: finalSequence, insidePet: true, mouthPoint: .init(x: 5, y: 6)) == .drop, "image drag drops only on exact native hit", failures: &failures)
        check(imageDrop.shouldRestoreHiddenPet, "image drag restores temporary hidden presentation", failures: &failures)
        check(PetImageCaptureAdmission.canBeginDrag(state: .idle, hasPendingText: false, hasPendingImage: false), "image drag is admitted from idle", failures: &failures)
        check(!PetImageCaptureAdmission.canBeginDrag(state: .asking, hasPendingText: true, hasPendingImage: false), "image drag cannot corrupt an active text confirmation", failures: &failures)
        check(!PetImageCaptureAdmission.canBeginDrag(state: .success, hasPendingText: false, hasPendingImage: false), "image drag waits for terminal animation reset", failures: &failures)
        check(!PetImageCaptureAdmission.shouldReleaseActiveImage(activeCaptureID: "image-lock", outcomeCaptureID: "text-result"), "text outcomes cannot release an active image lock", failures: &failures)
        check(PetImageCaptureAdmission.shouldReleaseActiveImage(activeCaptureID: "image-lock", outcomeCaptureID: "image-lock"), "matching image outcome releases its lock", failures: &failures)

        var consecutiveRequestCount = 0
        let consecutiveDirectory = URL(fileURLWithPath: "/tmp/pspet-consecutive-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let consecutiveServer = PetCaptureSocketServer(socketURL: consecutiveDirectory.appendingPathComponent("web-capture.sock")) { request in
            consecutiveRequestCount += 1
            if consecutiveRequestCount == 1 {
                return .presented(captureID: request.id)
            }
            return PetCaptureAdmission.busyOutcome(captureID: request.id)
        }
        consecutiveServer.start()
        let firstConsecutive = await consecutiveServer.handleMessage(
            Data(candidate.replacingOccurrences(of: "red-1", with: "first-consecutive").utf8)
        )
        let secondConsecutive = await consecutiveServer.handleMessage(
            Data(candidate.replacingOccurrences(of: "red-1", with: "second-consecutive").utf8)
        )
        let firstObject = (try? JSONSerialization.jsonObject(with: firstConsecutive)) as? [String: Any]
        let secondObject = (try? JSONSerialization.jsonObject(with: secondConsecutive)) as? [String: Any]
        check(
            firstObject?["type"] as? String == "presented",
            "first consecutive socket request remains presented",
            failures: &failures
        )
        check(
            secondObject?["type"] as? String == "failed"
                && secondObject?["code"] as? String == "pet-busy"
                && secondObject?["retryable"] as? Bool == true,
            "second consecutive socket request gets terminal pet-busy",
            failures: &failures
        )
        check(consecutiveServer.pendingCaptureIDs.contains("first-consecutive"), "busy request does not overwrite first pending ID", failures: &failures)
        consecutiveServer.stop()

        let wireDirectory = URL(fileURLWithPath: "/tmp/pspet-wire-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let wireSocketURL = wireDirectory.appendingPathComponent("web-capture.sock")
        let wireServer = PetCaptureSocketServer(socketURL: wireSocketURL) { request in
            .presented(captureID: request.id)
        }
        wireServer.start()
        check(wireServer.isRunning, "wire socket starts: \(wireServer.lastStartError ?? "unknown")", failures: &failures)
        let wireClientTask = Task.detached { () -> [Data] in
            let descriptor = try connect(to: wireSocketURL.path)
            let frame = try makeFrame(Data(candidate.replacingOccurrences(of: "red-1", with: "wire-1").utf8))
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try handle.write(contentsOf: frame)
            let initial = try readFrame(from: handle)
            let followUpOne = try readFrame(from: handle)
            let followUpTwo = try readFrame(from: handle)
            return [initial, followUpOne, followUpTwo]
        }
        for _ in 0..<100 where !wireServer.pendingCaptureIDs.contains("wire-1") {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        NotificationCenter.default.post(
            name: .petCaptureSourceShouldClear,
            object: PetCaptureOutcome.saved(captureID: "wire-1", mouthPoint: .init(x: 12, y: 34))
        )
        NotificationCenter.default.post(
            name: .petCaptureSaved,
            object: PetCaptureOutcome.saved(captureID: "wire-1", mouthPoint: .init(x: 12, y: 34))
        )
        do {
            let responsePayloads = try await wireClientTask.value
            let responseObjects = responsePayloads.compactMap {
                (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
            }
            let responseTypes = responseObjects.compactMap { $0["type"] as? String }
            check(responseTypes == ["presented", "animate", "saved"], "same socket receives presented/animate/saved", failures: &failures)
            check(responseObjects.last?["clearSource"] as? Bool == true, "saved response carries source-clear preference", failures: &failures)
        } catch {
            failures.append("same socket protocol failed: \(error.localizedDescription)")
        }
        wireServer.stop()

        let disconnectDirectory = URL(fileURLWithPath: "/tmp/pspet-disconnect-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let disconnectURL = disconnectDirectory.appendingPathComponent("web-capture.sock")
        let disconnectServer = PetCaptureSocketServer(socketURL: disconnectURL) { request in
            try? await Task.sleep(nanoseconds: 80_000_000)
            return .presented(captureID: request.id)
        }
        var disconnectedCaptureID: String?
        let disconnectObserver = NotificationCenter.default.addObserver(
            forName: .petCaptureClientDisconnected,
            object: nil,
            queue: nil
        ) { notification in
            disconnectedCaptureID = notification.object as? String
        }
        disconnectServer.start()
        check(disconnectServer.isRunning, "disconnect socket starts: \(disconnectServer.lastStartError ?? "unknown")", failures: &failures)
        let disconnectClientTask = Task.detached {
            let descriptor = try connect(to: disconnectURL.path)
            let frame = try makeFrame(Data(candidate.replacingOccurrences(of: "red-1", with: "drop-1").utf8))
            _ = frame.withUnsafeBytes { bytes in
                Darwin.send(descriptor, bytes.baseAddress, frame.count, 0)
            }
            Darwin.shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
        }
        _ = try? await disconnectClientTask.value
        for _ in 0..<100 where disconnectedCaptureID == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        check(!disconnectServer.pendingCaptureIDs.contains("drop-1"), "failed initial write releases pending capture", failures: &failures)
        check(disconnectedCaptureID == "drop-1", "client disconnect releases coordinator capture", failures: &failures)
        NotificationCenter.default.removeObserver(disconnectObserver)
        disconnectServer.stop()

        if failures.isEmpty {
            print("PromptStudioPetTests passed")
        } else {
            for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
            Foundation.exit(1)
        }
    }

    private static func check(_ condition: Bool, _ message: String, failures: inout [String]) {
        if !condition { failures.append(message) }
    }

    private static func connect(to path: String) throws -> Int32 {
        for _ in 0..<100 {
            let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw PetCaptureError.unavailable }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8) + [UInt8(0)]
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            guard bytes.count <= capacity else { throw PetCaptureError.unavailable }
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: UInt8.self, capacity: capacity) { rebound in
                    for index in 0..<bytes.count { rebound[index] = bytes[index] }
                }
            }
            let addressLength = socklen_t(MemoryLayout<sockaddr_un>.size)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                    Darwin.connect(descriptor, rebound, addressLength)
                }
            }
            if result == 0 {
                var timeout = timeval(tv_sec: 2, tv_usec: 0)
                _ = withUnsafePointer(to: &timeout) { pointer in
                    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, pointer, socklen_t(MemoryLayout<timeval>.size))
                }
                return descriptor
            }
            Darwin.close(descriptor)
            usleep(10_000)
        }
        throw PetCaptureError.unavailable
    }

    private static func makeFrame(_ payload: Data) throws -> Data {
        guard payload.count <= 1_048_576 else { throw PetCaptureError.unavailable }
        let length = UInt32(payload.count)
        var frame = Data([
            UInt8(length & 0xff),
            UInt8((length >> 8) & 0xff),
            UInt8((length >> 16) & 0xff),
            UInt8((length >> 24) & 0xff)
        ])
        frame.append(payload)
        return frame
    }

    private static func readFrame(from handle: FileHandle) throws -> Data {
        let header = try readExactly(4, from: handle)
        let length = UInt32(header[0])
            | (UInt32(header[1]) << 8)
            | (UInt32(header[2]) << 16)
            | (UInt32(header[3]) << 24)
        return try readExactly(Int(length), from: handle)
    }

    private static func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let chunk = try handle.read(upToCount: count - data.count), !chunk.isEmpty else {
                throw PetCaptureError.unavailable
            }
            data.append(chunk)
        }
        return data
    }
}
