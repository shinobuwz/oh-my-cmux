import CoreGraphics
import Foundation

/// Immutable render input for one pure-AppKit sidebar group header row.
///
/// Value fields only: action closures live in ``SidebarGroupHeaderRowActions``
/// and are excluded from equality so recycled cells can reconfigure cheaply
/// (same discipline as the hosted rows' Equatable snapshot contract).
struct SidebarGroupHeaderRowModel: Equatable {
    let groupId: UUID
    let name: String
    let iconSymbol: String
    let tintHex: String?
    let isCollapsed: Bool
    let isPinned: Bool
    let isActive: Bool
    let hasActiveDescendant: Bool
    let memberCount: Int
    let unreadCount: Int
    let canMarkRead: Bool
    let canMarkUnread: Bool
    let hasLatestNotifications: Bool
    let canMarkAllRead: Bool
    let canMarkAllUnread: Bool
    let shortcutHintText: String?
    let shortcutHintXOffset: Double
    let shortcutHintYOffset: Double
    let fontScale: CGFloat
    let globalFontMagnificationPercent: Int
    let cwdContextMenuItems: [CmuxResolvedConfigContextMenuItem]
    let rowSpacing: CGFloat
    let isFirstRow: Bool
    let isBeingDragged: Bool
    let topDropIndicatorVisible: Bool
    let bottomDropIndicatorVisible: Bool
}

/// Behavior bundle for one group header row; recreated per apply and excluded
/// from model equality.
@MainActor
struct SidebarGroupHeaderRowActions {
    let onToggleCollapsed: () -> Void
    let onSelect: () -> Void
    let onTapPlus: () -> Void
    let onRunResolvedItem: (CmuxResolvedConfigMenuAction) -> Void
    let onRename: () -> Void
    let onTogglePinned: () -> Void
    let onMarkRead: () -> Void
    let onMarkUnread: () -> Void
    let onClearLatestNotifications: () -> Void
    let onMarkAllRead: () -> Void
    let onMarkAllUnread: () -> Void
    let onDelete: () -> Void
    let onEditConfig: () -> Void
    let onOpenDocs: () -> Void
}
