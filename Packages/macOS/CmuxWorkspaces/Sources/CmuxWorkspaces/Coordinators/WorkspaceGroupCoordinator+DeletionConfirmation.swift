public import Foundation

extension WorkspaceGroupCoordinator {
    /// Resolves the live confirmation snapshot for deleting a workspace group.
    ///
    /// Membership is read from the current container and leaf records at
    /// action time, so stale sidebar render snapshots cannot drive the
    /// destructive confirmation copy or delete follow-through. A group is
    /// deletable only when empty: the returned snapshot's `isEmpty` reflects
    /// whether there are containers under the group.
    /// - Parameter groupId: The group being considered for deletion.
    /// - Returns: The current confirmation snapshot, or `nil` if the group no
    ///   longer exists.
    public func deletionConfirmation(groupId: UUID) -> WorkspaceGroupDeletionConfirmation? {
        guard let group = model.workspaceGroups.first(where: { $0.id == groupId }) else {
            return nil
        }
        let containerIds = model.containers(inGroup: groupId).map(\.id)
        let memberWorkspaceIds = model.leaves(inGroup: groupId).map(\.id)
        return WorkspaceGroupDeletionConfirmation(
            groupId: group.id,
            groupName: group.name,
            containerIds: containerIds,
            memberWorkspaceIds: memberWorkspaceIds
        )
    }

    /// Resolves delete intent from a rendered group header.
    ///
    /// The sidebar header row can briefly outlive the backing group record
    /// while SwiftUI drains an old list snapshot. From the user's perspective
    /// the folder is still on screen and its Delete Group menu item must act
    /// on that visible header instead of no-oping on the stale group id.
    public func deletionConfirmation(
        groupId: UUID,
        fallbackGroupName: String
    ) -> WorkspaceGroupDeletionConfirmation? {
        if let confirmation = deletionConfirmation(groupId: groupId) {
            return confirmation
        }
        // Group record already gone: synthesize an empty confirmation so the
        // app's confirmation UI no-ops cleanly rather than crashing on a nil
        // unwrap. There is nothing left to delete.
        return WorkspaceGroupDeletionConfirmation(
            groupId: groupId,
            groupName: fallbackGroupName,
            containerIds: [],
            memberWorkspaceIds: []
        )
    }

    /// Deletes a group using the exact membership the user confirmed.
    ///
    /// **Non-empty groups are rejected** (`false`): a group with containers has
    /// leaves that would be destroyed, and the normalized model requires
    /// containers to be removed individually (closing their leaves) before the
    /// group is deleted. Confirmation sheets run a nested modal loop, so other
    /// entrypoints can mutate the group before the user clicks the destructive
    /// button; this method re-checks emptiness against the live model.
    @discardableResult
    public func deleteWorkspaceGroup(
        confirmed confirmation: WorkspaceGroupDeletionConfirmation
    ) -> Bool {
        guard model.workspaceGroups.contains(where: { $0.id == confirmation.groupId }) else {
            return false
        }
        // Re-check live membership: any container or leaf under the group makes
        // the deletion unsafe. The user must empty the group first.
        let liveContainerIds = model.containers(inGroup: confirmation.groupId).map(\.id)
        let liveMemberIds = model.leaves(inGroup: confirmation.groupId).map(\.id)
        guard liveContainerIds.isEmpty && liveMemberIds.isEmpty else {
            return false
        }
        model.workspaceGroups.removeAll { $0.id == confirmation.groupId }
        model.normalizeWorkspaceNesting()
        host?.workspaceOrderDidChange(movedWorkspaceIds: [])
        return true
    }
}
