import Foundation

/// The complete folder selection used by context-menu and drag actions.
///
/// Folder selections are ordered by the visible folder order.  When a parent
/// and one of its descendants are selected together, only the parent is kept
/// because moving or deleting the parent already includes the descendant.
public struct FolderSelectionActionContext: Equatable, Sendable {
    public let orderedFolderIDs: [String]
    public let primaryID: String

    public init(orderedFolderIDs: [String], primaryID: String) {
        let normalized = FolderDragPayload(folderIDs: orderedFolderIDs).folderIDs
        self.orderedFolderIDs = normalized
        self.primaryID = normalized.contains(primaryID) ? primaryID : (normalized.first ?? primaryID)
    }

    public static func resolve(
        clickedFolderID: String,
        selectedFolderIDs: Set<String>,
        primaryID: String?,
        visualFolderIDs: [String],
        folders: [LibraryFolder] = []
    ) -> Self {
        guard selectedFolderIDs.contains(clickedFolderID) else {
            return Self(orderedFolderIDs: [clickedFolderID], primaryID: clickedFolderID)
        }

        var ordered = visualFolderIDs.filter(selectedFolderIDs.contains)
        let known = Set(ordered)
        ordered.append(contentsOf: selectedFolderIDs.subtracting(known).sorted())
        let normalized = normalizeParentChildOverlap(selectedFolderIDs: ordered, folders: folders)
        let requestedPrimary = primaryID ?? clickedFolderID
        let resolvedPrimary = primaryIDAfterNormalization(
            requestedPrimary,
            normalizedFolderIDs: normalized,
            folders: folders
        )
        return Self(
            orderedFolderIDs: normalized.isEmpty ? [clickedFolderID] : normalized,
            primaryID: resolvedPrimary
        )
    }

    /// Compatibility spelling for callers that refer to the complete folder
    /// list as `allFolders` rather than `folders`.
    public static func resolve(
        clickedFolderID: String,
        selectedFolderIDs: Set<String>,
        primaryID: String?,
        visualFolderIDs: [String],
        allFolders: [LibraryFolder]
    ) -> Self {
        resolve(
            clickedFolderID: clickedFolderID,
            selectedFolderIDs: selectedFolderIDs,
            primaryID: primaryID,
            visualFolderIDs: visualFolderIDs,
            folders: allFolders
        )
    }

    public func dragPayload() -> FolderDragPayload {
        FolderDragPayload(folderIDs: orderedFolderIDs)
    }

    /// Removes selected descendants that are already covered by a selected
    /// ancestor.  The first occurrence order is retained.
    public static func normalizeParentChildOverlap(
        selectedFolderIDs: [String],
        folders: [LibraryFolder]
    ) -> [String] {
        let payloadIDs = FolderDragPayload(folderIDs: selectedFolderIDs).folderIDs
        guard !payloadIDs.isEmpty, !folders.isEmpty else { return payloadIDs }

        let parentByID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0.parentId) })
        let selected = Set(payloadIDs)
        return payloadIDs.filter { folderID in
            var ancestor = parentByID[folderID] ?? nil
            var visited = Set<String>()
            while let ancestorID = ancestor, visited.insert(ancestorID).inserted {
                if selected.contains(ancestorID) {
                    return false
                }
                ancestor = parentByID[ancestorID] ?? nil
            }
            return true
        }
    }

    public static func normalizeParentChildOverlap(
        selectedFolderIDs: Set<String>,
        folders: [LibraryFolder]
    ) -> [String] {
        normalizeParentChildOverlap(selectedFolderIDs: selectedFolderIDs.sorted(), folders: folders)
    }

    private static func primaryIDAfterNormalization(
        _ primaryID: String,
        normalizedFolderIDs: [String],
        folders: [LibraryFolder]
    ) -> String {
        guard !normalizedFolderIDs.contains(primaryID), !folders.isEmpty else {
            return primaryID
        }
        let normalized = Set(normalizedFolderIDs)
        let parentByID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0.parentId) })
        var ancestor = parentByID[primaryID] ?? nil
        var visited = Set<String>()
        while let ancestorID = ancestor, visited.insert(ancestorID).inserted {
            if normalized.contains(ancestorID) {
                return ancestorID
            }
            ancestor = parentByID[ancestorID] ?? nil
        }
        return normalizedFolderIDs.first ?? primaryID
    }
}
