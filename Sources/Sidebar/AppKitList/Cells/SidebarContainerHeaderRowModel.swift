import CoreGraphics
import Foundation

/// Immutable render input for one workspace-container header row.
struct SidebarContainerHeaderRowModel: Equatable {
    let containerId: UUID
    let name: String
    let rootName: String
    let isCollapsed: Bool
    let isActive: Bool
    let isRootBroken: Bool
    let isGitCapable: Bool
    let isPointerHovering: Bool
    let indentation: CGFloat
    let fontScale: CGFloat
    let globalFontMagnificationPercent: Int
}

@MainActor
struct SidebarContainerHeaderRowActions {
    let onToggleCollapsed: () -> Void
    let onSelect: () -> Void
    let onTapPlus: () -> Void
    let onDelete: () -> Void
    let onLocateRoot: () -> Void
}
