import Foundation
@testable import PromptStudioCore

// This target intentionally avoids XCTest/Testing because the current
// Command Line Tools install does not expose those modules to SwiftPM.
// Run `swift run PromptStudioSmokeTests` for executable assertions.
func promptStudioCoreTestsTargetLoads() -> Bool {
    PromptFiltering.apply([], filter: PromptFilter()).isEmpty
}
