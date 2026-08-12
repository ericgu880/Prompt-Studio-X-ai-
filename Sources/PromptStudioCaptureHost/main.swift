import Foundation

#if canImport(Darwin)
import Darwin
#endif

// Chrome launches a native host with stdio pipes. BrowserHostManifest.allowed_origins is the
// browser-side gate; the first JSON envelope is checked again in PromptStudioCaptureHost so a
// direct process invocation cannot bypass the exact origin allowlist.
// Release allowlists are bundled next to the signed helper. Do not let an inherited
// environment variable replace that configuration for a directly invoked process.
let allowlist = CaptureOriginAllowlist.runtime(executablePath: CommandLine.arguments[0], environment: [:])
let origin = ProcessOrigin.parse(arguments: CommandLine.arguments, allowlist: allowlist)
guard case .allowed(let trustedOrigin) = origin else {
    CaptureHostLogger.status("rejected-origin")
    exit(2)
}

do {
    try PromptStudioCaptureHost(trustedOrigin: trustedOrigin, allowlist: allowlist).run()
} catch {
    CaptureHostLogger.status("stopped")
    exit(1)
}
