public import Foundation
public import CmuxSettings

/// Sequences every workspace-container flow over the window's
/// `WorkspacesModel`: container creation (a container record plus its main
/// leaf), leaf attach/detach/move, container rename/collapse/move, and
/// container removal (closing every leaf under it). Containers belong to
/// groups via ``WorkspaceContainer/groupId``; leaves belong to containers via
/// ``WorkspaceTabRepresenting/workspaceContainerId``.
///
/// The ordering invariant — main leaf fixed first inside a Git container,
/// pinned non-main leaves above unpinned — is enforced by
/// ``WorkspacesModel/normalizeWorkspaceNesting()``. This coordinator owns the
/// structural mutation; selection moves, sidebar multi-selection sync, and
/// workspace creation/teardown invert through ``WorkspaceGroupHosting``.
@MainActor
public final class WorkspaceContainerCoordinator<Tab: WorkspaceTabRepresenting> {
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

    /// Create a new container in `groupId` together with its first leaf. For
    /// a `git` container the leaf is created with ``WorkspaceLeafRole/main``
    /// and `mainLeafWorkingDirectory` (or a sensible default); for other kinds
    /// the leaf is ``WorkspaceLeafRole/external``/``.compatibility``. Returns
    /// the new container id, or `nil` when the group does not exist or no host
    /// is attached.
    @discardableResult
    public func createContainer(
        groupId: UUID,
        name: String?,
        kind: WorkspaceContainerKind,
        rootPath: String?,
        repositoryCommonDirectory: String?,
        remoteHost: String?,
        mainLeafWorkingDirectory: String?,
        select: Bool = true
    ) -> UUID? {
        guard let host else { return nil }
        guard model.workspaceGroups.contains(where: { $0.id == groupId }) else { return nil }

        let resolvedName = name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? name!.trimmingCharacters(in: .whitespacesAndNewlines)
            : defaultContainerName(kind: kind)
        let containerId = UUID()
        let role: WorkspaceLeafRole = kind == .git ? .main : .compatibility

        let leaf = host.createWorkspaceForContainer(
            title: nil,
            workingDirectory: mainLeafWorkingDirectory,
            role: role,
            initialSurface: .terminal,
            initialBrowserURL: nil,
            initialBrowserOmnibarVisible: false,
            initialBrowserTransparentBackground: false,
            inheritWorkingDirectory: mainLeafWorkingDirectory == nil,
            select: select
        )

        let container = WorkspaceContainer(
            id: containerId,
            groupId: groupId,
            name: resolvedName,
            kind: kind,
            rootPath: rootPath,
            repositoryCommonDirectory: repositoryCommonDirectory,
            remoteHost: remoteHost,
            isCollapsed: false,
            lastActiveWorkspaceId: leaf.id
        )
        model.workspaceContainers.append(container)
        model.assignContainer(workspaceId: leaf.id, containerId: containerId)
        model.normalizeWorkspaceNesting()
        if select {
            host.selectWorkspace(leaf)
        }
        host.workspaceOrderDidChange(movedWorkspaceIds: [leaf.id])
        return containerId
    }

    /// Create a brand-new leaf in `containerId`, attach it, and position it
    /// within the container per `placement`. The main leaf of a Git container
    /// always stays first. Returns the new leaf, or `nil` when the container
    /// does not exist or no host is attached.
    @discardableResult
    public func createLeaf(
        inContainer containerId: UUID,
        placement explicitPlacement: WorkspaceGroupNewPlacement? = nil,
        referenceWorkspaceId: UUID? = nil,
        select: Bool = true,
        initialSurface: NewWorkspaceInitialSurface = .terminal,
        title: String? = nil,
        initialBrowserURL: URL? = nil,
        initialBrowserOmnibarVisible: Bool = true,
        initialBrowserTransparentBackground: Bool = false
    ) -> Tab? {
        guard let host else { return nil }
        let placement = explicitPlacement ?? host.defaultNewWorkspacePlacementInContainer
        guard let container = model.workspaceContainers.first(where: { $0.id == containerId }) else { return nil }

        let referenceCwd: String?
        if let referenceWorkspaceId,
           let referenceTab = model.tabs.first(where: { $0.id == referenceWorkspaceId }),
           referenceTab.workspaceContainerId == containerId {
            referenceCwd = referenceTab.currentDirectory
        } else {
            referenceCwd = model.mainLeaf(ofContainer: containerId)?.currentDirectory
        }
        let role: WorkspaceLeafRole = container.kind == .git ? .managed : .external

        let leaf = host.createWorkspaceForContainer(
            title: title,
            workingDirectory: referenceCwd,
            role: role,
            initialSurface: initialSurface,
            initialBrowserURL: initialBrowserURL,
            initialBrowserOmnibarVisible: initialBrowserOmnibarVisible,
            initialBrowserTransparentBackground: initialBrowserTransparentBackground,
            inheritWorkingDirectory: referenceCwd == nil,
            select: select
        )
        model.assignContainer(workspaceId: leaf.id, containerId: containerId)
        placeWithinContainer(
            workspaceId: leaf.id,
            containerId: containerId,
            placement: placement,
            referenceWorkspaceId: referenceWorkspaceId
        )
        model.normalizeWorkspaceNesting()
        host.workspaceOrderDidChange(movedWorkspaceIds: [leaf.id])
        return leaf
    }

    // MARK: - Membership

    /// Attach an existing leaf to `containerId` as a non-main member. No-op
    /// when already a member, or when the leaf is the main leaf of a different
    /// Git container (those must be detached first).
    public func attachLeaf(
        workspaceId: UUID,
        toContainer containerId: UUID,
        placement: WorkspaceGroupNewPlacement? = nil,
        referenceWorkspaceId: UUID? = nil
    ) {
        guard let tab = model.tabs.first(where: { $0.id == workspaceId }) else { return }
        guard model.workspaceContainers.contains(where: { $0.id == containerId }) else { return }
        guard tab.workspaceContainerId != containerId else { return }
        // Reject moving a main leaf into another container: it would orphan the
        // source Git container's fixed-first invariant.
        if tab.leafBinding.role == .main,
           let source = tab.workspaceContainerId,
           source != containerId {
            return
        }
        model.assignContainer(workspaceId: workspaceId, containerId: containerId)
        if let placement {
            placeWithinContainer(
                workspaceId: workspaceId,
                containerId: containerId,
                placement: placement,
                referenceWorkspaceId: referenceWorkspaceId
            )
        }
        model.normalizeWorkspaceNesting()
        host?.workspaceOrderDidChange(movedWorkspaceIds: [workspaceId])
    }

    /// Detach a leaf from its container. The main leaf of a Git container
    /// cannot be detached alone — remove the container instead.
    public func detachLeaf(workspaceId: UUID) {
        guard let tab = model.tabs.first(where: { $0.id == workspaceId }),
              tab.workspaceContainerId != nil else { return }
        if model.isMainLeaf(workspaceId) { return }
        model.assignContainer(workspaceId: workspaceId, containerId: nil)
        model.normalizeWorkspaceNesting()
        host?.workspaceOrderDidChange(movedWorkspaceIds: [workspaceId])
    }

    /// Move an existing leaf to a new container and slot. Equivalent to
    /// ``detachLeaf(workspaceId:)`` then ``attachLeaf(workspaceId:toContainer:placement:referenceWorkspaceId:)``
    /// but in one pass that preserves the leaf.
    public func moveLeaf(
        workspaceId: UUID,
        toContainer containerId: UUID,
        placement: WorkspaceGroupNewPlacement? = nil,
        referenceWorkspaceId: UUID? = nil
    ) {
        attachLeaf(
            workspaceId: workspaceId,
            toContainer: containerId,
            placement: placement,
            referenceWorkspaceId: referenceWorkspaceId
        )
    }

    // MARK: - Container properties

    /// Rename a container. Whitespace-only names are ignored.
    public func renameContainer(containerId: UUID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let index = model.workspaceContainers.firstIndex(where: { $0.id == containerId }) else { return }
        guard model.workspaceContainers[index].name != trimmed else { return }
        model.workspaceContainers[index].name = trimmed
    }

    /// Toggle the collapsed disclosure of a container, moving focus to its
    /// last-active leaf when collapsing hides the current selection.
    public func toggleContainerCollapsed(containerId: UUID) {
        guard let host else { return }
        guard let index = model.workspaceContainers.firstIndex(where: { $0.id == containerId }) else { return }
        let nextCollapsed = !model.workspaceContainers[index].isCollapsed
        if nextCollapsed,
           let selectedTabId = model.selectedTabId,
           let selectedLeaf = model.tabs.first(where: { $0.id == selectedTabId }),
           selectedLeaf.workspaceContainerId == containerId,
           let focusLeaf = model.resolveLastActiveLeaf(inContainer: containerId) {
            host.selectWorkspace(focusLeaf)
        }
        setContainerCollapsed(containerId: containerId, isCollapsed: nextCollapsed)
    }

    /// Pure data mutation — flips the container collapse flag without touching
    /// selection. Use this from socket/CLI handlers.
    public func setContainerCollapsed(containerId: UUID, isCollapsed: Bool) {
        guard let index = model.workspaceContainers.firstIndex(where: { $0.id == containerId }) else { return }
        guard model.workspaceContainers[index].isCollapsed != isCollapsed else { return }
        model.workspaceContainers[index].isCollapsed = isCollapsed
    }

    /// Move a container to a new group and/or a new index within that group's
    /// containers. Container order across groups follows `workspaceContainers`
    /// array order; ``WorkspacesModel/normalizeWorkspaceNesting()`` rebuilds
    /// leaf order to match.
    public func moveContainer(containerId: UUID, toGroup groupId: UUID, toIndex targetIndex: Int) {
        guard let host else { return }
        guard let currentIndex = model.workspaceContainers.firstIndex(where: { $0.id == containerId }) else { return }
        guard model.workspaceGroups.contains(where: { $0.id == groupId }) else { return }
        // Clamp into the target group's container range.
        let targetGroupContainers = model.containers(inGroup: groupId)
        let clampedTarget = max(0, min(targetIndex, targetGroupContainers.count))
        var container = model.workspaceContainers.remove(at: currentIndex)
        container.groupId = groupId
        // Reinsert: when moving within the same group, the removal shifted
        // indices; when moving groups, insert among the target group's slots.
        let insertIndex = computedContainerInsertIndex(
            targetGroupInsertion: clampedTarget,
            groupId: groupId,
            removedCurrentIndex: currentIndex
        )
        model.workspaceContainers.insert(container, at: max(0, min(insertIndex, model.workspaceContainers.count)))
        model.normalizeWorkspaceNesting()
        let leafIds = model.leaves(inContainer: containerId).map(\.id)
        host.workspaceOrderDidChange(movedWorkspaceIds: leafIds)
    }

    // MARK: - Selection

    /// Resolve the container's last-active leaf and select it. No-op when the
    /// container is empty (should not occur — empty containers are pruned).
    public func selectContainerHeader(containerId: UUID) {
        guard let host else { return }
        guard let leaf = model.resolveLastActiveLeaf(inContainer: containerId) else { return }
        host.selectWorkspace(leaf)
    }

    // MARK: - Removal

    /// Remove a container, closing every leaf under it. Returns the number of
    /// leaves closed. The container record is removed last so the close path
    /// can still resolve membership.
    @discardableResult
    public func removeContainer(containerId: UUID, recordHistory: Bool = true) -> Int {
        guard let host else { return 0 }
        let members = model.leaves(inContainer: containerId)
        guard !members.isEmpty || model.workspaceContainers.contains(where: { $0.id == containerId }) else {
            return 0
        }
        var closed = 0
        for tab in members {
            if model.tabs.count <= 1 {
                _ = host.createWorkspaceForContainer(
                    title: nil,
                    workingDirectory: nil,
                    role: .external,
                    initialSurface: .terminal,
                    initialBrowserURL: nil,
                    initialBrowserOmnibarVisible: false,
                    initialBrowserTransparentBackground: false,
                    inheritWorkingDirectory: true,
                    select: true
                )
            }
            let countBefore = model.tabs.count
            host.closeWorkspaceForContainer(tab, recordHistory: recordHistory)
            if model.tabs.count < countBefore { closed += 1 }
        }
        model.workspaceContainers.removeAll { $0.id == containerId }
        model.normalizeWorkspaceNesting()
        host.workspaceOrderDidChange(movedWorkspaceIds: [])
        return closed
    }

    // MARK: - Placement helpers

    /// Position a leaf within its container according to placement, relative
    /// to `referenceWorkspaceId` when given. The container's main leaf (Git)
    /// is always displaced as the section's first slot by the subsequent
    /// normalize pass, so placement targets the non-main tier.
    private func placeWithinContainer(
        workspaceId: UUID,
        containerId: UUID,
        placement: WorkspaceGroupNewPlacement,
        referenceWorkspaceId: UUID?
    ) {
        guard let currentIndex = model.tabs.firstIndex(where: { $0.id == workspaceId }) else { return }
        let memberIndices = model.tabs.indices.filter {
            model.tabs[$0].workspaceContainerId == containerId && model.tabs[$0].id != workspaceId
        }
        let mainId = model.mainLeaf(ofContainer: containerId)?.id
        let targetIndex: Int
        switch placement {
        case .afterCurrent:
            if let referenceWorkspaceId,
               referenceWorkspaceId != workspaceId,
               let referenceIndex = model.tabs.firstIndex(where: {
                   $0.id == referenceWorkspaceId && $0.workspaceContainerId == containerId
               }) {
                targetIndex = referenceIndex + 1
            } else if let mainIndex = memberIndices.first(where: { model.tabs[$0].id == mainId }) {
                targetIndex = mainIndex + 1
            } else if let firstMember = memberIndices.first {
                targetIndex = firstMember
            } else {
                return
            }
        case .top:
            // Right after the main leaf (or first member); the main leaf stays
            // first via the normalize pass's main-first ordering.
            if let mainIndex = memberIndices.first(where: { model.tabs[$0].id == mainId }) {
                targetIndex = mainIndex + 1
            } else if let firstMember = memberIndices.first {
                targetIndex = firstMember
            } else {
                return
            }
        case .end:
            if let lastMember = memberIndices.last {
                targetIndex = lastMember + 1
            } else if let mainIndex = memberIndices.first(where: { model.tabs[$0].id == mainId }) {
                targetIndex = mainIndex + 1
            } else {
                return
            }
        }
        guard currentIndex != targetIndex else { return }
        let workspace = model.tabs.remove(at: currentIndex)
        let insertAt = currentIndex < targetIndex ? targetIndex - 1 : targetIndex
        model.tabs.insert(workspace, at: max(0, min(insertAt, model.tabs.count)))
    }

    /// Compute the absolute `workspaceContainers` insert index for a desired
    /// slot `targetGroupInsertion` within `groupId`, accounting for the index
    /// shift caused by removing the container from its (possibly different)
    /// current position.
    private func computedContainerInsertIndex(
        targetGroupInsertion: Int,
        groupId: UUID,
        removedCurrentIndex: Int
    ) -> Int {
        let groupContainerStart = model.workspaceContainers.firstIndex(where: { $0.groupId == groupId }) ?? model.workspaceContainers.count
        return groupContainerStart + targetGroupInsertion
    }

    private func defaultContainerName(kind: WorkspaceContainerKind) -> String {
        switch kind {
        case .git: return "Git"
        case .localDirectory: return "Folder"
        case .remoteSession: return "Remote"
        case .localSession: return "Session"
        }
    }
}
