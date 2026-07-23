import Foundation

/// The canonical on-disk locations of a non-bare git repository resolved for
/// worktree management.
///
/// Produced by ``GitWorktreeService/resolveRepository(containing:)`` in the
/// ``WorktreeRepositoryResolution/worktree(_:)`` case. Every path is absolute
/// and normalized. A linked worktree and the repository's main worktree share
/// the same ``commonDirectory`` (the shared object/ref store, i.e. the main
/// worktree's `.git`); ``worktreeRoot`` is the *selected* worktree's root while
/// ``mainRoot`` is the primary checkout under which managed worktrees are
/// created.
///
/// For a normal single checkout, ``worktreeRoot`` and ``mainRoot`` are equal,
/// and ``commonDirectory`` is `<mainRoot>/.git`.
public struct ResolvedWorktreeRepository: Sendable, Equatable {
    /// Absolute path to the working-tree root of the resolved worktree (the
    /// checkout the selected directory lives in).
    public let worktreeRoot: String

    /// Absolute path to the resolved worktree's own git directory (the `.git`
    /// directory, or the directory a `.git` *file* points at for a linked
    /// worktree).
    public let gitDirectory: String

    /// Absolute path to the shared common directory — the main worktree's
    /// `.git`, which holds the shared `refs`, `packed-refs`, `config`, and
    /// `info/exclude`. Managed worktree exclusion is written here.
    public let commonDirectory: String

    /// Absolute path to the repository's main (primary) worktree root. Managed
    /// worktrees are created under `<mainRoot>/.cmux-worktrees/`.
    public let mainRoot: String

    /// Creates a resolved worktree repository from its canonical locations.
    ///
    /// All paths should be absolute and normalized; the resolution pathway
    /// guarantees this. Callers normally receive an instance from
    /// ``GitWorktreeService/resolveRepository(containing:)`` rather than
    /// constructing one.
    public init(
        worktreeRoot: String,
        gitDirectory: String,
        commonDirectory: String,
        mainRoot: String
    ) {
        self.worktreeRoot = worktreeRoot
        self.gitDirectory = gitDirectory
        self.commonDirectory = commonDirectory
        self.mainRoot = mainRoot
    }
}
