import Foundation

/// The checked-out HEAD identity of a Git worktree leaf.
///
/// Non-Git leaves carry a `nil` ``WorkspaceLeafBinding/head``.
public enum WorkspaceLeafHead: Equatable, Sendable {
    /// Checked out on a named local or remote-tracking branch.
    case branch(String)
    /// Detached `HEAD`, optionally pointing at a commitish the app recovered.
    case detached(commitish: String?)
}

/// Persistent worktree-binding metadata for a workspace leaf.
///
/// The app target's `Workspace` is the source of truth and exposes
/// ``WorkspaceTabRepresenting/leafBinding`` as a **computed, read-only**
/// value backed by app-owned fields. The package reads it to enforce the
/// main-leaf-first ordering invariant, to resolve a container's main leaf,
/// and to surface broken state to coordinators without itself depending on
/// Git. There is no coordinator mutation hook: creation assigns `role`,
/// `worktreeRootPath`, and `head` once; `worktreeRootPath` is updated by the
/// app directly on root relocation; `isBroken` is derived from live Git state.
///
/// Role is stable for the leaf's lifetime:
/// - ``WorkspaceLeafRole/main`` — the first Git leaf of a container (fixed
///   first in the sidebar).
/// - ``WorkspaceLeafRole/managed`` — a cmux-created Git worktree leaf.
/// - ``WorkspaceLeafRole/external`` — an imported existing/linked worktree.
/// - ``WorkspaceLeafRole/compatibility`` — a non-Git or legacy restored leaf.
public struct WorkspaceLeafBinding: Equatable, Sendable {
    /// The leaf's structural role inside its container.
    public var role: WorkspaceLeafRole
    /// The immutable local worktree root path for a Git leaf, or `nil` for
    /// non-Git leaves and pre-adoption workspaces.
    public var worktreeRootPath: String?
    /// The checked-out HEAD identity, or `nil` for non-Git leaves.
    public var head: WorkspaceLeafHead?
    /// Whether the worktree is missing or corrupt (derived app-side from the
    /// Git service). A broken ``main`` leaf still stays first; the app
    /// decides whether to offer repair.
    public var isBroken: Bool

    /// Creates leaf binding metadata.
    public init(
        role: WorkspaceLeafRole,
        worktreeRootPath: String?,
        head: WorkspaceLeafHead?,
        isBroken: Bool
    ) {
        self.role = role
        self.worktreeRootPath = worktreeRootPath
        self.head = head
        self.isBroken = isBroken
    }
}

extension WorkspaceLeafBinding {
    /// A neutral binding for a non-Git, healthy, externally-positioned leaf.
    public static let external = WorkspaceLeafBinding(
        role: .external,
        worktreeRootPath: nil,
        head: nil,
        isBroken: false
    )

    /// A neutral binding for a restored-session leaf with an unreliable directory.
    public static let compatibility = WorkspaceLeafBinding(
        role: .compatibility,
        worktreeRootPath: nil,
        head: nil,
        isBroken: false
    )
}
