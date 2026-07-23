import Foundation

extension GitWorktreeService {
    /// Lists every worktree (main plus linked) in `repository` in porcelain form.
    ///
    /// Runs `git worktree list --porcelain` from the main worktree root with
    /// `GIT_OPTIONAL_LOCKS=0` so a concurrent `git` in another surface cannot
    /// block the listing, then parses branch, detached, bare, locked, and
    /// prunable state for each entry.
    ///
    /// - Parameter repository: The resolved repository to list.
    /// - Returns: The worktrees in git's reported order (main first).
    /// - Throws: ``GitWorktreeError/commandFailed(command:exitStatus:stderr:)``
    ///   when the listing command exited non-zero or could not be launched.
    public nonisolated func linkedWorktrees(
        in repository: ResolvedWorktreeRepository
    ) async throws -> [GitWorktree] {
        let output = try await runGit(
            ["worktree", "list", "--porcelain"],
            in: repository.mainRoot,
            nonLocking: true,
            commandLabel: "git worktree list"
        )
        return Self.parseWorktreePorcelain(output, mainRoot: repository.mainRoot)
    }

    /// Parses `git worktree list --porcelain` output into ``GitWorktree``
    /// snapshots.
    ///
    /// Tolerant of unknown porcelain fields (e.g. `cwd`) added by newer git
    /// versions: recognized tokens populate the model, everything else is
    /// ignored. `mainRoot` is used to flag the primary worktree entry.
    ///
    /// - Parameters:
    ///   - output: The raw porcelain output.
    ///   - mainRoot: The canonical main worktree root, for `isMainWorktree`.
    /// - Returns: The parsed worktrees in reported order.
    nonisolated static func parseWorktreePorcelain(
        _ output: String,
        mainRoot: String
    ) -> [GitWorktree] {
        let normalizedMainRoot = Self.standardizedPath(mainRoot)

        var entries: [GitWorktree] = []
        var path: String?
        var head: String?
        var branch: String?
        var isDetached = false
        var isBare = false
        var isLocked = false
        var lockedReason: String?
        var isPrunable = false
        var prunableReason: String?

        func flush() {
            guard let pathValue = path else { return }
            let shortBranch: String?
            if isDetached || isBare {
                shortBranch = nil
            } else if let branch {
                shortBranch = branch.hasPrefix("refs/heads/")
                    ? String(branch.dropFirst("refs/heads/".count))
                    : branch
            } else {
                shortBranch = nil
            }
            let normalizedPath = Self.standardizedPath(pathValue)
            entries.append(GitWorktree(
                path: pathValue,
                head: (head?.isEmpty == false) ? head : nil,
                branch: shortBranch,
                isDetached: isDetached,
                isBare: isBare,
                isMainWorktree: normalizedPath == normalizedMainRoot,
                isLocked: isLocked,
                lockedReason: isLocked ? (lockedReason ?? "") : nil,
                isPrunable: isPrunable,
                prunableReason: isPrunable ? prunableReason : nil
            ))
            path = nil
            head = nil
            branch = nil
            isDetached = false
            isBare = false
            isLocked = false
            lockedReason = nil
            isPrunable = false
            prunableReason = nil
        }

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.isEmpty {
                flush()
                continue
            }
            if line.hasPrefix("worktree ") {
                flush()
                path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("HEAD ") {
                head = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch ") {
                branch = String(line.dropFirst("branch ".count))
            } else if line == "detached" {
                isDetached = true
            } else if line == "bare" {
                isBare = true
            } else if line == "locked" {
                isLocked = true
                lockedReason = ""
            } else if line.hasPrefix("locked ") {
                isLocked = true
                lockedReason = String(line.dropFirst("locked ".count))
            } else if line == "prunable" {
                isPrunable = true
                prunableReason = nil
            } else if line.hasPrefix("prunable ") {
                isPrunable = true
                prunableReason = String(line.dropFirst("prunable ".count))
            }
            // Unknown fields (e.g. `cwd`) are ignored.
        }
        flush()
        return entries
    }
}
