import Foundation

/// Parent-owned immutable values consumed by the workspace sidebar's lazy rows.
///
/// The dictionaries and shared selection aggregate are value projections built
/// before `LazyVStack`. Row/action construction operates only on these copied
/// values, never on observable stores.
struct SidebarWorkspaceRowsSnapshot {
    let workspaceRowsById: [UUID: SidebarWorkspaceRowInput]
    let workspaceGroupMenuSnapshot: WorkspaceGroupMenuSnapshot
    let canCreateEmptyGroup: Bool
    let selectedContextMenuTargetAggregate: SidebarWorkspaceContextMenuTargetAggregate

    private let notificationIndex: SidebarWorkspaceNotificationIndex

    @MainActor
    init(
        workspaceRowsById: [UUID: SidebarWorkspaceRowInput],
        selectedContextTargetIds: [UUID],
        workspaceGroupMenuSnapshot: WorkspaceGroupMenuSnapshot,
        canCreateEmptyGroup: Bool,
        notificationIndex: SidebarWorkspaceNotificationIndex
    ) {
        self.workspaceRowsById = workspaceRowsById
        self.workspaceGroupMenuSnapshot = workspaceGroupMenuSnapshot
        self.canCreateEmptyGroup = canCreateEmptyGroup
        self.notificationIndex = notificationIndex
        selectedContextMenuTargetAggregate = SidebarWorkspaceContextMenuTargetAggregate(
            targetWorkspaceIds: selectedContextTargetIds,
            workspaceRowsById: workspaceRowsById,
            notificationIndex: notificationIndex
        )
    }

    @MainActor
    func contextMenuTargetAggregate(for input: SidebarWorkspaceRowInput) -> SidebarWorkspaceContextMenuTargetAggregate {
        guard !input.isMultiSelected else { return selectedContextMenuTargetAggregate }
        return SidebarWorkspaceContextMenuTargetAggregate(
            targetWorkspaceIds: [input.workspaceId],
            workspaceRowsById: workspaceRowsById,
            notificationIndex: notificationIndex
        )
    }

}
