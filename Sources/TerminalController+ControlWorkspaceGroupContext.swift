import CmuxControlSocket
import CmuxWorkspaces
import Foundation
import CmuxSettings

/// The workspace-group-domain witnesses for the stage-3c
/// ``ControlCommandCoordinator``: app-model witnesses for the former
/// `v2WorkspaceGroup*` dispatchers, minus the per-read `v2MainSync` hop (the
/// coordinator already runs on the main actor inside the socket-command policy
/// scope, so each hop would re-apply the identical thread-local focus-allowance
/// stack — a no-op). TabManager resolution goes through the shared
/// `resolveTabManager(routing:)`; app structs are converted to the package's
/// Sendable snapshots.
extension TerminalController: ControlWorkspaceGroupContext {
    func controlWorkspaceGroupStrings() -> ControlWorkspaceGroupStrings {
        ControlWorkspaceGroupStrings(
            allChildrenAreAnchors: String(
                localized: "workspaceGroup.error.allChildrenAreAnchors",
                defaultValue: "All requested children are ineligible because they are already group anchors; ungroup them first"
            ),
            workspaceIsOtherGroupAnchor: String(
                localized: "workspaceGroup.error.workspaceIsOtherGroupAnchor",
                defaultValue: "Workspace is the anchor of another group; ungroup it first"
            ),
            invalidReferenceWorkspace: String(
                localized: "workspaceGroup.error.invalidReferenceWorkspace",
                defaultValue: "Reference workspace must be a member of the target group"
            ),
            closeWorkspacesMustBeBoolean: String(
                localized: "workspaceGroup.error.closeWorkspacesMustBeBoolean",
                defaultValue: "close_workspaces must be a boolean"
            ),
            nonEmptyGroupCannotBeDeleted: String(
                localized: "workspaceGroup.error.nonEmptyDelete",
                defaultValue: "A non-empty group cannot be deleted"
            )
        )
    }

    /// Builds the Sendable snapshot of one group (the legacy
    /// `v2WorkspaceGroupPayload` data, minus the ref minting the coordinator now
    /// owns).
    private func controlWorkspaceGroupSnapshot(
        _ group: WorkspaceGroup,
        tabManager: TabManager
    ) -> ControlWorkspaceGroupSnapshot {
        let containerIDs = Set(
            tabManager.workspaceContainers
                .filter { $0.groupId == group.id }
                .map(\.id)
        )
        let memberIds: [UUID] = tabManager.tabs.compactMap {
            guard let containerID = $0.workspaceContainerId,
                  containerIDs.contains(containerID) else { return nil }
            return $0.id
        }
        return ControlWorkspaceGroupSnapshot(
            id: group.id,
            name: group.name,
            isCollapsed: group.isCollapsed,
            isPinned: group.isPinned,
            lastActiveWorkspaceID: group.lastActiveWorkspaceId,
            customColor: group.customColor,
            iconSymbol: group.iconSymbol,
            memberWorkspaceIDs: memberIds
        )
    }

    func controlWorkspaceGroupList(
        routing: ControlRoutingSelectors
    ) -> ControlWorkspaceGroupListResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        let groups = tabManager.workspaceGroups.map {
            controlWorkspaceGroupSnapshot($0, tabManager: tabManager)
        }
        let windowId = AppDelegate.shared?.windowId(for: tabManager)
        return .resolved(windowID: windowId, groups: groups)
    }

    func controlCreateWorkspaceGroup(
        routing: ControlRoutingSelectors,
        name: String,
        cwd: String?,
        childWorkspaceIDs: [UUID]
    ) -> ControlWorkspaceGroupCreateResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        let knownTabIds = Set(tabManager.tabs.map(\.id))
        let missing = childWorkspaceIDs.compactMap { knownTabIds.contains($0) ? nil : $0.uuidString }
        guard missing.isEmpty else { return .childWorkspaceNotFound(missing) }
        guard let groupID = tabManager.createWorkspaceGroup(name: name) else { return .notCreated }

        var movedContainerIDs = Set<UUID>()
        for workspaceID in childWorkspaceIDs {
            guard let containerID = tabManager.tabs.first(where: { $0.id == workspaceID })?.workspaceContainerId,
                  movedContainerIDs.insert(containerID).inserted else { continue }
            let targetIndex = tabManager.workspaceContainers.filter { $0.groupId == groupID }.count
            tabManager.moveWorkspaceContainer(containerId: containerID, toGroup: groupID, toIndex: targetIndex)
        }
        if movedContainerIDs.isEmpty,
           let cwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines),
           !cwd.isEmpty {
            _ = tabManager.createWorkspaceContainer(
                groupId: groupID,
                name: URL(fileURLWithPath: cwd).lastPathComponent,
                kind: .localDirectory,
                rootPath: cwd,
                select: false
            )
        }
        guard let group = tabManager.workspaceGroups.first(where: { $0.id == groupID }) else {
            return .notCreated
        }
        return .created(controlWorkspaceGroupSnapshot(group, tabManager: tabManager))
    }

    func controlUngroupWorkspaceGroup(
        routing: ControlRoutingSelectors,
        groupID: UUID
    ) -> Int? {
        guard let tabManager = resolveTabManager(routing: routing) else { return nil }
        guard tabManager.workspaceGroups.contains(where: { $0.id == groupID }) else { return -1 }
        let containers = tabManager.workspaceContainers.filter { $0.groupId == groupID }
        let keptCount = containers.reduce(0) { count, container in
            count + tabManager.workspaceLeaves(inContainer: container.id).count
        }
        if !containers.isEmpty {
            let fallbackGroupID = tabManager.workspaceGroups.first(where: { $0.id != groupID })?.id
                ?? tabManager.createWorkspaceGroup(
                    name: String(localized: "workspaceGroup.migrated.defaultName", defaultValue: "Workspaces")
                )
            guard let fallbackGroupID else { return -1 }
            for container in containers {
                let targetIndex = tabManager.workspaceContainers.filter { $0.groupId == fallbackGroupID }.count
                tabManager.moveWorkspaceContainer(
                    containerId: container.id,
                    toGroup: fallbackGroupID,
                    toIndex: targetIndex
                )
            }
        }
        return tabManager.deleteWorkspaceGroup(groupId: groupID) ? keptCount : -1
    }

    func controlDeleteWorkspaceGroup(
        routing: ControlRoutingSelectors,
        groupID: UUID
    ) -> Int? {
        guard let tabManager = resolveTabManager(routing: routing) else { return nil }
        guard tabManager.workspaceGroups.contains(where: { $0.id == groupID }) else { return -1 }
        guard !tabManager.workspaceContainers.contains(where: { $0.groupId == groupID }) else { return -2 }
        return tabManager.deleteWorkspaceGroup(groupId: groupID) ? 0 : -1
    }

    func controlRenameWorkspaceGroup(
        routing: ControlRoutingSelectors,
        groupID: UUID,
        name: String
    ) -> Bool? {
        guard let tabManager = resolveTabManager(routing: routing) else { return nil }
        let ok = tabManager.workspaceGroups.contains(where: { $0.id == groupID })
        if ok { tabManager.renameWorkspaceGroup(groupId: groupID, name: name) }
        return ok
    }

    func controlSetWorkspaceGroupCollapsed(
        routing: ControlRoutingSelectors,
        groupID: UUID,
        isCollapsed: Bool
    ) -> Bool? {
        guard let tabManager = resolveTabManager(routing: routing) else { return nil }
        let ok = tabManager.workspaceGroups.contains(where: { $0.id == groupID })
        if ok { tabManager.setWorkspaceGroupCollapsed(groupId: groupID, isCollapsed: isCollapsed) }
        return ok
    }

    func controlSetWorkspaceGroupPinned(
        routing: ControlRoutingSelectors,
        groupID: UUID,
        isPinned: Bool
    ) -> Bool? {
        guard let tabManager = resolveTabManager(routing: routing) else { return nil }
        let ok = tabManager.workspaceGroups.contains(where: { $0.id == groupID })
        if ok { tabManager.setWorkspaceGroupPinned(groupId: groupID, isPinned: isPinned) }
        return ok
    }

    func controlAddWorkspaceToGroup(
        routing: ControlRoutingSelectors,
        groupID: UUID,
        workspaceID: UUID,
        placement: WorkspaceGroupNewPlacement?,
        referenceWorkspaceID: UUID?
    ) -> ControlWorkspaceGroupAddResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        guard tabManager.workspaceGroups.contains(where: { $0.id == groupID }),
              let workspace = tabManager.tabs.first(where: { $0.id == workspaceID }),
              let containerID = workspace.workspaceContainerId else {
            return .notFound
        }
        let targetContainers = tabManager.workspaceContainers.filter { $0.groupId == groupID }
        let targetIndex: Int
        switch placement ?? .end {
        case .top:
            targetIndex = 0
        case .end:
            targetIndex = targetContainers.count
        case .afterCurrent:
            guard let referenceWorkspaceID,
                  let referenceContainerID = tabManager.tabs.first(where: { $0.id == referenceWorkspaceID })?.workspaceContainerId,
                  let referenceIndex = targetContainers.firstIndex(where: { $0.id == referenceContainerID }) else {
                return .invalidReferenceWorkspace
            }
            targetIndex = referenceIndex + 1
        }
        tabManager.moveWorkspaceContainer(containerId: containerID, toGroup: groupID, toIndex: targetIndex)
        return tabManager.workspaceContainers.contains(where: { $0.id == containerID && $0.groupId == groupID })
            ? .added
            : .notFound
    }

    func controlRemoveWorkspaceFromGroup(
        routing: ControlRoutingSelectors,
        workspaceID: UUID
    ) -> Bool? {
        guard let tabManager = resolveTabManager(routing: routing) else { return nil }
        guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceID }),
              let containerID = workspace.workspaceContainerId,
              let container = tabManager.workspaceContainers.first(where: { $0.id == containerID }) else {
            return false
        }
        let fallbackGroupID = tabManager.workspaceGroups.first(where: { $0.id != container.groupId })?.id
            ?? tabManager.createWorkspaceGroup(
                name: String(localized: "workspaceGroup.migrated.defaultName", defaultValue: "Workspaces")
            )
        guard let fallbackGroupID else { return false }
        let targetIndex = tabManager.workspaceContainers.filter { $0.groupId == fallbackGroupID }.count
        tabManager.moveWorkspaceContainer(containerId: containerID, toGroup: fallbackGroupID, toIndex: targetIndex)
        return true
    }

    func controlSetWorkspaceGroupAnchor(
        routing: ControlRoutingSelectors,
        groupID: UUID,
        workspaceID: UUID
    ) -> Bool? {
        guard let tabManager = resolveTabManager(routing: routing) else { return nil }
        guard let groupIndex = tabManager.workspaceGroups.firstIndex(where: { $0.id == groupID }),
              let containerID = tabManager.tabs.first(where: { $0.id == workspaceID })?.workspaceContainerId,
              tabManager.workspaceContainers.contains(where: { $0.id == containerID && $0.groupId == groupID }) else {
            return false
        }
        tabManager.workspaceGroups[groupIndex].lastActiveWorkspaceId = workspaceID
        return true
    }

    func controlCreateWorkspaceInGroup(
        routing: ControlRoutingSelectors,
        groupID: UUID,
        placementRaw: String?
    ) -> ControlWorkspaceGroupNewWorkspaceResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        if let raw = placementRaw,
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           WorkspaceGroupNewPlacement(rawString: raw) == nil {
            return .invalidPlacement(raw)
        }
        guard tabManager.workspaceGroups.contains(where: { $0.id == groupID }),
              let containerID = tabManager.createWorkspaceContainer(
                groupId: groupID,
                name: String(localized: "workspaceContainer.localSession", defaultValue: "Local Session"),
                kind: .localSession,
                rootPath: nil,
                select: false
              ),
              let workspace = tabManager.workspaceLeaves(inContainer: containerID).first else {
            return .notFound
        }
        return .created(workspaceID: workspace.id)
    }

    func controlSetWorkspaceGroupColor(
        routing: ControlRoutingSelectors,
        groupID: UUID,
        hex: String?
    ) -> Bool? {
        guard let tabManager = resolveTabManager(routing: routing) else { return nil }
        let ok = tabManager.workspaceGroups.contains(where: { $0.id == groupID })
        if ok { tabManager.setWorkspaceGroupColor(groupId: groupID, hex: hex) }
        return ok
    }

    func controlSetWorkspaceGroupIcon(
        routing: ControlRoutingSelectors,
        groupID: UUID,
        symbol: String?
    ) -> (found: Bool, storedSymbol: String?)? {
        guard let tabManager = resolveTabManager(routing: routing) else { return nil }
        let found = tabManager.workspaceGroups.contains(where: { $0.id == groupID })
        var storedIconSymbol: String?
        if found {
            storedIconSymbol = tabManager.setWorkspaceGroupIcon(groupId: groupID, symbol: symbol)
        }
        return (found, storedIconSymbol)
    }

    func controlMoveWorkspaceGroup(
        routing: ControlRoutingSelectors,
        groupID: UUID,
        toIndex: Int?,
        beforeGroupID: UUID?,
        afterGroupID: UUID?
    ) -> Bool? {
        guard let tabManager = resolveTabManager(routing: routing) else { return nil }
        guard let current = tabManager.workspaceGroups.firstIndex(where: { $0.id == groupID }) else {
            return false
        }
        // moveWorkspaceGroup interprets toIndex as the FINAL position the group
        // should occupy. before/after refer to a peer's CURRENT index, so when
        // the source comes before the peer in the original order, removing the
        // source shifts the peer left by one, and the translated final position
        // must shift with it.
        let target: Int? = {
            if let toIndex {
                return toIndex
            }
            if let beforeId = beforeGroupID,
               let beforeIndex = tabManager.workspaceGroups.firstIndex(where: { $0.id == beforeId }) {
                return current < beforeIndex ? beforeIndex - 1 : beforeIndex
            }
            if let afterId = afterGroupID,
               let afterIndex = tabManager.workspaceGroups.firstIndex(where: { $0.id == afterId }) {
                return current < afterIndex ? afterIndex : afterIndex + 1
            }
            return nil
        }()
        guard let target else { return false }
        tabManager.moveWorkspaceGroup(groupId: groupID, toIndex: target)
        return true
    }

    func controlFocusWorkspaceGroup(
        routing: ControlRoutingSelectors,
        groupID: UUID
    ) -> ControlWorkspaceGroupFocusResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        guard let group = tabManager.workspaceGroups.first(where: { $0.id == groupID }) else {
            return .notFound
        }
        let memberContainerIDs = Set(
            tabManager.workspaceContainers.filter { $0.groupId == groupID }.map(\.id)
        )
        let target = group.lastActiveWorkspaceId.flatMap { workspaceID in
            tabManager.tabs.first(where: {
                $0.id == workspaceID && $0.workspaceContainerId.map(memberContainerIDs.contains) == true
            })
        } ?? tabManager.tabs.first(where: {
            $0.workspaceContainerId.map(memberContainerIDs.contains) == true
        })
        guard let target else { return .notFound }
        if let windowId = AppDelegate.shared?.windowId(for: tabManager) {
            _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
            setActiveTabManager(tabManager)
        }
        tabManager.selectWorkspace(target)
        return .focused(workspaceID: target.id)
    }
}
