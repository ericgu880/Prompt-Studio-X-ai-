import Foundation

public struct FolderParentSortUpdate: Equatable, Sendable {
    public let folderID: String
    public let parentID: String?
    public let sortOrder: Int

    public init(folderID: String, parentID: String?, sortOrder: Int) {
        self.folderID = folderID
        self.parentID = parentID
        self.sortOrder = sortOrder
    }

    public var id: String { folderID }
    public var parentId: String? { parentID }
}

public enum FolderBatchMoveError: Error, LocalizedError, Equatable, Sendable {
    case emptySourceSelection
    case sourceFolderMissing(String)
    case targetFolderMissing(String)
    case targetIsSource(String)
    case targetIsDescendant(sourceID: String, targetID: String)
    case sourceAlreadyInTarget(String)
    case targetContainsSameName

    public var code: String {
        switch self {
        case .emptySourceSelection:
            "folder_move.empty_source"
        case .sourceFolderMissing:
            "folder_move.source_missing"
        case .targetFolderMissing:
            "folder_move.target_missing"
        case .targetIsSource:
            "folder_move.target_is_source"
        case .targetIsDescendant:
            "folder_move.target_is_descendant"
        case .sourceAlreadyInTarget:
            "folder_move.source_already_in_target"
        case .targetContainsSameName:
            "folder_move.target_name_conflict"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .emptySourceSelection:
            "未选择要移动的文件夹"
        case .sourceFolderMissing(let folderID):
            "来源文件夹不存在：\(folderID)"
        case .targetFolderMissing(let folderID):
            "目标文件夹不存在：\(folderID)"
        case .targetIsSource(let folderID):
            "不能将文件夹移动到自身：\(folderID)"
        case .targetIsDescendant(let sourceID, let targetID):
            "不能将文件夹移动到其子文件夹：\(sourceID) → \(targetID)"
        case .sourceAlreadyInTarget(let folderID):
            "文件夹已经位于目标文件夹中：\(folderID)"
        case .targetContainsSameName:
            "目标文件夹中已存在同名子文件夹"
        }
    }
}

public struct FolderBatchMovePlan: Equatable, Sendable {
    public let sourceFolderIDs: [String]
    public let updates: [FolderParentSortUpdate]
    public let updatedFolders: [LibraryFolder]

    public init(
        sourceFolderIDs: [String],
        updates: [FolderParentSortUpdate],
        updatedFolders: [LibraryFolder] = []
    ) {
        self.sourceFolderIDs = sourceFolderIDs
        self.updates = updates
        self.updatedFolders = updatedFolders
    }

    public var folderUpdates: [FolderParentSortUpdate] { updates }
}

public enum FolderBatchMovePlanner {
    public static func normalizeSourceFolderIDs(
        _ sourceFolderIDs: [String],
        allFolders: [LibraryFolder]
    ) throws -> [String] {
        let requestedIDs = FolderDragPayload(folderIDs: sourceFolderIDs).folderIDs
        guard !requestedIDs.isEmpty else {
            throw FolderBatchMoveError.emptySourceSelection
        }

        let foldersByID = Dictionary(uniqueKeysWithValues: allFolders.map { ($0.id, $0) })
        for folderID in requestedIDs where foldersByID[folderID] == nil {
            throw FolderBatchMoveError.sourceFolderMissing(folderID)
        }
        return FolderSelectionActionContext.normalizeParentChildOverlap(
            selectedFolderIDs: requestedIDs,
            folders: allFolders
        )
    }

    public static func plan(
        allFolders: [LibraryFolder],
        sourceFolderIDs: [String],
        targetParentID: String?
    ) throws -> FolderBatchMovePlan {
        let foldersByID = Dictionary(uniqueKeysWithValues: allFolders.map { ($0.id, $0) })
        let normalizedSourceIDs = try normalizeSourceFolderIDs(sourceFolderIDs, allFolders: allFolders)
        guard let targetParentID else {
            return try makePlan(
                allFolders: allFolders,
                foldersByID: foldersByID,
                normalizedSourceIDs: normalizedSourceIDs,
                targetParentID: nil
            )
        }
        guard foldersByID[targetParentID] != nil else {
            throw FolderBatchMoveError.targetFolderMissing(targetParentID)
        }
        return try makePlan(
            allFolders: allFolders,
            foldersByID: foldersByID,
            normalizedSourceIDs: normalizedSourceIDs,
            targetParentID: targetParentID
        )
    }

    /// Convenience overload for callers that represent root as an empty ID.
    public static func plan(
        allFolders: [LibraryFolder],
        sourceFolderIDs: [String],
        targetParentID: String
    ) throws -> FolderBatchMovePlan {
        try plan(allFolders: allFolders, sourceFolderIDs: sourceFolderIDs, targetParentID: Optional(targetParentID))
    }

    private static func makePlan(
        allFolders: [LibraryFolder],
        foldersByID: [String: LibraryFolder],
        normalizedSourceIDs: [String],
        targetParentID: String?
    ) throws -> FolderBatchMovePlan {
        let sourceSet = Set(normalizedSourceIDs)
        if let targetParentID {
            if sourceSet.contains(targetParentID) {
                throw FolderBatchMoveError.targetIsSource(targetParentID)
            }
            for sourceID in normalizedSourceIDs where isDescendant(targetID: targetParentID, of: sourceID, foldersByID: foldersByID) {
                throw FolderBatchMoveError.targetIsDescendant(sourceID: sourceID, targetID: targetParentID)
            }
        }

        for sourceID in normalizedSourceIDs {
            guard let source = foldersByID[sourceID] else {
                throw FolderBatchMoveError.sourceFolderMissing(sourceID)
            }
            if source.parentId == targetParentID {
                throw FolderBatchMoveError.sourceAlreadyInTarget(sourceID)
            }
        }

        let siblingFolders = allFolders.filter { $0.parentId == targetParentID }
        let siblingNames = Set(siblingFolders.filter { !sourceSet.contains($0.id) }.map(Self.normalizedName))
        var sourceNames = Set<String>()
        for sourceID in normalizedSourceIDs {
            guard let source = foldersByID[sourceID] else { continue }
            let name = Self.normalizedName(source)
            guard !siblingNames.contains(name), sourceNames.insert(name).inserted else {
                throw FolderBatchMoveError.targetContainsSameName
            }
        }

        var nextSortOrder = (siblingFolders.map(\.sortOrder).max() ?? -1) + 1
        var updates: [FolderParentSortUpdate] = []
        var updatedFolders: [LibraryFolder] = []
        for sourceID in normalizedSourceIDs {
            guard var folder = foldersByID[sourceID] else { continue }
            folder.parentId = targetParentID
            folder.sortOrder = nextSortOrder
            updates.append(FolderParentSortUpdate(folderID: folder.id, parentID: targetParentID, sortOrder: nextSortOrder))
            updatedFolders.append(folder)
            nextSortOrder += 1
        }
        return FolderBatchMovePlan(
            sourceFolderIDs: normalizedSourceIDs,
            updates: updates,
            updatedFolders: updatedFolders
        )
    }

    private static func normalizedName(_ folder: LibraryFolder) -> String {
        folder.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func isDescendant(
        targetID: String,
        of sourceID: String,
        foldersByID: [String: LibraryFolder]
    ) -> Bool {
        var current = foldersByID[targetID]?.parentId
        var visited = Set<String>()
        while let currentID = current, visited.insert(currentID).inserted {
            if currentID == sourceID { return true }
            current = foldersByID[currentID]?.parentId
        }
        return false
    }
}

public typealias FolderMovePlan = FolderBatchMovePlan
public typealias FolderMoveError = FolderBatchMoveError
