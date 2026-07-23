public import Foundation

/// Immutable workspace group data used by the sidebar workspace reorder resolver.
public struct SidebarWorkspaceReorderGroupSnapshot: Equatable, Sendable {
    /// The group identifier.
    public let id: UUID

    /// The structural representative leaf a group header resolves to for drop
    /// indicator hit testing — the group's first container's main/first leaf.
    ///
    /// This is a structural identity (a concrete member leaf), never a derived
    /// "last active" pointer: a group header is not a workspace, so the resolver
    /// needs one concrete leaf to anchor a fallback indicator when the pointer
    /// sits in empty space below the group. `nil` when the group has no leaves.
    public let focusWorkspaceId: UUID?

    /// Whether the group belongs to the leading pinned tier.
    public let isPinned: Bool

    /// Creates a workspace group snapshot for sidebar reorder planning.
    ///
    /// - Parameters:
    ///   - id: The group identifier.
    ///   - focusWorkspaceId: The structural representative leaf a group header
    ///     resolves to, or `nil` for an empty group.
    ///   - isPinned: Whether the group belongs to the leading pinned tier.
    public init(id: UUID, focusWorkspaceId: UUID?, isPinned: Bool) {
        self.id = id
        self.focusWorkspaceId = focusWorkspaceId
        self.isPinned = isPinned
    }
}
