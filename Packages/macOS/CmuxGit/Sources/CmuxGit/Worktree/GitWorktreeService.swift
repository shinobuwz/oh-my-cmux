import Foundation

/// Runs `git` worktree operations off the main thread through an injected
/// command runner and filesystem seam, returning pure ``Sendable`` values and
/// typed ``GitWorktreeError``s.
///
/// This service owns the Git-CLI side of the Group > WorkspaceContainer > managed
/// worktree model: resolving a selected directory to its canonical repository,
/// listing linked worktrees, validating branch names, creating and removing
/// managed worktrees under `<mainRoot>/.cmux-worktrees/`, and keeping that
/// directory ignored via `.git/info/exclude`. It holds no UI or persistence
/// state; a `@MainActor` coordinator constructs it once, `await`s its methods,
/// and owns any observable projection.
///
/// It is a `Sendable` value facade: its `nonisolated async` methods run on the
/// global concurrent executor (SE-0338), so `await service.createWorktree(...)`
/// from the main actor offloads the blocking `git` process off the main thread
/// and lets operations against independent repositories run in parallel. Every
/// mutating command is issued via the injected ``GitWorktreeCommandRunning``
/// seam, which drains standard output and standard error concurrently before
/// waiting for the process to exit.
///
/// - Important: If the package ever adopts the `NonisolatedNonsendingByDefault`
///   upcoming feature, a bare `nonisolated async` method flips to running on the
///   *caller's* actor (the main thread, here). At that point these methods must
///   be annotated `@concurrent` to keep them off the main thread.
///
/// ```swift
/// let service = GitWorktreeService()
/// switch await service.resolveRepository(containing: selectedPath) {
/// case .worktree(let repo):
///     let created = try await service.createWorktree(in: repo, branch: "feature/x", base: "main")
/// case .bare, .notARepository: break
/// }
/// ```
public struct GitWorktreeService: Sendable {
    /// The directory name, relative to the main worktree root, under which
    /// managed worktrees are created.
    static let managedWorktreesDirectoryName = ".cmux-worktrees"

    /// The `gitignore`-style pattern appended to `.git/info/exclude` so the
    /// managed worktree directory is ignored. A trailing slash matches the
    /// directory and everything beneath it recursively.
    static let managedWorktreesExcludePattern = ".cmux-worktrees/"

    let commands: any GitWorktreeCommandRunning
    let filesystem: any GitWorktreeFilesystem

    /// Creates a worktree service.
    ///
    /// Both seams default to their system implementations and are injected so
    /// tests can substitute fakes that never spawn a process or touch the real
    /// filesystem.
    ///
    /// - Parameters:
    ///   - commands: The `git` command-running seam.
    ///   - filesystem: The filesystem seam for layout and exclude writes.
    public init(
        commands: any GitWorktreeCommandRunning = SystemGitWorktreeCommandRunner(),
        filesystem: any GitWorktreeFilesystem = SystemGitWorktreeFilesystem()
    ) {
        self.commands = commands
        self.filesystem = filesystem
    }

    /// The canonical destination for a managed worktree on `branch`:
    /// `<mainRoot>/.cmux-worktrees/<branch>`.
    ///
    /// Pure and `nonisolated` so a coordinator can compute a live preview before
    /// creating anything. A branch containing `/` (e.g. `feature/x`) is left
    /// intact; standardization turns it into nested path components, which still
    /// live under the ignored `.cmux-worktrees/` directory.
    ///
    /// - Parameters:
    ///   - repository: The resolved repository identifying the main root.
    ///   - branch: The validated branch name.
    /// - Returns: The absolute, normalized destination path.
    public nonisolated static func managedWorktreeDestination(
        repository: ResolvedWorktreeRepository,
        branch: String
    ) -> String {
        URL(fileURLWithPath: repository.mainRoot, isDirectory: true)
            .appendingPathComponent(Self.managedWorktreesDirectoryName, isDirectory: true)
            .appendingPathComponent(branch, isDirectory: true)
            .standardizedFileURL
            .path
    }

    /// Runs `git <arguments>` in `directory`, returning its standard output on
    /// success or throwing a typed command failure.
    ///
    /// The single chokepoint that translates a ``GitWorktreeCommandOutcome`` into
    /// either a `stdout` string or a
    /// ``GitWorktreeError/commandFailed(command:exitStatus:stderr:)`` carrying the
    /// verbatim stderr and exit status.
    ///
    /// - Parameters:
    ///   - arguments: The arguments passed to `git` (without the `git` token).
    ///   - directory: The working directory for the process.
    ///   - nonLocking: When `true`, runs with `GIT_OPTIONAL_LOCKS=0`.
    ///   - commandLabel: A short label for the command, used in the thrown error.
    /// - Returns: The captured standard output on success.
    /// - Throws: ``GitWorktreeError/commandFailed(command:exitStatus:stderr:)``
    ///   when git exited non-zero or could not be launched.
    func runGit(
        _ arguments: [String],
        in directory: String,
        nonLocking: Bool,
        commandLabel: String
    ) async throws -> String {
        let outcome = await commands.runGit(
            arguments: arguments,
            directory: directory,
            nonLocking: nonLocking
        )
        guard outcome.didSucceed else {
            throw GitWorktreeError.commandFailed(
                command: commandLabel,
                exitStatus: outcome.exitStatus,
                stderr: outcome.stderr
            )
        }
        return outcome.stdout
    }

    /// Returns `path` as a single absolute, standardized filesystem path.
    nonisolated static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// If `path` refers to a file, returns its containing directory; otherwise
    /// returns `path` standardized. Lets `git` run from a selected file's folder.
    nonisolated static func containingDirectory(for path: String) -> String {
        let standardized = standardizedPath(path)
        var isDirectory: ObjCBool = false
        let isRegularFile = FileManager.default.fileExists(
            atPath: standardized,
            isDirectory: &isDirectory
        ) && !isDirectory.boolValue
        guard isRegularFile else { return standardized }
        return URL(fileURLWithPath: standardized)
            .deletingLastPathComponent()
            .standardizedFileURL
            .path
    }

    /// Derives the main worktree root from the shared common directory, falling
    /// back to the worktree root when the common directory is not laid out as
    /// `<mainRoot>/.git`.
    nonisolated static func mainRoot(
        fromCommonDirectory commonDirectory: String,
        fallbackWorktreeRoot: String
    ) -> String {
        guard commonDirectory.hasSuffix("/.git") else {
            return fallbackWorktreeRoot
        }
        return URL(fileURLWithPath: commonDirectory, isDirectory: true)
            .deletingLastPathComponent()
            .standardizedFileURL
            .path
    }

    /// Returns the trimmed string when non-empty, otherwise `nil`.
    nonisolated static func trimmedNonEmpty(_ string: String) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
