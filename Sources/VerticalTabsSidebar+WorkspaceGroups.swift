import AppKit
import CmuxFoundation
import SwiftUI
import CmuxSettings
import CmuxWorkspaces

extension VerticalTabsSidebar {
    func sidebarWorkspaceGroupTableConfiguration(
        group: WorkspaceGroup,
        memberWorkspaceIds: [UUID],
        renderContext: WorkspaceListRenderContext,
        showModifierHoldHints: Bool
    ) -> SidebarWorkspaceTableRowConfiguration {
        let selectedId = tabManager.selectedTabId
        let activeLeafId = group.lastActiveWorkspaceId
        let model = SidebarGroupHeaderRowModel(
            groupId: group.id,
            name: group.name,
            iconSymbol: RenderableSystemSymbol.resolvedWorkspaceGroupIcon(explicit: group.iconSymbol, configured: nil),
            tintHex: group.customColor,
            isCollapsed: group.isCollapsed,
            isPinned: group.isPinned,
            isActive: selectedId == activeLeafId,
            hasActiveDescendant: activeLeafId != nil && selectedId != nil && selectedId != activeLeafId
                && memberWorkspaceIds.contains(selectedId!),
            memberCount: memberWorkspaceIds.count,
            unreadCount: memberWorkspaceIds.reduce(0) { $0 + notificationStore.unreadCount(forTabId: $1) },
            canMarkRead: false,
            canMarkUnread: false,
            hasLatestNotifications: false,
            canMarkAllRead: false,
            canMarkAllUnread: false,
            shortcutHintText: nil,
            shortcutHintXOffset: 0,
            shortcutHintYOffset: 0,
            fontScale: renderContext.tabItemSettings.sidebarFontScale,
            globalFontMagnificationPercent: renderContext.environment.globalFontMagnificationPercent,
            cwdContextMenuItems: [],
            rowSpacing: tabRowSpacing,
            isFirstRow: renderContext.workspaceRenderItems.first?.id == .group(group.id),
            isBeingDragged: false,
            topDropIndicatorVisible: false,
            bottomDropIndicatorVisible: false
        )
        let actions = SidebarGroupHeaderRowActions(
            onToggleCollapsed: { [weak tabManager, groupId = group.id] in
                tabManager?.toggleWorkspaceGroupCollapsed(groupId: groupId)
            },
            onSelect: { [weak tabManager, groupId = group.id] in
                tabManager?.selectWorkspaceGroupHeader(groupId: groupId)
            },
            onTapPlus: { [weak tabManager, groupId = group.id] in
                guard let tabManager else { return }
                _ = AppDelegate.shared?.chooseWorkspaceRoot(
                    forGroup: groupId,
                    tabManager: tabManager,
                    preferredWindow: NSApp.keyWindow,
                    rollbackEmptyGroupOnFailure: false
                )
            },
            onRunResolvedItem: { _ in },
            onRename: { [weak tabManager, groupId = group.id, currentName = group.name] in
                guard let tabManager else { return }
                presentSidebarWorkspaceGroupRenamePrompt(
                    tabManager: tabManager,
                    groupId: groupId,
                    currentName: currentName
                )
            },
            onTogglePinned: { [weak tabManager, groupId = group.id] in
                tabManager?.toggleWorkspaceGroupPinned(groupId: groupId)
            },
            onMarkRead: {},
            onMarkUnread: {},
            onClearLatestNotifications: {},
            onMarkAllRead: {},
            onMarkAllUnread: {},
            onDelete: { [weak tabManager, groupId = group.id] in
                _ = tabManager?.deleteWorkspaceGroup(groupId: groupId)
            },
            onEditConfig: {},
            onOpenDocs: {}
        )
        return SidebarWorkspaceTableRowConfiguration(groupHeaderModel: model, actions: actions, environment: renderContext.environment)
    }
}
