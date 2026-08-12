import Foundation

#if canImport(Darwin)
import Darwin
#endif

// Chrome launches a native host with stdio pipes. BrowserHostManifest.allowed_origins is the
// browser-side gate; the first JSON envelope is checked again in PromptStudioCaptureHost so a
// direct process invocation cannot bypass the exact origin allowlist.
let origin = ProcessOrigin.parse(arguments: CommandLine.arguments)
if case .rejected = origin {
    CaptureHostLogger.status("rejected-origin")
    exit(2)
}

do {
    try PromptStudioCaptureHost().run()
} catch {
    CaptureHostLogger.status("stopped")
    exit(1)
}
