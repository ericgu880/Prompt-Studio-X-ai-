import Foundation

public struct PromptItemDragPreviewPlan: Equatable, Sendable {
    public static let maximumVisiblePreviewCount = 12

    public let previewItemIDs: [String]
    public let payloadOwnerID: String
    public let completePayload: PromptItemDragPayload
    public let totalItemCount: Int

    public init(orderedItemIDs: [String], draggedItemID: String) {
        let payload = PromptItemDragPayload(itemIDs: orderedItemIDs)
        completePayload = payload
        totalItemCount = payload.itemIDs.count
        let ownerID = payload.itemIDs.contains(draggedItemID)
            ? draggedItemID
            : (payload.itemIDs.first ?? draggedItemID)
        payloadOwnerID = ownerID

        let otherIDs = payload.itemIDs.filter { $0 != ownerID }
        let visibleOthers = Array(otherIDs.prefix(max(0, Self.maximumVisiblePreviewCount - 1)))
        previewItemIDs = visibleOthers + (ownerID.isEmpty ? [] : [ownerID])
    }
}
