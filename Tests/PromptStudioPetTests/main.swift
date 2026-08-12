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
        let wireClientTask = Task.detached { () -> [String] in
            let descriptor = try connect(to: wireSocketURL.path)
            let frame = try makeFrame(Data(candidate.replacingOccurrences(of: "red-1", with: "wire-1").utf8))
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try handle.write(contentsOf: frame)
            let initial = try readFrame(from: handle)
            let followUpOne = try readFrame(from: handle)
            let followUpTwo = try readFrame(from: handle)
            return [initial, followUpOne, followUpTwo].compactMap { payload in
                (try? JSONSerialization.jsonObject(with: payload))
                    .flatMap { $0 as? [String: Any] }?["type"] as? String
            }
        }
        for _ in 0..<100 where !wireServer.pendingCaptureIDs.contains("wire-1") {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        NotificationCenter.default.post(
            name: .petCaptureSaved,
            object: PetCaptureOutcome.saved(captureID: "wire-1", mouthPoint: .init(x: 12, y: 34))
        )
        do {
            let responseTypes = try await wireClientTask.value
            check(responseTypes == ["presented", "animate", "saved"], "same socket receives presented/animate/saved", failures: &failures)
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
        for _ in 0..<100 where !disconnectServer.pendingCaptureIDs.isEmpty {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        check(!disconnectServer.pendingCaptureIDs.contains("drop-1"), "failed initial write releases pending capture", failures: &failures)
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
