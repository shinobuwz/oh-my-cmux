import Foundation

/// A coalesced batch of recursive filesystem changes.
public struct RecursivePathWatcherEvent: Equatable, Sendable {
    /// Every absolute path reported during the coalescing window.
    public let changedPaths: Set<String>

    /// Paths whose create, remove, rename, or clone flags can change a directory listing.
    public let structurallyChangedPaths: Set<String>

    /// Whether FSEvents reported a dropped, wrapped, root, mount, or unmount event
    /// that requires the consumer to rebuild its complete snapshot.
    public let requiresFullRescan: Bool

    /// Creates a recursive filesystem event batch.
    ///
    /// - Parameters:
    ///   - changedPaths: Every absolute path affected by the batch.
    ///   - structurallyChangedPaths: Paths whose changes can alter directory listings.
    ///   - requiresFullRescan: Whether incremental path handling is unsafe.
    public init(
        changedPaths: Set<String>,
        structurallyChangedPaths: Set<String> = [],
        requiresFullRescan: Bool = false
    ) {
        self.changedPaths = changedPaths
        self.structurallyChangedPaths = structurallyChangedPaths
        self.requiresFullRescan = requiresFullRescan
    }

    func merging(_ other: RecursivePathWatcherEvent) -> RecursivePathWatcherEvent {
        RecursivePathWatcherEvent(
            changedPaths: changedPaths.union(other.changedPaths),
            structurallyChangedPaths: structurallyChangedPaths.union(other.structurallyChangedPaths),
            requiresFullRescan: requiresFullRescan || other.requiresFullRescan
        )
    }
}
