public import Foundation

// Nesting invariant maintenance over the model's own group > container > leaf
// storage: contiguous container sections, main-leaf-first, pinned tiers, and
// the selection/close lifecycle hooks that keep the normalized model honest.
extension WorkspacesModel {
    // MARK: - Membership

    /// Sets a workspace's container membership, then expands the leaf's
    /// container/group ancestors so the moved leaf stays visible. Called by
    /// coordinators after attaching/detaching a leaf.
    func assignContainer(workspaceId: UUID, containerId: UUID?) {
        guard let tab = tabs.first(where: { $0.id == workspaceId }) else { return }
        guard tab.workspaceContainerId != containerId else { return }
        tab.workspaceContainerId = containerId
        recordSelection(ofLeaf: tab.id)
    }

    // MARK: - Nesting normalization

    /// Rebuilds `tabs` (and sorts `workspaceGroups` by pin tier) so the
    /// canonical sidebar order holds:
    /// 1. Pinned groups (stable, in `workspaceGroups` order), each expanded as
    ///    its containers in order, each container as its leaves.
    /// 2. Unpinned groups, likewise.
    /// Within a container: main leaf first (Git only), then pinned non-main
    /// leaves, then unpinned non-main leaves, preserving relative order.
    /// Orphan leaves (nil container, migration only) are appended at the end.
    ///
    /// Call this after any structural mutation that could disturb nesting.
    /// Unlike the legacy contiguity normalizer, it never forges anchor
    /// workspaces: groups and containers are independent records.
    public func normalizeWorkspaceNesting() {
        guard !tabs.isEmpty else { return }

        // Drop membership pointing at unknown containers.
        let knownContainerIds = Set(workspaceContainers.map(\.id))
        for tab in tabs where tab.workspaceContainerId.map({ !knownContainerIds.contains($0) }) ?? false {
            tab.workspaceContainerId = nil
        }

        // Stable pin-tier sort of groups: pinned first, order preserved.
        workspaceGroups.sort { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
            return false
        }

        let containersByGroup: [UUID: [WorkspaceContainer]] = Dictionary(
            grouping: workspaceContainers,
            by: \.groupId
        )
        var leavesByContainer: [UUID: [Tab]] = Dictionary(
            grouping: tabs.filter { $0.workspaceContainerId != nil },
            by: { $0.workspaceContainerId! }
        )

        var reordered: [Tab] = []
        reordered.reserveCapacity(tabs.count)
        var emitted = Set<UUID>()

        for group in workspaceGroups {
            for container in containersByGroup[group.id] ?? [] {
                let members = orderedMembers(leavesByContainer[container.id] ?? [], in: container)
                leavesByContainer[container.id] = members
                for member in members where emitted.insert(member.id).inserted {
                    reordered.append(member)
                }
            }
        }
        // Append any orphan leaves (nil container) in current order.
        for tab in tabs where tab.workspaceContainerId == nil && emitted.insert(tab.id).inserted {
            reordered.append(tab)
        }

        tabs = reordered
    }

    /// Orders a container's members: main leaf first (Git only), then pinned
    /// non-main, then unpinned non-main, preserving relative order in each tier.
    private func orderedMembers(_ members: [Tab], in container: WorkspaceContainer) -> [Tab] {
        guard container.kind == .git else {
            // Non-Git: no fixed main leaf — pinned above unpinned, relative order kept.
            return members.filter(\.isPinned) + members.filter { !$0.isPinned }
        }
        let mainId = members.first(where: { $0.leafBinding.role == .main })?.id
        guard let mainId else {
            return members.filter(\.isPinned) + members.filter { !$0.isPinned }
        }
        let main = members.first(where: { $0.id == mainId })
        let nonMain = members.filter { $0.id != mainId }
        let pinnedNonMain = nonMain.filter(\.isPinned)
        let unpinnedNonMain = nonMain.filter { !$0.isPinned }
        return [main].compactMap { $0 } + pinnedNonMain + unpinnedNonMain
    }

    // MARK: - Selection

    /// Records the selected leaf on its container and group (their
    /// `lastActiveWorkspaceId`) and expands both ancestors so the row is
    /// visible. Call from the selection `didSet` host hook (replaces the
    /// legacy group auto-expand). No-op for `nil` or orphan leaves.
    public func recordSelection(ofLeaf leafId: UUID?) {
        guard let leafId,
              let leaf = tabs.first(where: { $0.id == leafId }),
              let containerId = leaf.workspaceContainerId,
              let containerIndex = workspaceContainers.firstIndex(where: { $0.id == containerId }) else {
            return
        }
        workspaceContainers[containerIndex].lastActiveWorkspaceId = leafId
        workspaceContainers[containerIndex].isCollapsed = false
        let groupId = workspaceContainers[containerIndex].groupId
        if let groupIndex = workspaceGroups.firstIndex(where: { $0.id == groupId }) {
            workspaceGroups[groupIndex].lastActiveWorkspaceId = leafId
            workspaceGroups[groupIndex].isCollapsed = false
        }
    }

    // MARK: - Close lifecycle

    /// Reconciles the hierarchy after a leaf has been removed from `tabs` by
    /// the close path: clears stale `lastActiveWorkspaceId` pointers, prunes
    /// containers that no longer have any leaves, and clears a group's
    /// last-active pointer when it referenced a leaf of a pruned container.
    /// The caller is responsible for having already removed the closed leaf
    /// from `tabs`.
    public func handleLeafRemoved(_ leafId: UUID) {
        // Clear stale last-active on containers.
        for index in workspaceContainers.indices where workspaceContainers[index].lastActiveWorkspaceId == leafId {
            let containerId = workspaceContainers[index].id
            let replacement = leaves(inContainer: containerId).first?.id
            workspaceContainers[index].lastActiveWorkspaceId = replacement
        }
        // Prune containers with no remaining leaves (a container without a
        // leaf has no purpose in the normalized model).
        let liveContainerIds = Set(tabs.compactMap(\.workspaceContainerId))
        let prunedContainerIds = Set(
            workspaceContainers.filter { !liveContainerIds.contains($0.id) }.map(\.id)
        )
        workspaceContainers.removeAll { prunedContainerIds.contains($0.id) }

        // Clear stale group last-active pointing at leaves under pruned containers.
        if !prunedContainerIds.isEmpty {
            for index in workspaceGroups.indices {
                guard let recorded = workspaceGroups[index].lastActiveWorkspaceId,
                      let containerId = workspaceContainers
                        .first(where: { $0.lastActiveWorkspaceId == recorded })?
                        .id,
                      prunedContainerIds.contains(containerId) else {
                    continue
                }
                workspaceGroups[index].lastActiveWorkspaceId =
                    resolveLastActiveLeaf(inGroup: workspaceGroups[index].id)?.id
            }
        }
        // Groups are never pruned here: they may remain empty.
    }
}
