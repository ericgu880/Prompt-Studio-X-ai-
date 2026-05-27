import Foundation
@testable import PromptStudioCore

// The current Command Line Tools install does not expose XCTest/Testing to
// SwiftPM test targets. Keep this target buildable for `swift test`; executable
// assertions live in `swift run PromptStudioSmokeTests`.
func promptStudioCoreTestsTargetLoads() -> Bool {
    AssetKind.infer(fileExtension: "png") == .image
        && PromptImportParser.parse(text: "Prompt: forest --no text", assetKind: .text).negativePrompt == "text"
        && PromptFiltering.apply([], filter: PromptFilter()).isEmpty
}
