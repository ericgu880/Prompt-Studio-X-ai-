import Foundation
@testable import PromptStudioCore

// The current Command Line Tools install does not expose XCTest/Testing to
// SwiftPM test targets. Keep this target buildable for `swift test`; executable
// Core assertions live in `swift run PromptStudioCoreUnitTests`.
func promptStudioCoreTestsTargetLoads() -> Bool {
    AssetKind.infer(fileExtension: "png") == .image
        && AssetFormatCatalog.support(forFileExtension: "psd").previewMode == .reference
        && AssetFormatCatalog.support(forFileExtension: "madeup").previewMode == .generic
        && TextSyntaxMode.infer(assetPath: "/tmp/mock.json", format: "", assetKind: .unknown) == .json
        && TextSyntaxRules.tokenKinds(in: #"{"count":1,"ok":true}"#, mode: .json).contains(.jsonKey)
        && PromptImportParser.parse(text: "Prompt: forest --no text", assetKind: .text).negativePrompt == "text"
        && PromptFiltering.apply([], filter: PromptFilter()).isEmpty
}
