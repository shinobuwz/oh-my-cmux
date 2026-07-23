import CmuxWorkspaces
import Foundation

/// Immutable hierarchy item used by both the SwiftUI and AppKit sidebar paths.
@MainActor
enum SidebarWorkspaceRenderItem {
    case groupHeader(groupId: UUID)
    case containerHeader(containerId: UUID)
    case workspace(workspaceId: UUID)

    var id: SidebarWorkspaceRenderItemID {
        switch self {
        case .groupHeader(let groupId): return .group(groupId)
        case .containerHeader(let containerId): return .container(containerId)
        case .workspace(let workspaceId): return .workspace(workspaceId)
        }
    }

    var rowWorkspaceId: UUID? {
        switch self {
        case .groupHeader, .containerHeader: return nil
        case .workspace(let workspaceId): return workspaceId
        }
    }

    static func renderItems(
        groups: [WorkspaceGroup],
        containers: [WorkspaceContainer],
        tabs: [Workspace]
    ) -> [SidebarWorkspaceRenderItem] {
        var items: [SidebarWorkspaceRenderItem] = []
        items.reserveCapacity(groups.count + containers.count + tabs.count)
        let containersByGroup = Dictionary(grouping: containers, by: \.groupId)
        let tabsByContainer = Dictionary(grouping: tabs.compactMap { tab -> (UUID, Workspace)? in
            guard let containerId = tab.workspaceContainerId else { return nil }
            return (containerId, tab)
        }, by: { $0.0 })
        for group in groups {
            items.append(.groupHeader(groupId: group.id))
            guard !group.isCollapsed else { continue }
            for container in containersByGroup[group.id] ?? [] {
                items.append(.containerHeader(containerId: container.id))
                guard !container.isCollapsed else { continue }
                for (_, tab) in tabsByContainer[container.id] ?? [] {
                    items.append(.workspace(workspaceId: tab.id))
                }
            }
        }
        // Compatibility for leaves not yet assigned to a normalized container.
        let renderedLeafIds = Set(items.compactMap(\.rowWorkspaceId))
        for tab in tabs where tab.workspaceContainerId == nil && !renderedLeafIds.contains(tab.id) {
            items.append(.workspace(workspaceId: tab.id))
        }
        return items
    }
}
