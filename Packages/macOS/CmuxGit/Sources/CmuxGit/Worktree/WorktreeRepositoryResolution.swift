import Foundation

/// The outcome of resolving an arbitrary selected directory to its enclosing
/// git repository for worktree operations.
///
/// Returned by ``GitWorktreeService/resolveRepository(containing:)``. The three
/// cases let a coordinator distinguish "not a repository at all" from "bare,
/// which has no working tree and cannot host a managed worktree at this path"
/// from a fully usable worktree, so the user sees the right message instead of a
/// generic failure.
///
/// ```swift
/// switch await service.resolveRepository(containing: selectedPath) {
/// case .notARepository: showNotAGitFolder()
/// case .bare(let path): showBareRepository(at: path)
/// case .worktree(let repo): await listWorktrees(in: repo)
/// }
/// ```
public enum WorktreeRepositoryResolution: Sendable, Equatable {
    /// The directory is not inside any git repository.
    case notARepository

    /// The directory is inside a bare repository, which has no working tree and
    /// cannot host a managed linked worktree at this location. The associated
    /// path is the bare repository's git directory.
    case bare(path: String)

    /// A non-bare repository with a working tree, usable for worktree
    /// operations. The associated value carries its canonical on-disk
    /// locations, including the main root where managed worktrees live.
    case worktree(ResolvedWorktreeRepository)
}
