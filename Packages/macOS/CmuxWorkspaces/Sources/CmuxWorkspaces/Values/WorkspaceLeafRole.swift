import Foundation

/// The structural role a workspace leaf plays inside its container.
///
/// The role is the single fact the hierarchy model needs to enforce ordering
/// invariants without reaching into Git: only a ``main`` leaf is fixed first
/// inside a Git container, and only ``main``/``managed`` leaves are treated
/// as repository worktrees for teardown. The app target's `Workspace` owns
/// the real Git state and assigns the role once at creation; the role is stable
/// for the leaf's lifetime. The package reads it.
public enum WorkspaceLeafRole: String, Sendable, CaseIterable, Equatable {
    /// The fixed primary worktree of a Git container. Exactly one per Git
    /// container; assigned at the first Git leaf's creation and stable for its
    /// lifetime. It stays first in the sidebar regardless of pin state or drag
    /// position, and is the fallback selection target for the container header.
    /// Non-Git containers never have a ``main`` leaf.
    case main
    /// A cmux-created Git worktree leaf. Reorders freely below the ``main``
    /// leaf and is torn down with its container.
    case managed
    /// An imported existing/linked worktree, or a workspace that shares a
    /// container but is not part of the repository's worktree set. Reorders
    /// freely; never fixed first.
    case external
    /// A restored-session leaf whose on-disk directory could not be
    /// reliably recovered. Treated as ``external`` for ordering but flagged
    /// so the app can offer reconnection rather than silent adoption.
    case compatibility
}
