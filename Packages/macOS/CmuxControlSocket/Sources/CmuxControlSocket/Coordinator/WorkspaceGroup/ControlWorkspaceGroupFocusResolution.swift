public import Foundation

/// The outcome of `workspace.group.focus`, preserving the legacy body's single
/// failure and the focused workspace it echoes back.
///
/// The legacy body focused the owning window, made its TabManager active, then
/// selected the group's last active workspace through `selectWorkspace` (so the
/// selection side effects fire). All of that is app state, so it runs behind the
/// seam; the coordinator mints the workspace ref.
public enum ControlWorkspaceGroupFocusResolution: Sendable, Equatable {
    /// No TabManager resolved (legacy `unavailable` / "TabManager not
    /// available").
    case tabManagerUnavailable
    /// The group or its selected workspace was not found (legacy `not_found` /
    /// "Group or workspace not found", `data: {"group_id": …}`).
    case notFound
    /// The group's last active workspace was focused. Carries the workspace id.
    case focused(workspaceID: UUID)
}
