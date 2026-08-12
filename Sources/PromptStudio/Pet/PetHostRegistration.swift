import Foundation
import SwiftUI

/// App-owned state for the browser host registration boundary.
///
/// The browser extension owns its native-messaging manifest and installation
/// scripts.  PromptStudio only exposes callbacks for the integration layer to
/// install or remove that host; this type deliberately does not generate or
/// serialize a browser manifest.
struct PetHostRegistration: Codable, Equatable, Sendable {
    var isInstalled: Bool
    var executablePath: String?
    var configuredBrowserCount: Int

    init(
        isInstalled: Bool = false,
        executablePath: String? = nil,
        configuredBrowserCount: Int = 0
    ) {
        self.isInstalled = isInstalled
        self.executablePath = executablePath
        self.configuredBrowserCount = max(0, configuredBrowserCount)
    }
}

/// Integration hook for host installation.  The default callbacks are no-ops
/// so the native pet can run without pretending to own browser registration.
@MainActor
final class PetHostRegistrationService: ObservableObject {
    typealias Action = () throws -> Void

    @Published private(set) var state: PetHostRegistration

    private let installAction: Action?
    private let removeAction: Action?

    init(
        state: PetHostRegistration = PetHostRegistration(),
        install: Action? = nil,
        remove: Action? = nil
    ) {
        self.state = state
        installAction = install
        removeAction = remove
    }

    /// Runs the integration-provided installer and marks the local state as
    /// installed only after it succeeds.
    @discardableResult
    func installHost() throws -> PetHostRegistration {
        try installAction?()
        state.isInstalled = true
        return state
    }

    /// Runs the integration-provided remover and marks the local state as
    /// removed only after it succeeds.
    @discardableResult
    func removeHost() throws -> PetHostRegistration {
        try removeAction?()
        state.isInstalled = false
        return state
    }
}

struct PetHostRegistrationView: View {
    @ObservedObject private var preferencesStore = PetPreferencesStore.shared

    /// Kept as display-only metadata until the integration layer supplies real
    /// install/remove callbacks.  No browser manifest is inferred here.
    let configuredBrowserCount: Int

    init(configuredBrowserCount: Int = 0) {
        self.configuredBrowserCount = max(0, configuredBrowserCount)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: preferencesStore.value.hostRegistrationEnabled ? "checkmark.shield" : "shield.slash")
                .font(.system(size: 21))
                .foregroundStyle(preferencesStore.value.hostRegistrationEnabled ? .green : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("浏览器连接")
                    .font(.system(size: 13, weight: .semibold))
                Text(preferencesStore.value.hostRegistrationEnabled ? "本地网页采集主机已启用" : "本地网页采集主机已停用")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if configuredBrowserCount > 0 {
                    Text("已连接 \(configuredBrowserCount) 个浏览器")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Text("浏览器主机的安装和移除由集成层处理")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }
}
