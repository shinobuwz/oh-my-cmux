import Foundation

/// One entry parsed from `git worktree list --porcelain`.
///
/// A pure value snapshot of a single worktree's state at listing time. The
/// service returns arrays of these from ``GitWorktreeService/linkedWorktrees(in:)``;
/// a coordinator holds them as plain values without ever touching the service
/// again to render a row.
///
/// The fields mirror the porcelain tokens git emits: the working-tree path,
/// `HEAD` commit, checked-out branch (or `detached`), `bare`, `locked <reason>`,
/// and `prunable <reason>`. Unknown tokens newer git versions add (e.g. `cwd`)
/// are tolerated by the parser and do not appear here.
public struct GitWorktree: Sendable, Equatable, Hashable {
    /// Absolute filesystem path of the worktree, exactly as git reports it.
    public let path: String

    /// The `HEAD` commit object id, or `nil` for an unborn or bare worktree.
    public let head: String?

    /// The short branch name (e.g. `feature/x`) for a worktree checked out on a
    /// branch. `nil` when detached, bare, or when git reports no branch.
    public let branch: String?

    /// `true` when the worktree is in a detached-HEAD state.
    public let isDetached: Bool

    /// `true` when the worktree is a bare repository entry.
    public let isBare: Bool

    /// `true` when this entry is the repository's primary (main) worktree — the
    /// one whose path equals the resolved main root.
    public let isMainWorktree: Bool

    /// `true` when git reports the worktree as `locked`.
    public let isLocked: Bool

    /// The lock reason when `locked <reason>` was reported; an empty string when
    /// the worktree is locked with no reason; `nil` when not locked.
    public let lockedReason: String?

    /// `true` when git reports the worktree as `prunable` (its administrative
    /// metadata can be cleaned up by `git worktree prune`).
    public let isPrunable: Bool

    /// The prune reason when `prunable <reason>` was reported; `nil` when not
    /// prunable or when prunable carried no reason.
    public let prunableReason: String?

    /// A human label for the worktree: its branch, falling back to the
    /// directory name when detached or bare.
    public var displayName: String {
        if let branch, !branch.isEmpty { return branch }
        return (path as NSString).lastPathComponent
    }

    /// Creates a worktree snapshot from parsed porcelain fields.
    ///
    /// All parameters correspond to the documented stored properties. Callers
    /// normally obtain instances from ``GitWorktreeService/linkedWorktrees(in:)``
    /// rather than constructing them directly.
    public init(
        path: String,
        head: String?,
        branch: String?,
        isDetached: Bool,
        isBare: Bool,
        isMainWorktree: Bool,
        isLocked: Bool,
        lockedReason: String?,
        isPrunable: Bool,
        prunableReason: String?
    ) {
        self.path = path
        self.head = head
        self.branch = branch
        self.isDetached = isDetached
        self.isBare = isBare
        self.isMainWorktree = isMainWorktree
        self.isLocked = isLocked
        self.lockedReason = lockedReason
        self.isPrunable = isPrunable
        self.prunableReason = prunableReason
    }
}
