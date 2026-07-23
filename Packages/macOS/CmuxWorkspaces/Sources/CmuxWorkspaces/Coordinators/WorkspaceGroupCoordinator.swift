public import Foundation
internal import OSLog

private let workspaceGroupLogger = Logger(subsystem: "com.cmuxterm.app", category: "WorkspaceGroupCoordinator")

/// Sequences every workspace-group flow over the window's `WorkspacesModel`:
/// group creation (an independent, possibly-empty group record), rename,
/// collapse/pin/color/icon mutation, and group-slot moves within a pin tier —
/// lifted from the legacy TabManager method bodies and normalized to the
/// group > container > leaf model. Groups no longer carry a hidden anchor
/// workspace: their lifecycle is independent and they may remain empty.
/// Workspace creation/teardown, selection moves, sidebar multi-selection
/// sync, localized strings, and settings reads invert through
/// `WorkspaceGroupHosting`. Leaf and container operations live on
/// ``WorkspaceContainerCoordinator``.
@MainActor
public final class WorkspaceGroupCoordinator<Tab: WorkspaceTabRepresenting> {
    let model: WorkspacesModel<Tab>
    weak var host: (any WorkspaceGroupHosting<Tab>)?

    /// Creates the coordinator over the window's workspace model.
    public init(model: WorkspacesModel<Tab>) {
        self.model = model
    }

    /// Attaches the window-side host.
    public func attach(host: any WorkspaceGroupHosting<Tab>) {
        self.host = host
    }

    // MARK: - Creation

    /// Create a new, independent, possibly-empty group. Returns the new group
    /// id. Unlike the legacy anchor-based flow, no workspace is created: the
    /// group is a pure sidebar record and may stay empty until a container is
    /// added via ``WorkspaceContainerCoordinator/createContainer``.
    @discardableResult
    public func createWorkspaceGroup(
        name: String,
        isPinned: Bool = false
    ) -> UUID? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.isEmpty
            ? nextAutoWorkspaceGroupName()
            : trimmedName
        let group = WorkspaceGroup(
            id: UUID(),
            name: resolvedName,
            isCollapsed: false,
            isPinned: isPinned,
            lastActiveWorkspaceId: nil,
            customColor: nil,
            iconSymbol: nil
        )
        model.workspaceGroups.append(group)
        model.normalizeWorkspaceNesting()
        host?.workspaceOrderDidChange(movedWorkspaceIds: [])
        return group.id
    }

    // MARK: - Group properties

    /// Rename a group. Whitespace-only names are ignored.
    public func renameWorkspaceGroup(groupId: UUID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let index = model.workspaceGroups.firstIndex(where: { $0.id == groupId }) else { return }
        guard model.workspaceGroups[index].name != trimmed else { return }
        model.workspaceGroups[index].name = trimmed
        // The group's name is the single source of truth for its header title.
        // The sidebar re-reads `group.name` via the published array, but the
        // imperatively-cached window-chrome surfaces (custom title bar, toolbar
        // command label) need an explicit nudge, and NSWindow.title is
        // refreshed inline by the host.
        host?.workspaceGroupNameDidChange()
    }

    /// UI-only collapse toggle: when collapsing, moves focus to the group's
    /// last-active leaf so the user does not end up focused on a row that is
    /// about to be hidden. The pure-data variant
    /// ``setWorkspaceGroupCollapsed(groupId:isCollapsed:)`` is the right call
    /// for socket/CLI paths that must preserve focus.
    public func toggleWorkspaceGroupCollapsed(groupId: UUID) {
        guard let host else { return }
        guard let index = model.workspaceGroups.firstIndex(where: { $0.id == groupId }) else { return }
        let nextCollapsed = !model.workspaceGroups[index].isCollapsed
        if nextCollapsed {
            if let selectedTabId = model.selectedTabId {
                let selectedLeafGroup = model.group(forLeaf: selectedTabId)
                if selectedLeafGroup?.id == groupId,
                   let focusLeaf = model.resolveLastActiveLeaf(inGroup: groupId) {
                    host.selectWorkspace(focusLeaf)
                }
            }
            // Strip any sidebar multi-selection entries that point at leaves
            // in this group that will be hidden by the collapse.
            let groupLeafIds: Set<UUID> = Set(model.leaves(inGroup: groupId).map(\.id))
            let focusLeafId = model.resolveLastActiveLeaf(inGroup: groupId)?.id
            let hiddenLeafIds = groupLeafIds.subtracting(focusLeafId.map { [$0] } ?? [])
            if !hiddenLeafIds.isEmpty,
               !host.sidebarSelectedWorkspaceIds.isDisjoint(with: hiddenLeafIds) {
                host.subtractSidebarSelection(
                    hiddenWorkspaceIds: hiddenLeafIds,
                    focusedWorkspaceId: focusLeafId
                )
            }
        }
        setWorkspaceGroupCollapsed(groupId: groupId, isCollapsed: nextCollapsed)
    }

    /// Pure data mutation — flips the collapse flag without touching
    /// selection. Use this from socket/CLI handlers so a non-focus-intent
    /// command never steals the user's active workspace.
    public func setWorkspaceGroupCollapsed(groupId: UUID, isCollapsed: Bool) {
        guard let index = model.workspaceGroups.firstIndex(where: { $0.id == groupId }) else { return }
        guard model.workspaceGroups[index].isCollapsed != isCollapsed else { return }
        model.workspaceGroups[index].isCollapsed = isCollapsed
    }

    /// Toggle the pinned state of a whole group. Pinned groups float above
    /// unpinned groups in the sidebar. Independent of per-leaf pin.
    public func toggleWorkspaceGroupPinned(groupId: UUID) {
        setWorkspaceGroupPinned(
            groupId: groupId,
            isPinned: !(model.workspaceGroups.first(where: { $0.id == groupId })?.isPinned ?? false)
        )
    }

    /// Sets the group's pinned state and renormalizes the group pin tiers.
    public func setWorkspaceGroupPinned(groupId: UUID, isPinned: Bool) {
        guard let index = model.workspaceGroups.firstIndex(where: { $0.id == groupId }) else { return }
        guard model.workspaceGroups[index].isPinned != isPinned else { return }
        model.workspaceGroups[index].isPinned = isPinned
        model.normalizeWorkspaceNesting()
        let leafIds = model.leaves(inGroup: groupId).map(\.id)
        host?.workspaceOrderDidChange(movedWorkspaceIds: leafIds)
    }

    /// Sets the group-level color override (hex string, nil clears).
    public func setWorkspaceGroupColor(groupId: UUID, hex: String?) {
        guard let index = model.workspaceGroups.firstIndex(where: { $0.id == groupId }) else { return }
        guard model.workspaceGroups[index].customColor != hex else { return }
        model.workspaceGroups[index].customColor = hex
    }

    /// Sets the group header icon (normalized through the host's symbol
    /// catalog); returns the normalized symbol.
    @discardableResult
    public func setWorkspaceGroupIcon(groupId: UUID, symbol: String?) -> String? {
        guard let host else { return nil }
        let normalized = host.normalizedGroupIconSymbol(symbol)
        guard let index = model.workspaceGroups.firstIndex(where: { $0.id == groupId }) else { return nil }
        guard model.workspaceGroups[index].iconSymbol != normalized else { return normalized }
        model.workspaceGroups[index].iconSymbol = normalized
        return normalized
    }

    // MARK: - Group selection

    /// Resolve the group's last-active leaf and select it. No-op when the
    /// group is empty (no containers/leaves) — the app may choose to focus the
    /// empty group header as a UI concern.
    public func selectGroupHeader(groupId: UUID) {
        guard let host else { return }
        guard let leaf = model.resolveLastActiveLeaf(inGroup: groupId) else { return }
        host.selectWorkspace(leaf)
    }

    // MARK: - Group slots

    /// Move a group to a new position within its pin tier. `targetIndex` is
    /// interpreted as the FINAL position in `workspaceGroups` (post-move) and
    /// is clamped to the range occupied by groups in the same pin tier as the
    /// source. Container and leaf order follows the group's new position via
    /// ``WorkspacesModel/normalizeWorkspaceNesting()``.
    public func moveWorkspaceGroup(groupId: UUID, toIndex targetIndex: Int) {
        guard moveWorkspaceGroupSlot(groupId: groupId, toIndex: targetIndex) else { return }
        model.normalizeWorkspaceNesting()
        let leafIds = model.leaves(inGroup: groupId).map(\.id)
        host?.workspaceOrderDidChange(movedWorkspaceIds: leafIds)
    }

    @discardableResult
    private func moveWorkspaceGroupSlot(groupId: UUID, toIndex targetIndex: Int) -> Bool {
        guard let currentIndex = model.workspaceGroups.firstIndex(where: { $0.id == groupId }) else { return false }
        let isPinned = model.workspaceGroups[currentIndex].isPinned
        let sameTierIndices = model.workspaceGroups.indices.filter { model.workspaceGroups[$0].isPinned == isPinned }
        guard let firstSameTier = sameTierIndices.first,
              let lastSameTier = sameTierIndices.last else { return false }
        let clampedTarget = max(firstSameTier, min(targetIndex, lastSameTier))
        guard clampedTarget != currentIndex else { return false }
        let group = model.workspaceGroups.remove(at: currentIndex)
        model.workspaceGroups.insert(group, at: max(0, min(clampedTarget, model.workspaceGroups.count)))
        return true
    }

    // MARK: - Deletion

    /// Delete a group. **Fails (returns `false`) when the group is non-empty**
    /// — a non-empty group has containers whose leaves would be destroyed.
    /// Callers must first remove every container
    /// (``WorkspaceContainerCoordinator/removeContainer``) or confirm via
    /// ``deletionConfirmation``. Empty groups delete unconditionally.
    @discardableResult
    public func deleteWorkspaceGroup(groupId: UUID) -> Bool {
        guard let confirmation = deletionConfirmation(groupId: groupId) else { return false }
        return deleteWorkspaceGroup(confirmed: confirmation)
    }

    // MARK: - Naming

    /// Pick the next "Group N" name that doesn't collide with an existing
    /// group. Used when the user creates a group without naming it. The
    /// localized format comes from the host (String(localized:) stays
    /// app-side).
    private func nextAutoWorkspaceGroupName() -> String {
        let used = Set(model.workspaceGroups.map(\.name))
        var n = model.workspaceGroups.count + 1
        while true {
            let format = host?.localizedAutoGroupNameFormat ?? "Group %lld"
            let candidate = String.localizedStringWithFormat(format, n)
            if !used.contains(candidate) { return candidate }
            n += 1
        }
    }
}
