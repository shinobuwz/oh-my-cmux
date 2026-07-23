public import Foundation

// Sidebar ordering reads and reorder-index clamps over the model's
// group > container > leaf storage. All pure reads; mutating flows live on
// the coordinators and ``WorkspacesModel``'s nesting invariants extension.
extension WorkspacesModel {
    // MARK: - Structural resolves

    /// The container owning the leaf, or `nil` for an orphan leaf.
    public func container(forLeaf leafId: UUID) -> WorkspaceContainer? {
        guard let containerId = tabs.first(where: { $0.id == leafId })?.workspaceContainerId else {
            return nil
        }
        return workspaceContainers.first(where: { $0.id == containerId })
    }

    /// The group owning the container, or `nil`.
    public func group(forContainer containerId: UUID) -> WorkspaceGroup? {
        guard let container = workspaceContainers.first(where: { $0.id == containerId }) else {
            return nil
        }
        return workspaceGroups.first(where: { $0.id == container.groupId })
    }

    /// The group owning the leaf's container, or `nil` for an orphan leaf.
    public func group(forLeaf leafId: UUID) -> WorkspaceGroup? {
        container(forLeaf: leafId).flatMap { group(forContainer: $0.id) }
    }

    /// The containers belonging to `groupId`, in `workspaceContainers` order.
    public func containers(inGroup groupId: UUID) -> [WorkspaceContainer] {
        workspaceContainers.filter { $0.groupId == groupId }
    }

    /// The leaves belonging to `containerId`, in `tabs` order.
    public func leaves(inContainer containerId: UUID) -> [Tab] {
        tabs.filter { $0.workspaceContainerId == containerId }
    }

    /// The leaves belonging to `groupId` (across its containers), in order.
    public func leaves(inGroup groupId: UUID) -> [Tab] {
        let containerIds = Set(containers(inGroup: groupId).map(\.id))
        return tabs.filter { containerIds.contains($0.workspaceContainerId ?? UUID()) }
    }

    // MARK: - Main leaf

    /// The fixed main leaf of a Git container (the leaf whose binding role is
    /// ``WorkspaceLeafRole/main``), or `nil` for non-Git containers or when
    /// no main leaf is present. The main leaf stays first in its container.
    public func mainLeaf(ofContainer containerId: UUID) -> Tab? {
        guard let container = workspaceContainers.first(where: { $0.id == containerId }),
              container.kind == .git else {
            return nil
        }
        let members = leaves(inContainer: containerId)
        return members.first(where: { $0.leafBinding.role == .main }) ?? members.first
    }

    /// Whether the leaf is the fixed main leaf of its Git container.
    public func isMainLeaf(_ leafId: UUID) -> Bool {
        guard let leaf = tabs.first(where: { $0.id == leafId }) else { return false }
        return leaf.leafBinding.role == .main && mainLeaf(ofContainer: leaf.workspaceContainerId ?? UUID())?.id == leafId
    }

    // MARK: - Last-active resolution

    /// The last active leaf for a group: the recorded
    /// ``WorkspaceGroup/lastActiveWorkspaceId`` when it still exists under the
    /// group, otherwise the group's first available leaf (main leaf of its
    /// first container, then any leaf). `nil` when the group is empty.
    public func resolveLastActiveLeaf(inGroup groupId: UUID) -> Tab? {
        let groupLeaves = leaves(inGroup: groupId)
        if let group = workspaceGroups.first(where: { $0.id == groupId }),
           let recorded = group.lastActiveWorkspaceId,
           let leaf = groupLeaves.first(where: { $0.id == recorded }) {
            return leaf
        }
        // Fall back to the first container's main leaf, else the first leaf.
        for container in containers(inGroup: groupId) {
            if let main = mainLeaf(ofContainer: container.id) { return main }
            if let first = leaves(inContainer: container.id).first { return first }
        }
        return groupLeaves.first
    }

    /// The last active leaf for a container: the recorded
    /// ``WorkspaceContainer/lastActiveWorkspaceId`` when it still exists,
    /// otherwise the container's main leaf, otherwise its first leaf.
    public func resolveLastActiveLeaf(inContainer containerId: UUID) -> Tab? {
        let members = leaves(inContainer: containerId)
        if let container = workspaceContainers.first(where: { $0.id == containerId }),
           let recorded = container.lastActiveWorkspaceId,
           let leaf = members.first(where: { $0.id == recorded }) {
            return leaf
        }
        return mainLeaf(ofContainer: containerId) ?? members.first
    }

    // MARK: - Reorder clamps

    /// Clamps a requested reorder index for a leaf into its legal range: the
    /// leaf's own container section (so leaves never leave their container via
    /// a plain index reorder), and the pinned tier within that section.
    func clampedReorderIndex(for workspace: Tab, targetIndex: Int) -> Int {
        let clamped = max(0, min(targetIndex, tabs.count - 1))
        guard let containerId = workspace.workspaceContainerId else {
            // Orphan leaf (migration only): plain global clamp.
            return clamped
        }
        return clampedLeafReorderIndex(
            for: workspace,
            withinContainer: containerId,
            clampedTargetIndex: clamped
        )
    }

    /// The in-container clamp for a leaf reorder: the leaf may move anywhere
    /// inside its container's contiguous section, but the container's main
    /// leaf (when present) always occupies the section's first slot.
    func clampedLeafReorderIndex(
        for workspace: Tab,
        withinContainer containerId: UUID,
        clampedTargetIndex: Int
    ) -> Int {
        let memberIndices = tabs.indices.filter { tabs[$0].workspaceContainerId == containerId }
        guard let firstIndex = memberIndices.first,
              let lastIndex = memberIndices.last else {
            return clampedTargetIndex
        }
        let mainId = mainLeaf(ofContainer: containerId)?.id
        // Pinned non-main members sit directly after the main leaf.
        let pinnedMemberCount = memberIndices.reduce(into: 0) { count, index in
            let member = tabs[index]
            if member.id != mainId, member.isPinned { count += 1 }
        }
        let isMain = workspace.id == mainId
        // The main leaf is fixed at the section's leading edge.
        if isMain { return firstIndex }

        let lowerBound: Int
        let upperBound: Int
        if workspace.isPinned {
            lowerBound = min(firstIndex + 1, lastIndex)
            upperBound = max(firstIndex + pinnedMemberCount, lowerBound)
        } else {
            lowerBound = min(firstIndex + 1 + pinnedMemberCount, lastIndex)
            upperBound = lastIndex
        }
        return min(max(clampedTargetIndex, lowerBound), upperBound)
    }

    /// The number of leading members in a container's section that are pinned
    /// (including the main leaf for Git containers), used for pin-tier moves.
    func leadingPinnedMemberCount(inContainer containerId: UUID) -> Int {
        let mainId = mainLeaf(ofContainer: containerId)?.id
        var count = 0
        for tab in tabs where tab.workspaceContainerId == containerId {
            if tab.id == mainId || tab.isPinned {
                count += 1
            } else {
                break
            }
        }
        return count
    }
}
