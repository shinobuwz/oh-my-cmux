public import Foundation
public import CmuxSettings

/// The window-side seam the group and container coordinators drive for the
/// effects they cannot own: workspace creation/teardown (the `Workspace` god
/// object still lives in the app target), selection moves, sidebar
/// multi-selection sync, localized strings, settings reads, and window-chrome
/// refreshes. The per-window `TabManager` is the single implementer.
///
/// Synchronous two-way protocol for the same reason as `WorkspacesHosting`:
/// every hierarchy operation is one MainActor turn interleaving reads and
/// writes (creating a leaf re-enters the model through the `tabs` willSet,
/// selecting a workspace re-enters through the selection `didSet`).
@MainActor
public protocol WorkspaceGroupHosting<Tab>: WorkspaceOrderHosting {
    /// The window's workspace ("tab") type; the app target's `Workspace`.
    associatedtype Tab: WorkspaceTabRepresenting

    // MARK: Workspace lifecycle (stays with the Workspace god object)

    /// Creates a workspace leaf inside a container. The app target owns Git,
    /// so it populates the leaf binding's immutable worktree root path, HEAD
    /// identity, and broken state from live Git state, and assigns `role`
    /// (the coordinator decides whether the leaf is ``WorkspaceLeafRole/main``
    /// or ``WorkspaceLeafRole/managed`` for a Git container, or
    /// ``WorkspaceLeafRole/external``/``compatibility`` otherwise).
    func createWorkspaceForContainer(
        title: String?,
        workingDirectory: String?,
        role: WorkspaceLeafRole,
        initialSurface: NewWorkspaceInitialSurface,
        initialBrowserURL: URL?,
        initialBrowserOmnibarVisible: Bool,
        initialBrowserTransparentBackground: Bool,
        inheritWorkingDirectory: Bool,
        select: Bool
    ) -> Tab
    /// Closes a leaf during container removal (legacy
    /// `closeWorkspace(_:recordHistory:)`, including its teardown chain).
    func closeWorkspaceForContainer(_ tab: Tab, recordHistory: Bool)
    /// Selects the workspace through the legacy selection entry point
    /// (DEBUG switch tracing + dismissal context ride along).
    func selectWorkspace(_ tab: Tab)

    // MARK: Sidebar multi-selection sync (CmuxSidebar model, owned app-side)

    /// The current sidebar multi-selection.
    var sidebarSelectedWorkspaceIds: Set<UUID> { get }
    /// Collapses the sidebar multi-selection onto the freshly created focus
    /// leaf (legacy `replaceSelection(with: [focusId])` +
    /// `postDidHide(hiddenWorkspaceIds:focusedWorkspaceId:)`).
    func collapseSidebarSelectionForContainerCreation(
        hiddenWorkspaceIds: Set<UUID>,
        focusLeafId: UUID
    )
    /// Strips now-hidden leaves from the sidebar multi-selection on container
    /// collapse (legacy `subtractSelection(_:)` +
    /// `postDidHide(hiddenWorkspaceIds:focusedWorkspaceId:)`).
    func subtractSidebarSelection(
        hiddenWorkspaceIds: Set<UUID>,
        focusedWorkspaceId: UUID?
    )

    // MARK: App-side values

    /// Localized `"Group %lld"` format for auto-generated group names
    /// (String(localized:) stays app-side).
    var localizedAutoGroupNameFormat: String { get }
    /// The stored global default placement for new leaves in a container
    /// (legacy settings read of `workspaceGroups.newWorkspacePlacement`).
    var defaultNewWorkspacePlacementInContainer: WorkspaceGroupNewPlacement { get }
    /// Normalizes a group icon SF Symbol name (legacy
    /// `RenderableSystemSymbol.normalized(_:)`, app-side catalog).
    func normalizedGroupIconSymbol(_ symbol: String?) -> String?
    /// A group was renamed: refresh window chrome and post the legacy
    /// `workspaceGroupNameDidChange` notification.
    func workspaceGroupNameDidChange()
}
