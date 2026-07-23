import Foundation

extension GitWorktreeService {
    /// Validates `branch` as a git branch name for `repository`.
    ///
    /// Delegates to git's own ref-format rules by running
    /// `git check-ref-format --normalize refs/heads/<branch>`, so the check
    /// matches what `git worktree add -b` will accept: rejects empty names,
    /// invalid characters, `..`, leading/trailing `/` or `.`, a `.lock`
    /// suffix, `@{`, and control characters, while accepting slashes
    /// (e.g. `feature/x`).
    ///
    /// Suitable for live UI feedback before a create is attempted.
    ///
    /// - Parameters:
    ///   - branch: The candidate branch name.
    ///   - repository: The resolved repository used as the command's context.
    /// - Returns: `true` when git accepts the name as a valid branch ref.
    public nonisolated func validateBranchName(
        _ branch: String,
        in repository: ResolvedWorktreeRepository
    ) async -> Bool {
        let trimmed = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let outcome = await commands.runGit(
            arguments: ["check-ref-format", "--normalize", "refs/heads/" + trimmed],
            directory: repository.mainRoot,
            nonLocking: true
        )
        return outcome.didSucceed
    }
}
