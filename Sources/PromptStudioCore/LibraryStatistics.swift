import Foundation

/// The small set of aggregate counts needed by the library navigation UI.
///
/// The repository computes these counts directly in SQLite so callers do not
/// need to load every prompt item (and its versions) just to render counts.
public struct LibraryStatistics: Equatable, Sendable {
    public let activeCount: Int
    public let favoriteCount: Int
    public let recentCount: Int
    public let trashCount: Int
    public let folderCounts: [String: Int]

    public init(
        activeCount: Int,
        favoriteCount: Int,
        recentCount: Int,
        trashCount: Int,
        folderCounts: [String: Int] = [:]
    ) {
        self.activeCount = activeCount
        self.favoriteCount = favoriteCount
        self.recentCount = recentCount
        self.trashCount = trashCount
        self.folderCounts = folderCounts
    }

    /// Short aliases keep the value convenient for callers that already use
    /// the collection names rather than the UI's `*Count` labels.
    public var active: Int { activeCount }
    public var favorite: Int { favoriteCount }
    public var recent: Int { recentCount }
    public var trash: Int { trashCount }
    public var countsByFolderID: [String: Int] { folderCounts }
    public var folderItemCounts: [String: Int] { folderCounts }

    public subscript(folderID: String) -> Int {
        folderCounts[folderID] ?? 0
    }
}
