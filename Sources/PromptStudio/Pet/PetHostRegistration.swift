import Foundation
import SwiftUI

struct PetHostRegistration: Codable, Equatable, Sendable {
    var hostName: String
    var executablePath: String
    var extensionIDs: [String]

    init(
        hostName: String = "com.promptstudio.capture",
        executablePath: String = "",
        extensionIDs: [String] = []
    ) {
        self.hostName = hostName
        self.executablePath = executablePath
        self.extensionIDs = extensionIDs.filter { !$0.isEmpty && !$0.contains("*") }
    }

    var allowedOrigins: [String] {
        extensionIDs.map { "chrome-extension://\($0)/" }.sorted()
    }

    func manifestData() throws -> Data {
        let manifest: [String: Any] = [
            "name": hostName,
            "description": "PromptStudio local web capture host",
            "path": executablePath,
            "type": "stdio",
            "allowed_origins": allowedOrigins
        ]
        return try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    }

    func manifestJSON() -> String {
        guard let data = try? manifestData() else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

enum PetHostRegistrationService {
    static let defaultHostName = "com.promptstudio.capture"

    static func manifest(
        executablePath: String,
        extensionIDs: [String]
    ) -> PetHostRegistration {
        PetHostRegistration(
            hostName: defaultHostName,
            executablePath: executablePath,
            extensionIDs: extensionIDs
        )
    }
}

struct PetHostRegistrationView: View {
    @ObservedObject private var preferencesStore = PetPreferencesStore.shared
    let executablePath: String
    let extensionIDs: [String]

    init(executablePath: String = "", extensionIDs: [String] = []) {
        self.executablePath = executablePath
        self.extensionIDs = extensionIDs
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
                if !extensionIDs.isEmpty {
                    Text("已配置 \(extensionIDs.count) 个浏览器扩展")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }
}
