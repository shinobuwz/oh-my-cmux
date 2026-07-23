public import Foundation

/// A read-only snapshot of one workspace group, as the app target exposes it to
/// ``ControlCommandCoordinator`` through ``ControlWorkspaceGroupContext``.
///
/// Mirrors the app target's `WorkspaceGroup` (plus its computed membership)
/// without the package importing the app target. The coordinator turns each
/// snapshot into the `workspace.group.*` group payload, minting the
public struct ControlWorkspaceGroupSnapshot: Sendable, Equatable {
    /// A read-only snapshot of one workspace group, as the app target exposes it to
    /// ``ControlCommandCoordinator`` through ``ControlWorkspaceGroupContext``.
    ///
    /// Mirrors the app target's `WorkspaceGroup` (plus its computed membership)
    /// without the package importing the app target. The coordinator turns each
    /// snapshot into the `workspace.group.*` group payload, minting the
    /// `workspace_group` / `workspace` refs itself (the legacy
    /// `v2WorkspaceGroupPayload` did the minting inline).
    public let id: UUID
    /// The group's display name.
    public let name: String
    /// Whether the group is collapsed in the sidebar.
    public let isCollapsed: Bool
    /// Whether the group is pinned.
    public let isPinned: Bool
    /// The last active descendant workspace used when the group header is
    /// selected. `nil` for a freshly created empty group.
    public let lastActiveWorkspaceID: UUID?
    /// The group's custom color override, if any.
    public let customColor: String?
    /// The group's custom icon symbol, if any.
    public let iconSymbol: String?
    /// The group's member workspace identifiers, in tab order.
    public let memberWorkspaceIDs: [UUID]

    /// Creates a workspace-group snapshot.
    ///
    /// - Parameters:
    ///   - id: The group's stable identifier.
    ///   - name: The group's display name.
    ///   - isCollapsed: Whether the group is collapsed.
    ///   - isPinned: Whether the group is pinned.
    ///   - lastActiveWorkspaceID: The last active descendant workspace, if any.
    ///   - customColor: The custom color override, if any.
    ///   - iconSymbol: The custom icon symbol, if any.
    ///   - memberWorkspaceIDs: The member workspace identifiers, in tab order.
    public init(
        id: UUID,
        name: String,
        isCollapsed: Bool,
        isPinned: Bool,
        lastActiveWorkspaceID: UUID?,
        customColor: String?,
        iconSymbol: String?,
        memberWorkspaceIDs: [UUID]
    ) {
        self.id = id
        self.name = name
        self.isCollapsed = isCollapsed
        self.isPinned = isPinned
        self.lastActiveWorkspaceID = lastActiveWorkspaceID
        self.customColor = customColor
        self.iconSymbol = iconSymbol
        self.memberWorkspaceIDs = memberWorkspaceIDs
    }
}
