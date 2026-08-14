import Foundation

enum LicenseRuntimeConfiguration {
    private static let productionServerURL = URL(string: "https://license.promptstudio.app")!

    static var serverURL: URL {
        resolvedServerURL(
            bundledValue: Bundle.main.object(forInfoDictionaryKey: "PromptStudioLicenseServerURL") as? String,
            allowsRuntimeOverrides: runtimeOverridesAllowed,
            environment: ProcessInfo.processInfo.environment,
            userDefaultsValue: UserDefaults.standard.string(forKey: "PromptStudioLicenseServerURL")
        )
    }

    static var purchaseURL: URL? {
        purchaseURL(rawValue: Bundle.main.object(forInfoDictionaryKey: "PromptStudioPurchaseURL") as? String)
    }

    static func resolvedServerURL(
        bundledValue: String? = nil,
        allowsRuntimeOverrides: Bool,
        environment: [String: String],
        userDefaultsValue: String?
    ) -> URL {
        if allowsRuntimeOverrides {
            if let raw = environment["PROMPTSTUDIO_LICENSE_SERVER_URL"],
               let url = validatedRuntimeOverrideURL(raw) {
                return url
            }
            if let url = validatedRuntimeOverrideURL(userDefaultsValue) {
                return url
            }
        }
        if let url = validatedHTTPSURL(bundledValue) {
            return url
        }
        return productionServerURL
    }

    static func purchaseURL(rawValue: String?) -> URL? {
        validatedHTTPSURL(rawValue)
    }

    private static func validatedHTTPSURL(_ rawValue: String?) -> URL? {
        guard let rawValue,
              let components = URLComponents(string: rawValue),
              components.scheme == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil,
              let url = components.url else {
            return nil
        }
        return url
    }

    private static func validatedRuntimeOverrideURL(_ rawValue: String?) -> URL? {
        if let url = validatedHTTPSURL(rawValue) {
            return url
        }
        guard let rawValue,
              let components = URLComponents(string: rawValue),
              components.scheme?.lowercased() == "http",
              let host = components.host?.lowercased(),
              ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host),
              components.user == nil,
              components.password == nil,
              let url = components.url else {
            return nil
        }
        return url
    }

    private static var runtimeOverridesAllowed: Bool {
#if DEBUG
        true
#else
        false
#endif
    }
}

enum AppRuntimePolicy {
    static var includesDemoLibraryContent: Bool {
#if DEBUG
        true
#else
        false
#endif
    }
}

enum LicensePresentation {
    static func planName(plan: String, licenseType: String) -> String {
        if licenseType == "lifetime" || plan == "pro_lifetime" {
            return "PromptStudio Pro 永久授权"
        }
        if licenseType == "subscription" {
            return "PromptStudio Pro 订阅"
        }
        return "PromptStudio Pro"
    }
}
