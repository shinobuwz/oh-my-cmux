public import Foundation

/// The workspace-leaf seam used by the hierarchy model and coordinators.
///
/// The app target's `Workspace` is the single conformer. Reference semantics
/// let coordinators update container membership and pin state on live leaves.
/// Worktree-binding metadata (``leafBinding``) is read-only here: the app
/// owns the Git state and assigns role + identity when a leaf is created.
@MainActor
public protocol WorkspaceTabRepresenting: AnyObject, Identifiable where ID == UUID {
    /// The workspace's stable identity.
    var id: UUID { get }
    /// The owning ``WorkspaceContainer/id``, or `nil` during migration before
    /// the leaf has been adopted by a container.
    var workspaceContainerId: UUID? { get set }
    /// Whether the workspace is pinned (pinned leaves float above unpinned
    /// within their container).
    var isPinned: Bool { get set }
    /// The workspace's current working directory. Containers use this for
    /// local and remote compatibility migration.
    var currentDirectory: String { get }
    /// Persistent worktree-binding metadata. The app populates the immutable
    /// root path, HEAD identity, and broken state from live Git state, and
    /// assigns ``WorkspaceLeafRole`` at creation via the host seam. The
    /// package reads it to enforce main-leaf-first ordering and to resolve a
    /// container's main leaf.
    var leafBinding: WorkspaceLeafBinding { get }
}
