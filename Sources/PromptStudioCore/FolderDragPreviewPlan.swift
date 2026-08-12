import Foundation

public struct FolderDragPreviewPlan: Equatable, Sendable {
    public static let maximumVisiblePreviewCount = 12

    public let previewFolderIDs: [String]
    public let payloadOwnerID: String
    public let completePayload: FolderDragPayload
    public let totalFolderCount: Int

    public init(orderedFolderIDs: [String], draggedFolderID: String) {
        let payload = FolderDragPayload(folderIDs: orderedFolderIDs)
        completePayload = payload
        totalFolderCount = payload.folderIDs.count

        let ownerID = payload.folderIDs.contains(draggedFolderID)
            ? draggedFolderID
            : (payload.folderIDs.first ?? draggedFolderID)
        payloadOwnerID = ownerID

        let otherIDs = payload.folderIDs.filter { $0 != ownerID }
        let visibleOthers = Array(otherIDs.prefix(max(0, Self.maximumVisiblePreviewCount - 1)))
        previewFolderIDs = visibleOthers + (ownerID.isEmpty ? [] : [ownerID])
    }

    public var previewIDs: [String] { previewFolderIDs }
    public var totalCount: Int { totalFolderCount }
}
