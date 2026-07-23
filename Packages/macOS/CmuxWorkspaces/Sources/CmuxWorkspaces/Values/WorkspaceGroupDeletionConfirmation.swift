public import Foundation

/// Current workspace-group membership used to confirm destructive group deletion.
///
/// In the normalized hierarchy a group owns containers, and containers own
/// leaves; destructive deletion closes every leaf under the group's
/// containers. Confirmation copy therefore represents the group's containers
/// rather than a hidden anchor workspace.
public struct WorkspaceGroupDeletionConfirmation: Equatable, Sendable {
    /// The group's stable identity.
    public let groupId: UUID
    /// The group's current display name.
    public let groupName: String
    /// The group's containers in sidebar order, at confirmation time.
    public let containerIds: [UUID]
    /// Leaf identifiers that destructive deletion will close, in window order.
    public let memberWorkspaceIds: [UUID]

    /// Number of containers under the group.
    public var containerCount: Int { containerIds.count }

    /// Number of leaves destructive deletion would close.
    public var memberCount: Int { memberWorkspaceIds.count }

    /// Whether the group has no containers and therefore no leaves to close.
    public var isEmpty: Bool { containerIds.isEmpty }

    /// Creates a deletion confirmation snapshot.
    public init(
        groupId: UUID,
        groupName: String,
        containerIds: [UUID],
        memberWorkspaceIds: [UUID]
    ) {
        self.groupId = groupId
        self.groupName = groupName
        self.containerIds = containerIds
        self.memberWorkspaceIds = memberWorkspaceIds
    }
}
