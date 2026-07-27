import Foundation

/// Identifies one shared filesystem watcher by its normalized watched paths.
///
/// Used as the key for ``WorkspaceGitMetadataWatcherRegistry``'s exact-set
/// sharing: de-duplicated and sorted so two subscribers passing the same
/// paths in different orders share one event source. Both
/// ``SidebarGitMetadataService`` (internal fan-out) and the registry
/// (cross-service sharing) construct keys from the same path arrays, so the
/// normalization is identical.
public struct WorkspaceGitMetadataWatchedPathsKey: Equatable, Hashable, Sendable {
    public let paths: [String]

    public init(paths: [String]) {
        self.paths = Array(Set(paths)).sorted()
    }
}
