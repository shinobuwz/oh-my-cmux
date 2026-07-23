public import Foundation

/// Sequences every sidebar/socket workspace reorder flow over the window's
/// `WorkspacesModel`: move-to-top, single and batch reorders, drag-driven
/// container-membership inference, container-header (between-group) reorders,
/// and pin-state changes — normalized to the group > container > leaf model.
///
/// **Key invariants enforced:**
/// - Leaves only reorder within their own container section; a plain index
///   reorder never moves a leaf out of its container (use
///   ``WorkspaceContainerCoordinator/moveLeaf`` for that).
/// - The main leaf of a Git container is fixed first; it never yields its
///   leading slot to a drag or pin change.
/// - Container headers reorder between groups via ``reorderContainer(_:toGroup:toIndex:)``,
///   which reparents the container record rather than moving leaves.
///
/// Pure plan computation stays in `WorkspaceReorderPlanner`; observable
/// order-change publication inverts through `WorkspaceOrderHosting`.
@MainActor
public final class WorkspaceReorderCoordinator<Tab: WorkspaceTabRepresenting> {
    private let model: WorkspacesModel<Tab>
    private let planner = WorkspaceReorderPlanner()
    private weak var host: (any WorkspaceOrderHosting)?

    /// Creates the coordinator over the window's workspace model.
    public init(model: WorkspacesModel<Tab>) {
        self.model = model
    }

    /// Attaches the window-side host for order-change publication.
    public func attach(host: any WorkspaceOrderHosting) {
        self.host = host
    }

    // MARK: - Move to top

    /// Moves one workspace to the top of its pin tier within its container
    /// (the main-leaf-first invariant still holds for Git containers).
    public func moveTabToTop(_ tabId: UUID) {
        moveTabsToTop([tabId])
    }

    /// Moves the given workspaces to the top of their pin tiers within their
    /// respective containers, preserving relative order. The main leaf stays
    /// first in any Git container.
    public func moveTabsToTop(_ tabIds: Set<UUID>) {
        guard !tabIds.isEmpty else { return }
        let selectedTabs = model.tabs.filter { tabIds.contains($0.id) }
        guard !selectedTabs.isEmpty else { return }
        let previousOrder = model.tabs.map(\.id)

        // Group the moved leaves by container so each container's section is
        // rebuilt independently.
        let selectedByContainer = Dictionary(grouping: selectedTabs, by: { $0.workspaceContainerId })
        var emitted = Set<UUID>()
        var reordered: [Tab] = []
        reordered.reserveCapacity(model.tabs.count)
        for tab in model.tabs {
            guard let containerId = tab.workspaceContainerId else {
                // Orphan leaf (migration only): keep in place relative to its tier.
                if emitted.insert(tab.id).inserted { reordered.append(tab) }
                continue
            }
            guard let selectedInContainer = selectedByContainer[containerId],
                  !selectedInContainer.isEmpty,
                  !emitted.contains(containerId) else {
                // Not a moved member of this container, or already emitted it.
                if emitted.insert(tab.id).inserted { reordered.append(tab) }
                continue
            }
            // Emit the container's section once: main (if not selected), selected
            // pinned, remaining pinned, selected unpinned, remaining unpinned.
            let members = model.leaves(inContainer: containerId)
            let selectedIds = Set(selectedInContainer.map(\.id))
            let mainId = model.mainLeaf(ofContainer: containerId)?.id
            let main = members.first(where: { $0.id == mainId })
            if let main, !selectedIds.contains(main.id), emitted.insert(main.id).inserted {
                reordered.append(main)
            }
            let nonMain = members.filter { $0.id != mainId }
            let selectedPinned = nonMain.filter { selectedIds.contains($0.id) && $0.isPinned }
            let remainingPinned = nonMain.filter { !selectedIds.contains($0.id) && $0.isPinned }
            let selectedUnpinned = nonMain.filter { selectedIds.contains($0.id) && !$0.isPinned }
            let remainingUnpinned = nonMain.filter { !selectedIds.contains($0.id) && !$0.isPinned }
            for member in selectedPinned + remainingPinned + selectedUnpinned + remainingUnpinned
            where emitted.insert(member.id).inserted {
                reordered.append(member)
            }
            emitted.insert(containerId)
        }
        model.tabs = reordered
        if model.tabs.map(\.id) != previousOrder {
            host?.workspaceOrderDidChange(movedWorkspaceIds: selectedTabs.map(\.id))
        }
    }

    /// Moves a workspace to the top of the unpinned tier of its container for a
    /// notification bump; no-ops for main leaves, pinned leaves, or leaves
    /// already at the boundary.
    public func moveTabToTopForNotification(_ tabId: UUID) {
        guard let tab = model.tabs.first(where: { $0.id == tabId }),
              let containerId = tab.workspaceContainerId else { return }
        if model.isMainLeaf(tabId) { return }
        if tab.isPinned { return }
        let previousOrder = model.tabs.map(\.id)
        let members = model.leaves(inContainer: containerId)
        let mainId = model.mainLeaf(ofContainer: containerId)?.id
        let pinnedMembers = members.filter { $0.id != mainId && $0.isPinned }
        var unpinnedMembers = members.filter { $0.id != mainId && !$0.isPinned }
        guard let unpinnedIndex = unpinnedMembers.firstIndex(where: { $0.id == tabId }) else { return }
        let moved = unpinnedMembers.remove(at: unpinnedIndex)
        unpinnedMembers.insert(moved, at: 0)
        // Rebuild only this container's section in place.
        var reordered: [Tab] = []
        var emittedContainer = false
        for existing in model.tabs {
            if existing.workspaceContainerId == containerId {
                if !emittedContainer {
                    let main = members.first(where: { $0.id == mainId })
                    if let main { reordered.append(main) }
                    reordered.append(contentsOf: pinnedMembers)
                    reordered.append(contentsOf: unpinnedMembers)
                    emittedContainer = true
                }
            } else {
                reordered.append(existing)
            }
        }
        model.tabs = reordered
        if model.tabs.map(\.id) != previousOrder {
            host?.workspaceOrderDidChange(movedWorkspaceIds: [tabId])
        }
    }

    // MARK: - Single leaf reorder

    /// Reorders one leaf to the clamped target index; drag operations
    /// additionally run neighbor-based container-membership inference when an
    /// explicit container is supplied. Leaves never leave their container via a
    /// plain index reorder; the main leaf stays first.
    @discardableResult
    public func reorderWorkspace(
        tabId: UUID,
        toIndex targetIndex: Int,
        isDragOperation: Bool = false,
        explicitContainerId: UUID? = nil
    ) -> Bool {
        let plan = workspaceReorderPlan(tabId: tabId, toIndex: targetIndex)
        guard let plan else { return false }
        if model.tabs.count <= 1 {
            return true
        }
        if plan.fromIndex == plan.toIndex {
            guard isDragOperation, explicitContainerId != nil else {
                return true
            }
            let previousOrder = model.tabs.map(\.id)
            let previousContainerId = model.tabs[plan.fromIndex].workspaceContainerId
            applyDragInferredContainerMembership(workspaceId: tabId, explicitContainerId: explicitContainerId)
            let currentContainerId = model.tabs.first(where: { $0.id == tabId })?.workspaceContainerId
            if currentContainerId != previousContainerId || model.tabs.map(\.id) != previousOrder {
                host?.workspaceOrderDidChange(movedWorkspaceIds: [tabId])
            }
            return true
        }

        let workspace = model.tabs.remove(at: plan.fromIndex)
        model.tabs.insert(workspace, at: plan.toIndex)
        if isDragOperation {
            applyDragInferredContainerMembership(workspaceId: tabId, explicitContainerId: explicitContainerId)
        } else {
            model.normalizeWorkspaceNesting()
        }
        host?.workspaceOrderDidChange(movedWorkspaceIds: [tabId])
        return true
    }

    /// Reorders relative to a sibling workspace (socket before/after verbs).
    @discardableResult
    public func reorderWorkspace(
        tabId: UUID,
        before beforeId: UUID? = nil,
        after afterId: UUID? = nil,
        isDragOperation: Bool = false
    ) -> Bool {
        guard let plan = workspaceReorderPlan(tabId: tabId, before: beforeId, after: afterId) else { return false }
        return reorderWorkspace(tabId: tabId, toIndex: plan.toIndex, isDragOperation: isDragOperation)
    }

    /// The clamped single-leaf reorder plan, or `nil` when unknown. The clamp
    /// keeps the leaf inside its container section and respects the main-
    /// leaf-first invariant.
    public func workspaceReorderPlan(tabId: UUID, toIndex targetIndex: Int) -> WorkspaceReorderPlanItem? {
        guard let currentIndex = model.tabs.firstIndex(where: { $0.id == tabId }) else { return nil }
        if model.tabs.count <= 1 {
            return WorkspaceReorderPlanItem(workspaceId: tabId, fromIndex: currentIndex, toIndex: currentIndex)
        }
        let workspace = model.tabs[currentIndex]
        let clamped = model.clampedReorderIndex(for: workspace, targetIndex: targetIndex)
        return WorkspaceReorderPlanItem(workspaceId: tabId, fromIndex: currentIndex, toIndex: clamped)
    }

    /// The before/after-relative reorder plan, or `nil` when unknown.
    public func workspaceReorderPlan(
        tabId: UUID,
        before beforeId: UUID? = nil,
        after afterId: UUID? = nil
    ) -> WorkspaceReorderPlanItem? {
        guard let currentIndex = model.tabs.firstIndex(where: { $0.id == tabId }) else { return nil }
        if let beforeId {
            guard let idx = model.tabs.firstIndex(where: { $0.id == beforeId }) else { return nil }
            let targetIndex = currentIndex < idx ? idx - 1 : idx
            return workspaceReorderPlan(tabId: tabId, toIndex: targetIndex)
        }
        if let afterId {
            guard let idx = model.tabs.firstIndex(where: { $0.id == afterId }) else { return nil }
            let targetIndex = currentIndex < idx ? idx : idx + 1
            return workspaceReorderPlan(tabId: tabId, toIndex: targetIndex)
        }
        return nil
    }

    // MARK: - Container-header reorder (between groups)

    /// Reorder a container header to a new group and/or position. This
    /// reparents the container record (moving its whole leaf section with it)
    /// rather than reordering leaves individually.
    @discardableResult
    public func reorderContainer(
        _ containerId: UUID,
        toGroup groupId: UUID,
        toIndex targetIndex: Int
    ) -> Bool {
        guard let host else { return false }
        guard let currentIndex = model.workspaceContainers.firstIndex(where: { $0.id == containerId }) else { return false }
        guard model.workspaceGroups.contains(where: { $0.id == groupId }) else { return false }
        let targetGroupContainers = model.containers(inGroup: groupId)
        let clampedTarget = max(0, min(targetIndex, targetGroupContainers.count))
        var container = model.workspaceContainers.remove(at: currentIndex)
        let sameGroup = container.groupId == groupId
        container.groupId = groupId
        let groupStart = model.workspaceContainers.firstIndex(where: { $0.groupId == groupId }) ?? model.workspaceContainers.count
        // Account for the removal shift when moving within the same group.
        let insertIndex: Int
        if sameGroup && currentIndex < groupStart {
            insertIndex = max(0, min(groupStart - 1 + clampedTarget, model.workspaceContainers.count))
        } else {
            insertIndex = max(0, min(groupStart + clampedTarget, model.workspaceContainers.count))
        }
        model.workspaceContainers.insert(container, at: insertIndex)
        model.normalizeWorkspaceNesting()
        let leafIds = model.leaves(inContainer: containerId).map(\.id)
        host.workspaceOrderDidChange(movedWorkspaceIds: leafIds)
        return true
    }

    // MARK: - Sidebar drag planning

    /// The row-id space a sidebar drag plans in: container-header rows when
    /// the drag involves a container header or a leaf promotion, otherwise the
    /// full leaf rows of a single container.
    public func sidebarReorderLeafIds(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID? = nil,
        usesContainerRows: Bool = false
    ) -> [UUID] {
        guard usesContainerRows || sidebarReorderUsesContainerRows(
            forDraggedWorkspaceId: draggedWorkspaceId,
            targetWorkspaceId: targetWorkspaceId
        ) else {
            // Within-container drag: plan in the dragged leaf's container rows.
            if let draggedWorkspaceId,
               let leaf = model.tabs.first(where: { $0.id == draggedWorkspaceId }),
               let containerId = leaf.workspaceContainerId {
                return model.leaves(inContainer: containerId).map(\.id)
            }
            return model.tabs.map(\.id)
        }
        return model.sidebarContainerHeaderIds(promotingWorkspaceId: draggedWorkspaceId)
    }

    /// The pinned subset of the drag's row-id space.
    public func sidebarReorderPinnedLeafIds(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID? = nil,
        usesContainerRows: Bool = false
    ) -> Set<UUID> {
        let ids = sidebarReorderLeafIds(
            forDraggedWorkspaceId: draggedWorkspaceId,
            targetWorkspaceId: targetWorkspaceId,
            usesContainerRows: usesContainerRows
        )
        let tabsById = Dictionary(uniqueKeysWithValues: model.tabs.map { ($0.id, $0) })
        return Set(ids.filter { tabsById[$0]?.isPinned == true })
    }

    /// The legal insertion range for an in-container leaf drag, or `nil` when
    /// the drag is not constrained to a container section. The main leaf's
    /// leading slot is excluded from the range.
    public func sidebarReorderLegalInsertionRange(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID? = nil,
        usesContainerRows: Bool = false,
        explicitContainerId: UUID? = nil
    ) -> ClosedRange<Int>? {
        guard !usesContainerRows,
              let draggedWorkspaceId,
              let draggedWorkspace = model.tabs.first(where: { $0.id == draggedWorkspaceId }),
              let containerId = explicitContainerId ?? draggedWorkspace.workspaceContainerId,
              model.isMainLeaf(draggedWorkspaceId) == false else {
            return nil
        }
        let memberIndices = model.tabs.indices.filter { model.tabs[$0].workspaceContainerId == containerId }
        guard let firstIndex = memberIndices.first,
              let lastIndex = memberIndices.last else {
            return nil
        }
        let mainId = model.mainLeaf(ofContainer: containerId)?.id
        let pinnedMemberCount = memberIndices.reduce(into: 0) { count, index in
            let member = model.tabs[index]
            if member.id != mainId, member.isPinned { count += 1 }
        }
        if draggedWorkspace.isPinned {
            let lower = min(firstIndex + 1, lastIndex)
            let upper = max(firstIndex + pinnedMemberCount, lower)
            return lower...upper
        }
        let lower = min(firstIndex + 1 + pinnedMemberCount, lastIndex)
        let upper = lastIndex
        return min(lower, upper)...max(lower, upper)
    }

    /// Routes a sidebar reorder to the container-header path or the
    /// within-container leaf path.
    @discardableResult
    public func reorderSidebarRow(
        tabId: UUID,
        toIndex targetIndex: Int,
        isDragOperation: Bool = false,
        usesContainerRows: Bool = false,
        explicitContainerId: UUID? = nil
    ) -> Bool {
        if usesContainerRows {
            // A leaf being promoted to a container header row means detaching it
            // into the target group's scope — handled by the container
            // coordinator's move/attach, not a plain reorder. Treat as a no-op
            // reorder here; the coordinator owns the structural change.
            return false
        }
        return reorderWorkspace(
            tabId: tabId,
            toIndex: targetIndex,
            isDragOperation: isDragOperation,
            explicitContainerId: explicitContainerId
        )
    }

    /// Whether a sidebar drag plans in container-header rows (container header
    /// involved or a grouped child being promoted out of its container).
    public func sidebarReorderUsesContainerRows(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID?
    ) -> Bool {
        sidebarReorderUsesContainerRows(
            forDraggedWorkspaceId: draggedWorkspaceId,
            targetWorkspaceId: targetWorkspaceId,
            leafContainerIdByLeafId: Dictionary(uniqueKeysWithValues: model.tabs.map { ($0.id, $0.workspaceContainerId) })
        )
    }

    /// Snapshot variant of `sidebarReorderUsesContainerRows` over a caller-
    /// provided membership map.
    public func sidebarReorderUsesContainerRows(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID?,
        leafContainerIdByLeafId: [UUID: UUID?]
    ) -> Bool {
        guard let draggedWorkspaceId else { return false }
        // A container-header drag (the dragged id is a container's main leaf
        // header) or targeting a container header plans in header rows.
        if model.isMainLeaf(draggedWorkspaceId) ||
            targetWorkspaceId.map(model.isMainLeaf) == true {
            return true
        }
        guard let draggedContainerId = leafContainerIdByLeafId[draggedWorkspaceId],
              draggedContainerId != nil else {
            return false
        }
        // A grouped child dragged over top-level space is leaving its container;
        // plan in container-header rows so the promotion is explicit and ordered.
        guard let targetWorkspaceId else { return true }
        guard let targetContainerId = leafContainerIdByLeafId[targetWorkspaceId] else {
            return false
        }
        return targetContainerId == nil
    }

    /// After a drag-driven reorder, infer the dragged leaf's container
    /// membership from its new neighbors in `tabs[]`. The main leaf of a Git
    /// container never changes membership via drag — reparent its container
    /// instead.
    private func applyDragInferredContainerMembership(workspaceId: UUID, explicitContainerId: UUID? = nil) {
        guard let index = model.tabs.firstIndex(where: { $0.id == workspaceId }) else { return }
        let tab = model.tabs[index]
        if model.isMainLeaf(workspaceId) {
            // Main leaves don't change container membership via drag; their
            // container owns them. Renormalize so the section stays together.
            model.normalizeWorkspaceNesting()
            return
        }
        if let explicitContainerId {
            guard model.workspaceContainers.contains(where: { $0.id == explicitContainerId }) else { return }
            model.assignContainer(workspaceId: workspaceId, containerId: explicitContainerId)
            model.normalizeWorkspaceNesting()
            return
        }
        let before: Tab? = index > 0 ? model.tabs[index - 1] : nil
        let after: Tab? = (index + 1) < model.tabs.count ? model.tabs[index + 1] : nil
        let beforeContainer = before?.workspaceContainerId
        let afterContainer = after?.workspaceContainerId
        let currentContainer = tab.workspaceContainerId
        // If both neighbors share a container (incl. both nil): land in that
        // membership state. Sandwiched inside a container → join it; sandwiched
        // in the orphan section → clear membership. Otherwise preserve current.
        let inferred: UUID?
        if beforeContainer == afterContainer {
            inferred = beforeContainer
        } else {
            inferred = currentContainer
        }
        if tab.workspaceContainerId != inferred {
            model.assignContainer(workspaceId: workspaceId, containerId: inferred)
        }
        model.normalizeWorkspaceNesting()
    }

    // MARK: - Batch reorder

    /// Validates a batch reorder request against the live order. A batch
    /// reorder reorders leaves **within their own container only**: the request
    /// must not move leaves between containers. Each container's section is
    /// reordered independently per the pinned-ahead-of-unpinned invariant
    /// (main leaf always first for Git containers).
    public func workspaceBatchReorderPlan(
        orderedWorkspaceIds: [UUID]
    ) -> Result<[WorkspaceReorderPlanItem], WorkspaceBatchReorderError> {
        planner.batchReorderPlan(
            orderedWorkspaceIds: orderedWorkspaceIds,
            current: workspaceOrderSnapshots()
        )
    }

    /// Applies (or dry-runs) a batch reorder, rebuilding each affected
    /// container's section from the planner's final order. Leaves never leave
    /// their container; the main-leaf-first + pinned-tier invariants hold.
    @discardableResult
    public func reorderWorkspaces(
        orderedWorkspaceIds: [UUID],
        dryRun: Bool = false
    ) -> Result<[WorkspaceReorderPlanItem], WorkspaceBatchReorderError> {
        let result = workspaceBatchReorderPlan(orderedWorkspaceIds: orderedWorkspaceIds)
        guard case .success(let plan) = result else { return result }
        guard !dryRun else { return result }

        let movedWorkspaceIds = plan
            .filter { $0.fromIndex != $0.toIndex }
            .map(\.workspaceId)
        guard !movedWorkspaceIds.isEmpty else { return result }

        // Per-container rebuild: the request may name leaves across several
        // containers, but each container's section is reordered independently
        // and leaves never cross container boundaries. Within a container the
        // final order is: main leaf (Git, when present), then ordered pinned
        // non-main leaves, remaining pinned non-main, ordered unpinned
        // non-main, remaining unpinned non-main.
        let tabsById = Dictionary(uniqueKeysWithValues: model.tabs.map { ($0.id, $0) })
        var orderedByContainer: [UUID: [UUID]] = [:]
        for id in orderedWorkspaceIds {
            guard let containerId = tabsById[id]?.workspaceContainerId else { continue }
            orderedByContainer[containerId, default: []].append(id)
        }

        var emitted = Set<UUID>()
        var reordered: [Tab] = []
        reordered.reserveCapacity(model.tabs.count)
        var emittedContainers = Set<UUID>()
        for tab in model.tabs {
            if let containerId = tab.workspaceContainerId,
               let orderedIds = orderedByContainer[containerId],
               emittedContainers.insert(containerId).inserted {
                let members = model.leaves(inContainer: containerId)
                let mainId = model.mainLeaf(ofContainer: containerId)?.id
                let orderedIdSet = Set(orderedIds)
                if let main = members.first(where: { $0.id == mainId }),
                   emitted.insert(main.id).inserted {
                    reordered.append(main)
                }
                let nonMain = members.filter { $0.id != mainId }
                let orderedPinned = orderedIds.compactMap { tabsById[$0] }
                    .filter { $0.workspaceContainerId == containerId && $0.isPinned }
                let remainingPinned = nonMain.filter { $0.isPinned && !orderedIdSet.contains($0.id) }
                let orderedUnpinned = orderedIds.compactMap { tabsById[$0] }
                    .filter { $0.workspaceContainerId == containerId && !$0.isPinned }
                let remainingUnpinned = nonMain.filter { !$0.isPinned && !orderedIdSet.contains($0.id) }
                for member in orderedPinned + remainingPinned + orderedUnpinned + remainingUnpinned
                where emitted.insert(member.id).inserted {
                    reordered.append(member)
                }
            } else if emitted.insert(tab.id).inserted {
                reordered.append(tab)
            }
        }
        model.tabs = reordered
        model.normalizeWorkspaceNesting()
        host?.workspaceOrderDidChange(movedWorkspaceIds: movedWorkspaceIds)
        return result
    }

    private func workspaceOrderSnapshots() -> [WorkspaceOrderSnapshot] {
        model.tabs.map { WorkspaceOrderSnapshot(id: $0.id, isPinned: $0.isPinned) }
    }

    // MARK: - Pinning

    /// Toggles the workspace's pin state.
    public func togglePin(tabId: UUID) {
        guard let index = model.tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let tab = model.tabs[index]
        setPinned(tab, pinned: !tab.isPinned)
    }

    /// Sets one workspace's pin state and reorders it into its tier. The main
    /// leaf of a Git container stays first regardless of pin state.
    public func setPinned(_ tab: Tab, pinned: Bool) {
        guard tab.isPinned != pinned else { return }
        tab.isPinned = pinned
        reorderTabForPinnedState(tab)
        host?.workspaceOrderDidChange(movedWorkspaceIds: [tab.id])
    }

    /// Sets pin state for many workspaces at once; returns the ids whose
    /// state actually changed, in request order.
    @discardableResult
    public func setPinned(workspaceIds: [UUID], pinned: Bool) -> [UUID] {
        guard !workspaceIds.isEmpty else { return [] }
        if workspaceIds.count == 1,
           let workspaceId = workspaceIds.first,
           let tab = model.tabs.first(where: { $0.id == workspaceId }) {
            let changed = tab.isPinned != pinned
            setPinned(tab, pinned: pinned)
            return changed ? [workspaceId] : []
        }

        var seen = Set<UUID>()
        let orderedTargetIds = workspaceIds.filter { seen.insert($0).inserted }
        let targetIds = Set(orderedTargetIds)
        var workspacesById: [UUID: Tab] = [:]
        var changedIdSet = Set<UUID>()

        for workspace in model.tabs {
            workspacesById[workspace.id] = workspace
            guard targetIds.contains(workspace.id), workspace.isPinned != pinned else { continue }
            workspace.isPinned = pinned
            changedIdSet.insert(workspace.id)
        }

        guard !changedIdSet.isEmpty else { return [] }
        let changedIds = orderedTargetIds.filter { changedIdSet.contains($0) }

        for id in changedIds {
            if let workspace = workspacesById[id] {
                reorderTabForPinnedState(workspace)
            }
        }
        host?.workspaceOrderDidChange(movedWorkspaceIds: changedIds)
        return changedIds
    }

    /// Reorders a tab to its pin tier within its container. The main leaf
    /// stays first; orphan leaves reorder in the global orphan section.
    private func reorderTabForPinnedState(_ tab: Tab) {
        guard let index = model.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        if tab.workspaceContainerId != nil {
            model.normalizeWorkspaceNesting()
            return
        }
        // Orphan leaf (migration only): insert at the leading pinned boundary.
        model.tabs.remove(at: index)
        let pinnedCount = model.leadingGlobalPinnedRowCount()
        let insertIndex = min(pinnedCount, model.tabs.count)
        model.tabs.insert(tab, at: insertIndex)
    }
}

// MARK: - Model helpers used by the reorder coordinator

extension WorkspacesModel {
    /// The container-header row ids in the order containers render (one per
    /// container, represented by its main leaf for Git containers and by its
    /// first leaf otherwise). Optionally inserts a grouped leaf being promoted
    /// to top level near its container's row.
    func sidebarContainerHeaderIds(promotingWorkspaceId promotedWorkspaceId: UUID? = nil) -> [UUID] {
        var ids: [UUID] = []
        var emittedContainerIds = Set<UUID>()
        for container in workspaceContainers {
            let representative: UUID? = {
                if let main = mainLeaf(ofContainer: container.id) { return main.id }
                return leaves(inContainer: container.id).first?.id
            }()
            if let representative, emittedContainerIds.insert(container.id).inserted {
                ids.append(representative)
            }
        }
        if let promotedWorkspaceId, !ids.contains(promotedWorkspaceId) {
            ids.append(promotedWorkspaceId)
        }
        return ids
    }

    /// The number of leading orphan (nil-container) rows in `tabs[]` that
    /// render as pinned. Used only for migration-era orphan leaf ordering.
    func leadingGlobalPinnedRowCount() -> Int {
        var count = 0
        for tab in tabs where tab.workspaceContainerId == nil {
            guard tab.isPinned else { break }
            count += 1
        }
        return count
    }
}
