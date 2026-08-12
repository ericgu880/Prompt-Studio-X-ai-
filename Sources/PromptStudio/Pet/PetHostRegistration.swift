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

enum PetHostRegistrationError: LocalizedError, Equatable {
    case unavailable
    case helperMissing
    case noSupportedBrowser
    case invalidOriginConfiguration

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "浏览器主机安装服务暂不可用"
        case .helperMissing:
            "PromptStudio 网页采集组件缺失或不可执行"
        case .noSupportedBrowser:
            "未检测到 Chrome、Edge 或 Arc"
        case .invalidOriginConfiguration:
            "浏览器扩展来源配置无效"
        }
    }
}

struct PetBrowserHostInstaller {
    static let developmentOrigin = "chrome-extension://ejdemjnekbbpodkgfpngckkhghfeheng/"

    private static let manifestName = "com.creatigo.promptstudio.capture"
    private static let browserLocations: [(appName: String, manifestDirectory: String)] = [
        ("Google Chrome.app", "Google/Chrome/NativeMessagingHosts"),
        ("Microsoft Edge.app", "Microsoft Edge/NativeMessagingHosts"),
        ("Arc.app", "Arc/User Data/NativeMessagingHosts")
    ]

    private let homeURL: URL
    private let applicationRoots: [URL]
    private let appBundleURL: URL
    private let fileManager: FileManager

    init(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationRoots: [URL]? = nil,
        appBundleURL: URL = Bundle.main.bundleURL,
        fileManager: FileManager = .default
    ) {
        self.homeURL = homeURL
        self.applicationRoots = applicationRoots ?? [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            homeURL.appendingPathComponent("Applications", isDirectory: true)
        ]
        self.appBundleURL = appBundleURL
        self.fileManager = fileManager
    }

    func install() throws -> PetHostRegistration {
        let helperURL = appBundleURL.appendingPathComponent("Contents/Helpers/PromptStudioCaptureHost")
        guard helperURL.path.hasPrefix("/"), fileManager.isExecutableFile(atPath: helperURL.path) else {
            throw PetHostRegistrationError.helperMissing
        }
        let destinations = detectedManifestDirectories()
        guard !destinations.isEmpty else { throw PetHostRegistrationError.noSupportedBrowser }
        let origins = try allowedOrigins(helperURL: helperURL)
        let manifest = NativeHostManifest(
            name: Self.manifestName,
            description: "PromptStudio web capture host",
            path: helperURL.path,
            type: "stdio",
            allowedOrigins: origins
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(manifest)
        for directory in destinations {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let destination = directory.appendingPathComponent("\(Self.manifestName).json")
            try data.write(to: destination, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
        return PetHostRegistration(
            isInstalled: true,
            executablePath: helperURL.path,
            configuredBrowserCount: destinations.count
        )
    }

    func remove() throws -> PetHostRegistration {
        let decoder = JSONDecoder()
        for directory in allManifestDirectories() {
            let destination = directory.appendingPathComponent("\(Self.manifestName).json")
            guard let data = try? Data(contentsOf: destination),
                  let manifest = try? decoder.decode(NativeHostManifest.self, from: data),
                  manifest.name == Self.manifestName else { continue }
            try fileManager.removeItem(at: destination)
        }
        return PetHostRegistration()
    }

    private func detectedManifestDirectories() -> [URL] {
        Self.browserLocations.compactMap { browser in
            guard applicationRoots.contains(where: {
                fileManager.fileExists(atPath: $0.appendingPathComponent(browser.appName).path)
            }) else { return nil }
            return applicationSupportURL.appendingPathComponent(browser.manifestDirectory, isDirectory: true)
        }
    }

    private func allManifestDirectories() -> [URL] {
        Self.browserLocations.map {
            applicationSupportURL.appendingPathComponent($0.manifestDirectory, isDirectory: true)
        }
    }

    private var applicationSupportURL: URL {
        homeURL.appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    private func allowedOrigins(helperURL: URL) throws -> [String] {
        let sidecarURL = helperURL.deletingLastPathComponent()
            .appendingPathComponent("PromptStudioCaptureHost.allowed-origins.json")
        let configured: [String]
        if let data = try? Data(contentsOf: sidecarURL),
           let configuration = try? JSONDecoder().decode(AllowedOriginsConfiguration.self, from: data) {
            configured = configuration.allowedOrigins
        } else {
            configured = [Self.developmentOrigin]
        }
        let exact = Array(Set(configured.filter(Self.isExactExtensionOrigin))).sorted()
        guard !exact.isEmpty else { throw PetHostRegistrationError.invalidOriginConfiguration }
        return exact
    }

    private static func isExactExtensionOrigin(_ value: String) -> Bool {
        guard value.hasPrefix("chrome-extension://"), value.hasSuffix("/") else { return false }
        let id = value.dropFirst("chrome-extension://".count).dropLast()
        return id.count == 32 && id.allSatisfy { $0 >= "a" && $0 <= "p" }
    }

    private struct AllowedOriginsConfiguration: Decodable {
        let allowedOrigins: [String]

        enum CodingKeys: String, CodingKey {
            case allowedOrigins = "allowed_origins"
        }
    }

    private struct NativeHostManifest: Codable {
        let name: String
        let description: String
        let path: String
        let type: String
        let allowedOrigins: [String]

        enum CodingKeys: String, CodingKey {
            case name, description, path, type
            case allowedOrigins = "allowed_origins"
        }
    }
}

/// Integration hook for host installation.  The default callbacks are no-ops
/// so the native pet can run without pretending to own browser registration.
@MainActor
final class PetHostRegistrationService: ObservableObject {
    typealias Action = () throws -> PetHostRegistration

    @Published private(set) var state: PetHostRegistration
    @Published private(set) var errorMessage: String?

    private let installAction: Action?
    private let removeAction: Action?

    init(
        state: PetHostRegistration = PetHostRegistration(),
        install: Action? = nil,
        remove: Action? = nil
    ) {
        self.state = state
        errorMessage = nil
        installAction = install
        removeAction = remove
    }

    static func live(installer: PetBrowserHostInstaller = PetBrowserHostInstaller()) -> PetHostRegistrationService {
        PetHostRegistrationService(
            install: { try installer.install() },
            remove: { try installer.remove() }
        )
    }

    /// Runs the integration-provided installer and marks the local state as
    /// installed only after it succeeds.
    @discardableResult
    func installHost() throws -> PetHostRegistration {
        do {
            guard let installAction else { throw PetHostRegistrationError.unavailable }
            state = try installAction()
            errorMessage = nil
            return state
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    /// Runs the integration-provided remover and marks the local state as
    /// removed only after it succeeds.
    @discardableResult
    func removeHost() throws -> PetHostRegistration {
        do {
            guard let removeAction else { throw PetHostRegistrationError.unavailable }
            state = try removeAction()
            errorMessage = nil
            return state
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }
}

struct PetHostRegistrationView: View {
    @ObservedObject var registrationService: PetHostRegistrationService

    init(registrationService: PetHostRegistrationService) {
        self.registrationService = registrationService
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: registrationService.state.isInstalled ? "checkmark.shield" : "shield.slash")
                .font(.system(size: 21))
                .foregroundStyle(registrationService.state.isInstalled ? .green : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("浏览器连接")
                    .font(.system(size: 13, weight: .semibold))
                Text(registrationService.state.isInstalled ? "本地网页采集主机已启用" : "本地网页采集主机已停用")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if registrationService.state.configuredBrowserCount > 0 {
                    Text("已连接 \(registrationService.state.configuredBrowserCount) 个浏览器")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Text("启用后会连接本机已安装的 Chrome、Edge 或 Arc")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if let errorMessage = registrationService.errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
            }
            Spacer()
        }
    }
}
