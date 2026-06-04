import Foundation
@testable import PromptStudioCore

// The current Command Line Tools install does not expose XCTest/Testing to
// SwiftPM test targets. Keep this target buildable for `swift test`; executable
// Core assertions live in `swift run PromptStudioCoreUnitTests`.
func promptStudioCoreTestsTargetLoads() -> Bool {
    let attachment = PromptItem(
        id: "attachment",
        title: "Design",
        type: .text,
        assetKind: .source,
        modelId: "local_asset",
        modelName: "Local Asset",
        folderName: "",
        category: "附件",
        assetPath: "/tmp/mock.psd",
        aspectRatio: "0:0",
        width: 0,
        height: 0,
        format: "PSD",
        fileSize: 1
    )
    return AssetKind.infer(fileExtension: "png") == .image
        && AssetFormatCatalog.support(forFileExtension: "psd").previewMode == .reference
        && AssetFormatCatalog.support(forFileExtension: "madeup").previewMode == .generic
        && attachment.isAttachmentAsset
        && AssetKindFilter.other.matches(attachment)
        && TextSyntaxMode.infer(assetPath: "/tmp/mock.json", format: "", assetKind: .unknown) == .json
        && TextSyntaxRules.tokenKinds(in: #"{"count":1,"ok":true}"#, mode: .json).contains(.jsonKey)
        && PromptImportParser.parse(text: "Prompt: forest --no text", assetKind: .text).negativePrompt == "text"
        && PromptFiltering.apply([], filter: PromptFilter()).isEmpty
}
