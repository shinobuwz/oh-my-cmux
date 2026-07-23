import Foundation

extension GitWorktreeService {
    /// Resolves an arbitrary selected directory to its enclosing git repository.
    ///
    /// Walks the directory through `git rev-parse` to canonicalize its
    /// locations: the working-tree root of the selected checkout, its git
    /// directory, the shared common directory, and the main worktree root under
    /// which managed worktrees live. Bare repositories (which have no working
    /// tree) and directories outside any repository are distinguished so a
    /// coordinator can show the right message rather than a generic failure.
    ///
    /// - Parameter directory: An absolute path to start from. A path to a file is
    ///   resolved to its containing directory.
    /// - Returns: A ``WorktreeRepositoryResolution`` describing the repository.
    public nonisolated func resolveRepository(
        containing directory: String
    ) async -> WorktreeRepositoryResolution {
        let startDirectory = Self.containingDirectory(for: directory)

        // A non-bare work tree reports a toplevel; a bare repo and a non-repo do not.
        let toplevelOutcome = await commands.runGit(
            arguments: ["rev-parse", "--path-format=absolute", "--show-toplevel"],
            directory: startDirectory,
            nonLocking: true
        )
        if toplevelOutcome.didSucceed,
           let toplevel = Self.trimmedNonEmpty(toplevelOutcome.stdout) {
            return await resolveWorktree(startingFrom: Self.standardizedPath(toplevel))
        }

        // Toplevel failed: distinguish a bare repository from a non-repository.
        let bareOutcome = await commands.runGit(
            arguments: ["rev-parse", "--is-bare-repository", "--absolute-git-dir"],
            directory: startDirectory,
            nonLocking: true
        )
        if bareOutcome.didSucceed {
            let lines = bareOutcome.stdout.split(separator: "\n").map(String.init)
            let isBare = Self.trimmedNonEmpty(lines.first ?? "") == "true"
            if isBare {
                let barePath = Self.trimmedNonEmpty(lines.count > 1 ? lines[1] : "")
                    .map(Self.standardizedPath(_:))
                    ?? Self.standardizedPath(startDirectory)
                return .bare(path: barePath)
            }
        }
        return .notARepository
    }

    /// Resolves the git directory, common directory, and main root for a
    /// confirmed non-bare worktree rooted at `worktreeRoot`.
    private nonisolated func resolveWorktree(
        startingFrom worktreeRoot: String
    ) async -> WorktreeRepositoryResolution {
        let dirsOutcome = await commands.runGit(
            arguments: [
                "rev-parse", "--absolute-git-dir",
                "--path-format=absolute", "--git-common-dir",
            ],
            directory: worktreeRoot,
            nonLocking: true
        )
        let gitDirectory: String
        let commonDirectory: String
        if dirsOutcome.didSucceed {
            let lines = dirsOutcome.stdout.split(separator: "\n").map(String.init)
            gitDirectory = Self.trimmedNonEmpty(lines.first ?? "")
                .map(Self.standardizedPath(_:))
                ?? Self.standardizedPath(worktreeRoot + "/.git")
            commonDirectory = Self.trimmedNonEmpty(lines.count > 1 ? lines[1] : "")
                .map(Self.standardizedPath(_:))
                ?? gitDirectory
        } else {
            gitDirectory = Self.standardizedPath(worktreeRoot + "/.git")
            commonDirectory = gitDirectory
        }
        let mainRoot = Self.mainRoot(
            fromCommonDirectory: commonDirectory,
            fallbackWorktreeRoot: worktreeRoot
        )
        return .worktree(ResolvedWorktreeRepository(
            worktreeRoot: worktreeRoot,
            gitDirectory: gitDirectory,
            commonDirectory: commonDirectory,
            mainRoot: mainRoot
        ))
    }
}
