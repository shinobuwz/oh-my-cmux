import SwiftUI

struct SidebarWorkspaceTableContextMenuActions {
    let didOpen: () -> Void
    let didClose: () -> Void
}

/// Mutable, non-observed holder for the last-built table rows. The sidebar
/// container freezes row building against it during interactive divider
/// drags (rows cannot change while the resizer owns the mouse), so
/// per-width-tick body evals skip the row-projection prelude.
@MainActor
final class SidebarAppKitFrozenRowsBox {
    var rows: [SidebarWorkspaceTableRowConfiguration]?
}

/// Immutable description of one AppKit-owned sidebar row.
@MainActor
struct SidebarWorkspaceTableRowConfiguration {
    typealias ContentFactory = (
        _ isPointerHovering: Bool,
        _ contextMenuActions: SidebarWorkspaceTableContextMenuActions
    ) -> AnyView

    let id: SidebarWorkspaceRenderItemID
    let workspaceId: UUID?
    let groupId: UUID?
    let containerId: UUID?
    let isGroupHeader: Bool
    let isContainerHeader: Bool
    let isPinned: Bool
    let makeContent: ContentFactory
    let appKitGroupHeaderModel: SidebarGroupHeaderRowModel?
    let appKitGroupHeaderActions: SidebarGroupHeaderRowActions?
    let appKitContainerHeaderModel: SidebarContainerHeaderRowModel?
    let appKitContainerHeaderActions: SidebarContainerHeaderRowActions?
    let appKitWorkspaceRowModel: SidebarWorkspaceRowModel?
    let appKitWorkspaceRowActions: SidebarAppKitRowActions?
    let appKitWorkspaceRowWorkspace: Workspace?
    let appKitWorkspaceRowRebuild: (@MainActor () -> SidebarWorkspaceRowModel)?

    private let environment: SidebarWorkspaceTableEnvironmentSnapshot
    private let equivalenceValue: Any
    private let isEquivalentValue: (Any) -> Bool

    init<Content: View & Equatable>(
        id: SidebarWorkspaceRenderItemID,
        workspaceId: UUID,
        groupId: UUID?,
        isGroupHeader: Bool,
        isPinned: Bool,
        environment: SidebarWorkspaceTableEnvironmentSnapshot,
        equivalenceValue: Content,
        makeContent: @escaping ContentFactory
    ) {
        self.id = id
        self.workspaceId = workspaceId
        self.groupId = groupId
        self.containerId = nil
        self.isGroupHeader = isGroupHeader
        self.isContainerHeader = false
        self.isPinned = isPinned
        self.environment = environment
        self.makeContent = makeContent
        self.appKitGroupHeaderModel = nil
        self.appKitGroupHeaderActions = nil
        self.appKitContainerHeaderModel = nil
        self.appKitContainerHeaderActions = nil
        self.appKitWorkspaceRowModel = nil
        self.appKitWorkspaceRowActions = nil
        self.appKitWorkspaceRowWorkspace = nil
        self.appKitWorkspaceRowRebuild = nil
        self.equivalenceValue = equivalenceValue
        self.isEquivalentValue = { value in
            guard let value = value as? Content else { return false }
            return value == equivalenceValue
        }
    }
    init(
        groupHeaderModel: SidebarGroupHeaderRowModel,
        actions: SidebarGroupHeaderRowActions,
        environment: SidebarWorkspaceTableEnvironmentSnapshot
    ) {
        self.id = .group(groupHeaderModel.groupId)
        self.workspaceId = nil
        self.groupId = groupHeaderModel.groupId
        self.containerId = nil
        self.isGroupHeader = true
        self.isContainerHeader = false
        self.isPinned = groupHeaderModel.isPinned
        self.environment = environment
        self.makeContent = { _, _ in AnyView(EmptyView()) }
        self.appKitGroupHeaderModel = groupHeaderModel
        self.appKitGroupHeaderActions = actions
        self.appKitContainerHeaderModel = nil
        self.appKitContainerHeaderActions = nil
        self.appKitWorkspaceRowModel = nil
        self.appKitWorkspaceRowActions = nil
        self.appKitWorkspaceRowWorkspace = nil
        self.appKitWorkspaceRowRebuild = nil
        self.equivalenceValue = groupHeaderModel
        self.isEquivalentValue = { value in
            guard let value = value as? SidebarGroupHeaderRowModel else { return false }
            return value == groupHeaderModel
        }
    }

    init(
        workspaceRowModel: SidebarWorkspaceRowModel,
        actions: SidebarAppKitRowActions,
        groupId: UUID?,
        isPinned: Bool,
        environment: SidebarWorkspaceTableEnvironmentSnapshot,
        workspace: Workspace? = nil,
        rebuild: (@MainActor () -> SidebarWorkspaceRowModel)? = nil
    ) {
        self.id = .workspace(workspaceRowModel.workspaceId)
        self.workspaceId = workspaceRowModel.workspaceId
        self.groupId = groupId
        self.containerId = workspace?.workspaceContainerId
        self.isGroupHeader = false
        self.isContainerHeader = false
        self.isPinned = isPinned
        self.environment = environment
        self.makeContent = { _, _ in AnyView(EmptyView()) }
        self.appKitGroupHeaderModel = nil
        self.appKitGroupHeaderActions = nil
        self.appKitContainerHeaderModel = nil
        self.appKitContainerHeaderActions = nil
        self.appKitWorkspaceRowModel = workspaceRowModel
        self.appKitWorkspaceRowActions = actions
        self.appKitWorkspaceRowWorkspace = workspace
        self.appKitWorkspaceRowRebuild = rebuild
        self.equivalenceValue = workspaceRowModel
        self.isEquivalentValue = { value in
            guard let value = value as? SidebarWorkspaceRowModel else { return false }
            return value == workspaceRowModel
        }
    }

    init(
        containerHeaderModel: SidebarContainerHeaderRowModel,
        actions: SidebarContainerHeaderRowActions,
        environment: SidebarWorkspaceTableEnvironmentSnapshot
    ) {
        self.id = .container(containerHeaderModel.containerId)
        self.workspaceId = nil
        self.groupId = nil
        self.containerId = containerHeaderModel.containerId
        self.isGroupHeader = false
        self.isContainerHeader = true
        self.isPinned = false
        self.environment = environment
        self.makeContent = { _, _ in AnyView(EmptyView()) }
        self.appKitGroupHeaderModel = nil
        self.appKitGroupHeaderActions = nil
        self.appKitContainerHeaderModel = containerHeaderModel
        self.appKitContainerHeaderActions = actions
        self.appKitWorkspaceRowModel = nil
        self.appKitWorkspaceRowActions = nil
        self.appKitWorkspaceRowWorkspace = nil
        self.appKitWorkspaceRowRebuild = nil
        self.equivalenceValue = containerHeaderModel
        self.isEquivalentValue = { value in
            guard let value = value as? SidebarContainerHeaderRowModel else { return false }
            return value == containerHeaderModel
        }
    }

    func hasEquivalentContent(to other: Self) -> Bool {
        environment.hasEquivalentPresentation(to: other.environment)
            && isEquivalentValue(other.equivalenceValue)
    }
    var estimatedHeight: CGFloat {
        let fontScale = CGFloat(environment.globalFontMagnificationPercent) / 100
        let calculator = SidebarWorkspaceTableRowHeightCalculator()
        if isGroupHeader { return calculator.estimatedGroupHeaderHeight(fontScale: fontScale) }
        if let model = appKitContainerHeaderModel { return SidebarContainerHeaderTableCellView.preferredHeight(model: model) }
        return calculator.estimatedWorkspaceHeight(fontScale: fontScale, titleLineCount: 1, auxiliaryLineCount: 0)
    }
}
