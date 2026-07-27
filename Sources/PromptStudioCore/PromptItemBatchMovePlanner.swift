import Foundation

public struct PromptItemBatchMovePlan: Sendable {
    public let updatedItems: [PromptItem]
    public let unchangedIDs: [String]
    public let ignoredIDs: [String]

    public init(updatedItems: [PromptItem], unchangedIDs: [String], ignoredIDs: [String]) {
        self.updatedItems = updatedItems
        self.unchangedIDs = unchangedIDs
        self.ignoredIDs = ignoredIDs
    }
}

public enum PromptItemBatchMovePlanner {
    public static func plan(
        items: [PromptItem],
        requestedIDs: [String],
        targetFolderID: String,
        targetFolderName: String,
        updatedAt: Date = Date()
    ) -> PromptItemBatchMovePlan {
        let itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        var seenIDs = Set<String>()
        var updatedItems: [PromptItem] = []
        var unchangedIDs: [String] = []
        var ignoredIDs: [String] = []

        for id in requestedIDs where seenIDs.insert(id).inserted {
            guard var item = itemsByID[id], !item.isDeleted else {
                ignoredIDs.append(id)
                continue
            }
            guard item.folderId != targetFolderID else {
                unchangedIDs.append(id)
                continue
            }

            item.folderId = targetFolderID
            item.folderName = targetFolderName
            item.category = item.assetKind.displayName
            item.updatedAt = updatedAt
            updatedItems.append(item)
        }

        return PromptItemBatchMovePlan(
            updatedItems: updatedItems,
            unchangedIDs: unchangedIDs,
            ignoredIDs: ignoredIDs
        )
    }
}
