import Foundation

extension GitWorktreeService {
    /// Creates a new managed worktree on a fresh branch from an explicit base
    /// checkout.
    ///
    /// Validates `branch`, prepares the managed layout (creating
    /// `<mainRoot>/.cmux-worktrees/` and updating `.git/info/exclude`), then runs
    /// `git worktree add -b <branch> <destination> <base>` where `destination`
    /// is ``managedWorktreeDestination(repository:branch:)`` and `base` is the
    /// commit-ish supplied by the caller (e.g. `main`, a tag, or a SHA).
    ///
    /// The created worktree is returned by re-listing so its `HEAD` and branch
    /// reflect git's actual state. If a branch named `branch` already exists,
    /// git rejects the creation and the failure is surfaced as a
    /// ``GitWorktreeError/commandFailed(command:exitStatus:stderr:)`` with the
    /// exact stderr.
    ///
    /// - Parameters:
    ///   - repository: The resolved repository to create within.
    ///   - branch: The new branch name; validated via
    ///     ``validateBranchName(_:in:)``.
    ///   - base: The commit-ish the new branch starts from.
    /// - Returns: The created ``GitWorktree``.
    /// - Throws: ``GitWorktreeError/invalidBranchName(_:)`` when the name is
    ///   invalid, ``GitWorktreeError/filesystemFailure(operation:error:)`` when
    ///   the layout cannot be prepared, or
    ///   ``GitWorktreeError/commandFailed(command:exitStatus:stderr:)`` when the
    ///   creation command fails.
    public nonisolated func createWorktree(
        in repository: ResolvedWorktreeRepository,
        branch: String,
        base: String
    ) async throws -> GitWorktree {
        let trimmedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBranch.isEmpty,
              await validateBranchName(trimmedBranch, in: repository) else {
            throw GitWorktreeError.invalidBranchName(branch)
        }

        let destination = Self.managedWorktreeDestination(
            repository: repository,
            branch: trimmedBranch
        )
        try ensureManagedLayout(in: repository)

        _ = try await runGit(
            ["worktree", "add", "-b", trimmedBranch, destination, base],
            in: repository.mainRoot,
            nonLocking: false,
            commandLabel: "git worktree add"
        )

        return try await worktree(at: destination, in: repository)
            ?? Self.synthesizedWorktree(path: destination, branch: trimmedBranch)
    }

    /// Recreates a missing managed worktree from a retained branch.
    ///
    /// Used when a managed worktree's directory has been removed outside git but
    /// its branch still exists in the repository. Validates `branch`, prepares
    /// the managed layout, then runs `git worktree add <destination> <branch>`
    /// (without `-b`) to check out the existing branch into a fresh worktree at
    /// ``managedWorktreeDestination(repository:branch:)``.
    ///
    /// - Parameters:
    ///   - repository: The resolved repository to recreate within.
    ///   - branch: The existing branch to check out into the new worktree.
    /// - Returns: The recreated ``GitWorktree``.
    /// - Throws: ``GitWorktreeError/invalidBranchName(_:)`` when the name is
    ///   invalid, ``GitWorktreeError/filesystemFailure(operation:error:)`` when
    ///   the layout cannot be prepared, or
    ///   ``GitWorktreeError/commandFailed(command:exitStatus:stderr:)`` when the
    ///   branch does not exist or the creation command fails.
    public nonisolated func recreateWorktree(
        in repository: ResolvedWorktreeRepository,
        branch: String
    ) async throws -> GitWorktree {
        let trimmedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBranch.isEmpty,
              await validateBranchName(trimmedBranch, in: repository) else {
            throw GitWorktreeError.invalidBranchName(branch)
        }

        let destination = Self.managedWorktreeDestination(
            repository: repository,
            branch: trimmedBranch
        )
        try ensureManagedLayout(in: repository)

        _ = try await runGit(
            ["worktree", "add", destination, trimmedBranch],
            in: repository.mainRoot,
            nonLocking: false,
            commandLabel: "git worktree add"
        )

        return try await worktree(at: destination, in: repository)
            ?? Self.synthesizedWorktree(path: destination, branch: trimmedBranch)
    }

    /// Removes a linked worktree, optionally forcing removal of a dirty one,
    /// while preserving its branch.
    ///
    /// Runs `git worktree remove [--force] <path>` from the main worktree root,
    /// then prunes stale administrative metadata. `git worktree remove` does not
    /// delete the checked-out branch, so the branch survives removal and can be
    /// reused — for example by ``recreateWorktree(in:branch:)``. The main
    /// worktree cannot be removed this way; git refuses it and the failure is
    /// surfaced as a typed command error.
    ///
    /// - Parameters:
    ///   - repository: The resolved repository owning the worktree.
    ///   - path: The absolute path of the linked worktree to remove.
    ///   - force: When `true`, passes `--force` to remove a worktree with
    ///     modifications or untracked files.
    /// - Throws: ``GitWorktreeError/commandFailed(command:exitStatus:stderr:)``
    ///   when the removal command fails. A prune failure is ignored because the
    ///   removal itself already succeeded and the branch is preserved.
    public nonisolated func removeWorktree(
        in repository: ResolvedWorktreeRepository,
        at path: String,
        force: Bool = false
    ) async throws {
        let target = Self.standardizedPath(path)
        var arguments = ["worktree", "remove"]
        if force { arguments.append("--force") }
        arguments.append(target)

        _ = try await runGit(
            arguments,
            in: repository.mainRoot,
            nonLocking: false,
            commandLabel: "git worktree remove"
        )

        // Best-effort cleanup of stale metadata; a prune failure does not undo a
        // successful removal, and the branch is preserved regardless.
        _ = try? await runGit(
            ["worktree", "prune"],
            in: repository.mainRoot,
            nonLocking: false,
            commandLabel: "git worktree prune"
        )
    }

    /// Returns the worktree whose path matches `destination`, re-listing first.
    private nonisolated func worktree(
        at destination: String,
        in repository: ResolvedWorktreeRepository
    ) async throws -> GitWorktree? {
        let normalizedDestination = Self.standardizedPath(destination)
        let worktrees = try await linkedWorktrees(in: repository)
        return worktrees.first { Self.standardizedPath($0.path) == normalizedDestination }
    }

    /// Builds a minimal fallback snapshot when a just-created worktree is not yet
    /// visible in a re-list (an unlikely race); callers normally receive a fully
    /// populated entry instead.
    nonisolated static func synthesizedWorktree(path: String, branch: String) -> GitWorktree {
        GitWorktree(
            path: path,
            head: nil,
            branch: branch,
            isDetached: false,
            isBare: false,
            isMainWorktree: false,
            isLocked: false,
            lockedReason: nil,
            isPrunable: false,
            prunableReason: nil
        )
    }
}
