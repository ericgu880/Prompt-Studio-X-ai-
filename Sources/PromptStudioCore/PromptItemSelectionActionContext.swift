import Foundation

public struct PromptItemSelectionActionContext: Equatable, Sendable {
    public let orderedItemIDs: [String]
    public let primaryID: String

    public init(orderedItemIDs: [String], primaryID: String) {
        self.orderedItemIDs = PromptItemDragPayload(itemIDs: orderedItemIDs).itemIDs
        self.primaryID = self.orderedItemIDs.contains(primaryID) ? primaryID : (self.orderedItemIDs.first ?? primaryID)
    }

    public static func resolve(
        clickedItemID: String,
        selectedItemIDs: Set<String>,
        primaryID: String?,
        visualItemIDs: [String]
    ) -> Self {
        guard selectedItemIDs.contains(clickedItemID) else {
            return Self(orderedItemIDs: [clickedItemID], primaryID: clickedItemID)
        }

        var ordered = visualItemIDs.filter(selectedItemIDs.contains)
        let known = Set(ordered)
        ordered.append(contentsOf: selectedItemIDs.subtracting(known).sorted())
        return Self(
            orderedItemIDs: ordered.isEmpty ? [clickedItemID] : ordered,
            primaryID: primaryID ?? clickedItemID
        )
    }

    public func dragPayload() -> PromptItemDragPayload {
        PromptItemDragPayload(itemIDs: orderedItemIDs)
    }
}
