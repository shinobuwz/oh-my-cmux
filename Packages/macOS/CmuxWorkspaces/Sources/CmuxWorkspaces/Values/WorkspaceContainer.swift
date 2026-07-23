public import Foundation

/// A persistent second-level sidebar container between a group and workspace leaves.
///
/// The container owns root identity and presentation state. Leaf membership lives on
/// ``WorkspaceTabRepresenting/workspaceContainerId``; the model's workspace order is
/// the canonical order of leaves inside each container.
public struct WorkspaceContainer: Identifiable, Equatable, Sendable {
    /// The container's stable identity across session restoration.
    public let id: UUID
    /// The independent top-level group that owns this container.
    public var groupId: UUID
    /// The user-visible container name.
    public var name: String
    /// The root binding category.
    public var kind: WorkspaceContainerKind
    /// The canonical local root or last known remote path, when available.
    public var rootPath: String?
    /// The canonical shared Git directory used to compare repository identity.
    public var repositoryCommonDirectory: String?
    /// The remote host identity for ``WorkspaceContainerKind/remoteSession``.
    public var remoteHost: String?
    /// Whether the last known local root is missing or unavailable.
    public var isRootBroken: Bool
    /// Whether the container's leaf rows are collapsed in the sidebar.
    public var isCollapsed: Bool
    /// The last active member workspace used when the container header is selected.
    public var lastActiveWorkspaceId: UUID?

    /// Creates a persistent workspace container.
    ///
    /// - Parameters:
    ///   - id: Stable container identity.
    ///   - groupId: Owning top-level group identity.
    ///   - name: User-visible name.
    ///   - kind: Root binding category.
    ///   - rootPath: Canonical local root or last known remote path.
    ///   - repositoryCommonDirectory: Canonical shared Git directory for Git roots.
    ///   - remoteHost: Remote host identity for remote sessions.
    ///   - isCollapsed: Initial disclosure state.
    ///   - lastActiveWorkspaceId: Initial active member workspace, if any.
    public init(
        id: UUID,
        groupId: UUID,
        name: String,
        kind: WorkspaceContainerKind,
        rootPath: String?,
        repositoryCommonDirectory: String?,
        remoteHost: String?,
        isCollapsed: Bool,
        lastActiveWorkspaceId: UUID?,
        isRootBroken: Bool = false
    ) {
        self.id = id
        self.groupId = groupId
        self.name = name
        self.kind = kind
        self.rootPath = rootPath
        self.repositoryCommonDirectory = repositoryCommonDirectory
        self.remoteHost = remoteHost
        self.isCollapsed = isCollapsed
        self.lastActiveWorkspaceId = lastActiveWorkspaceId
        self.isRootBroken = isRootBroken
    }

    /// Whether the container can create additional managed Git worktrees.
    public var supportsManagedWorktrees: Bool {
        kind == .git
    }
}
