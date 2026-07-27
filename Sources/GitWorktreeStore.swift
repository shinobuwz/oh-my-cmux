import CmuxFoundation
import Foundation

// MARK: - Models

/// One entry returned by `git worktree list --porcelain`.
///
/// A pure value snapshot: the sidebar view receives these without ever
/// touching the store, keeping the observable surface at the view boundary.
struct GitWorktreeEntry: Sendable, Equatable, Identifiable {
    /// Absolute filesystem path of the worktree, as reported by git.
    let path: String
    /// HEAD commit sha, when git reports one. `nil` for bare/unborn worktrees.
    let head: String?
    /// Short branch name (e.g. `feature/x`) for a checked-out branch worktree.
    /// `nil` when detached or bare.
    let branch: String?
    let isDetached: Bool
    let isBare: Bool
    /// `true` when this worktree's path equals the registered repository root.
    let isMainWorktree: Bool
    /// Non-nil when git reports the worktree as locked. Empty string for a
    /// lock with no reason.
    let lockedReason: String?

    var id: String { path }

    /// Human label for the row: the branch, falling back to the directory name.
    var displayName: String {
        if let branch, !branch.isEmpty { return branch }
        return (path as NSString).lastPathComponent
    }
}

/// A registered git repository and its freshly-fetched worktrees.
///
/// `worktrees`, `lastError`, and `isRefreshing` are recomputed by the store on
/// every refresh; `rootPath` is the stable identity persisted to UserDefaults.
struct GitWorktreeRepository: Sendable, Equatable, Identifiable {
    let rootPath: String
    var worktrees: [GitWorktreeEntry]
    var lastError: String?
    var isRefreshing: Bool

    var id: String { rootPath }
    var displayName: String { (rootPath as NSString).lastPathComponent }

    init(
        rootPath: String,
        worktrees: [GitWorktreeEntry] = [],
        lastError: String? = nil,
        isRefreshing: Bool = false
    ) {
        self.rootPath = rootPath
        self.worktrees = worktrees
        self.lastError = lastError
        self.isRefreshing = isRefreshing
    }
}

enum GitWorktreeError: LocalizedError, Equatable {
    case invalidBranchName
    case commandFailed(stderr: String, fallback: String)

    var errorDescription: String? {
        switch self {
        case .invalidBranchName:
            return String(
                localized: "gitWorktrees.error.invalidBranchName",
                defaultValue: "Branch name must not be empty."
            )
        case .commandFailed(let stderr, let fallback):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? fallback : "\(fallback) \(trimmed)"
        }
    }
}


// MARK: - Store

/// Owns the registered repository roots and their worktree snapshots.
///
/// All mutations happen on the main actor. Repository root paths are persisted
/// as a JSON-encoded `[String]` in `UserDefaults`; nothing is written to
/// `cmux.json`, repo-local config, or `.git/info/exclude`. Every git operation
/// goes through `git` on the CLI via the injected ``CommandRunning`` seam —
/// there is no in-process libgit2 and no third-party registration.
@MainActor
final class GitWorktreeStore: ObservableObject {
    /// Current repository snapshots, ordered by registration. Each carries its
    /// own `worktrees`, `lastError`, and `isRefreshing` so the view can render
    /// per-repository state without touching the store.
    @Published private(set) var repositories: [GitWorktreeRepository] = []

    /// `true` while a `refreshAll()` pass is in flight.
    @Published private(set) var isRefreshing: Bool = false

    /// Transient, user-facing failure message for the most recent add/create
    /// attempt (e.g. "selected folder is not a git repository"). Cleared at the
    /// start of the next such operation.
    @Published private(set) var lastErrorMessage: String?

    /// UserDefaults key holding the JSON-encoded `[String]` of repository roots.
    static let repositoryRootsDefaultsKey = "cmux.gitWorktrees.repositoryRoots"

    private let defaults: UserDefaults
    private let commandRunner: any CommandRunning
    private let gitTimeout: TimeInterval

    /// Creates a worktree store.
    ///
    /// - Parameters:
    ///   - defaults: The `UserDefaults` holding the persisted repository roots.
    ///   - commandRunner: The ``CommandRunning`` seam that spawns `git`. Inject
    ///     a fake in tests so they never spawn a real process.
    ///   - gitTimeout: The finite deadline (seconds) for each `git` invocation;
    ///     the deadline is the cancellation safety net for a dropped call.
    init(
        defaults: UserDefaults = .standard,
        commandRunner: any CommandRunning = CommandRunner(),
        gitTimeout: TimeInterval = 30
    ) {
        self.defaults = defaults
        self.commandRunner = commandRunner
        self.gitTimeout = gitTimeout
        Task { await loadPersistedRepositories() }
    }

    // MARK: - Public API

    /// Resolves `path` to its git toplevel, registers it (idempotent), and
    /// refreshes its worktrees. Returns `false` (and sets `lastErrorMessage`)
    /// when `path` is not inside a git repository.
    @discardableResult
    func addRepository(path: String) async -> Bool {
        lastErrorMessage = nil
        guard let root = await resolveRepositoryRoot(path: path) else {
            lastErrorMessage = String(
                localized: "gitWorktrees.error.noRepository",
                defaultValue: "The selected folder is not a git repository."
            )
            return false
        }
        if let existingIndex = repositories.firstIndex(where: { $0.rootPath == root }) {
            repositories[existingIndex].isRefreshing = true
            await refresh(repositoryRoot: root)
            return true
        }
        repositories.append(GitWorktreeRepository(rootPath: root, isRefreshing: true))
        persistRepositoryRoots()
        await refresh(repositoryRoot: root)
        return true
    }

    /// Drops a repository registration. Worktrees on disk are left untouched —
    /// this only removes the tracked root and its snapshot.
    func removeRepository(rootPath: String) async {
        guard repositories.contains(where: { $0.rootPath == rootPath }) else { return }
        repositories.removeAll(where: { $0.rootPath == rootPath })
        persistRepositoryRoots()
    }

    /// Re-lists worktrees for every registered repository.
    func refreshAll() async {
        isRefreshing = true
        let roots = repositories.map(\.rootPath)
        for root in roots {
            await refresh(repositoryRoot: root)
        }
        isRefreshing = false
    }

    /// Creates a new worktree on a fresh branch (`worktree add -b`) and
    /// refreshes the repository. When `destinationPath` is nil/empty the store
    /// uses the default sibling path (see ``defaultWorktreeDestination``).
    /// Returns the absolute path of the created worktree.
    @discardableResult
    func createWorktree(
        repositoryRoot: String,
        branchName: String,
        destinationPath: String?
    ) async throws -> String {
        lastErrorMessage = nil
        let trimmedBranch = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBranch.isEmpty else {
            throw GitWorktreeError.invalidBranchName
        }
        let trimmedDestination = destinationPath?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedDestination = trimmedDestination
            .flatMap { $0.isEmpty ? nil : $0 }
        ?? Self.defaultWorktreeDestination(repositoryRoot: repositoryRoot, branchName: trimmedBranch)

        let result = await runGit(
            in: repositoryRoot,
            arguments: ["worktree", "add", "-b", trimmedBranch, resolvedDestination, "HEAD"]
        )
        guard result.status == 0 else {
            let error = GitWorktreeError.commandFailed(
                stderr: result.stderr,
                fallback: String(
                    localized: "gitWorktrees.error.createFailed",
                    defaultValue: "Could not create worktree."
                )
            )
            lastErrorMessage = error.errorDescription
            throw error
        }
        await refresh(repositoryRoot: repositoryRoot)
        return resolvedDestination
    }

    /// Removes a worktree (`worktree remove`), prunes, and refreshes. The main
    /// worktree cannot be removed this way; callers should guard on
    /// `GitWorktreeEntry.isMainWorktree`.
    func removeWorktree(repositoryRoot: String, path: String, force: Bool = false) async throws {
        lastErrorMessage = nil
        var arguments = ["worktree", "remove"]
        if force { arguments.append("--force") }
        arguments.append(path)
        let result = await runGit(in: repositoryRoot, arguments: arguments)
        guard result.status == 0 else {
            let error = GitWorktreeError.commandFailed(
                stderr: result.stderr,
                fallback: String(
                    localized: "gitWorktrees.error.removeFailed",
                    defaultValue: "Could not remove worktree."
                )
            )
            lastErrorMessage = error.errorDescription
            throw error
        }
        _ = await runGit(in: repositoryRoot, arguments: ["worktree", "prune"])
        await refresh(repositoryRoot: repositoryRoot)
    }

    /// Prunes stale worktree metadata (`worktree prune`) and refreshes.
    func pruneWorktrees(repositoryRoot: String) async {
        _ = await runGit(in: repositoryRoot, arguments: ["worktree", "prune"])
        await refresh(repositoryRoot: repositoryRoot)
    }

    /// Refreshes one repository's worktree list. Safe to call for a root that is
    /// no longer a valid repository: the snapshot is cleared and `lastError` set.
    func refresh(repositoryRoot: String) async {
        guard let index = repositories.firstIndex(where: { $0.rootPath == repositoryRoot }) else {
            return
        }
        repositories[index].isRefreshing = true
        let result = await runGit(
            in: repositoryRoot,
            arguments: ["worktree", "list", "--porcelain"],
            nonLocking: true
        )
        guard result.status == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            repositories[index].worktrees = []
            repositories[index].lastError = detail.isEmpty
                ? String(localized: "gitWorktrees.error.fetchFailed", defaultValue: "Could not list worktrees.")
                : detail
            repositories[index].isRefreshing = false
            return
        }
        repositories[index].worktrees = Self.parseWorktreeList(
            result.stdout,
            repositoryRoot: repositoryRoot
        )
        repositories[index].lastError = nil
        repositories[index].isRefreshing = false
    }

    // MARK: - Default destination

    /// The default worktree destination: a sibling directory of the repository
    /// root named `<repoName>-<branchName>`. Pure/nonisolated so the
    /// create-worktree sheet can compute a live preview without the store.
    nonisolated static func defaultWorktreeDestination(
        repositoryRoot: String,
        branchName: String
    ) -> String {
        let rootURL = URL(fileURLWithPath: repositoryRoot, isDirectory: true).standardizedFileURL
        let parent = rootURL.deletingLastPathComponent()
        let safeBranch = branchName.replacingOccurrences(of: "/", with: "-")
        let name = "\(rootURL.lastPathComponent)-\(safeBranch)"
        return parent.appendingPathComponent(name, isDirectory: true).path
    }

    // MARK: - Persistence

    private func persistRepositoryRoots() {
        let roots = repositories.map(\.rootPath)
        if let data = try? JSONEncoder().encode(roots) {
            defaults.set(data, forKey: Self.repositoryRootsDefaultsKey)
        } else {
            // Defensive fallback so a malformed encoder can never lose roots.
            defaults.set(roots, forKey: Self.repositoryRootsDefaultsKey)
        }
    }

    private func loadPersistedRepositories() async {
        var roots: [String] = []
        if let data = defaults.data(forKey: Self.repositoryRootsDefaultsKey),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            roots = decoded
        } else if let array = defaults.stringArray(forKey: Self.repositoryRootsDefaultsKey) {
            roots = array
        }

        var seen = Set<String>()
        var loaded: [GitWorktreeRepository] = []
        for root in roots {
            let standardized = URL(
                fileURLWithPath: root,
                isDirectory: true
            ).standardizedFileURL.path
            guard !seen.contains(standardized) else { continue }
            seen.insert(standardized)
            loaded.append(GitWorktreeRepository(rootPath: standardized, isRefreshing: true))
        }
        guard !loaded.isEmpty else {
            repositories = []
            return
        }
        repositories = loaded
        // Validate each root against git without blocking; invalid roots land
        // with a `lastError` snapshot rather than disappearing silently.
        for repository in loaded {
            await refresh(repositoryRoot: repository.rootPath)
        }
    }

    // MARK: - Git execution

    /// The captured outcome of one `git` invocation, shaped for the store's
    /// call sites. `status == 0` is the success gate; `stderr` carries the
    /// diagnostic on failure.
    private struct GitCommandOutput: Sendable, Equatable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Runs `git <arguments>` in `directory` via the injected
    /// ``CommandRunning`` seam with a finite deadline.
    ///
    /// `nonLocking` runs `/usr/bin/env GIT_OPTIONAL_LOCKS=0 git …` so a
    /// concurrent `git` in another surface cannot block the worktree listing;
    /// mutating commands (`worktree add`/`remove`/`prune`) pass
    /// `nonLocking: false` and run `git …` directly. A cancelled task
    /// short-circuits before spawning, and the deadline bounds any in-flight
    /// invocation even if the caller never cancels.
    private func runGit(
        in directory: String,
        arguments: [String],
        nonLocking: Bool = false
    ) async -> GitCommandOutput {
        if Task.isCancelled {
            return GitCommandOutput(status: -1, stdout: "", stderr: "cancelled")
        }
        let executable: String
        let fullArguments: [String]
        if nonLocking {
            executable = "/usr/bin/env"
            fullArguments = ["GIT_OPTIONAL_LOCKS=0", "git"] + arguments
        } else {
            executable = "git"
            fullArguments = arguments
        }
        let result = await commandRunner.run(
            directory: directory,
            executable: executable,
            arguments: fullArguments,
            timeout: gitTimeout
        )
        if result.timedOut {
            return GitCommandOutput(
                status: -1,
                stdout: result.stdout ?? "",
                stderr: "git command timed out after \(gitTimeout) seconds"
            )
        }
        return GitCommandOutput(
            status: result.exitStatus ?? -1,
            stdout: result.stdout ?? "",
            stderr: result.stderr ?? result.executionError ?? ""
        )
    }

    // MARK: - Git resolution & parsing

    private func resolveRepositoryRoot(path: String) async -> String? {
        let result = await runGit(
            in: path,
            arguments: ["rev-parse", "--show-toplevel"],
            nonLocking: true
        )
        guard result.status == 0 else { return nil }
        let raw = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        return URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL.path
    }

    /// Parses `git worktree list --porcelain` output into entries. Tolerant of
    /// unknown porcelain fields (e.g. `cwd`) added by newer git versions.
    static func parseWorktreeList(
        _ output: String,
        repositoryRoot: String
    ) -> [GitWorktreeEntry] {
        let normalizedRoot = URL(
            fileURLWithPath: repositoryRoot,
            isDirectory: true
        ).standardizedFileURL.path

        var entries: [GitWorktreeEntry] = []
        var path: String?
        var head: String?
        var branch: String?
        var isDetached = false
        var isBare = false
        var isLocked = false
        var lockedReason: String?

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
            let normalizedPath = URL(
                fileURLWithPath: pathValue,
                isDirectory: true
            ).standardizedFileURL.path
            entries.append(GitWorktreeEntry(
                path: pathValue,
                head: (head?.isEmpty == false) ? head : nil,
                branch: shortBranch,
                isDetached: isDetached,
                isBare: isBare,
                isMainWorktree: normalizedPath == normalizedRoot,
                lockedReason: isLocked ? (lockedReason ?? "") : nil
            ))
            path = nil
            head = nil
            branch = nil
            isDetached = false
            isBare = false
            isLocked = false
            lockedReason = nil
        }

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.isEmpty {
                flush()
                continue
            }
            if line.hasPrefix("worktree ") {
                // A new entry begins; flush any unflushed entry defensively.
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
            }
            // Unknown fields (e.g. `cwd`) are ignored.
        }
        flush()
        return entries
    }
}
